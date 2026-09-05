import Foundation
import Combine
import AppKit
import Carbon

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

    init(result: SearchResult) {
        self.result = result
        treeTitle = result.treeTitle.isEmpty
            ? PreviewUtil.makePreview(result.content)
            : result.treeTitle
        chunkPreview = PreviewUtil.makePreview(result.content)
        caption = "\(result.sourceApp) · 分段更新 \(TimeUtil.displayTime(result.chunkUpdatedAtMs))"
    }
}

// MARK: - 分页单位

struct PageUnit {
    let dayKey: String
    let dayStartMs: Int64
    let dayEndMs: Int64
    let dayCount: Int
    let offsetInDay: Int
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

// MARK: - 视图模式

enum AppViewMode: Equatable {
    case list
    case newRecord
    case searchResults
    case settings
}

// MARK: - 应用状态

/// 全部方法预期在主线程 / 主 RunLoop 上调用
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private(set) var store: DataStore?
    private var units: [PageUnit] = []
    private var cursor = 0
    private var latestMetas: [(id: String, createdAtMs: Int64, updatedAtMs: Int64)] = []

    @Published var rows: [TreeRowVM] = []
    @Published var dayTitle = "暂无记录"
    @Published var dayMetaText = ""
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
    @Published var searchResults: [SearchResultVM] = []

