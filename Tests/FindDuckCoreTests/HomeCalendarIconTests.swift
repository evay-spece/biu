import XCTest
@testable import FindDuck

final class HomeCalendarIconTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testMidnightChangesDateAndWeekday() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let before = HomeCalendarDay(date: date("2026-11-08T15:59:59Z"), timeZone: zone)
        let after = HomeCalendarDay(date: date("2026-11-08T16:00:00Z"), timeZone: zone)
        XCTAssertEqual(before.day, 8)
        XCTAssertEqual(before.weekday, "周日")
        XCTAssertEqual(after.day, 9)
        XCTAssertEqual(after.weekday, "周一")
        XCTAssertNotEqual(before.key, after.key)
    }
    func testTimeZoneChangeCanChangeDisplayedDay() {
        let instant = date("2026-11-08T18:00:00Z")
        let china = HomeCalendarDay(date: instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let utc = HomeCalendarDay(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(china.day, 9)
        XCTAssertEqual(utc.day, 8)
        XCTAssertNotEqual(china.key, utc.key)
    }
    @MainActor func testOnlyCalendarIsReplacedAndImageIsCachedByDay() {
        XCTAssertTrue(HomeCalendarIcon.isCalendar("/System/Applications/Calendar.app"))
        XCTAssertFalse(HomeCalendarIcon.isCalendar("/System/Library/CoreServices/Finder.app"))
        let first = HomeCalendarIcon.image(for: date("2026-11-08T00:00:00Z"))
        let sameDay = HomeCalendarIcon.image(for: date("2026-11-08T00:01:00Z"))
        let tomorrow = HomeCalendarIcon.image(for: date("2026-11-09T00:00:00Z"))
        XCTAssertTrue(first === sameDay)
        XCTAssertFalse(first === tomorrow)
        XCTAssertNotNil(first.tiffRepresentation)
        XCTAssertEqual(first.size.width, 256)
    }
}
