import XCTest
@testable import FindDuck

final class ClipboardDayGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func entry(_ day: Int, _ hour: Int, _ minute: Int = 0) -> ClipboardEntry {
        ClipboardEntry(kind: .text, text: "sample", imageName: nil, fingerprint: UUID().uuidString, captured: date(day, hour, minute))
    }
    func testOldDaysMergeIntoThreePartsRegardlessOfCopyGaps() {
        let entries = [entry(6, 0), entry(6, 11, 59), entry(6, 12), entry(6, 17, 59), entry(6, 18), entry(6, 23, 59)]
        let now = date(7, 10)
        let groups = ClipboardSession.group(entries, now: now, calendar: calendar)
        XCTAssertEqual(groups.map { $0.entries.count }, [2, 2, 2])
        XCTAssertEqual(groups.map { $0.title(now: now, calendar: calendar) }, ["昨天 · 晚上", "昨天 · 下午", "昨天 · 早上"])
        XCTAssertEqual(groups.flatMap(\.entries).map(\.id), entries.reversed().map(\.id))
    }
    func testTodayKeepsTenMinuteSessionsAndDoesNotJoinYesterdayAtMidnight() {
        let yesterday = entry(6, 23, 59), midnight = entry(7, 0, 1), next = entry(7, 0, 11), split = entry(7, 0, 22)
        let groups = ClipboardSession.group([yesterday, midnight, next, split], now: date(7, 1), calendar: calendar)
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [[split.id], [next.id, midnight.id], [yesterday.id]])
    }
    func testDifferentOldDatesNeverMergeAndRolloverRegroupsToday() {
        let older = entry(5, 23), yesterday = entry(6, 0), a = entry(7, 9), b = entry(7, 11)
        let before = ClipboardSession.group([older, yesterday, a, b], now: date(7, 12), calendar: calendar)
        XCTAssertEqual(before.count, 4)
        let after = ClipboardSession.group([older, yesterday, a, b], now: date(8, 0), calendar: calendar)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0].title(now: date(8, 0), calendar: calendar), "昨天 · 早上")
        XCTAssertEqual(after[2].title(now: date(8, 0), calendar: calendar), "11月5日 · 晚上")
    }
}
