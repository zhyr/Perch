import Foundation
import Combine
import AppKit
import Carbon
import ServiceManagement

// MARK: - 列表 VM

struct ChunkRowVM: Identifiable {
    let chunk: ChunkRec
    var id: String { chunk.id }
    let preview: String
    let caption: String

    init(chunk: ChunkRec) {
        self.chunk = chunk
        preview = PreviewUtil.makePreview(chunk.content)
        var parts: [String] = ["来自 \(chunk.sourceApp)"]
        parts.append("更新 \(TimeUtil.displayTime(chunk.updatedAtMs))")
        if let lc = chunk.lastCopiedMs {
            parts.append("复于 \(TimeUtil.displayTime(lc))")
        }
        caption = parts.joined(separator: " · ")
    }
}

struct TreeRowVM: Identifiable {
    let tree: TreeRec
    var id: String { tree.id }
    let titleText: String?
    let preview: String
    let fullText: String
    let caption: String
    let chunks: [ChunkRowVM]
    /// 树级标签 + 分段标签（分段标签原样并入展示）
    var tags: [String] = []

    init(tree: TreeRec) {
        self.tree = tree
        titleText = tree.title.isEmpty ? nil : tree.title
        let latest = tree.latest
        preview = latest.map { PreviewUtil.makePreview($0.content) } ?? "(空)"
        fullText = latest?.content ?? ""
        var parts: [String] = []
        if let lc = latest, !lc.sourceApp.isEmpty {
            parts.append("来自 \(lc.sourceApp)")
        }
        parts.append("\(tree.chunks.count) 段")
        parts.append("更新 \(TimeUtil.displayTime(tree.updatedAtMs))")
        caption = parts.joined(separator: " · ")
        // UI 展示按创建时间正序，新追加的 chunk 出现在最后
        chunks = tree.chunks
            .sorted { $0.createdAtMs < $1.createdAtMs }
            .map { ChunkRowVM(chunk: $0) }
    }
}

struct SearchResultVM: Identifiable {
    let result: SearchResult
    var id: String { result.chunkID }
    let treeTitle: String
    let chunkPreview: String
    let caption: String
    let isImage: Bool
    let isNote: Bool
    /// 该条命中的树标签 + 分段标签（去重，树在前）
    let tags: [String]

    init(result: SearchResult, tags: [String] = []) {
        self.result = result
        treeTitle = result.treeTitle.isEmpty
            ? PreviewUtil.makePreview(result.content)
            : result.treeTitle
        chunkPreview = PreviewUtil.makePreview(result.content)
        caption = "\(result.sourceApp) · 分段更新 \(TimeUtil.displayTime(result.chunkUpdatedAtMs))"
        isImage = result.isImage
        isNote = result.treeKind == "note"
        self.tags = tags
    }
}

// MARK: - 分页单位

struct PageUnit {
    let dayKey: String
    let dayStartMs: Int64
    let dayEndMs: Int64
    let dayCount: Int
    let offsetInDay: Int
    /// 该屏第一条在「已去重列表」中的全局下标（列表最多 99 条，直接内存切片，不再回查数据库）
    let globalOffset: Int
    let count: Int
    let pageNo: Int
    let pagesInDay: Int
}

struct DayBucket {
    let key: String
    let startMs: Int64
    let endMs: Int64
    var count: Int
}

/// 日期跳转用的目录项（每个有记录的日子一项，含跨屏信息）
struct DayJumpItem: Identifiable {
    var id: String { dayKey }
    let dayKey: String
    let label: String
    let count: Int
    let pageCount: Int
}

// MARK: - 视图模式

enum AppViewMode: Equatable {
    case list
    case newRecord
    case searchResults
    case settings
    case clipboardHistory
    case tagCloud
    case tagResults
}

// MARK: - 应用状态

