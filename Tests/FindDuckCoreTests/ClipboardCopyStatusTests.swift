import XCTest
@testable import FindDuck

final class ClipboardCopyStatusTests: XCTestCase {
    func testOnlyCurrentPasteboardCopyIsMarked() {
        let first = UUID(), second = UUID()
        var status = ClipboardCopyStatus(entryID: first, plainText: false, changeCount: 10)
        XCTAssertFalse(status.invalidateIfChanged(10))
        XCTAssertEqual(status.entryID, first)
        status = ClipboardCopyStatus(entryID: second, plainText: true, changeCount: 12)
        XCTAssertNotEqual(status.entryID, first)
        XCTAssertEqual(status.entryID, second)
        XCTAssertTrue(status.plainText)
        XCTAssertTrue(status.invalidateIfChanged(14))
        XCTAssertNil(status.entryID)
        XCTAssertFalse(status.invalidateIfChanged(14))
    }
}
