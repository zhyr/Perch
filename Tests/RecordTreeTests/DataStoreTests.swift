import XCTest
@testable import RecordTree

/// DataStore 测试辅助：在临时目录创建独立数据库，测试后自动清理。
final class DataStoreTestHelper {
    let tmpURL: URL
    let store: DataStore

    init() throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordTreeTest_\(UUID().uuidString)", isDirectory: true)
        AppPaths.configureRoot(tmpURL)
        store = try DataStore()
    }

    deinit {
        try? store.close()
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - 数据插入

    /// 插入一条剪贴板文本记录（每条间隔 >60s 以避免合并到同一棵树）
    @discardableResult
    func insertClipboard(content: String, source: String = "TestApp", atMs: Int64) throws -> MutationInfo {
        try store.performExternalCopy(content: content, source: source, atMs: atMs)
    }

    /// 插入一条剪贴板图片记录
    @discardableResult
    func insertClipboardImage(content: String, attachment: String, source: String = "TestApp", atMs: Int64) throws -> MutationInfo {
        try store.performExternalImageCopy(content: content, attachment: attachment, source: source, atMs: atMs)
    }

    /// 插入一条笔记
    @discardableResult
    func insertNote(title: String, content: String, atMs: Int64) throws -> MutationInfo {
        try store.performManualNewRecord(title: title, content: content, atMs: atMs)
    }

    // MARK: - 时间工具

    /// 生成指定日期某时刻的毫秒时间戳
    static func ms(year: Int, month: Int, day: Int, hour: Int = 9, minute: Int = 0) -> Int64 {
        var comp = DateComponents()
        comp.year = year
        comp.month = month
        comp.day = day
        comp.hour = hour
        comp.minute = minute
        comp.timeZone = .current
        let d = Calendar.current.date(from: comp)!
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// 同一天中指定时分的时间戳（基于某天的 startOfDay）
    static func msOnDay(_ startMs: Int64, hour: Int, minute: Int = 0) -> Int64 {
        let d = TimeUtil.date(fromMs: startMs)
        var comp = Calendar.current.dateComponents([.year, .month, .day], from: d)
        comp.hour = hour
        comp.minute = minute
        comp.timeZone = .current
        let result = Calendar.current.date(from: comp)!
        return Int64(result.timeIntervalSince1970 * 1000)
    }
}

// MARK: - 搜索功能测试

final class DataStoreSearchTests: XCTestCase {

    func testSearch_byContent() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "Hello World", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "Swift编程指南", atMs: Self.ms(9, 15, 10))
        try h.insertClipboard(content: "Another text", atMs: Self.ms(9, 15, 11))

        let results = try h.store.searchChunks(keyword: "Swift")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].content, "Swift编程指南")
    }

    func testSearch_byTitle() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "项目计划", content: "今天开会", atMs: Self.ms(9, 15, 9))
        try h.insertNote(title: "日记", content: "天气晴朗", atMs: Self.ms(9, 15, 10))

        let results = try h.store.searchChunks(keyword: "项目")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].treeTitle, "项目计划")
    }

    func testSearch_returnsAttachmentAndTreeKind() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "文本记录", atMs: Self.ms(9, 15, 9))
        try h.insertClipboardImage(content: "图片描述", attachment: "images/2026-09-15/abc.png", atMs: Self.ms(9, 15, 10))
        try h.insertNote(title: "笔记", content: "笔记内容", atMs: Self.ms(9, 15, 11))

        let textResults = try h.store.searchChunks(keyword: "文本")
        XCTAssertEqual(textResults.count, 1)
        XCTAssertEqual(textResults[0].attachment, "")
        XCTAssertEqual(textResults[0].treeKind, "clipboard")
        XCTAssertFalse(textResults[0].isImage)

        let imgResults = try h.store.searchChunks(keyword: "图片")
        XCTAssertEqual(imgResults.count, 1)
        XCTAssertEqual(imgResults[0].attachment, "images/2026-09-15/abc.png")
        XCTAssertEqual(imgResults[0].treeKind, "clipboard")
        XCTAssertTrue(imgResults[0].isImage)

        let noteResults = try h.store.searchChunks(keyword: "笔记")
        XCTAssertFalse(noteResults.isEmpty)
        XCTAssertEqual(noteResults[0].treeKind, "note")
    }

    func testSearch_emptyKeyword_returnsEmpty() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "Some text", atMs: Self.ms(9, 15, 9))

        XCTAssertTrue(try h.store.searchChunks(keyword: "").isEmpty)
        XCTAssertTrue(try h.store.searchChunks(keyword: "   ").isEmpty)
    }

    func testSearch_noMatch_returnsEmpty() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "Hello", atMs: Self.ms(9, 15, 9))

        XCTAssertTrue(try h.store.searchChunks(keyword: "不存在的关键词xyz").isEmpty)
    }

    func testSearch_caseInsensitive() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "Hello World", atMs: Self.ms(9, 15, 9))

        XCTAssertEqual(try h.store.searchChunks(keyword: "hello").count, 1)
        XCTAssertEqual(try h.store.searchChunks(keyword: "HELLO").count, 1)
        XCTAssertEqual(try h.store.searchChunks(keyword: "HeLLo").count, 1)
    }

    func testSearch_likeWildcardsEscaped() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "折扣50%优惠", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "另一条记录", atMs: Self.ms(9, 15, 10))

        // 搜索 "50%" 不应匹配所有记录（如果 % 未被转义，会匹配全部）
        let results = try h.store.searchChunks(keyword: "50%")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].content, "折扣50%优惠")
    }

    func testSearch_underscoreEscaped() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "user_id", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "userid", atMs: Self.ms(9, 15, 10))

        // 搜索 "user_" 如果 _ 未被转义，会匹配两条（_ 匹配任意单字符）
        let results = try h.store.searchChunks(keyword: "user_")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].content, "user_id")
    }

    func testSearch_multipleMatches() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "Hello Alice", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "Hello Bob", atMs: Self.ms(9, 15, 10))
        try h.insertClipboard(content: "Goodbye", atMs: Self.ms(9, 15, 11))

        let results = try h.store.searchChunks(keyword: "Hello")
        XCTAssertEqual(results.count, 2)
    }

    func testSearch_orderedByUpdatedAtDesc() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "旧笔记", content: "keyword", atMs: Self.ms(9, 14, 9))
        try h.insertNote(title: "新笔记", content: "keyword", atMs: Self.ms(9, 15, 9))

        let results = try h.store.searchChunks(keyword: "keyword")
        XCTAssertEqual(results.count, 2)
        // 更新的排在前面
        XCTAssertGreaterThan(results[0].treeUpdatedAtMs, results[1].treeUpdatedAtMs)
        XCTAssertEqual(results[0].treeTitle, "新笔记")
        XCTAssertEqual(results[1].treeTitle, "旧笔记")
    }

    private static func ms(_ month: Int, _ day: Int, _ hour: Int) -> Int64 {
        DataStoreTestHelper.ms(year: 2026, month: month, day: day, hour: hour)
    }
}