    /// 列表内单个记录的删除是否需要二次确认（默认开启：删除不可恢复，先确认再执行）
    @Published var requireDeleteConfirm = true

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
    }

    /// 更新“删除需二次确认”设置
    func setRequireDeleteConfirm(_ value: Bool) {
        requireDeleteConfirm = value
        UserDefaults.standard.set(value, forKey: "deleteRequiresConfirm")
    }

    func boot() throws {
        // 若用户曾选择自定义数据目录（iCloud Drive / 同步盘），先恢复
        AppPaths.restoreConfiguredRoot()
        store = try DataStore()
        reload()
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

    /// 同步盘上的数据库被其它设备更新：关掉旧连接、重新打开并刷新界面
    func reloadFromRemoteChange() {
        guard let old = store else { return }
        do {
            try old.close()
        } catch {
            NSLog("close before remote reload failed: \(error)")
        }
        do {
            store = try DataStore()
            reload()
            showToast("已同步其它设备的最新数据")
        } catch {
            NSLog("reload after remote change failed: \(error)")
            store = old
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
        guard let store, !content.isEmpty else { return }
        do {
            let at = TimeUtil.msNow()
            let info = try store.performExternalCopy(content: content, source: source, atMs: at)
            archive(info: info, kind: "复制自外部", content: content, source: source, atMs: at)
            reload()
        } catch {
            NSLog("handleExternalCopy error: \(error)")
        }
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
        guard let store, let img = ClipboardImage.decodePNG(rawImage) else { return }
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
            reload()
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

    func updateShortcut(keyCode: UInt32, modifiers: UInt32) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        UserDefaults.standard.set(keyCode, forKey: "shortcutKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "shortcutModifiers")
        applyShortcut()
    }

    func applyShortcut() {
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
            showToast("已新建记录")
            return true
        } catch {
            NSLog("createNewRecord error: \(error)")
            return false
        }
    }

    // MARK: - 归档

    func toggleArchiveTree(_ treeID: String) {
        guard let store else { return }
        do {
            let wasArchived = rows.first(where: { $0.id == treeID })?.tree.isArchived ?? false
            try store.setArchived(treeID: treeID, archived: !wasArchived, atMs: TimeUtil.msNow())
            reload()
            showToast(!wasArchived ? "已归档" : "已取消归档")
        } catch {
            NSLog("toggleArchiveTree error: \(error)")
        }
    }

    // MARK: - 追加 chunk

    @discardableResult
    func manualAppendToTree(_ treeID: String, content: String) -> Bool {
        guard let store, let content = cleaned(content) else { return false }
        do {
            let at = TimeUtil.msNow()
            guard let info = try store.performManualAppend(treeID: treeID, content: content, atMs: at) else {
                showToast("目标记录不存在")
                return false
            }
            archive(info: info, kind: "手工追加分段", content: content, source: "手动输入", atMs: at)
            reload()
            revealTree(treeID, expand: true)
            showToast("已追加分段")
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
            searchResults = raw.map { SearchResultVM(result: $0) }
        } catch {
            NSLog("performSearch error: \(error)")
            searchResults = []
        }
    }

    func openSearchResult(treeID: String, chunkID: String) {
        reload() // 确保分页单位最新
        guard latestMetas.contains(where: { $0.id == treeID }) else { return }
        highlightedChunkID = chunkID
        revealTree(treeID, expand: true)
        viewMode = .list
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.highlightedChunkID = nil
        }
    }

    // MARK: - 点击复制

    func copyRecord(_ treeID: String) {
        guard let row = rows.first(where: { $0.id == treeID }) else { return }
        guard let c = row.tree.latest else { return }
        if c.isImage {
            writeImageAndFlag(c)
        } else {
            writeAndFlag(content: c.content, chunkID: c.id)
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
            writeAndFlag(content: vm.chunk.content, chunkID: chunkID)
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
        showToast("已复制整棵记录")
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

    private func writeAndFlag(content: String, chunkID: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(content, forType: .string) else {
            showToast("复制失败")
            return
        }
        ClipboardSession.shared.beginCopy(content: content, chunkID: chunkID)
        showToast("已复制")
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

    // MARK: - 分页导航

    func goNewer() {
        guard cursor > 0 else { return }
        cursor -= 1
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        // 翻页后固定回到该屏顶部，避免停留在上一屏的滚动深度造成“原地跳变”
        scrollTargetTreeID = rows.first?.id
    }

    func goOlder() {
        guard cursor < units.count - 1 else { return }
        cursor += 1
        expandedTreeID = nil
        highlightedChunkID = nil
        loadPage()
        scrollTargetTreeID = rows.first?.id
    }

    /// 直接回到最新记录所在的那一屏
    func goToNewestPage() {
        guard cursor > 0 else { return }
        cursor = 0
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

    /// 数据变更引发列表重排后，把当前页切换到包含 treeID 的那一屏，并请求滚动到该记录。
    /// 必须在 reload()（latestMetas / units / rows 已更新）之后调用。
    func revealTree(_ treeID: String, expand: Bool) {
        guard store != nil,
              let idx = latestMetas.firstIndex(where: { $0.id == treeID })
        else {
            if expand { expandedTreeID = nil }
            return
        }
        let meta = latestMetas[idx]
        let range = TimeUtil.dayRangeMs(meta.updatedAtMs)
        let dayKey = TimeUtil.dayKey(meta.updatedAtMs)
        let rank = latestMetas[0..<idx].filter { $0.updatedAtMs >= range.start && $0.updatedAtMs < range.end }.count
        let pageNo = rank / Config.pageSize
        guard let unitIdx = units.firstIndex(where: { $0.dayKey == dayKey && $0.pageNo == pageNo }) else {
            if expand { expandedTreeID = nil }
            return
        }
        if cursor != unitIdx {
            cursor = unitIdx
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
            let metas = try store.allTreeMetas()
            latestMetas = metas
            var buckets: [DayBucket] = []
            for m in metas {
                let range = TimeUtil.dayRangeMs(m.updatedAtMs)
                if var last = buckets.last, last.startMs == range.start {
                    last.count += 1
                    buckets[buckets.count - 1] = last
                } else {
                    buckets.append(
                        DayBucket(
                            key: TimeUtil.dayKey(range.start),
                            startMs: range.start,
                            endMs: range.end,
                            count: 1
                        )
                    )
                }
            }
            var newUnits: [PageUnit] = []
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
                            count: cnt,
                            pageNo: p,
                            pagesInDay: pages
                        )
                    )
                }
            }
            units = newUnits
            if cursor >= units.count {
                cursor = max(0, units.count - 1)
            }
            loadPage()
        } catch {
            NSLog("reload error: \(error)")
            clearRows()
        }
    }

    private func clearRows() {
        rows = []
        dayTitle = "暂无记录"
        dayMetaText = ""
        hasNewer = false
        hasOlder = false
    }

    private func loadPage() {
        guard let store else {
            clearRows()
            return
        }
        guard !units.isEmpty else {
            clearRows()
            return
        }
        let u = units[cursor]
        guard
            let trees = try? store.fetchTrees(
                startMs: u.dayStartMs,
                endMs: u.dayEndMs,
                limit: u.count,
                offset: u.offsetInDay
            )
        else {
            clearRows()
            return
        }
        rows = trees.map { TreeRowVM(tree: $0) }
        dayTitle = TimeUtil.dayLabel(ms: u.dayStartMs)
        dayMetaText = u.pagesInDay > 1
            ? "共 \(u.dayCount) 条 · 第 \(u.pageNo + 1)/\(u.pagesInDay) 屏"
            : "共 \(u.dayCount) 条 · 全部"
        hasNewer = cursor > 0
        hasOlder = cursor < units.count - 1
    }

    /// 变更后若树的归属天与当前显示天不同，跳到新归属天的第一页（通常在今天）
    private func relocateIfNeeded(_ info: MutationInfo) {
        guard !units.isEmpty else { return }
        let currentKey = units[cursor].dayKey
        guard currentKey != info.newDay else { return }
        if let idx = units.firstIndex(where: { $0.dayKey == info.newDay && $0.pageNo == 0 }) {
            cursor = idx
            loadPage()
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

    // MARK: - 杂项

    private func cleaned(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func showToast(_ text: String) {
        lastToast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.lastToast = nil
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }
}
