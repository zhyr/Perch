import Foundation

// MARK: - 全局配置

enum Config {
    /// 60 秒合并窗口：与最后一次更新的 chunk 间隔在此范围内，复制会并入同一 maintree
    static let mergeWindowMs: Int64 = 60_000
    /// 外部复制可入库的最小长度（不计空白）：少于该长度视为无意义复制，先入库再按规则清理
    static let minCaptureTextLen = 5
    /// 每屏最大条数
    static let pageSize = 10
    /// 窗口可调最小尺寸
    static let panelMinWidth: CGFloat = 380
    static let panelMinHeight: CGFloat = 492
    /// 窗口默认尺寸
    static let panelWidth: CGFloat = 480
    static let panelHeight: CGFloat = 600
    /// 窗口可调最大尺寸
    static let panelMaxWidth: CGFloat = 700
    static let panelMaxHeight: CGFloat = 800
}

// MARK: - 应用品牌信息

enum AppInfo {
    /// 中文名
    static let zhName = "栖痕"
    /// 英文名
    static let enName = "Perch"
}

// MARK: - 路径

enum AppPaths {
    /// 数据目录名（曾用 RecordTree，首次运行会自动迁移旧目录）
    static let dataFolderName = AppInfo.enName
    private static let legacyFolderName = "RecordTree"

