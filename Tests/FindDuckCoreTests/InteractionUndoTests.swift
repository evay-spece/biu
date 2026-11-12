import XCTest
@testable import FindDuck

@MainActor final class InteractionUndoTests: XCTestCase {
    func testEscapeCancelsLatestConditionInsteadOfRestoringPriorValues() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SearchLibrary(storage: root)
        defer { model.shutdown() }
        model.query = "合"
        model.query = "合同"
        model.category = .pdf
        model.category = .word
        model.toggleTagSelection("sample")
        XCTAssertTrue(model.consumeEscape())
        XCTAssertTrue(model.selectedTagIDs.isEmpty)
        XCTAssertEqual(model.category, .word)
        XCTAssertTrue(model.consumeEscape())
        XCTAssertEqual(model.category, .all)
        XCTAssertEqual(model.query, "合同")
        XCTAssertTrue(model.consumeEscape())
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.consumeEscape())
    }

    func testDirectorySwitchCancelsScopeAndRemovedTagsStayRemoved() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SearchLibrary(storage: root)
        defer { model.shutdown() }
        let first = root.appendingPathComponent("a")
        let second = root.appendingPathComponent("b")
        model.activateDirectory(first)
        model.activateDirectory(second)
        XCTAssertTrue(model.consumeEscape())
        XCTAssertNil(model.directoryScope)
        model.toggleTagSelection("tag")
        model.toggleTagSelection("tag")
        XCTAssertFalse(model.consumeEscape())
        XCTAssertTrue(model.selectedTagIDs.isEmpty)
    }

    func testRepeatedValuesShareOneCancellationAndInactiveConditionsAreRemoved() {
        var conditions = FilterCancellation<String>()
        conditions.record("query", active: true)
        conditions.record("query", active: true)
        conditions.record("category", active: true)
        conditions.record("category", active: true)
        XCTAssertEqual(conditions.pop(), "category")
        XCTAssertEqual(conditions.pop(), "query")
        XCTAssertNil(conditions.pop())
        conditions.record("tag", active: true)
        conditions.record("tag", active: false)
        XCTAssertNil(conditions.pop())
    }
}
