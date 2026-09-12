import Foundation
import SQLite3

enum DBError: Error {
    case openFailed(String)
    case queryFailed(String)
}

/// SQLite 持久化 + Markdown 按天/小时归档（数据主源为 SQLite）
final class DataStore {
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 最近一次本地写入时间（相对 2001 参考秒），供远端变更监视器判定是否为自己写入
    static var lastLocalMutationSec: TimeInterval = 0

    // MARK: - 初始化

    init() throws {
        try AppPaths.ensureDirs()
        let path = AppPaths.dbURL.path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw DBError.openFailed("无法打开数据库: \(path)")
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        // 数据目录可能位于 iCloud Drive / 其它同步盘：
        // DELETE 日志 + FULL 同步，避免 WAL 旁文件在跨设备同步时损坏或遗漏。
        try exec("PRAGMA journal_mode=DELETE;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS maintree (
                id          TEXT PRIMARY KEY,
                title       TEXT DEFAULT '',
                kind        TEXT NOT NULL DEFAULT 'clipboard',
                created_at  INTEGER NOT NULL,
                updated_at  INTEGER NOT NULL,
                archived_at INTEGER DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS chunk (
                id             TEXT PRIMARY KEY,
                maintree_id    TEXT NOT NULL REFERENCES maintree(id) ON DELETE CASCADE,
                content        TEXT NOT NULL,
                attachment     TEXT NOT NULL DEFAULT '',
                source_app     TEXT NOT NULL DEFAULT '',
                created_at     INTEGER NOT NULL,
                updated_at     INTEGER NOT NULL,
                last_copied_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_maintree_updated ON maintree (updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_maintree_kind ON maintree (kind, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_chunk_tree ON chunk (maintree_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_chunk_updated ON chunk (updated_at DESC);
            CREATE TABLE IF NOT EXISTS tag (
                id         TEXT PRIMARY KEY,
                name       TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS item_tag (
                item_type  TEXT NOT NULL,
                item_id    TEXT NOT NULL,
                tag_id     TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                created_at INTEGER NOT NULL,
                PRIMARY KEY (item_type, item_id, tag_id)
            );
            CREATE INDEX IF NOT EXISTS idx_item_tag_item ON item_tag (item_type, item_id);
            CREATE INDEX IF NOT EXISTS idx_item_tag_tag ON item_tag (tag_id);
            """
        )
        // 兼容旧库：加上 title / archived_at 列
        _ = try? exec("ALTER TABLE maintree ADD COLUMN title TEXT DEFAULT '';")
        _ = try? exec("ALTER TABLE maintree ADD COLUMN archived_at INTEGER DEFAULT 0;")
        // 兼容旧库：区分笔记 / 剪切板记录
        _ = try? exec("ALTER TABLE maintree ADD COLUMN kind TEXT NOT NULL DEFAULT 'clipboard';")
        // 兼容旧库：图片等附件相对路径
        _ = try? exec("ALTER TABLE chunk ADD COLUMN attachment TEXT DEFAULT '';")

        // 一次性迁移：把历史记录按分段来源区分为 note / clipboard。
        // 全部分段均为"手动输入"的树判定为 note，其余（含外部复制来源）为 clipboard。
        migrateTreeKindsIfNeeded()
    }

    /// 首次引入 kind 字段时的历史数据分类迁移
    private func migrateTreeKindsIfNeeded() {
        let key = "migratedTreeKinds"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            // 找出所有分段 source_app 均为"手动输入"的树，标记为 note
            try run(
                """
                UPDATE maintree SET kind = 'note' WHERE id IN (
                    SELECT m.id FROM maintree m
                    WHERE NOT EXISTS (
                        SELECT 1 FROM chunk c
                        WHERE c.maintree_id = m.id AND c.source_app != '手动输入'
                    )
                    AND EXISTS (
                        SELECT 1 FROM chunk c WHERE c.maintree_id = m.id
                    )
                )
                """
            )
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("migrateTreeKindsIfNeeded error: \(error)")
        }
    }

    /// 显式关闭数据库（切换存储目录、远端变更重载前调用，会先完成事务落盘）
    func close() throws {
        guard let db else { return }
        let rc = sqlite3_close(db)
        self.db = nil
        if rc != SQLITE_OK {
            throw DBError.queryFailed("sqlite close failed rc=\(rc)")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func noteMutation() {
        DataStore.lastLocalMutationSec = Date.timeIntervalSinceReferenceDate
    }

    // MARK: - 底层封装

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.queryFailed(msg)
        }
    }

    private func run(_ sql: String, _ params: [Any?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.queryFailed(errMsg())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.queryFailed(errMsg())
        }
        noteMutation()
    }

    private func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.queryFailed(errMsg())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let n = sqlite3_column_count(stmt)
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let t = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: t)
                    } else {
                        row[name] = ""
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    break
                }
            }
            out.append(row)
        }
        return out
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            if let p {
                switch p {
                case let v as Int64:
                    sqlite3_bind_int64(stmt, idx, v)
                case let v as Double:
                    sqlite3_bind_double(stmt, idx, v)
                case let v as String:
                    let ns = v as NSString
                    if let c = ns.utf8String {
                        sqlite3_bind_text(stmt, idx, c, -1, sqliteTransient)
                    } else {
                        sqlite3_bind_null(stmt, idx)
                    }
                default:
                    sqlite3_bind_null(stmt, idx)
                }
            } else {
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func errMsg() -> String {
        guard let db else { return "db closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - 行映射

    private func str(_ r: [String: Any], _ k: String) -> String {
        (r[k] as? String) ?? ""
    }
    private func int(_ r: [String: Any], _ k: String) -> Int64 {
        (r[k] as? Int64) ?? 0
    }
    private func intOpt(_ r: [String: Any], _ k: String) -> Int64? {
        if let v = r[k] as? Int64 { return v }
        return nil
    }

    private func tree(from r: [String: Any], chunks: [ChunkRec]) -> TreeRec {
        let archivedRaw = intOpt(r, "aa") ?? 0
        return TreeRec(
            id: str(r, "id"),
            title: str(r, "title"),
            kind: str(r, "kind"),
            archivedAtMs: archivedRaw > 0 ? archivedRaw : nil,
            createdAtMs: int(r, "ca"),
            updatedAtMs: int(r, "ua"),
            chunks: chunks
        )
    }

    private func chunk(from r: [String: Any]) -> ChunkRec {
        ChunkRec(
            id: str(r, "id"),
            maintreeID: str(r, "tid"),
            content: str(r, "content"),
            attachment: str(r, "at"),
            sourceApp: str(r, "sa"),
            createdAtMs: int(r, "ca"),
            updatedAtMs: int(r, "ua"),
            lastCopiedMs: intOpt(r, "lca")
        )
    }

    // MARK: - 基础查询

    /// 全部 maintree 元信息，按更新时间倒序
    func allTreeMetas() throws -> [(id: String, createdAtMs: Int64, updatedAtMs: Int64)] {
        let rows = try query(
            "SELECT id, created_at AS ca, updated_at AS ua FROM maintree ORDER BY updated_at DESC, created_at DESC, id"
        )
        return rows.map { (id: str($0, "id"), createdAtMs: int($0, "ca"), updatedAtMs: int($0, "ua")) }
    }

    /// 全部 maintree 元信息，按更新时间倒序（主列表用）。
    /// 主列表必须展示全部记录（手工笔记 + 剪贴板采集）：
    /// 曾按 kind='note' 过滤导致用户 216 条历史"消失"，已按 2026-09-12 决策恢复全量。
    func allNoteTreeMetas() throws -> [(id: String, createdAtMs: Int64, updatedAtMs: Int64)] {
        let rows = try query(
            "SELECT id, created_at AS ca, updated_at AS ua FROM maintree ORDER BY updated_at DESC, created_at DESC, id"
        )
        return rows.map { (id: str($0, "id"), createdAtMs: int($0, "ca"), updatedAtMs: int($0, "ua")) }
    }

    func treeUpdatedMs(_ treeID: String) throws -> Int64 {
        let rows = try query("SELECT updated_at AS ua FROM maintree WHERE id = ?", [treeID])
        return rows.first.map { int($0, "ua") } ?? 0
    }

    /// 某一天区间内按倒序取一页 maintree（含全部 chunk）
    func fetchTrees(startMs: Int64, endMs: Int64, limit: Int, offset: Int) throws -> [TreeRec] {
        let rows = try query(
            """
            SELECT id, title, kind, created_at AS ca, updated_at AS ua, archived_at AS aa
            FROM maintree
            WHERE updated_at >= ? AND updated_at < ?
            ORDER BY updated_at DESC, created_at DESC, id
            LIMIT ? OFFSET ?
            """,
            [startMs, endMs, Int64(limit), Int64(offset)]
        )
        var out: [TreeRec] = []
        for r in rows {
            let tid = str(r, "id")
            out.append(tree(from: r, chunks: try chunks(ofTree: tid)))
        }
        return out
    }

    /// 某一天区间内按倒序取一页 maintree（主列表用，含全部类型）
    func fetchNoteTrees(startMs: Int64, endMs: Int64, limit: Int, offset: Int) throws -> [TreeRec] {
        let rows = try query(
            """
            SELECT id, title, kind, created_at AS ca, updated_at AS ua, archived_at AS aa
            FROM maintree
            WHERE updated_at >= ? AND updated_at < ?
            ORDER BY updated_at DESC, created_at DESC, id
            LIMIT ? OFFSET ?
            """,
            [startMs, endMs, Int64(limit), Int64(offset)]
        )
        var out: [TreeRec] = []
        for r in rows {
            let tid = str(r, "id")
            out.append(tree(from: r, chunks: try chunks(ofTree: tid)))
        }
        return out
    }

    func chunks(ofTree treeID: String) throws -> [ChunkRec] {
        let rows = try query(
            """
            SELECT id, maintree_id AS tid, content, attachment AS at, source_app AS sa,
                   created_at AS ca, updated_at AS ua, last_copied_at AS lca
            FROM chunk WHERE maintree_id = ?
            ORDER BY updated_at DESC, created_at DESC, id
            """,
            [treeID]
        )
        return rows.map { chunk(from: $0) }
    }

    /// 剪切板历史：取 clipboard 类型树下的全部 chunk，按更新时间倒序（分页）
    func fetchClipboardHistory(limit: Int, offset: Int) throws -> [ClipboardHistoryItem] {
        let rows = try query(
            """
            SELECT c.id AS id, c.maintree_id AS tid, c.content, c.attachment AS at,
                   c.source_app AS sa, c.created_at AS ca, c.updated_at AS ua, c.last_copied_at AS lca
            FROM chunk c
            JOIN maintree m ON m.id = c.maintree_id
            WHERE m.kind = 'clipboard'
            ORDER BY c.updated_at DESC, c.created_at DESC, c.id
            LIMIT ? OFFSET ?
            """,
            [Int64(limit), Int64(offset)]
        )
        return rows.map {
            ClipboardHistoryItem(
                id: str($0, "id"),
                treeID: str($0, "tid"),
                content: str($0, "content"),
                attachment: str($0, "at"),
                sourceApp: str($0, "sa"),
                createdAtMs: int($0, "ca"),
                updatedAtMs: int($0, "ua"),
                lastCopiedMs: intOpt($0, "lca")
            )
        }
    }

    /// 剪切板历史总条数
    func clipboardHistoryCount() throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS c FROM chunk c JOIN maintree m ON m.id = c.maintree_id WHERE m.kind = 'clipboard'"
        )
        return Int(rows.first.map { int($0, "c") } ?? 0)
    }

    /// 全库最后被更新的 chunk（合并候选，仅 clipboard 类型树）
    private func latestUpdatedChunk() throws -> (treeID: String, updatedMs: Int64)? {
        let rows = try query(
            "SELECT c.maintree_id AS tid, c.updated_at AS ua FROM chunk c JOIN maintree m ON m.id = c.maintree_id WHERE m.kind = 'clipboard' ORDER BY c.updated_at DESC, c.created_at DESC LIMIT 1"
        )
        guard let r = rows.first else { return nil }
        return (str(r, "tid"), int(r, "ua"))
    }

    private func chunkInfo(_ chunkID: String) throws -> (treeID: String, content: String, source: String, attachment: String)? {
        let rows = try query(
            "SELECT maintree_id AS tid, content, source_app AS sa, attachment AS at FROM chunk WHERE id = ?",
            [chunkID]
        )
        guard let r = rows.first else { return nil }
        return (str(r, "tid"), str(r, "content"), str(r, "sa"), str(r, "at"))
    }

    private func chunkAttachments(ofTree treeID: String) throws -> [String] {
        let rows = try query(
            "SELECT attachment AS at FROM chunk WHERE maintree_id = ? AND attachment != ''",
            [treeID]
        )
        return rows.compactMap { str($0, "at") }
    }

    // MARK: - 写入操作

    /// 外部文本复制：1 分钟内并入最近更新的 chunk 所在树，否则新建树
    func performExternalCopy(content: String, source: String, atMs: Int64) throws -> MutationInfo {
        try externalInsert(content: content, attachment: "", source: source, atMs: atMs)
    }

    /// 外部图片复制：content 为展示文字，attachment 为图片相对路径（images/...）
    func performExternalImageCopy(content: String, attachment: String, source: String, atMs: Int64) throws -> MutationInfo {
        try externalInsert(content: content, attachment: attachment, source: source, atMs: atMs)
    }

    private func externalInsert(content: String, attachment: String, source: String, atMs: Int64) throws -> MutationInfo {
        let treeID: String
        if let top = try latestUpdatedChunk(), atMs - top.updatedMs <= Config.mergeWindowMs {
            treeID = top.treeID
        } else {
            treeID = newID("tree")
            try run(
                "INSERT INTO maintree (id, title, kind, created_at, updated_at, archived_at) VALUES (?, '', 'clipboard', ?, ?, 0)",
                [treeID, atMs, atMs]
            )
        }
        let oldUpd = try treeUpdatedMs(treeID)
        let chunkID = newID("chunk")
        try run(
            "INSERT INTO chunk (id, maintree_id, content, attachment, source_app, created_at, updated_at, last_copied_at) VALUES (?,?,?,?,?,?,?,NULL)",
            [chunkID, treeID, content, attachment, source, atMs, atMs]
        )
        let newUpd = max(atMs, oldUpd)
        try run("UPDATE maintree SET updated_at = ? WHERE id = ?", [newUpd, treeID])
        return MutationInfo(
            treeID: treeID,
            chunkID: chunkID,
            newTree: oldUpd == 0,
            oldDay: TimeUtil.dayKey(oldUpd == 0 ? atMs : oldUpd),
            newDay: TimeUtil.dayKey(atMs)
        )
    }

    /// 自我复制：只更新时间，不新增 chunk
    func performSelfCopy(chunkID: String, atMs: Int64) throws -> (info: MutationInfo, content: String, source: String)? {
        guard let ci = try chunkInfo(chunkID) else { return nil }
        let oldUpd = try treeUpdatedMs(ci.treeID)
        try run(
            "UPDATE chunk SET updated_at = ?, last_copied_at = ? WHERE id = ?",
            [atMs, atMs, chunkID]
        )
        let newUpd = max(atMs, oldUpd)
        try run("UPDATE maintree SET updated_at = ? WHERE id = ?", [newUpd, ci.treeID])
        let info = MutationInfo(
            treeID: ci.treeID,
            chunkID: chunkID,
            newTree: false,
            oldDay: TimeUtil.dayKey(oldUpd == 0 ? atMs : oldUpd),
            newDay: TimeUtil.dayKey(atMs)
        )
        return (info, ci.content, ci.source)
    }

    /// 手工新建一条记录（含首个 chunk）。
    /// attachment/sourceApp 供「剪切板历史归档为笔记」复用：保留原始来源应用与图片附件，kind 仍为 note。
    func performManualNewRecord(
        title: String,
        content: String,
        atMs: Int64,
        attachment: String = "",
        sourceApp: String = "手动输入"
    ) throws -> MutationInfo {
        let treeID = newID("tree")
        try run(
            "INSERT INTO maintree (id, title, kind, created_at, updated_at, archived_at) VALUES (?, ?, 'note', ?, ?, 0)",
            [treeID, title, atMs, atMs]
        )
        let chunkID = newID("chunk")
        try run(
            "INSERT INTO chunk (id, maintree_id, content, attachment, source_app, created_at, updated_at, last_copied_at) VALUES (?,?,?,?,?,?,?,NULL)",
            [chunkID, treeID, content, attachment, sourceApp, atMs, atMs]
        )
        return MutationInfo(
            treeID: treeID,
            chunkID: chunkID,
            newTree: true,
            oldDay: TimeUtil.dayKey(atMs),
            newDay: TimeUtil.dayKey(atMs)
        )
    }

    /// 手工向已有树追加 chunk
    func performManualAppend(treeID: String, content: String, atMs: Int64) throws -> MutationInfo? {
        let oldUpd = try treeUpdatedMs(treeID)
        guard oldUpd > 0 else { return nil } // 树不存在
        let chunkID = newID("chunk")
        try run(
            "INSERT INTO chunk (id, maintree_id, content, source_app, created_at, updated_at, last_copied_at) VALUES (?,?,?,?,?,?,NULL)",
            [chunkID, treeID, content, "手动输入", atMs, atMs]
        )
        let newUpd = max(atMs, oldUpd)
        try run("UPDATE maintree SET updated_at = ? WHERE id = ?", [newUpd, treeID])
        return MutationInfo(
            treeID: treeID,
            chunkID: chunkID,
            newTree: false,
            oldDay: TimeUtil.dayKey(oldUpd),
            newDay: TimeUtil.dayKey(atMs)
        )
    }

    // MARK: - 归档与搜索

    // MARK: - 删除

    /// 删除整棵 maintree（连同其下全部 chunk 与图片附件）
    func deleteTree(_ treeID: String) throws -> MutationInfo? {
        let rows = try query("SELECT updated_at AS ua FROM maintree WHERE id = ?", [treeID])
        guard let r = rows.first else { return nil }
        let oldUpd = int(r, "ua")
        let day = TimeUtil.dayKey(oldUpd)
        for a in try chunkAttachments(ofTree: treeID) { Self.removeAttachmentIfExists(a) }
        try run("DELETE FROM chunk WHERE maintree_id = ?", [treeID])
        try run("DELETE FROM maintree WHERE id = ?", [treeID])
        return MutationInfo(treeID: treeID, chunkID: nil, newTree: false, oldDay: day, newDay: day)
    }

    /// 删除单个 chunk。若删除的是最后一个 chunk，则整棵树一并删除（避免空树）。
    func deleteChunk(_ chunkID: String) throws -> MutationInfo? {
        guard let ci = try chunkInfo(chunkID) else { return nil }
        let treeID = ci.treeID
        let oldUpd = try treeUpdatedMs(treeID)
        try run("DELETE FROM chunk WHERE id = ?", [chunkID])
        Self.removeAttachmentIfExists(ci.attachment)

        let remain = try query(
            "SELECT COALESCE(MAX(updated_at), 0) AS ua, COUNT(*) AS cnt FROM chunk WHERE maintree_id = ?",
            [treeID]
        )
        guard let rr = remain.first else {
            return nil
        }
        let remainCount = int(rr, "cnt")
        if remainCount == 0 {
            let day = TimeUtil.dayKey(oldUpd)
            try run("DELETE FROM maintree WHERE id = ?", [treeID])
            return MutationInfo(treeID: treeID, chunkID: chunkID, newTree: false, oldDay: day, newDay: day)
        }
        let newUpd = int(rr, "ua")
        try run("UPDATE maintree SET updated_at = ? WHERE id = ?", [newUpd, treeID])
        return MutationInfo(
            treeID: treeID,
            chunkID: chunkID,
            newTree: false,
            oldDay: TimeUtil.dayKey(oldUpd),
            newDay: TimeUtil.dayKey(newUpd)
        )
    }

    /// 批量删除多条整树记录（含其下全部 chunk 与图片附件）。
    /// 一次性聚合受影响的天，供上层统一重写 Markdown 归档。
    struct TreeDeleteSummary {
        /// 实际删除成功的记录 id
        var treeIDs: [String] = []
        var chunkCount: Int = 0
        var dayKeys: Set<String> = []
    }

    func deleteTrees(_ treeIDs: [String]) throws -> TreeDeleteSummary {
        var summary = TreeDeleteSummary()
        guard !treeIDs.isEmpty else { return summary }
        let placeholders = Array(repeating: "?", count: treeIDs.count).joined(separator: ",")
        let params: [Any?] = treeIDs

        // 受影响天（记录原归属天），只统计确实存在的树
        let treeRows = try query(
            "SELECT id, updated_at AS ua FROM maintree WHERE id IN (\(placeholders))",
            params
        )
        for r in treeRows {
            summary.treeIDs.append(str(r, "id"))
            summary.dayKeys.insert(TimeUtil.dayKey(int(r, "ua")))
        }
        guard !summary.treeIDs.isEmpty else { return summary }
        let existParams: [Any?] = summary.treeIDs
        let existPH = Array(repeating: "?", count: summary.treeIDs.count).joined(separator: ",")

        let cntRows = try query(
            "SELECT COUNT(*) AS c FROM chunk WHERE maintree_id IN (\(existPH))",
            existParams
        )
        summary.chunkCount = Int(cntRows.first.map { int($0, "c") } ?? 0)

        // 清理图片附件，再级联删除 chunk 与 maintree
        let attRows = try query(
            "SELECT attachment AS at FROM chunk WHERE maintree_id IN (\(existPH)) AND attachment != ''",
            existParams
        )
        for a in attRows {
            Self.removeAttachmentIfExists(str(a, "at"))
        }
        try run("DELETE FROM chunk WHERE maintree_id IN (\(existPH))", existParams)
        try run("DELETE FROM maintree WHERE id IN (\(existPH))", existParams)
        return summary
    }

    /// 一键清空剪切板历史：删除全部 kind='clipboard' 的树（含分段与图片附件）。
    /// 手工笔记（kind='note'）不受影响。返回删除摘要供事件日志与 Markdown 归档重写。
    func deleteAllClipboardHistory() throws -> TreeDeleteSummary {
        let rows = try query("SELECT id FROM maintree WHERE kind = 'clipboard'")
        let ids = rows.map { str($0, "id") }
        guard !ids.isEmpty else { return TreeDeleteSummary() }
        return try deleteTrees(ids)
    }

    /// 尽力清理附件文件（仅允许删除 images/ 目录内的文件，防止误删其它内容）
    private static func removeAttachmentIfExists(_ relativePath: String) {
        guard !relativePath.isEmpty,
              let url = AppPaths.attachmentURL(relativePath: relativePath)?.standardizedFileURL else { return }
        let images = AppPaths.imagesRootURL.standardizedFileURL.path
        guard url.path.hasPrefix(images + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 一键清空全部：删除所有 maintree 与 chunk（数据不可恢复），返回受影响的天与数量
    func deleteAllRecords() throws -> (trees: Int, chunks: Int, days: [String]) {
        let treeRows = try query("SELECT updated_at AS ua FROM maintree")
        var daySet = Set<String>()
        for r in treeRows {
            daySet.insert(TimeUtil.dayKey(int(r, "ua")))
        }
        let countRows = try query(
            "SELECT (SELECT COUNT(*) FROM maintree) AS t, (SELECT COUNT(*) FROM chunk) AS c"
        )
        let t = countRows.first.map { int($0, "t") } ?? 0
        let c = countRows.first.map { int($0, "c") } ?? 0
        try run("DELETE FROM chunk")
        try run("DELETE FROM maintree")
        try? FileManager.default.removeItem(at: AppPaths.imagesRootURL)
        return (Int(t), Int(c), daySet.sorted())
    }

    func setArchived(treeID: String, archived: Bool, atMs: Int64) throws {
        let value: Int64 = archived ? atMs : 0
        try run("UPDATE maintree SET archived_at = ? WHERE id = ?", [value, treeID])
    }

    func updateTitle(treeID: String, title: String) throws {
        try run("UPDATE maintree SET title = ? WHERE id = ?", [title, treeID])
    }

    /// 更新某个分段的内容（笔记编辑用）
    func updateChunkContent(chunkID: String, content: String, atMs: Int64) throws {
        try run(
            "UPDATE chunk SET content = ?, updated_at = ? WHERE id = ?",
            [content, atMs, chunkID]
        )
    }

    /// 更新 maintree 的更新时间（编辑/追加后用于重排）
    func touchTree(treeID: String, atMs: Int64) throws {
        try run("UPDATE maintree SET updated_at = ? WHERE id = ?", [atMs, treeID])
    }

    func searchChunks(keyword: String) throws -> [SearchResult] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        let pattern = "%\(term)%"
        let rows = try query(
            """
            SELECT c.id AS cid, c.maintree_id AS tid, c.content, c.source_app AS sa,
                   c.updated_at AS cua, m.updated_at AS tua, m.title
            FROM chunk c
            JOIN maintree m ON m.id = c.maintree_id
            WHERE LOWER(c.content) LIKE ? OR LOWER(m.title) LIKE ?
            ORDER BY m.updated_at DESC, c.updated_at DESC
            LIMIT 200
            """,
            [pattern, pattern]
        )
        return rows.map {
            SearchResult(
                chunkID: str($0, "cid"),
                treeID: str($0, "tid"),
                treeTitle: str($0, "title"),
                content: str($0, "content"),
                sourceApp: str($0, "sa"),
                chunkUpdatedAtMs: int($0, "cua"),
                treeUpdatedAtMs: int($0, "tua")
            )
        }
    }

    private func newID(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Markdown 归档

    /// 事件日志文本（小时文件用）
    static func eventBlock(kind: String, content: String, source: String,
                           treeID: String, chunkID: String?, atMs: Int64) -> String {
        var s = "### \(TimeUtil.clock(atMs)) · \(kind)\n"
        s += "- 记录: \(treeID)\n"
        if let cid = chunkID { s += "- 分段: \(cid)\n" }
        s += "- 来源: \(source)\n"
        s += "- 内容:\n\n\(content)\n\n---\n\n"
        return s
    }

    /// 追加一条事件到对应小时 Markdown
    func writeEventLog(atMs: Int64, block: String) throws {
        let day = TimeUtil.dayKey(atMs)
        let hour = TimeUtil.hourKey(atMs)
        let url = AppPaths.hourlyMarkdownURL(dayKey: day, hour: hour)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "# \(AppInfo.zhName) 小时归档 · \(day) \(hour) 时\n\n"
        if !fm.fileExists(atPath: url.path) {
            try (header + block).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        do {
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(block.utf8))
        } catch {
            try (header + block).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 重写某一天的天级 Markdown（树状一览，从 SQLite 生成）
    func rewriteDailyMarkdown(dayKey: String) throws {
        guard let range = TimeUtil.dayRangeMs(ofDayKey: dayKey) else { return }
        let trees = try fetchTrees(startMs: range.start, endMs: range.end, limit: 5000, offset: 0)
        let url = AppPaths.dailyMarkdownURL(dayKey: dayKey)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let text = Self.renderDayMarkdown(dayKey: dayKey, trees: trees)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func renderDayMarkdown(dayKey: String, trees: [TreeRec]) -> String {
        var s = "# \(AppInfo.zhName) 归档 · \(dayKey)\n\n"
        s += "> 记录按最后更新时间归入当天，树内分段按更新时间倒序。\n\n"
        if trees.isEmpty {
            s += "_当天无记录。_\n"
            return s
        }
        for (i, t) in trees.enumerated() {
            let latest = t.latest
            let source = latest?.sourceApp ?? "未知"
            let archived = t.isArchived ? " · 已归档" : ""
            s += "## \(i + 1). 记录 \(t.id)\(archived)\n"
            s += "- 最后更新: \(TimeUtil.displayTime(t.updatedAtMs))\n"
            s += "- 最新来源: \(source)\n"
            s += "- 分段数: \(t.chunks.count)\n\n"
            for (j, c) in t.chunks.enumerated() {
                var line = "\(j + 1). **\(TimeUtil.displayTime(c.updatedAtMs))** 来自 `\(c.sourceApp)`"
                if let lc = c.lastCopiedMs {
                    line += " · 最后复制于 \(TimeUtil.displayTime(lc))"
                }
                if c.attachment.isEmpty {
                    s += line + "\n\n```\n\(c.content)\n```\n\n"
                } else {
                    // daily md 位于 <root>/markdown/daily，附件在 <root>/images，相对路径为 ../..
                    s += line + "\n\n\(c.content)\n\n![附件](../../\(c.attachment))\n\n"
                }
            }
        }
        return s
    }

    // MARK: - 标签

    /// 覆盖式设置某条目（tree/chunk）的标签，按名称自动建 tag；随后清理孤儿标签
    func setTags(itemType: String, itemID: String, names: [String]) throws {
        let cleaned = Array(
            NSOrderedSet(array: names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        ).compactMap { $0 as? String }
        try run("DELETE FROM item_tag WHERE item_type = ? AND item_id = ?", [itemType, itemID])
        for name in cleaned {
            var tagID: String
            let existing = try query("SELECT id FROM tag WHERE name = ?", [name])
            if let row = existing.first {
                tagID = str(row, "id")
            } else {
                tagID = newID("tag")
                try run(
                    "INSERT OR IGNORE INTO tag (id, name, created_at) VALUES (?, ?, ?)",
                    [tagID, name, TimeUtil.msNow()]
                )
                if let again = try query("SELECT id FROM tag WHERE name = ?", [name]).first {
                    // 并发/唯一冲突时以已存在的为准
                    tagID = str(again, "id")
                }
            }
            try run(
                "INSERT OR IGNORE INTO item_tag (item_type, item_id, tag_id, created_at) VALUES (?, ?, ?, ?)",
                [itemType, itemID, tagID, TimeUtil.msNow()]
            )
        }
        // 清理没有任何引用的孤儿标签
        try run(
            "DELETE FROM tag WHERE id NOT IN (SELECT DISTINCT tag_id FROM item_tag)"
        )
        noteMutation()
    }

    /// 某条目的全部标签名
    func tagsForItem(itemType: String, itemID: String) throws -> [String] {
        let rows = try query(
            """
            SELECT t.name AS name FROM item_tag it
            JOIN tag t ON t.id = it.tag_id
            WHERE it.item_type = ? AND it.item_id = ?
            ORDER BY it.created_at ASC, t.name ASC
            """,
            [itemType, itemID]
        )
        return rows.map { str($0, "name") }
    }

    /// 批量取一组树的标签：treeID -> [tagName]（含树自身标签）
    func tagsForTrees(_ treeIDs: [String]) throws -> [String: [String]] {
        guard !treeIDs.isEmpty else { return [:] }
        let ph = treeIDs.map { _ in "?" }.joined(separator: ",")
        var out: [String: [String]] = [:]
        let rows = try query(
            """
            SELECT it.item_id AS tid, t.name AS name FROM item_tag it
            JOIN tag t ON t.id = it.tag_id
            WHERE it.item_type = 'tree' AND it.item_id IN (\(ph))
            ORDER BY it.created_at ASC
            """,
            treeIDs
        )
        for r in rows {
            out[str(r, "tid"), default: []].append(str(r, "name"))
        }
        // 树的分段标签也并入显示（前缀分段·以示区别）
        let crows = try query(
            """
            SELECT c.maintree_id AS tid, t.name AS name FROM item_tag it
            JOIN tag t ON t.id = it.tag_id
            JOIN chunk c ON c.id = it.item_id
            WHERE it.item_type = 'chunk' AND c.maintree_id IN (\(ph))
            ORDER BY it.created_at ASC
            """,
            treeIDs
        )
        for r in crows {
            out[str(r, "tid"), default: []].append(str(r, "name"))
        }
        return out
    }

    struct TagCloudEntry {
        let name: String
        let treeCount: Int
        let chunkCount: Int
        var total: Int { treeCount + chunkCount }
    }

    /// 标签云：按引用条数倒序
    func tagCloud() throws -> [TagCloudEntry] {
        let rows = try query(
            """
            SELECT t.name AS name,
                   (SELECT COUNT(*) FROM item_tag it WHERE it.tag_id = t.id AND it.item_type = 'tree') AS tc,
                   (SELECT COUNT(*) FROM item_tag it WHERE it.tag_id = t.id AND it.item_type = 'chunk') AS cc
            FROM tag t
            ORDER BY (tc + cc) DESC, t.name ASC
            LIMIT 200
            """
        )
        return rows.map { TagCloudEntry(name: str($0, "name"), treeCount: Int(int($0, "tc")), chunkCount: Int(int($0, "cc"))) }
    }

    /// 按标签名取所有相关树（树本身打标 或 其任一分段打标），按树更新时间倒序
    func treesByTag(_ name: String) throws -> [TreeRec] {
        let rows = try query(
            """
            SELECT DISTINCT m.id AS id FROM maintree m
            LEFT JOIN item_tag it_t ON it_t.item_type = 'tree' AND it_t.item_id = m.id
            LEFT JOIN tag t_t ON t_t.id = it_t.tag_id
            LEFT JOIN chunk c ON c.maintree_id = m.id
            LEFT JOIN item_tag it_c ON it_c.item_type = 'chunk' AND it_c.item_id = c.id
            LEFT JOIN tag t_c ON t_c.id = it_c.tag_id
            WHERE t_t.name = ? OR t_c.name = ?
            """,
            [name, name]
        )
        let ids = rows.map { str($0, "id") }
        guard !ids.isEmpty else { return [] }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let trows = try query(
            """
            SELECT id, title, kind, created_at AS ca, updated_at AS ua, archived_at AS aa
            FROM maintree WHERE id IN (\(ph))
            ORDER BY updated_at DESC, created_at DESC, id
            """,
            ids
        )
        var out: [TreeRec] = []
        for r in trows {
            let tid = str(r, "id")
            out.append(tree(from: r, chunks: try chunks(ofTree: tid)))
        }
        return out
    }

    /// 未打标签的树（不含任何 tree 级标签），附上供 AI 打标的合并内容
    struct UntaggedTreeContent {
        let treeID: String
        let title: String
        let merged: String
    }

    func untaggedTreeContents(limit: Int = 300) throws -> [UntaggedTreeContent] {
        let rows = try query(
            """
            SELECT m.id AS id, m.title AS title FROM maintree m
            WHERE NOT EXISTS (
                SELECT 1 FROM item_tag it WHERE it.item_type = 'tree' AND it.item_id = m.id
            )
            ORDER BY m.updated_at DESC
            LIMIT ?
            """,
            [Int64(limit)]
        )
        var out: [UntaggedTreeContent] = []
        for r in rows {
            let tid = str(r, "id")
            let title = str(r, "title")
            let cs = try chunks(ofTree: tid)
            var parts: [String] = []
            if !title.isEmpty { parts.append("标题：\(title)") }
            for c in cs {
                if !c.attachment.isEmpty { parts.append("[图片附件] \(c.content)") }
                else { parts.append(String(c.content.prefix(400))) }
            }
            var merged = parts.joined(separator: "\n")
            if merged.count > 1600 {
                merged = String(merged.prefix(1600))
            }
            out.append(UntaggedTreeContent(treeID: tid, title: title, merged: merged))
        }
        return out
    }

    /// 单棵树的合并内容（供 AI 打标签），树不存在返回 nil
    func mergedContentForTree(treeID: String) throws -> String? {
        let rows = try query("SELECT title FROM maintree WHERE id = ?", [treeID])
        guard let r = rows.first else { return nil }
        let title = str(r, "title")
        let cs = try chunks(ofTree: treeID)
        var parts: [String] = []
        if !title.isEmpty { parts.append("标题：\(title)") }
        for c in cs {
            if !c.attachment.isEmpty { parts.append("[图片附件] \(c.content)") }
            else { parts.append(String(c.content.prefix(400))) }
        }
        var merged = parts.joined(separator: "\n")
        if merged.count > 1600 { merged = String(merged.prefix(1600)) }
        return merged
    }
}