    /// “自定义数据文件夹”持久化键（通过设置页选择，可指向 iCloud Drive / 其它同步盘）
    private static let syncRootPathKey = "storage.syncRootPath"
    private static let syncRootBookmarkKey = "storage.syncRootBookmark"

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 默认本机存储：~/Documents/Perch
    static var localDefaultRootURL: URL {
        documentsURL.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// 当前生效的数据根目录（启动时经 restoreConfiguredRoot 决定）
    private(set) static var overrideRoot: URL?
    static var rootURL: URL { overrideRoot ?? localDefaultRootURL }
    static var isUsingCustomRoot: Bool { overrideRoot != nil }
    static var dbURL: URL { rootURL.appendingPathComponent("recordtree.sqlite") }

    /// 图片附件目录（相对路径记录于 chunk.attachment，随数据目录跨设备同步）
    static var imagesRootURL: URL {
        rootURL.appendingPathComponent("images", isDirectory: true)
    }

    /// 由 chunk.attachment（相对路径，如 images/2026-09-04/xxx.png）解析绝对 URL
    static func attachmentURL(relativePath: String) -> URL? {
        guard relativePath.hasPrefix("images/") else { return nil }
        return rootURL.appendingPathComponent(relativePath)
    }

    // MARK: - 自定义同步文件夹

    /// 启动时恢复用户选择的数据目录（优先书签，其次路径）。
    /// 目标必须仍然存在且可读，否则回落到本机存储，避免静默写错位置。
    static func restoreConfiguredRoot() {
        overrideRoot = nil
        let fm = FileManager.default
        let prefs = UserDefaults.standard

        var resolved: URL?
        if let data = prefs.data(forKey: syncRootBookmarkKey) {
            var stale = false
            if let u = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                resolved = u
                if stale, let refreshed = try? u.bookmarkData(
                    options: [], includingResourceValuesForKeys: nil, relativeTo: nil
                ) {
                    prefs.set(refreshed, forKey: syncRootBookmarkKey)
                }
            }
        }
        if resolved == nil, let path = prefs.string(forKey: syncRootPathKey) {
            resolved = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let root = resolved?.standardizedFileURL else { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard fm.isReadableFile(atPath: root.path), fm.isWritableFile(atPath: root.path) else { return }
        overrideRoot = root
    }

    static func configureRoot(_ url: URL) {
        overrideRoot = url.standardizedFileURL
    }

    static func saveConfiguredRoot(_ url: URL) {
        let prefs = UserDefaults.standard
        prefs.set(url.path, forKey: syncRootPathKey)
        if let data = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            prefs.set(data, forKey: syncRootBookmarkKey)
        }
    }

    static func clearConfiguredRoot() {
        overrideRoot = nil
        let prefs = UserDefaults.standard
        prefs.removeObject(forKey: syncRootPathKey)
        prefs.removeObject(forKey: syncRootBookmarkKey)
    }

    /// 界面展示用
    static var storageModeLabel: String {
        let p = rootURL.path.lowercased()
        if p.contains("mobile documents") || p.contains("com~apple~clouddocs") {
            return "iCloud Drive 同步"
        }
        return isUsingCustomRoot ? "自定义同步文件夹" : "本机存储"
    }

    /// 旧版（RecordTree 目录）数据仅迁移一次（仅在本机默认目录场景）
    static func migrateLegacyDataIfNeeded() {
        guard overrideRoot == nil else { return }
        let fm = FileManager.default
        let legacy = documentsURL.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: rootURL.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: rootURL)
        } catch {
            NSLog("数据目录迁移失败（将使用全新空目录）: \(error)")
        }
    }
    private static var markdownRoot: URL {
        rootURL.appendingPathComponent("markdown", isDirectory: true)
    }
    static func hourlyMarkdownURL(dayKey: String, hour: String) -> URL {
        markdownRoot.appendingPathComponent("hourly", isDirectory: true)
            .appendingPathComponent(dayKey, isDirectory: true)
            .appendingPathComponent("\(hour).md")
    }
    static func dailyMarkdownURL(dayKey: String) -> URL {
        markdownRoot.appendingPathComponent("daily", isDirectory: true)
            .appendingPathComponent("\(dayKey).md")
    }
    static func ensureDirs() throws {
        migrateLegacyDataIfNeeded()
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: imagesRootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: markdownRoot, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: markdownRoot.appendingPathComponent("hourly", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: markdownRoot.appendingPathComponent("daily", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - 时间工具（毫秒时间戳）

enum TimeUtil {
    static func msNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func date(fromMs ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0) }

    private static func makeFmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "zh_CN")
        d.timeZone = .current
        d.dateFormat = f
        return d
    }
    private static let dayKeyFmt = makeFmt("yyyy-MM-dd")
    private static let hourKeyFmt = makeFmt("HH")
    private static let clockFmt = makeFmt("HH:mm:ss")
    private static let monthDayFmt = makeFmt("M月d日 EEEE")
    private static let titleDateFmt = makeFmt("MM/dd EEE")

    static func dayKey(_ ms: Int64) -> String { dayKeyFmt.string(from: date(fromMs: ms)) }
    static func hourKey(_ ms: Int64) -> String { hourKeyFmt.string(from: date(fromMs: ms)) }
    static func clock(_ ms: Int64) -> String { clockFmt.string(from: date(fromMs: ms)) }
    static func monthDay(_ ms: Int64) -> String { monthDayFmt.string(from: date(fromMs: ms)) }

    /// 底部日期标题：09/05 周六 这种 mm/dd + 短星期格式
    static func titleDate(ms: Int64) -> String { titleDateFmt.string(from: date(fromMs: ms)) }

    /// 同一天内只显示时分秒，否则补上日期
    static func displayTime(_ ms: Int64) -> String {
        isSameDay(ms, msNow()) ? clock(ms) : "\(dayKey(ms)) \(clock(ms))"
    }

    static func parseDayKey(_ key: String) -> Date? {
        dayKeyFmt.date(from: key)
    }

    static func dayRangeMs(_ ms: Int64) -> (start: Int64, end: Int64) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date(fromMs: ms))
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    static func dayRangeMs(ofDayKey key: String) -> (start: Int64, end: Int64)? {
        guard let d = parseDayKey(key) else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: d)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    /// 今天 / 昨天 / M月d日 周x
    static func dayLabel(ms: Int64) -> String {
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date())
        let d1 = cal.startOfDay(for: date(fromMs: ms))
        let days = cal.dateComponents([.day], from: d0, to: d1).day ?? 0
        switch days {
        case 0: return "今天"
        case -1: return "昨天"
        default: return monthDay(ms)
        }
    }

    static func isSameDay(_ a: Int64, _ b: Int64) -> Bool {
        let cal = Calendar.current
        return cal.isDate(date(fromMs: a), inSameDayAs: date(fromMs: b))
    }
}

// MARK: - 预览文本工具

enum PreviewUtil {
    /// 去换行后取前 maxLen 个字符，超出加省略号
    static func makePreview(_ s: String, maxLen: Int = 20) -> String {
        let flat = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maxLen else { return flat }
        return String(flat.prefix(maxLen)) + "…"
    }
}

// MARK: - 复制内容规则（用于剪贴板监听入库后的清理判定）

enum CaptureFilter {
    /// 文字的有效字数：忽略全部空白后统计字符数（中文“字”与英文“字符”等价计数）。
    static func visibleTextLength(_ s: String) -> Int {
        s.filter { !$0.isWhitespace }.count
    }

    /// 是否属于“过短复制”（不计空白少于 Config.minCaptureTextLen），应被清理而不保留入库。
    static func isTooShort(_ s: String) -> Bool {
        visibleTextLength(s) < Config.minCaptureTextLen
    }
}