// MARK: - 剪贴板历史分页测试

final class DataStoreClipboardPaginationTests: XCTestCase {

    func testClipboardHistoryTimes_descending() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "A", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "B", atMs: Self.ms(9, 15, 10))
        try h.insertClipboard(content: "C", atMs: Self.ms(9, 14, 9))

        let times = try h.store.clipboardHistoryUpdatedMsDesc()
        XCTAssertEqual(times.count, 3)
        // 倒序排列
        XCTAssertGreaterThan(times[0], times[1])
        XCTAssertGreaterThan(times[1], times[2])
    }

    func testClipboardHistoryTimes_onlyClipboardKind() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "clip", atMs: Self.ms(9, 15, 9))
        try h.insertNote(title: "note", content: "note", atMs: Self.ms(9, 15, 10))

        let times = try h.store.clipboardHistoryUpdatedMsDesc()
        // 笔记不应出现在剪贴板历史中
        XCTAssertEqual(times.count, 1)
    }

    func testFetchClipboardPage_dayRange() throws {
        let h = try DataStoreTestHelper()
        let day1Ms = Self.ms(9, 15, 9)
        try h.insertClipboard(content: "今天1", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "今天2", atMs: Self.ms(9, 15, 14))
        try h.insertClipboard(content: "昨天1", atMs: Self.ms(9, 14, 9))

        let day1Range = TimeUtil.dayRangeMs(day1Ms)
        let items = try h.store.fetchClipboardHistoryPage(
            startMs: day1Range.start, endMs: day1Range.end, limit: 100, offset: 0
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.content.hasPrefix("今天") })
    }

    func testFetchClipboardPage_offsetAndLimit() throws {
        let h = try DataStoreTestHelper()
        let baseMs = Self.ms(9, 15, 9)
        let dayRange = TimeUtil.dayRangeMs(baseMs)

        // 插入 15 条记录（同一天，每条间隔 2 分钟 >60s 避免合并）
        for i in 0..<15 {
            try h.insertClipboard(content: "item_\(i)", atMs: baseMs + Int64(i * 2) * 60_000)
        }

        // 第一页：10 条
        let page1 = try h.store.fetchClipboardHistoryPage(
            startMs: dayRange.start, endMs: dayRange.end, limit: 10, offset: 0
        )
        XCTAssertEqual(page1.count, 10)

        // 第二页：5 条
        let page2 = try h.store.fetchClipboardHistoryPage(
            startMs: dayRange.start, endMs: dayRange.end, limit: 10, offset: 10
        )
        XCTAssertEqual(page2.count, 5)

        // 确保两页内容不重叠
        let page1Contents = Set(page1.map { $0.content })
        let page2Contents = Set(page2.map { $0.content })
        XCTAssertTrue(page1Contents.isDisjoint(with: page2Contents))
    }

    func testFetchClipboardPage_emptyDay() throws {
        let h = try DataStoreTestHelper()
        let emptyDayMs = Self.ms(9, 13, 9)
        let range = TimeUtil.dayRangeMs(emptyDayMs)

        let items = try h.store.fetchClipboardHistoryPage(
            startMs: range.start, endMs: range.end, limit: 10, offset: 0
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testClipboardHistoryCount() throws {
        let h = try DataStoreTestHelper()
        try h.insertClipboard(content: "A", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "B", atMs: Self.ms(9, 15, 11))
        try h.insertNote(title: "N", content: "N", atMs: Self.ms(9, 15, 10))

        let count = try h.store.clipboardHistoryCount()
        XCTAssertEqual(count, 2)
    }

    func testFetchClipboardPage_imageItem() throws {
        let h = try DataStoreTestHelper()
        let baseMs = Self.ms(9, 15, 9)
        try h.insertClipboardImage(
            content: "图片描述", attachment: "images/2026-09-15/test.png", atMs: baseMs
        )

        let range = TimeUtil.dayRangeMs(baseMs)
        let items = try h.store.fetchClipboardHistoryPage(
            startMs: range.start, endMs: range.end, limit: 10, offset: 0
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].attachment, "images/2026-09-15/test.png")
        XCTAssertTrue(items[0].isImage)
    }

    private static func ms(_ month: Int, _ day: Int, _ hour: Int) -> Int64 {
        DataStoreTestHelper.ms(year: 2026, month: month, day: day, hour: hour)
    }
}