/// 全部方法预期在主线程 / 主 RunLoop 上调用
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private(set) var store: DataStore?
    /// 笔记列表：全局页码翻页（0 基，当前第 page+1 页）
    private var notePage = 0
    private var latestMetas: [(id: String, createdAtMs: Int64, updatedAtMs: Int64)] = []

    @Published var rows: [TreeRowVM] = []
    /// 笔记列表页码标题：第 X / N 页
    @Published var dayTitle = "暂无笔记"
    @Published var dayMetaText = ""
    @Published var noteTotal = 0
    var notePageCount: Int { max(1, (noteTotal + Config.pageSize - 1) / Config.pageSize) }
    @Published var hasNewer = false
    @Published var hasOlder = false
    @Published var expandedTreeID: String?
    @Published var highlightedChunkID: String?
    @Published var lastToast: String?
    /// 数据变更导致列表重排后，需要把某条记录滚动到可视区域（视图消费后应调用 consumeScrollTarget 置空）
    @Published var scrollTargetTreeID: String?
    /// 列表滚动进行中：UI 据此临时抑制悬停高亮/预览，避免滚动时内容抖动
    @Published var scrollInProgress = false

    @Published var viewMode: AppViewMode = .list
    @Published var previousViewMode: AppViewMode? = nil
    /// 任一自定义弹层 / 模式激活（删除确认、丢弃草稿、日期跳转、多选）。
    /// AppDelegate 的 ESC 监听据此放行按键，避免弹层期按 ESC 把整个面板藏掉。
    @Published var overlayActive = false
    @Published var searchResults: [SearchResultVM] = []

    // MARK: - 剪切板历史（按天分屏，列表只展示去重后的最近 99 条）
    @Published var clipboardHistoryItems: [ClipboardHistoryItem] = []
    /// 库里剪贴板历史的总条数（全部保留，不删数据）
    @Published var clipboardHistoryTotal = 0
    /// 当前列表实际展示的去重后条数（≤ Config.clipboardRecentLimit）
    @Published var clipboardListedCount = 0
    /// 去重后的最近列表（最多 99 条）；翻页只在这份数据里切片
    private var clipboardRecentItems: [ClipboardHistoryItem] = []
    @Published var clipboardHasNewer = false
    @Published var clipboardHasOlder = false
    @Published var clipboardDayTitle = ""
    @Published var clipboardDayMetaText = ""
    /// 当前屏所在日期（yyyy-MM-dd），供剪贴板历史日期跳转目录标记当前位置
    @Published var clipboardCurrentDayKey = ""
    private var clipboardUnits: [PageUnit] = []
    private var clipboardCursor = 0

    /// 剪贴板历史的日期跳转目录（最新在上，每项一个“有记录的日子”）
    @Published var dayJumpItems: [DayJumpItem] = []

    /// 列表内单个记录的删除是否需要二次确认（默认开启：删除不可恢复，先确认再执行）
    @Published var requireDeleteConfirm = true

    /// 开机自启动（macOS 13+ 使用 SMAppService.mainApp）
    @Published var launchAtLoginEnabled = false

    /// 是否自动记录外部剪贴板变化（关闭后只保留手动新建 / 追加分段）
    @Published var autoRecordClipboard = true

    /// 全局快捷键：keyCode 与 Carbon 修饰符
    @Published var shortcutKeyCode: UInt32 = UInt32(kVK_ANSI_P)
    @Published var shortcutModifiers: UInt32 = UInt32(controlKey | shiftKey)

    /// 快捷键被触发时执行的闭包（由 AppDelegate 注入）
    var shortcutAction: (() -> Void)?

    private var toastWork: DispatchWorkItem?

    private init() {
        let defaults = UserDefaults.standard
        if let code = defaults.object(forKey: "shortcutKeyCode") as? NSNumber {
            shortcutKeyCode = code.uint32Value
        }
        if let mods = defaults.object(forKey: "shortcutModifiers") as? NSNumber {
            shortcutModifiers = mods.uint32Value
        }
        if defaults.object(forKey: "deleteRequiresConfirm") != nil {
            requireDeleteConfirm = defaults.bool(forKey: "deleteRequiresConfirm")
        }
        if defaults.object(forKey: "autoRecordClipboard") != nil {
            autoRecordClipboard = defaults.bool(forKey: "autoRecordClipboard")
        }
        launchAtLoginEnabled = Self.launchAtLoginStatus()
        // 启动即触发迁移：把旧版明文 API Key 从 UserDefaults 搬进 Keychain
        _ = Self.cloudAPIKey()
    }

    /// 更新“删除需二次确认”设置
    func setRequireDeleteConfirm(_ value: Bool) {
        requireDeleteConfirm = value
        UserDefaults.standard.set(value, forKey: "deleteRequiresConfirm")
    }

    // MARK: - 开机自启动

    /// 查询 SMAppService 的注册状态
    private static func launchAtLoginStatus() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard #available(macOS 13.0, *) else {
            showToast("macOS 13 以下版本不支持该接口")
            return
        }
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = Self.launchAtLoginStatus()
            showToast(launchAtLoginEnabled ? "已设置开机自启动" : "已取消开机自启动")
        } catch {
            launchAtLoginEnabled = Self.launchAtLoginStatus()
            showToast("自启动设置失败：\(error.localizedDescription)")
            NSLog("setLaunchAtLogin error: \(error)")
        }
    }

    // MARK: - 自动记录剪贴板

    func setAutoRecordClipboard(_ value: Bool) {
        autoRecordClipboard = value
        UserDefaults.standard.set(value, forKey: "autoRecordClipboard")
        showToast(value ? "已开启自动记录剪贴板" : "已关闭自动记录剪贴板，可手动新建/追加")
    }

    func boot() throws {
        migrateAICloudDefaultsIfNeeded()
        // 若用户曾选择自定义数据目录（iCloud Drive / 同步盘），先恢复
        AppPaths.restoreConfiguredRoot()
        store = try DataStore()
        reload()
        // 启动后默认落在剪贴板历史；笔记视图仍可通过页面内「返回」进入
        showClipboardHistory()
    }

    /// AI 云端默认迁移：旧默认（OpenAI / gpt-4o-mini）→ 阅粒 Yueli AI（freemodel）。
    /// 仅当存储值仍等于旧默认（即用户从未定制）时替换；自定义值不动。
    private func migrateAICloudDefaultsIfNeeded() {
        let d = UserDefaults.standard
        if d.string(forKey: "ai.cloud.base") == "https://api.openai.com/v1" {
            d.set("https://yueli.com/api/yueliai/v1/completions", forKey: "ai.cloud.base")
        }
        if d.string(forKey: "ai.cloud.model") == "gpt-4o-mini" {
            d.set("freemodel", forKey: "ai.cloud.model")
        }
    }

    // MARK: - 存储与 iCloud 同步

    var storageLabel: String { AppPaths.storageModeLabel }
    var storagePathDisplay: String { AppPaths.rootURL.path }
    var isCustomStorage: Bool { AppPaths.isUsingCustomRoot }

    /// 弹窗让用户选择数据文件夹（建议指向 iCloud Drive 或其它同步盘）
    func chooseSyncStorageFolder() {
        guard store != nil else {
            showToast("数据尚未就绪")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择数据文件夹"
        panel.prompt = "使用此文件夹"
        panel.message = "栖痕会把数据库与 Markdown 归档存放在所选文件夹中。\n\n跨设备同步：在每台 Mac 上选择同一个 iCloud Drive（或其它同步盘）文件夹即可自动同步。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try applyStorageRoot(to: url)
            showToast("数据已切换到：\(url.lastPathComponent)")
        } catch {
            showErrorAlert(title: "无法切换数据文件夹", message: "\(error)")
        }
    }

    /// 恢复为本机默认存储（~/Documents/Perch）
    func restoreLocalStorage() {
        do {
            try applyStorageRoot(to: AppPaths.localDefaultRootURL)
            showToast("已恢复为本机存储")
        } catch {
            showErrorAlert(title: "无法恢复本机存储", message: "\(error)")
        }
    }

    /// 把当前数据目录迁移到 target（或直接采用其中已存在的栖痕数据）。
    ///
    /// 迁移规则（避免误删数据）：
    /// 1. target 是空目录/尚不存在 → 把当前整个目录移过去；
    /// 2. target 已有 recordtree.sqlite（其它设备的同步数据）→ 直接切换采用，
    ///    本机旧目录原样保留（手动删除即可）；
    /// 3. target 非空且不含栖痕数据 → 报错，防止把数据混入无关目录。
    private func applyStorageRoot(to target: URL) throws {
        let fm = FileManager.default
        let stdTarget = target.standardizedFileURL
        let cur = AppPaths.rootURL.standardizedFileURL

        if cur.path == stdTarget.path {
            AppPaths.saveConfiguredRoot(stdTarget)
            return
        }

        let targetExists = fm.fileExists(atPath: stdTarget.path)
        let targetDB = stdTarget.appendingPathComponent("recordtree.sqlite")
        let targetHasPerchData = fm.fileExists(atPath: targetDB.path)
        var targetEmpty = false
        if targetExists && !targetHasPerchData {
            let items = try fm.contentsOfDirectory(atPath: stdTarget.path)
            targetEmpty = items.isEmpty
        }
        guard targetHasPerchData || !targetExists || targetEmpty else {
            throw StorageError.targetNotEmpty
        }

        // 先关闭旧连接，确保 WAL 等已合并落盘后再移动
        try? store?.close()
        store = nil

        do {
            if !targetHasPerchData, fm.fileExists(atPath: cur.path), cur.path != stdTarget.path {
                if targetExists { try fm.removeItem(at: stdTarget) } // 已确认是空目录
                try fm.moveItem(at: cur, to: stdTarget)
            }
            AppPaths.configureRoot(stdTarget)
            AppPaths.saveConfiguredRoot(stdTarget)
            try AppPaths.ensureDirs()
            store = try DataStore()
            reload()
            expandedTreeID = nil
            highlightedChunkID = nil
        } catch {
            // 回滚：把刚移走的目录移回原处，恢复旧配置并重开旧库
            if !targetHasPerchData,
               cur.path != stdTarget.path,
               fm.fileExists(atPath: stdTarget.path),
               !fm.fileExists(atPath: cur.path) {
                try? fm.moveItem(at: stdTarget, to: cur)
            }
            AppPaths.configureRoot(cur)
            store = try? DataStore()
            reload()
            throw error
        }
    }

    /// 同步盘上的数据库被其它设备更新：关掉旧连接、重新打开并刷新界面。
    /// 打开失败时不再把已 close 的旧连接装回去（之后所有查询都会失败，列表变成空白）。
    func reloadFromRemoteChange() {
        guard store != nil else { return }
        guard DataStore.databaseFileIsReady(at: AppPaths.dbURL) else {
            NSLog("skip remote reload: database file not ready")
            return
        }
        do {
            try store?.close()
        } catch {
            NSLog("close before remote reload failed: \(error)")
        }
        store = nil
        do {
            store = try DataStore()
            reload()
            refreshClipboardHistoryIfVisible()
            showToast("已同步其它设备的最新数据")
        } catch {
            NSLog("reload after remote change failed: \(error)")
            store = try? DataStore()
            if store != nil {
                reload()
                refreshClipboardHistoryIfVisible()
            }
            showToast("云端数据重载失败")
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    enum StorageError: LocalizedError {
        case targetNotEmpty
        var errorDescription: String? {
            "所选文件夹已存在其它内容且不是栖痕的数据目录。请换一个空文件夹，或选择之前放置过栖痕数据的文件夹。"
        }
    }

    // MARK: - 剪贴板事件

    func handleExternalCopy(content: String, source: String) {
        guard autoRecordClipboard, let store, !content.isEmpty else { return }
        do {
            let at = TimeUtil.msNow()
            let info = try store.performExternalCopy(content: content, source: source, atMs: at)
            // 处理规则：先按正常流程保存入库，随后对“过短复制”做清理（撤掉刚入库的分段）。
            // 不直接改写用户剪贴板，避免干扰自我复制判定与第三方粘贴体验。
            if CaptureFilter.isTooShort(content) {
                cleanUpTooShort(info, content: content, source: source, atMs: at)
                return
            }
            archive(info: info, kind: "复制自外部", content: content, source: source, atMs: at)
            // 剪贴板采集只进「剪贴板历史」，不再触发笔记列表 reload（列表不展示 clipboard 树）
            refreshClipboardHistoryIfVisible()
        } catch {
            NSLog("handleExternalCopy error: \(error)")
        }
    }

    /// 撤销一次“过短复制”的入库：删除对应分段；若该分段是树上唯一分段则整树一并删除。
    /// 事件日志不写入“复制”记录（本就不该成为历史），只重写受影响天归档。
    /// 仅涉及 clipboard 树：无需 reload 笔记列表，正在浏览剪贴板历史时刷新该页。
    private func cleanUpTooShort(_ info: MutationInfo, content: String, source: String, atMs: Int64) {
        guard let store else { return }
        do {
            guard let deletion = try store.deleteChunk(info.chunkID ?? "") else {
                refreshClipboardHistoryIfVisible()
                return
            }
            for day in deletion.affectedDays {
                try? store.rewriteDailyMarkdown(dayKey: day)
            }
            if expandedTreeID == deletion.treeID { expandedTreeID = nil }
            refreshClipboardHistoryIfVisible()
            NSLog("已按规则清理过短复制（<\(Config.minCaptureTextLen) 字）：from \(source), content=\(content)")
        } catch {
            NSLog("cleanUpTooShort error: \(error)")
        }
    }

    /// 正在浏览「剪贴板历史」时重建分桶并尽量停留在当前日期与页码
    private func refreshClipboardHistoryIfVisible() {
        guard viewMode == .clipboardHistory else { return }
        let curPage = clipboardUnits.indices.contains(clipboardCursor)
            ? clipboardUnits[clipboardCursor].pageNo
            : 0
        rebuildClipboardUnits(keepingDay: clipboardCurrentDayKey, keepingPageNo: curPage)
    }

    func handleSelfCopy(chunkID: String) {
        guard let store else { return }
        do {
            let at = TimeUtil.msNow()
            guard let r = try store.performSelfCopy(chunkID: chunkID, atMs: at) else { return }
            archive(info: r.info, kind: "复制自\(AppInfo.zhName)（仅更新时间）", content: r.content, source: AppInfo.zhName, atMs: at)
            reload()
            relocateIfNeeded(r.info)
        } catch {
            NSLog("handleSelfCopy error: \(error)")
        }
    }

    // MARK: - 图片剪贴板

    /// 外部图片复制：转 PNG 保存到数据目录，并生成展示文字记录
    func handleExternalImageCopy(rawImage: Data, source: String) {
        guard autoRecordClipboard, let store, let img = ClipboardImage.decodePNG(rawImage) else { return }
        do {
            let at = TimeUtil.msNow()
            let rel = try ClipboardImage.savePNG(
                img.pngData,
                dayKey: TimeUtil.dayKey(at),
                atMs: at
            )
            let text = Self.imageChunkText(width: img.width, height: img.height, bytes: img.pngData.count)
            let info = try store.performExternalImageCopy(content: text, attachment: rel, source: source, atMs: at)
            archive(info: info, kind: "复制图片（外部）", content: text, source: source, atMs: at)
            // 同上：只影响剪贴板历史，无需 reload 笔记列表
            refreshClipboardHistoryIfVisible()
        } catch {
            NSLog("handleExternalImageCopy error: \(error)")
        }
    }

    /// 图片 chunk 的展示文字
    static func imageChunkText(width: Int, height: Int, bytes: Int) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "[图片] \(width)×\(height) · \(fmt.string(fromByteCount: Int64(bytes)))"
    }

    // MARK: - 视图切换

    func showNewRecord() {
        viewMode = .newRecord
    }

    func cancelNewRecord() {
        viewMode = .list
    }

    func showSearch() {
        viewMode = .searchResults
        searchResults = []
    }

    func exitSearch() {
        viewMode = .list
        searchResults = []
    }

    func showSettings() {
        if viewMode != .settings {
            previousViewMode = viewMode
        }
        viewMode = .settings
    }

    /// 从设置页返回，回到进入设置之前的页面；若未记录则回主列表
    func backFromSettings() {
        viewMode = previousViewMode ?? .list
        previousViewMode = nil
    }

    /// 返回主列表页（通用）
    func returnToList() {
        viewMode = .list
        previousViewMode = nil
    }

    // MARK: - 剪切板历史

    func showClipboardHistory() {
        if viewMode != .clipboardHistory {
            previousViewMode = viewMode
        }
        viewMode = .clipboardHistory
        rebuildClipboardUnits(keepingDay: nil)
    }

    func exitClipboardHistory() {
        viewMode = previousViewMode ?? .list
        previousViewMode = nil
    }

    /// 重建剪贴板历史的按天分桶分页结构。
    /// 数据源 = 按内容去重后的最近 99 条（只按时间倒序取有限行，不再扫全表）。
    /// keepingDay：数据变化后希望停留的日期（不存在则回落到最新一屏）。
    /// keepingPageNo：希望停留的当天页码（0 基），不传则默认停留在该天第 1 屏。
    private func rebuildClipboardUnits(keepingDay keepDayKey: String?, keepingPageNo: Int = 0) {
        guard let store else { return }
        let items: [ClipboardHistoryItem]
        do {
            items = try store.fetchClipboardRecentUnique(limit: Config.clipboardRecentLimit)
        } catch {
            // 查询失败时保留当前列表。原先用 try? 得到空数组，界面会显示成“暂无历史”。
            NSLog("rebuildClipboardUnits error: \(error)")
            return
        }
        clipboardRecentItems = items
        clipboardListedCount = items.count
        // 库里总条数用 COUNT 查询（不拉全量），列表只展示最近 99 条去重记录
        clipboardHistoryTotal = (try? store.clipboardHistoryCount()) ?? items.count

        var buckets: [DayBucket] = []
        for item in items {
            let range = TimeUtil.dayRangeMs(item.updatedAtMs)
            if var last = buckets.last, last.startMs == range.start {
                last.count += 1
                buckets[buckets.count - 1] = last
            } else {
                buckets.append(
                    DayBucket(key: TimeUtil.dayKey(range.start), startMs: range.start, endMs: range.end, count: 1)
                )
            }
        }
        dayJumpItems = buckets.map { b in
            let pages = max(1, (b.count + Config.pageSize - 1) / Config.pageSize)
            return DayJumpItem(
                dayKey: b.key,
                label: TimeUtil.dayLabel(ms: b.startMs),
                count: b.count,
                pageCount: pages
            )
        }

        var newUnits: [PageUnit] = []
        var globalOffset = 0
        for b in buckets {
            let pages = max(1, (b.count + Config.pageSize - 1) / Config.pageSize)
            for p in 0..<pages {
                let off = p * Config.pageSize
                let cnt = min(Config.pageSize, b.count - off)
                newUnits.append(
                    PageUnit(
                        dayKey: b.key,
                        dayStartMs: b.startMs,
                        dayEndMs: b.endMs,
                        dayCount: b.count,
                        offsetInDay: off,
                        globalOffset: globalOffset + off,
                        count: cnt,
                        pageNo: p,
                        pagesInDay: pages
                    )
                )
            }
            globalOffset += b.count
        }
        clipboardUnits = newUnits

        // 尽量停留在原来的天 + 原来的页码；若天数或页码已不存在，则回退到合理位置
        if let keep = keepDayKey, !keep.isEmpty, !clipboardUnits.isEmpty {
            let targetPage = max(0, keepingPageNo)
            if let idx = clipboardUnits.firstIndex(where: { $0.dayKey == keep && $0.pageNo == targetPage }) {
                // 精确命中：天 + 页码都还在
                clipboardCursor = idx
            } else if let firstOfDay = clipboardUnits.firstIndex(where: { $0.dayKey == keep }) {
                // 当天还在，但目标页码不存在（如当天记录数变少），回退到该天最后一页
                let lastOfDay = clipboardUnits.lastIndex(where: { $0.dayKey == keep }) ?? firstOfDay
                clipboardCursor = lastOfDay
            } else if let firstEarlier = clipboardUnits.firstIndex(where: { $0.dayKey < keep }) {
                // 目标天不存在（如该天记录被清空），跳到紧邻的更早一天的首页
                clipboardCursor = firstEarlier
            } else {
                // 目标天比所有现存天都还老 → 跳到最老一屏
                clipboardCursor = clipboardUnits.count - 1
            }
        } else {
            clipboardCursor = 0
        }
        // 边界保护
        if clipboardCursor >= clipboardUnits.count {
            clipboardCursor = max(0, clipboardUnits.count - 1)
        }
        if clipboardCursor < 0 {
            clipboardCursor = 0
        }
        loadClipboardPage()
    }

    private func loadClipboardPage() {
        guard !clipboardUnits.isEmpty, !clipboardRecentItems.isEmpty else {
            clipboardHistoryItems = []
            clipboardDayTitle = ""
            clipboardDayMetaText = ""
            clipboardCurrentDayKey = ""
            clipboardHasNewer = false
            clipboardHasOlder = false
            return
        }
        let u = clipboardUnits[clipboardCursor]
        // 翻页只在已去重、已截断的 99 条里切片，不再回查数据库
        let start = u.globalOffset
        let end = min(start + u.count, clipboardRecentItems.count)
        clipboardHistoryItems = start < end ? Array(clipboardRecentItems[start..<end]) : []
        if clipboardHistoryItems.isEmpty {
            clipboardHasNewer = clipboardCursor > 0
            clipboardHasOlder = clipboardCursor < clipboardUnits.count - 1
            return
        }
        clipboardCurrentDayKey = u.dayKey
        clipboardDayTitle = TimeUtil.titleDate(ms: u.dayStartMs)
        clipboardDayMetaText = u.pagesInDay > 1
            ? "共 \(u.dayCount) 条 · 第 \(u.pageNo + 1)/\(u.pagesInDay) 屏"
            : "共 \(u.dayCount) 条"
        clipboardHasNewer = clipboardCursor > 0
        clipboardHasOlder = clipboardCursor < clipboardUnits.count - 1
    }

    // MARK: - 剪贴板历史翻页

    func goClipboardNewer() {
        guard clipboardCursor > 0 else { return }
        clipboardCursor -= 1
        loadClipboardPage()
    }

    func goClipboardOlder() {
        guard clipboardCursor < clipboardUnits.count - 1 else { return }
        clipboardCursor += 1
        loadClipboardPage()
    }

    /// 回到最新记录所在的一屏
    func goClipboardNewest() {
        guard clipboardCursor > 0 else { return }
        clipboardCursor = 0
        loadClipboardPage()
    }

    /// 跳到指定日期的第一屏（日期目录项来自 dayJumpItems）
    func jumpClipboardToDay(_ dayKey: String) {
        guard let idx = clipboardUnits.firstIndex(where: { $0.dayKey == dayKey && $0.pageNo == 0 }) else {
            return
        }
        clipboardCursor = idx
        loadClipboardPage()
    }

    /// 复制剪切板历史中的某条记录
    func copyClipboardItem(_ item: ClipboardHistoryItem) {
        if item.isImage {
            // 图片：尝试回写原图
            if let url = AppPaths.attachmentURL(relativePath: item.attachment),
               let png = try? Data(contentsOf: url) {
                let pbItem = NSPasteboardItem()
                guard pbItem.setData(png, forType: .png) else {
                    showToast("复制失败")
                    return
                }
                if let img = NSImage(data: png), let tiff = img.tiffRepresentation {
                    pbItem.setData(tiff, forType: .tiff)
                }
                pbItem.setString(item.id, forType: ClipboardImage.selfCopyMarkerType)
                let pb = NSPasteboard.general
                pb.clearContents()
                guard pb.writeObjects([pbItem]) else {
                    showToast("复制失败")
                    return
                }
                showToast("已复制图片")
            } else {
                writeAndFlag(content: item.content, chunkID: item.id, feedback: "已复制")
            }
        } else {
            writeAndFlag(content: item.content, chunkID: item.id, feedback: "已复制")
        }
    }

    /// 剪贴板历史：立即删除单条（不弹二次确认）。
    /// 数据路径：DataStore.deleteChunk 会删掉该 chunk 及其标签、图片附件；
    /// 若它是所在记录树里最后一个分段，空树（maintree 行与树级标签）一并清理。
    /// 删除后重建去重列表，从更早的记录补足 99 条。
    func deleteClipboardItemImmediately(_ item: ClipboardHistoryItem) {
        guard let store else { return }
        let keepDay = clipboardCurrentDayKey
        let keepPage = clipboardUnits.indices.contains(clipboardCursor)
            ? clipboardUnits[clipboardCursor].pageNo
            : 0
        do {
            guard let info = try store.deleteChunk(item.id) else { return }
            // 与其它删除入口一致：写事件日志、重写受影响日期的 Markdown 归档
            archive(
                info: info,
                kind: "删除剪切板历史条目",
                content: item.content,
                source: AppInfo.zhName,
                atMs: TimeUtil.msNow()
            )
            if highlightedChunkID == item.id { highlightedChunkID = nil }
            rebuildClipboardUnits(keepingDay: keepDay, keepingPageNo: keepPage)
            showToast("已删除")
        } catch {
            NSLog("deleteClipboardItemImmediately error: \(error)")
            showToast("删除失败")
        }
    }

    /// 一键清空全部记录（需先在 UI 层确认，删除即不可恢复）
    func clearAllRecords() {
        guard let store else { return }
        do {
            let at = TimeUtil.msNow()
            let result = try store.deleteAllRecords()
            let block = DataStore.eventBlock(
                kind: "一键清空全部记录",
                content: "清空了全部记录：共 \(result.trees) 条 maintree、\(result.chunks) 个 chunk",
                source: AppInfo.zhName,
                treeID: "",
                chunkID: nil,
                atMs: at
            )
            try? store.writeEventLog(atMs: at, block: block)
            for day in result.days {
                try? store.rewriteDailyMarkdown(dayKey: day)
            }
            expandedTreeID = nil
            highlightedChunkID = nil
            reload()
            showToast("已清空全部记录")
        } catch {
            NSLog("clearAllRecords error: \(error)")
            showToast("清空失败")
        }
    }

    /// 一键清空剪切板历史（UI 层需先确认）：只删 clipboard 类型树，
    /// 手工笔记（note）不受影响；受影响天的 Markdown 归档同步重写
    func clearClipboardHistory() {
        guard let store else { return }
        do {
            let at = TimeUtil.msNow()
            let summary = try store.deleteAllClipboardHistory()
            guard !summary.treeIDs.isEmpty else {
                showToast("剪切板历史已是空的")
                return
            }
            let block = DataStore.eventBlock(
                kind: "一键清空剪切板历史（\(summary.treeIDs.count) 条，含 \(summary.chunkCount) 个分段）",
                content: "清空剪切板历史：\n" + summary.treeIDs.joined(separator: "\n"),
                source: AppInfo.zhName,
                treeID: "",
                chunkID: nil,
                atMs: at
            )
            try? store.writeEventLog(atMs: at, block: block)
            for day in summary.dayKeys {
                try? store.rewriteDailyMarkdown(dayKey: day)
            }
            rebuildClipboardUnits(keepingDay: nil)
            reload()
            showToast("已清空剪切板历史（\(summary.treeIDs.count) 条）")
        } catch {
            NSLog("clearClipboardHistory error: \(error)")
            showToast("清空失败")
        }
    }

    func updateShortcut(keyCode: UInt32, modifiers: UInt32) {
        let oldKey = shortcutKeyCode
        let oldMods = shortcutModifiers
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        let combo = shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)
        if applyShortcut() {
            UserDefaults.standard.set(keyCode, forKey: "shortcutKeyCode")
            UserDefaults.standard.set(modifiers, forKey: "shortcutModifiers")
            showToast("快捷键已更新为 \(combo)")
        } else {
            // 注册失败（被系统/其它应用占用）时回滚，避免保存一个永远不生效的快捷键
            shortcutKeyCode = oldKey
            shortcutModifiers = oldMods
            _ = applyShortcut()
            showToast("\(combo) 注册失败：已被系统或其它应用占用")
        }
    }

    /// 应用当前快捷键设置。返回是否注册成功（失败说明组合被占用，见 HotkeyManager.register）
    @discardableResult
    func applyShortcut() -> Bool {
        HotkeyManager.shared.register(
            keyCode: shortcutKeyCode,
            modifiers: shortcutModifiers
        ) { [weak self] in
            self?.shortcutAction?()
        }
    }

    // MARK: - 新建 / 编辑

    @discardableResult
    func createNewRecord(title: String, content: String) -> Bool {
        guard let content = cleaned(content), let store else { return false }
        do {
            let at = TimeUtil.msNow()
            let info = try store.performManualNewRecord(title: title, content: content, atMs: at)
            archive(info: info, kind: "手工新建记录", content: content, source: "手动输入", atMs: at)
            reload()
            revealTree(info.treeID, expand: false)
            viewMode = .list
            showToast("已新建笔记")
            return true
        } catch {
            NSLog("createNewRecord error: \(error)")
            return false
        }
    }

    /// 读取当前剪切板文本（去除首尾空白），用于一键粘贴为笔记 / 分段
    func clipboardText() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 一键将剪切板文本保存为新笔记（无需打开编辑器）
    @discardableResult
    func createNoteFromClipboard() -> Bool {
        guard let text = clipboardText(), let store else {
            showToast("剪切板中没有可粘贴的文本")
            return false
        }
        do {
            let at = TimeUtil.msNow()
            let info = try store.performManualNewRecord(title: "", content: text, atMs: at)
            archive(info: info, kind: "从剪切板粘贴为笔记", content: text, source: "剪切板", atMs: at)
            reload()
            revealTree(info.treeID, expand: false)
            showToast("已从剪切板创建笔记")
            return true
        } catch {
            NSLog("createNoteFromClipboard error: \(error)")
            return false
        }
    }

    /// 剪切板历史条目 → 归档为笔记：新建 kind='note' 记录（内容/附件/来源取自该条目），
    /// 原历史条目保留不动。归档后主列表可见。
    @discardableResult
    func archiveClipboardItemAsNote(_ item: ClipboardHistoryItem) -> Bool {
        guard let store else { return false }
        do {
            let at = TimeUtil.msNow()
            // 图片必须复制为独立附件：若直接沿用剪切板条目的文件路径，
            // 之后「删除该条目 / 清空剪切板历史」会把文件一并删除，导致笔记图片永久损坏。
            var attachment = ""
            if item.isImage {
                guard let src = AppPaths.attachmentURL(relativePath: item.attachment),
                      let data = try? Data(contentsOf: src),
                      let copied = try? ClipboardImage.savePNG(data, dayKey: TimeUtil.dayKey(at), atMs: at)
                else {
                    showToast("归档失败：原图文件已丢失")
                    return false
                }
                attachment = copied
            }
            let info = try store.performManualNewRecord(
                title: "",
                content: item.content,
                atMs: at,
                attachment: attachment,
                sourceApp: item.sourceApp
            )
            archive(
                info: info,
                kind: "剪切板历史归档为笔记",
                content: item.content,
                source: item.sourceApp.isEmpty ? "剪切板历史" : item.sourceApp,
                atMs: at
            )
            reload()
            revealTree(info.treeID, expand: false)
            showToast("已归档为笔记")
            return true
        } catch {
            NSLog("archiveClipboardItemAsNote error: \(error)")
            showToast("归档失败")
            return false
        }
    }

    /// 一键将剪切板文本追加到指定笔记树（无需打开行内编辑器）
    @discardableResult
    func appendClipboardToTree(_ treeID: String) -> Bool {
        guard let text = clipboardText(), let store else {
            showToast("剪切板中没有可粘贴的文本")
            return false
        }
        do {
            let at = TimeUtil.msNow()
            guard let info = try store.performManualAppend(treeID: treeID, content: text, atMs: at) else {
                showToast("目标记录不存在")
                return false
            }
            archive(info: info, kind: "从剪切板追加分段", content: text, source: "剪切板", atMs: at)
            reload()
            revealTree(treeID, expand: true)
            showToast("已追加剪切板内容")
            return true
        } catch {
            NSLog("appendClipboardToTree error: \(error)")
            return false
        }
    }

    /// 更新笔记：修改标题与首个分段内容（树状笔记的其它分段通过追加/删除管理）
    @discardableResult
    func updateRecord(treeID: String, title: String, content: String) -> Bool {
        guard let content = cleaned(content), let store else { return false }
        do {
            let at = TimeUtil.msNow()
            let oldUpd = try store.treeUpdatedMs(treeID)
            try store.updateTitle(treeID: treeID, title: title)
            // 找到首个分段（按创建时间正序的第一个）并更新内容
            let chunks = try store.chunks(ofTree: treeID).sorted { $0.createdAtMs < $1.createdAtMs }
            var editedChunkID: String?
            if let first = chunks.first {
                try store.updateChunkContent(chunkID: first.id, content: content, atMs: at)
                try store.touchTree(treeID: treeID, atMs: at)
                editedChunkID = first.id
            }
            // 编辑会改变内容并把记录移动到「今天」，必须同步重写旧天与新天的 Markdown 归档，
            // 否则 daily 归档会残留旧内容、且记录仍挂在旧日期下。
            archive(
                info: MutationInfo(
                    treeID: treeID,
                    chunkID: editedChunkID,
                    newTree: false,
                    oldDay: TimeUtil.dayKey(oldUpd == 0 ? at : oldUpd),
                    newDay: TimeUtil.dayKey(at)
                ),
                kind: "编辑笔记",
                content: content,
                source: "手动编辑",
                atMs: at
            )
            reload()
            revealTree(treeID, expand: false)
            showToast("已更新笔记")
            return true
        } catch {
            NSLog("updateRecord error: \(error)")
            return false
        }
    }

    // MARK: - 归档

    func toggleArchiveTree(_ treeID: String) {
        guard let store else { return }
        do {
            let wasArchived = rows.first(where: { $0.id == treeID })?.tree.isArchived ?? false
            try store.setArchived(treeID: treeID, archived: !wasArchived, atMs: TimeUtil.msNow())
            // 归档状态会写入当天 Markdown（已归档标记），需重写该记录所属天的归档
            rewriteArchiveDay(ofTree: treeID)
            reload()
            showToast(!wasArchived ? "已归档" : "已取消归档")
        } catch {
            NSLog("toggleArchiveTree error: \(error)")
        }
    }

    /// 仅重写某条记录所属天的 daily Markdown（用于不改动事件日志的元数据变更，如归档开关）
    private func rewriteArchiveDay(ofTree treeID: String) {
        guard let store, let updated = try? store.treeUpdatedMs(treeID) else { return }
        try? store.rewriteDailyMarkdown(dayKey: TimeUtil.dayKey(updated))
    }

    // MARK: - 追加 chunk

    /// 追加分段。keepAdding=true 用于"连续追加"场景：保存后不清滚动定位，
    /// 让行内编辑器保持在原位继续输入，避免每次保存都把树滚到顶部打断节奏。
    @discardableResult
    func manualAppendToTree(_ treeID: String, content: String, keepAdding: Bool = false) -> Bool {
        guard let store, let content = cleaned(content) else { return false }
        do {
            let at = TimeUtil.msNow()
            guard let info = try store.performManualAppend(treeID: treeID, content: content, atMs: at) else {
                showToast("目标记录不存在")
                return false
            }
            archive(info: info, kind: "手工追加分段", content: content, source: "手动输入", atMs: at)
            reload()
            if keepAdding {
                scrollTargetTreeID = nil
                showToast("已追加分段，⌘⏎ 继续 · ESC 结束")
            } else {
                revealTree(treeID, expand: true)
                showToast("已追加分段")
            }
            return true
        } catch {
            NSLog("manualAppendToTree error: \(error)")
            return false
        }
    }

    // MARK: - 搜索

    func performSearch(_ query: String) {
        guard let store else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchResults = []
            return
        }
        do {
            let raw = try store.searchChunks(keyword: term)
            let treeTags = (try? store.tagsGrouped(itemType: "tree", itemIDs: Array(Set(raw.map(\.treeID))))) ?? [:]
            let chunkTags = (try? store.tagsGrouped(itemType: "chunk", itemIDs: raw.map(\.chunkID))) ?? [:]
            searchResults = raw.map { result in
                var seen = Set<String>()
                var tags: [String] = []
                for name in (treeTags[result.treeID] ?? []) + (chunkTags[result.chunkID] ?? []) {
                    if seen.insert(name).inserted { tags.append(name) }
                }
                return SearchResultVM(result: result, tags: tags)
            }
        } catch {
            NSLog("performSearch error: \(error)")
            searchResults = []
        }
    }

    func openSearchResult(_ result: SearchResult) {
        if result.treeKind == "note" {
            // 笔记类型：跳转到主列表并定位
            reload() // 确保分页单位最新
            guard latestMetas.contains(where: { $0.id == result.treeID }) else { return }
            highlightedChunkID = result.chunkID
            revealTree(result.treeID, expand: true)
            viewMode = .list
        } else {
            // 剪贴板类型：跳转到剪贴板历史并定位到对应条目所在日期
            let dayKey = TimeUtil.dayKey(result.chunkUpdatedAtMs)
            rebuildClipboardUnits(keepingDay: dayKey)
            viewMode = .clipboardHistory
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.highlightedChunkID = nil
        }
    }

    /// 把搜索命中保存为笔记。已经是笔记的不再复制一份。
    @discardableResult
    func saveSearchResultAsNote(_ result: SearchResult) -> Bool {
        guard result.treeKind != "note" else {
            showToast("这条已在笔记中")
            return false
        }
        let item = ClipboardHistoryItem(
            id: result.chunkID,
            treeID: result.treeID,
            content: result.content,
            attachment: result.attachment,
            sourceApp: result.sourceApp,
            createdAtMs: result.chunkUpdatedAtMs,
            updatedAtMs: result.chunkUpdatedAtMs,
            lastCopiedMs: nil
        )
        return archiveClipboardItemAsNote(item)
    }

    /// 复制搜索结果的内容
    func copySearchResult(_ result: SearchResult) {
        if result.isImage {
            // 图片：尝试回写原图
            if let url = AppPaths.attachmentURL(relativePath: result.attachment),
               let png = try? Data(contentsOf: url) {
                let pbItem = NSPasteboardItem()
                guard pbItem.setData(png, forType: .png) else {
                    showToast("复制失败")
                    return
                }
                if let img = NSImage(data: png), let tiff = img.tiffRepresentation {
                    pbItem.setData(tiff, forType: .tiff)
                }
                pbItem.setString(result.chunkID, forType: ClipboardImage.selfCopyMarkerType)
                let pb = NSPasteboard.general
                pb.clearContents()
                guard pb.writeObjects([pbItem]) else {
                    showToast("复制失败")
                    return
                }
                showToast("已复制图片")
            } else {
                writeAndFlag(content: result.content, chunkID: result.chunkID, feedback: "已复制")
            }
        } else {
            writeAndFlag(content: result.content, chunkID: result.chunkID, feedback: "已复制")
        }
    }

    // MARK: - 点击复制

    func copyRecord(_ treeID: String) {
        guard let row = rows.first(where: { $0.id == treeID }) else { return }
        guard let c = row.tree.latest else { return }
        if c.isImage {
            writeImageAndFlag(c)
        } else {
            writeAndFlag(content: c.content, chunkID: c.id, feedback: "已复制最新内容")
        }
    }

    func copyChunk(_ chunkID: String) {
        guard
            let row = rows.first(where: { $0.chunks.contains(where: { $0.id == chunkID }) }),
            let vm = row.chunks.first(where: { $0.id == chunkID })
        else { return }
        if vm.chunk.isImage {
            writeImageAndFlag(vm.chunk)
        } else {
            writeAndFlag(content: vm.chunk.content, chunkID: chunkID, feedback: "已复制该分段")
        }
    }

    /// 复制整棵记录：标题 + 全部 chunk，按时序（最早在前）拼接
    func copyTree(_ treeID: String) {
        guard let row = rows.first(where: { $0.id == treeID }) else { return }
        let text = Self.treeExportText(row.tree)
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            showToast("复制失败")
            return
        }
        ClipboardSession.shared.beginTreeCopy(content: text)
        let n = row.tree.chunks.count
        showToast(n > 1 ? "已复制整棵记录（\(n) 段）" : "已复制整棵记录")
    }

    static func treeExportText(_ t: TreeRec) -> String {
        var parts: [String] = []
        if !t.title.isEmpty { parts.append(t.title) }
        for c in t.chunks.sorted(by: { $0.createdAtMs < $1.createdAtMs }) {
            parts.append(c.content)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 删除

    func deleteTree(_ treeID: String) {
        guard let store else { return }
        do {
            guard let info = try store.deleteTree(treeID) else { return }
            let count = rows.first(where: { $0.id == treeID })?.tree.chunks.count ?? 0
            archive(
                info: info,
                kind: "删除记录（含 \(count) 个分段）",
                content: "整棵记录 \(treeID) 及其全部分段已删除",
                source: AppInfo.zhName,
                atMs: TimeUtil.msNow()
            )
            if expandedTreeID == treeID { expandedTreeID = nil }
            highlightedChunkID = nil
            reload()
            showToast("已删除记录")
        } catch {
            NSLog("deleteTree error: \(error)")
        }
    }

    /// 批量删除多条整树记录（主列表多选删除）。
    /// 一次删除 + 一次事件日志 + 一次归档重写，避免多次 reload 造成界面跳动。
    func deleteTrees(_ treeIDs: [String]) {
        guard let store, !treeIDs.isEmpty else { return }
        do {
            let at = TimeUtil.msNow()
            let summary = try store.deleteTrees(treeIDs)
            guard !summary.treeIDs.isEmpty else { return }
            let block = DataStore.eventBlock(
                kind: "批量删除记录（\(summary.treeIDs.count) 条，含 \(summary.chunkCount) 个分段）",
                content: "删除记录：\n" + summary.treeIDs.joined(separator: "\n"),
                source: AppInfo.zhName,
                treeID: summary.treeIDs.first ?? "",
                chunkID: nil,
                atMs: at
            )
            try? store.writeEventLog(atMs: at, block: block)
            for day in summary.dayKeys {
                try? store.rewriteDailyMarkdown(dayKey: day)
            }
            expandedTreeID = nil
            highlightedChunkID = nil
            reload()
            showToast("已删除 \(summary.treeIDs.count) 条记录")
        } catch {
            NSLog("deleteTrees error: \(error)")
        }
    }

    func deleteChunk(_ chunkID: String) {
        guard let store else { return }
        guard
            let row = rows.first(where: { $0.chunks.contains(where: { $0.id == chunkID }) }),
            let vm = row.chunks.first(where: { $0.id == chunkID })
        else { return }
        guard row.chunks.count > 1 else {
            showToast("该记录仅剩一个分段，请删除整条记录")
            return
        }
        do {
            guard let info = try store.deleteChunk(chunkID) else { return }
            archive(
                info: info,
                kind: "删除分段",
                content: vm.chunk.content,
                source: AppInfo.zhName,
                atMs: TimeUtil.msNow()
            )
            if highlightedChunkID == chunkID { highlightedChunkID = nil }
            reload()
            revealTree(row.id, expand: true)
            showToast("已删除分段")
        } catch {
            NSLog("deleteChunk error: \(error)")
        }
    }

    private func writeAndFlag(content: String, chunkID: String, feedback: String = "已复制") {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(content, forType: .string) else {
            showToast("复制失败")
            return
        }
        ClipboardSession.shared.beginCopy(content: content, chunkID: chunkID)
        showToast(feedback)
    }

    /// 图片 chunk 回写：把原图（PNG+TIFF）放回剪贴板，并附带自我复制标记，不清空时文本保持空
    private func writeImageAndFlag(_ chunk: ChunkRec) {
        guard let url = AppPaths.attachmentURL(relativePath: chunk.attachment),
              let png = try? Data(contentsOf: url) else {
            // 附件缺失（可能同步未完成）：退化为复制展示文字
            writeAndFlag(content: chunk.content, chunkID: chunk.id)
            return
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else {
            showToast("复制失败")
            return
        }
        if let img = NSImage(data: png), let tiff = img.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(chunk.id, forType: ClipboardImage.selfCopyMarkerType)
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects([item]) else {
            showToast("复制失败")
            return
        }
        showToast("已复制图片")
    }

    // MARK: - 分页导航（笔记列表：全局页码翻页）

    /// scroll：是否同时滚动到新页顶部（键盘翻页时由键盘焦点接管定位，传 false）
    func goNewer(scroll: Bool = true) {
        guard notePage > 0 else { return }
        notePage -= 1
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        if scroll {
            // 翻页后固定回到该页顶部，避免停留在上一页的滚动深度造成“原地跳变”
            scrollTargetTreeID = rows.first?.id
        }
    }

    func goOlder(scroll: Bool = true) {
        guard notePage < notePageCount - 1 else { return }
        notePage += 1
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        if scroll {
            scrollTargetTreeID = rows.first?.id
        }
    }

    /// 跳到指定页码（1 基）
    func goToPage(_ page1: Int) {
        let p = max(1, min(page1, notePageCount)) - 1
        guard p != notePage else { return }
        notePage = p
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        scrollTargetTreeID = rows.first?.id
    }

    /// 直接回到第 1 页（最新记录）
    func goToNewestPage() {
        guard notePage > 0 else { return }
        notePage = 0
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        scrollTargetTreeID = rows.first?.id
    }

    func toggleExpanded(_ treeID: String) {
        expandedTreeID = (expandedTreeID == treeID) ? nil : treeID
    }

    /// 视图已消费滚动定位请求后调用
    func consumeScrollTarget() {
        scrollTargetTreeID = nil
    }

    /// 数据变更引发列表重排后，把当前页切换到包含 treeID 的那一页，并请求滚动到该记录。
    /// 必须在 reload()（latestMetas / rows 已更新）之后调用。
    func revealTree(_ treeID: String, expand: Bool) {
        guard store != nil,
              let idx = latestMetas.firstIndex(where: { $0.id == treeID })
        else {
            if expand { expandedTreeID = nil }
            return
        }
        let page = idx / Config.pageSize
        if notePage != page {
            notePage = page
            loadPage()
        }
        if expand { expandedTreeID = treeID }
        scrollTargetTreeID = treeID
    }

    // MARK: - 重载与页面加载

    func reload() {
        guard let store else {
            clearRows()
            return
        }
        do {
            let metas = try store.allNoteTreeMetas()
            latestMetas = metas
            noteTotal = metas.count
            // 边界保护：确保当前页在有效范围内
            if notePage >= notePageCount {
                notePage = notePageCount - 1
            }
            if notePage < 0 {
                notePage = 0
            }
            loadPage()
        } catch {
            NSLog("reload error: \(error)")
            clearRows()
        }
    }

    private func clearRows() {
        rows = []
        dayTitle = "暂无笔记"
        dayMetaText = ""
        noteTotal = 0
        hasNewer = false
        hasOlder = false
    }

    private func loadPage() {
        guard let store else {
            clearRows()
            return
        }
        guard noteTotal > 0 else {
            clearRows()
            return
        }
        guard
            let trees = try? store.fetchNoteTreesPage(
                limit: Config.pageSize,
                offset: notePage * Config.pageSize
            )
        else {
            clearRows()
            return
        }
        rows = trees.map { TreeRowVM(tree: $0) }
        // 标签批量注入（树级 + 分段级合并展示）
        if let tagMap = try? store.tagsForTrees(trees.map { $0.id }) {
            rows = rows.map { row in
                var r = row
                r.tags = tagMap[row.id] ?? []
                return r
            }
        }
        dayTitle = "第 \(notePage + 1) / \(notePageCount) 页"
        dayMetaText = "共 \(noteTotal) 条笔记"
        hasNewer = notePage > 0
        hasOlder = notePage < notePageCount - 1
    }

    /// 变更后若树所在的页与当前页不同，跳到包含该树的页（编辑/追加会把树顶到最前，通常回到第 1 页）
    private func relocateIfNeeded(_ info: MutationInfo) {
        guard let idx = latestMetas.firstIndex(where: { $0.id == info.treeID }) else { return }
        let page = idx / Config.pageSize
        if notePage != page {
            notePage = page
            loadPage()
            scrollTargetTreeID = rows.first?.id
        }
    }

    // MARK: - Markdown 归档编排

    private func archive(info: MutationInfo, kind: String, content: String, source: String, atMs: Int64) {
        guard let store else { return }
        let block = DataStore.eventBlock(
            kind: kind,
            content: content,
            source: source,
            treeID: info.treeID,
            chunkID: info.chunkID,
            atMs: atMs
        )
        try? store.writeEventLog(atMs: atMs, block: block)
        for day in info.affectedDays {
            try? store.rewriteDailyMarkdown(dayKey: day)
        }
    }

    // MARK: - 标签

    @Published var tagCloudItems: [DataStore.TagCloudEntry] = []
    @Published var tagResults: [TreeRowVM] = []
    @Published var selectedTagName = ""

    /// AI 打标签
    @Published var isAutoTagging = false
    @Published var aiTagProgressText = ""

    private var aiTagTask: Task<Void, Never>?

    enum AIConfigKey {
        static let provider = "ai.provider"
        static let cloudBase = "ai.cloud.base"
        /// 旧版明文存放 API Key 的键：仅用于迁移读取与清理，不再写入
        static let cloudKey = "ai.cloud.key"
        static let cloudModel = "ai.cloud.model"
        static let ollamaBase = "ai.ollama.base"
        static let ollamaModel = "ai.ollama.model"
        static let mlxBase = "ai.mlx.base"
        static let mlxModel = "ai.mlx.model"
    }

    /// 敏感值（API Key）改存 Keychain，这里只保留 account 名
    enum AISecretKey {
        static let cloudAPIKey = "ai.cloud.key"
    }

    /// 读取云端 API Key：优先 Keychain；发现旧版明文（UserDefaults）时自动迁移过去。
    static func cloudAPIKey() -> String {
        if let stored = KeychainStore.string(for: AISecretKey.cloudAPIKey), !stored.isEmpty {
            // 顺手清掉可能残留的旧明文
            clearLegacyPlaintextCloudKey()
            return stored
        }

        let legacy = (UserDefaults.standard.string(forKey: AIConfigKey.cloudKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return "" }

        // 迁移失败（如钥匙串访问被拒）时保留旧值继续可用，下次启动再试
        if KeychainStore.set(legacy, for: AISecretKey.cloudAPIKey) {
            clearLegacyPlaintextCloudKey()
        }
        return legacy
    }

    /// 写入云端 API Key（空字符串即清除）。返回是否写入成功。
    @discardableResult
    static func setCloudAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = KeychainStore.set(trimmed, for: AISecretKey.cloudAPIKey)
        if ok { clearLegacyPlaintextCloudKey() }
        return ok
    }

    /// 清掉历史遗留的明文键，避免它继续留在 UserDefaults plist / 备份里
    private static func clearLegacyPlaintextCloudKey() {
        let d = UserDefaults.standard
        guard d.object(forKey: AIConfigKey.cloudKey) != nil else { return }
        d.removeObject(forKey: AIConfigKey.cloudKey)
    }

    /// 读取当前生效的 AI 端点配置（按设置页选中的预设）
    static func currentAIConfig() -> (preset: AIProviderPreset, config: AIEndpointConfig) {
        let d = UserDefaults.standard
        let preset = AIProviderPreset(rawValue: d.integer(forKey: AIConfigKey.provider)) ?? .cloud
        var base: String
        let key: String
        var model: String
        switch preset {
        case .cloud:
            base = d.string(forKey: AIConfigKey.cloudBase) ?? preset.defaultBaseURL
            key = cloudAPIKey()
            model = d.string(forKey: AIConfigKey.cloudModel) ?? preset.defaultModel
            // 迁移：旧版默认（OpenAI / gpt-4o-mini）视为未定制，切换到 Yueli AI freemodel 新默认
            if base == "https://api.openai.com/v1" { base = preset.defaultBaseURL }
            if model == "gpt-4o-mini" { model = preset.defaultModel }
        case .ollama:
            base = d.string(forKey: AIConfigKey.ollamaBase) ?? preset.defaultBaseURL
            key = ""
            model = d.string(forKey: AIConfigKey.ollamaModel) ?? preset.defaultModel
        case .mlx:
            base = d.string(forKey: AIConfigKey.mlxBase) ?? preset.defaultBaseURL
            key = ""
            model = d.string(forKey: AIConfigKey.mlxModel) ?? preset.defaultModel
        }
        return (
            preset,
            AIEndpointConfig(
                baseURL: base.isEmpty ? preset.defaultBaseURL : base,
                apiKey: key,
                model: model.isEmpty ? preset.defaultModel : model
            )
        )
    }

    func showTagCloud() {
        refreshTagCloud()
        viewMode = .tagCloud
    }

    func refreshTagCloud() {
        tagCloudItems = (try? store?.tagCloud()) ?? []
    }

    func openTag(_ name: String) {
        selectedTagName = name
        tagResults = loadTagResultRows(name)
        viewMode = .tagResults
    }

    func backToTagCloud() {
        refreshTagCloud()
        viewMode = .tagCloud
    }

    private func loadTagResultRows(_ name: String) -> [TreeRowVM] {
        guard let store,
              let trees = try? store.treesByTag(name) else { return [] }
        var rows = trees.map { TreeRowVM(tree: $0) }
        if let tagMap = try? store.tagsForTrees(trees.map { $0.id }) {
            rows = rows.map { row in
                var r = row
                r.tags = tagMap[row.id] ?? []
                return r
            }
        }
        return rows
    }

    /// 供标签编辑弹层回填当前值
    func treeTagNames(_ treeID: String) -> [String] {
        (try? store?.tagsForItem(itemType: "tree", itemID: treeID)) ?? []
    }

    func chunkTagNames(_ chunkID: String) -> [String] {
        (try? store?.tagsForItem(itemType: "chunk", itemID: chunkID)) ?? []
    }

    /// 从标签结果页定位到主列表。
    /// 标签结果可能包含剪贴板历史记录，它们不在主列表里，无法定位，给出提示而不是静默跳转。
    func openTreeFromTagResult(_ treeID: String) {
        guard let store,
              let metas = try? store.allNoteTreeMetas(),
              metas.contains(where: { $0.id == treeID })
        else {
            showToast("该记录属于剪切板历史，可用右键复制")
            return
        }
        viewMode = .list
        reload()
        revealTree(treeID, expand: false)
    }

    /// 手工设置树级标签
    func setTreeTags(_ treeID: String, names: [String]) {
        guard let store else { return }
        do {
            try store.setTags(itemType: "tree", itemID: treeID, names: names)
            reload()
            refreshTagCloud()
            showToast(names.isEmpty ? "已清除标签" : "已设置 \(names.count) 个标签")
        } catch {
            NSLog("setTreeTags error: \(error)")
            showToast("标签保存失败")
        }
    }

    /// 手工设置分段级标签
    func setChunkTags(_ chunkID: String, names: [String]) {
        guard let store else { return }
        do {
            try store.setTags(itemType: "chunk", itemID: chunkID, names: names)
            reload()
            refreshTagCloud()
            showToast(names.isEmpty ? "已清除标签" : "已设置 \(names.count) 个标签")
        } catch {
            NSLog("setChunkTags error: \(error)")
            showToast("标签保存失败")
        }
    }

    /// 对单棵树执行 AI 打标签（追加式：与现有标签合并）
    func aiTagTree(_ treeID: String) {
        guard !isAutoTagging else {
            showToast("批量打标签进行中，请稍候")
            return
        }
        guard let store else { return }
        let (_, endpoint) = Self.currentAIConfig()
        // DB 访问全部在主线程完成后，Task 内只做网络调用
        guard let merged = try? store.mergedContentForTree(treeID: treeID) else {
            showToast("记录不存在")
            return
        }
        let existing = treeTagNames(treeID)
        isAutoTagging = true
        aiTagProgressText = "AI 分析中…"
        aiTagTask = Task { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async { self.isAutoTagging = false }
            }
            do {
                let raw = try await TagAIService.chat(config: endpoint, userContent: merged)
                let tags = TagAIService.parseTags(raw)
                guard !tags.isEmpty else {
                    DispatchQueue.main.async { self.showToast("AI 未返回有效标签") }
                    return
                }
                await MainActor.run {
                    self.setTreeTags(treeID, names: tags + existing)
                }
            } catch {
                NSLog("aiTagTree error: \(error)")
                DispatchQueue.main.async { self.showToast("AI 打标签失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 批量：为所有未打标签的记录 AI 打标签
    func startAutoTagUntaggedTrees() {
        guard !isAutoTagging else { return }
        guard let store else { return }
        guard let items = try? store.untaggedTreeContents(limit: 300), !items.isEmpty else {
            showToast("所有记录都已有标签")
            return
        }
        let (_, endpoint) = Self.currentAIConfig()
        isAutoTagging = true
        let total = items.count
        aiTagProgressText = "0 / \(total)"
        var okCount = 0
        var failCount = 0
        aiTagTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in items {
                if Task.isCancelled { break }
                do {
                    let raw = try await TagAIService.chat(config: endpoint, userContent: item.merged)
                    let tags = TagAIService.parseTags(raw)
                    if !tags.isEmpty {
                        try? store.setTags(itemType: "tree", itemID: item.treeID, names: tags)
                        okCount += 1
                    } else {
                        failCount += 1
                    }
                } catch {
                    failCount += 1
                    NSLog("autoTag error: \(error)")
                    self.aiTagProgressText = "出错：\(error.localizedDescription)"
                    // 连续失败过多视为端点不可用，中止
                    if failCount >= 3 && okCount == 0 { break }
                }
                let done = okCount + failCount
                self.aiTagProgressText = "\(done) / \(total) · 最新：\(item.title.isEmpty ? String(item.merged.prefix(16)) : item.title)"
            }
            self.isAutoTagging = false
            self.reload()
            self.refreshTagCloud()
            if Task.isCancelled {
                self.showToast("已停止（完成 \(okCount) 条）")
            } else if okCount == 0 && failCount > 0 {
                self.showToast("AI 打标签失败，请检查设置")
            } else {
                self.showToast("已为 \(okCount) 条记录打标签")
            }
        }
    }

    func stopAutoTag() {
        aiTagTask?.cancel()
    }

    // MARK: - 杂项

    private func cleaned(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func showToast(_ text: String) {
        lastToast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.lastToast = nil
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }
}
