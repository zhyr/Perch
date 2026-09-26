import XCTest
@testable import RecordTree

/// 分页逻辑测试。
///
/// rebuildClipboardUnits 是 AppModel 的 private 方法，无法直接测试。
/// 这里通过 recreate 相同算法的辅助结构来验证分页数学的正确性，
/// 同时用 DataStore 验证真实数据查询的端到端行为。
final class PaginationLogicTests: XCTestCase {

    // MARK: - 测试用分页算法镜像
    // 以下结构和方法镜像 AppModel.rebuildClipboardUnits 的逻辑，
    // 用于独立验证算法正确性。

    struct TestPageUnit: Equatable {
        let dayKey: String
        let dayStartMs: Int64
        let dayEndMs: Int64
        let dayCount: Int
        let offsetInDay: Int
        let count: Int
        let pageNo: Int
        let pagesInDay: Int
    }

    struct TestDayBucket {
        let key: String
        let startMs: Int64
        let endMs: Int64
        var count: Int
    }

    /// 镜像 rebuildClipboardUnits 的分桶 + 分页算法
    static func buildUnits(times: [Int64], pageSize: Int) -> [TestPageUnit] {
        var buckets: [TestDayBucket] = []
        for t in times {
            let range = TimeUtil.dayRangeMs(t)
            if var last = buckets.last, last.startMs == range.start {
                last.count += 1
                buckets[buckets.count - 1] = last
            } else {
                buckets.append(
                    TestDayBucket(key: TimeUtil.dayKey(range.start), startMs: range.start, endMs: range.end, count: 1)
                )
            }
        }

        var units: [TestPageUnit] = []
        for b in buckets {
            let pages = max(1, (b.count + pageSize - 1) / pageSize)
            for p in 0..<pages {
                let off = p * pageSize
                let cnt = min(pageSize, b.count - off)
                units.append(
                    TestPageUnit(
                        dayKey: b.key, dayStartMs: b.startMs, dayEndMs: b.endMs,
                        dayCount: b.count, offsetInDay: off, count: cnt,
                        pageNo: p, pagesInDay: pages
                    )
                )
            }
        }
        return units
    }

    /// 镜像 rebuildClipboardUnits 的游标回退逻辑
    static func resolveCursor(
        units: [TestPageUnit],
        keepDayKey: String?,
        keepingPageNo: Int = 0
    ) -> Int {
        guard let keep = keepDayKey, !keep.isEmpty, !units.isEmpty else {
            return 0
        }
        let targetPage = max(0, keepingPageNo)
        if let idx = units.firstIndex(where: { $0.dayKey == keep && $0.pageNo == targetPage }) {
            return idx
        } else if let firstOfDay = units.firstIndex(where: { $0.dayKey == keep }) {
            let lastOfDay = units.lastIndex(where: { $0.dayKey == keep }) ?? firstOfDay
            return lastOfDay
        } else if let firstEarlier = units.firstIndex(where: { $0.dayKey < keep }) {
            return firstEarlier
        } else {
            return units.count - 1
        }
    }

    // MARK: - 日期分桶测试