// MARK: - 笔记分页测试

final class DataStoreNotePaginationTests: XCTestCase {

    func testAllNoteTreeMetas_count() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "N1", content: "C1", atMs: Self.ms(9, 15, 9))
        try h.insertNote(title: "N2", content: "C2", atMs: Self.ms(9, 15, 10))
        try h.insertClipboard(content: "clip", atMs: Self.ms(9, 15, 11))

        let metas = try h.store.allNoteTreeMetas()
        XCTAssertEqual(metas.count, 2)
    }

    func testAllNoteTreeMetas_orderedByUpdatedDesc() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "旧", content: "C", atMs: Self.ms(9, 14, 9))
        try h.insertNote(title: "新", content: "C", atMs: Self.ms(9, 15, 9))

        let metas = try h.store.allNoteTreeMetas()
        XCTAssertEqual(metas.count, 2)
        XCTAssertGreaterThan(metas[0].updatedAtMs, metas[1].updatedAtMs)
    }

    func testFetchNoteTreesPage_firstPage() throws {
        let h = try DataStoreTestHelper()
        let base = Self.ms(9, 15, 8)
        for i in 0..<15 {
            try h.insertNote(title: "笔记\(i)", content: "内容\(i)", atMs: base + Int64(i * 2) * 60_000)
        }

        let page1 = try h.store.fetchNoteTreesPage(limit: 10, offset: 0)
        XCTAssertEqual(page1.count, 10)

        let page2 = try h.store.fetchNoteTreesPage(limit: 10, offset: 10)
        XCTAssertEqual(page2.count, 5)

        // 两页不重叠
        let ids1 = Set(page1.map { $0.id })
        let ids2 = Set(page2.map { $0.id })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }

    func testTagsGrouped_treeAndChunk() throws {
        let h = try DataStoreTestHelper()
        let info = try h.insertNote(title: "标签笔记", content: "正文", atMs: Self.ms(9, 15, 9))
        try h.store.setTags(itemType: "tree", itemID: info.treeID, names: ["工作"])
        try h.store.setTags(itemType: "chunk", itemID: info.chunkID ?? "", names: ["docker"])

        let trees = try h.store.tagsGrouped(itemType: "tree", itemIDs: [info.treeID])
        let chunks = try h.store.tagsGrouped(itemType: "chunk", itemIDs: [info.chunkID ?? ""])
        XCTAssertEqual(trees[info.treeID], ["工作"])
        XCTAssertEqual(chunks[info.chunkID ?? ""], ["docker"])
        XCTAssertTrue(try h.store.tagsGrouped(itemType: "tree", itemIDs: []).isEmpty)
    }

    func testFetchNoteTreesPage_empty() throws {
        let h = try DataStoreTestHelper()

        let page = try h.store.fetchNoteTreesPage(limit: 10, offset: 0)
        XCTAssertTrue(page.isEmpty)
    }

    func testFetchNoteTreesPage_offsetBeyondData() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "N", content: "C", atMs: Self.ms(9, 15, 9))

        let page = try h.store.fetchNoteTreesPage(limit: 10, offset: 10)
        XCTAssertTrue(page.isEmpty)
    }

    func testFetchNoteTreesPage_onlyNotes() throws {
        let h = try DataStoreTestHelper()
        try h.insertNote(title: "笔记", content: "C", atMs: Self.ms(9, 15, 9))
        try h.insertClipboard(content: "剪贴板", atMs: Self.ms(9, 15, 10))

        let page = try h.store.fetchNoteTreesPage(limit: 10, offset: 0)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page[0].title, "笔记")
        XCTAssertTrue(page[0].isNote)
    }

    private static func ms(_ month: Int, _ day: Int, _ hour: Int) -> Int64 {
        DataStoreTestHelper.ms(year: 2026, month: month, day: day, hour: hour)
    }
}
