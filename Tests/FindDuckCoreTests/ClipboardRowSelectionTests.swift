import XCTest
import Combine
@testable import FindDuck

@MainActor final class ClipboardRowSelectionTests: XCTestCase {
    func testOnlyOldAndNewRowsPublishWhileOtherRowsStayUntouched() {
        let selection = ClipboardRowSelection()
        let ids = (0..<523).map { _ in UUID() }
        let flags = ids.map { selection.flag(for: $0) }
        var changes: [Int] = []
        let subscriptions = flags.enumerated().map { index, flag in
            flag.objectWillChange.sink { changes.append(index) }
        }
        withExtendedLifetime(subscriptions) {
            selection.select(ids[0])
            XCTAssertEqual(changes, [0])
            changes.removeAll()
            for _ in 0..<10000 { selection.select(ids[0]) }
            XCTAssertTrue(changes.isEmpty)
            selection.select(ids[1])
            XCTAssertEqual(changes, [0, 1])
            XCTAssertFalse(flags[0].isSelected)
            XCTAssertTrue(flags[1].isSelected)
            XCTAssertEqual(flags.filter(\.isSelected).count, 1)
        }
    }
    func testUncreatedRowsAndRemovalRetainCorrectSelection() {
        let selection = ClipboardRowSelection()
        let id = UUID()
        selection.select(id)
        let flag = selection.flag(for: id)
        XCTAssertTrue(flag.isSelected)
        selection.retain([])
        XCTAssertNil(selection.selectedID)
        XCTAssertFalse(flag.isSelected)
        XCTAssertFalse(selection.flag(for: id).isSelected)
    }
    func testConfirmationLocksAnchorUntilCancelledAndCleansUpRemovedRows() {
        let selection = ClipboardRowSelection()
        let a = UUID(), b = UUID()
        let flag = selection.flag(for: a)
        selection.setConfirmation(true, for: a)
        XCTAssertEqual(selection.selectedID, a)
        XCTAssertTrue(flag.deleteConfirmation)
        selection.select(b)
        XCTAssertEqual(selection.selectedID, a)
        selection.setConfirmation(false, for: a)
        selection.select(b)
        XCTAssertEqual(selection.selectedID, b)
        XCTAssertFalse(flag.deleteConfirmation)
        selection.setConfirmation(true, for: a)
        selection.retain([b])
        XCTAssertNil(selection.confirmingID)
        XCTAssertNil(selection.selectedID)
        XCTAssertFalse(flag.deleteConfirmation)
    }
}