    func testDayBucketing_singleDay() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<3).map { Self.plusMin(base, $0 * 10) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].dayCount, 3)
        XCTAssertEqual(units[0].pageNo, 0)
        XCTAssertEqual(units[0].pagesInDay, 1)
        XCTAssertEqual(units[0].count, 3)
        XCTAssertEqual(units[0].offsetInDay, 0)
    }

    func testDayBucketing_multipleDays() {
        let day1 = Self.ms(9, 15, 8)
        let day2 = Self.ms(9, 14, 8)
        let times = [
            Self.plusMin(day1, 0),
            Self.plusMin(day2, 0),
            Self.plusMin(day2, 10),
        ]
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 2)
        // 第一天（时间更晚）在前
        XCTAssertEqual(units[0].dayCount, 1)
        XCTAssertEqual(units[1].dayCount, 2)
    }

    func testDayBucketing_emptyData() {
        let units = Self.buildUnits(times: [], pageSize: 10)
        XCTAssertTrue(units.isEmpty)
    }

    func testDayBucketing_gapDays() {
        // 今天有记录，昨天没有，前天有记录 → 应产生 2 个桶（不补空天）
        let day1 = Self.ms(9, 15, 8)
        let day3 = Self.ms(9, 13, 8)
        let times = [day1, day3]
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 2)
        let dayKeys = units.map { $0.dayKey }
        XCTAssertEqual(dayKeys.count, 2)
    }

    // MARK: - 页码计算测试

    func testPageCount_exactlyOnePage() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<10).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].pagesInDay, 1)
        XCTAssertEqual(units[0].count, 10)
    }

    func testPageCount_twoPages() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<15).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].pagesInDay, 2)
        XCTAssertEqual(units[0].pageNo, 0)
        XCTAssertEqual(units[0].count, 10)
        XCTAssertEqual(units[1].pageNo, 1)
        XCTAssertEqual(units[1].count, 5)
    }

    func testPageCount_singleItem() {
        let base = Self.ms(9, 15, 8)
        let times = [base]
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].pagesInDay, 1)
        XCTAssertEqual(units[0].count, 1)
    }

    func testPageCount_pageSizeMinusOne() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<9).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].count, 9)
    }

    func testPageCount_pageSizePlusOne() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<11).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].count, 10)
        XCTAssertEqual(units[1].count, 1)
    }

    // MARK: - 游标回退逻辑测试

    func testCursorResolve_exactMatch() {
        let day1 = Self.ms(9, 15, 8)
        let day2 = Self.ms(9, 14, 8)
        let times = (0..<15).map { Self.plusMin(day1, $0 * 2) } + [day2]
        let units = Self.buildUnits(times: times, pageSize: 10)
        let day1Key = TimeUtil.dayKey(day1)

        // 精确命中第 1 页（pageNo=1）
        let cursor = Self.resolveCursor(units: units, keepDayKey: day1Key, keepingPageNo: 1)
        XCTAssertEqual(units[cursor].pageNo, 1)
        XCTAssertEqual(units[cursor].dayKey, day1Key)
    }

    func testCursorResolve_pageMissing_fallbackToLastPage() {
        // 当天有 15 条（2 页），但请求第 3 页（不存在）
        let base = Self.ms(9, 15, 8)
        let times = (0..<15).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)
        let dayKey = TimeUtil.dayKey(base)

        let cursor = Self.resolveCursor(units: units, keepDayKey: dayKey, keepingPageNo: 5)
        // 应回退到该天最后一页
        XCTAssertEqual(units[cursor].dayKey, dayKey)
        XCTAssertEqual(units[cursor].pageNo, 1) // 最后一页
    }

    func testCursorResolve_dayMissing_fallbackToEarlierDay() {
        // 今天 + 前天有记录，昨天没有
        // 请求昨天（不存在），应跳到前天
        let day1 = Self.ms(9, 15, 8)
        let day3 = Self.ms(9, 13, 8)
        let times = [day1, day3]
        let units = Self.buildUnits(times: times, pageSize: 10)

        let yesterdayKey = TimeUtil.dayKey(Self.ms(9, 14, 8))
        let cursor = Self.resolveCursor(units: units, keepDayKey: yesterdayKey)

        // 应跳到前天（更早的一天）
        let day3Key = TimeUtil.dayKey(day3)
        XCTAssertEqual(units[cursor].dayKey, day3Key)
    }

    func testCursorResolve_targetOlderThanAll_fallbackToOldest() {
        // 只有今天 + 昨天有记录
        // 请求一周前（比所有天都老），应跳到最老一屏
        let day1 = Self.ms(9, 15, 8)
        let day2 = Self.ms(9, 14, 8)
        let times = [day1, day2]
        let units = Self.buildUnits(times: times, pageSize: 10)

        let veryOldKey = "2026-09-01"
        let cursor = Self.resolveCursor(units: units, keepDayKey: veryOldKey)

        // 应跳到最老一屏（最后一个 unit）
        XCTAssertEqual(cursor, units.count - 1)
        XCTAssertEqual(units[cursor].dayKey, TimeUtil.dayKey(day2))
    }

    func testCursorResolve_nilDay_returnsZero() {
        let base = Self.ms(9, 15, 8)
        let times = (0..<3).map { Self.plusMin(base, $0 * 2) }
        let units = Self.buildUnits(times: times, pageSize: 10)

        let cursor = Self.resolveCursor(units: units, keepDayKey: nil)
        XCTAssertEqual(cursor, 0)
    }

    func testCursorResolve_emptyData_returnsZero() {
        let units: [TestPageUnit] = []
        let cursor = Self.resolveCursor(units: units, keepDayKey: "2026-09-15")
        XCTAssertEqual(cursor, 0)
    }

    func testCursorResolve_emptyStringDay_returnsZero() {
        let base = Self.ms(9, 15, 8)
        let times = [base]
        let units = Self.buildUnits(times: times, pageSize: 10)

        let cursor = Self.resolveCursor(units: units, keepDayKey: "")
        XCTAssertEqual(cursor, 0)
    }

    // MARK: - 端到端分页验证（使用 DataStore）

    func testEndToEnd_multipleDaysPagination() throws {
        let h = try DataStoreTestHelper()
        let day1 = Self.ms(9, 15, 8)
        let day2 = Self.ms(9, 14, 8)

        // 今天 15 条（2 页），昨天 5 条（1 页）
        // 每条间隔 2 分钟（>60s 合并窗口），每条创建独立 chunk
        for i in 0..<15 {
            try h.insertClipboard(content: "today_\(i)", atMs: Self.plusMin(day1, i * 2))
        }
        for i in 0..<5 {
            try h.insertClipboard(content: "yesterday_\(i)", atMs: Self.plusMin(day2, i * 2))
        }

        let times = try h.store.clipboardHistoryUpdatedMsDesc()
        let units = Self.buildUnits(times: times, pageSize: Config.pageSize)

        // 今天 2 页 + 昨天 1 页 = 3 个分页单元
        XCTAssertEqual(units.count, 3)

        // 验证第一页是今天的最新 10 条
        let page1 = try h.store.fetchClipboardHistoryPage(
            startMs: units[0].dayStartMs, endMs: units[0].dayEndMs,
            limit: units[0].count, offset: units[0].offsetInDay
        )
        XCTAssertEqual(page1.count, 10)

        // 验证第二页是今天剩余 5 条
        let page2 = try h.store.fetchClipboardHistoryPage(
            startMs: units[1].dayStartMs, endMs: units[1].dayEndMs,
            limit: units[1].count, offset: units[1].offsetInDay
        )
        XCTAssertEqual(page2.count, 5)

        // 验证第三页是昨天的 5 条
        let page3 = try h.store.fetchClipboardHistoryPage(
            startMs: units[2].dayStartMs, endMs: units[2].dayEndMs,
            limit: units[2].count, offset: units[2].offsetInDay
        )
        XCTAssertEqual(page3.count, 5)
        XCTAssertTrue(page3.allSatisfy { $0.content.hasPrefix("yesterday_") })
    }

    func testEndToEnd_gapDayNavigation() throws {
        // 场景：今天有记录，昨天没有，前天有记录
        // 模拟"前一天无记录导致翻页卡 bug"的场景
        let h = try DataStoreTestHelper()
        let today = Self.ms(9, 15, 8)
        let dayBefore = Self.ms(9, 13, 8)

        try h.insertClipboard(content: "today", atMs: today)
        try h.insertClipboard(content: "day_before", atMs: dayBefore)

        let times = try h.store.clipboardHistoryUpdatedMsDesc()
        let units = Self.buildUnits(times: times, pageSize: Config.pageSize)

        // 只有 2 个桶（今天 + 前天），昨天不产生桶
        XCTAssertEqual(units.count, 2)

        // 尝试定位到"昨天"（不存在）
        let yesterdayKey = TimeUtil.dayKey(Self.ms(9, 14, 8))
        let cursor = Self.resolveCursor(units: units, keepDayKey: yesterdayKey)

        // 应回退到前天（第一个更早的天）
        let dayBeforeKey = TimeUtil.dayKey(dayBefore)
        XCTAssertEqual(units[cursor].dayKey, dayBeforeKey)

        // 验证能正确查询前天的数据
        let items = try h.store.fetchClipboardHistoryPage(
            startMs: units[cursor].dayStartMs, endMs: units[cursor].dayEndMs,
            limit: units[cursor].count, offset: units[cursor].offsetInDay
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content, "day_before")
    }

    func testEndToEnd_preservePageAfterDataChange() throws {
        // 场景：用户正在浏览今天第 2 页，有新数据写入后应保持在第 2 页
        let h = try DataStoreTestHelper()
        let today = Self.ms(9, 15, 8)

        // 插入 15 条（2 页）
        for i in 0..<15 {
            try h.insertClipboard(content: "item_\(i)", atMs: Self.plusMin(today, i * 2))
        }

        let times = try h.store.clipboardHistoryUpdatedMsDesc()
        var units = Self.buildUnits(times: times, pageSize: Config.pageSize)
        let todayKey = TimeUtil.dayKey(today)

        // 用户在第 2 页（pageNo=1）
        var cursor = Self.resolveCursor(units: units, keepDayKey: todayKey, keepingPageNo: 1)
        XCTAssertEqual(units[cursor].pageNo, 1)
        XCTAssertEqual(units[cursor].count, 5)

        // 模拟新数据写入（再插入 3 条，今天变为 18 条 = 2 页）
        for i in 15..<18 {
            try h.insertClipboard(content: "new_\(i)", atMs: Self.plusMin(today, i * 2))
        }

        // 重建分页
        let newTimes = try h.store.clipboardHistoryUpdatedMsDesc()
        units = Self.buildUnits(times: newTimes, pageSize: Config.pageSize)

        // 保留第 2 页
        cursor = Self.resolveCursor(units: units, keepDayKey: todayKey, keepingPageNo: 1)
        XCTAssertEqual(units[cursor].pageNo, 1)
        // 第 2 页现在有 8 条（之前 5 + 新增 3）
        XCTAssertEqual(units[cursor].count, 8)
    }

    // MARK: - 笔记分页边界测试

    func testNotePageCount_calculation() {
        let pageSize = Config.pageSize // 10

        XCTAssertEqual(max(1, (0 + pageSize - 1) / pageSize), 1)
        XCTAssertEqual(max(1, (1 + pageSize - 1) / pageSize), 1)
        XCTAssertEqual(max(1, (10 + pageSize - 1) / pageSize), 1)
        XCTAssertEqual(max(1, (11 + pageSize - 1) / pageSize), 2)
        XCTAssertEqual(max(1, (20 + pageSize - 1) / pageSize), 2)
        XCTAssertEqual(max(1, (21 + pageSize - 1) / pageSize), 3)
    }

    func testNotePageBoundary_pageEqualsPageCount() {
        var notePage = 5
        let noteTotal = 25
        let pageSize = Config.pageSize
        let notePageCount = max(1, (noteTotal + pageSize - 1) / pageSize) // 3

        if notePage >= notePageCount {
            notePage = notePageCount - 1
        }
        if notePage < 0 {
            notePage = 0
        }
        XCTAssertEqual(notePage, 2)
    }

    func testNotePageBoundary_negativePage() {
        var notePage = -1
        let noteTotal = 5
        let pageSize = Config.pageSize
        let notePageCount = max(1, (noteTotal + pageSize - 1) / pageSize)

        if notePage >= notePageCount {
            notePage = notePageCount - 1
        }
        if notePage < 0 {
            notePage = 0
        }
        XCTAssertEqual(notePage, 0)
    }

    func testNotePageBoundary_zeroTotal() {
        var notePage = 3
        let noteTotal = 0
        let pageSize = Config.pageSize
        let notePageCount = max(1, (noteTotal + pageSize - 1) / pageSize)

        if notePage >= notePageCount {
            notePage = notePageCount - 1
        }
        if notePage < 0 {
            notePage = 0
        }
        XCTAssertEqual(notePage, 0)
    }

    // MARK: - 时间工具测试

    func testTimeUtil_dayRangeMs_startOfDay() {
        let noonMs = Self.ms(9, 15, 12)
        let range = TimeUtil.dayRangeMs(noonMs)
        let startDay = TimeUtil.date(fromMs: range.start)

        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute, .second], from: startDay)
        XCTAssertEqual(comp.hour, 0)
        XCTAssertEqual(comp.minute, 0)
        XCTAssertEqual(comp.second, 0)
    }

    func testTimeUtil_dayRangeMs_endIsNextDay() {
        let dayMs = Self.ms(9, 15, 12)
        let range = TimeUtil.dayRangeMs(dayMs)
        XCTAssertEqual(range.end - range.start, 86_400_000)
    }

    /// 日界毫秒必须包住原始时间戳，否则分桶会计入、SQL 区间却查不到，历史页变空。
    func testTimeUtil_dayRangeMs_containsSourceTimestamp() {
        let samples: [Int64] = [
            Self.ms(1, 1, 0),
            Self.ms(9, 15, 0),
            Self.ms(9, 15, 23) + 59 * 60_000 + 59_000,
            Self.ms(6, 1, 0),
            TimeUtil.msNow(),
        ]
        for ms in samples {
            let range = TimeUtil.dayRangeMs(ms)
            XCTAssertGreaterThanOrEqual(ms, range.start, "\(ms) 落在区间起点之前")
            XCTAssertLessThan(ms, range.end, "\(ms) 落在区间终点之外")
        }
    }

    func testTimeUtil_dayKey_consistentForSameDay() {
        let morning = Self.ms(9, 15, 6)
        let evening = Self.ms(9, 15, 23)
        XCTAssertEqual(TimeUtil.dayKey(morning), TimeUtil.dayKey(evening))
    }

    func testTimeUtil_dayKey_differentForDifferentDays() {
        let day1 = Self.ms(9, 15, 12)
        let day2 = Self.ms(9, 14, 12)
        XCTAssertNotEqual(TimeUtil.dayKey(day1), TimeUtil.dayKey(day2))
    }

    func testTimeUtil_isSameDay() {
        let morning = Self.ms(9, 15, 6)
        let evening = Self.ms(9, 15, 23)
        let nextDay = Self.ms(9, 16, 0)
        XCTAssertTrue(TimeUtil.isSameDay(morning, evening))
        XCTAssertFalse(TimeUtil.isSameDay(morning, nextDay))
    }

    // MARK: - 辅助方法

    private static func ms(_ month: Int, _ day: Int, _ hour: Int) -> Int64 {
        DataStoreTestHelper.ms(year: 2026, month: month, day: day, hour: hour)
    }

    /// 在某时间戳基础上增加 N 分钟
    private static func plusMin(_ baseMs: Int64, _ minutes: Int) -> Int64 {
        baseMs + Int64(minutes) * 60_000
    }
}
