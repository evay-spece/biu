import XCTest
@testable import FindDuck

final class TextRowSelectionTests: XCTestCase {
    func testStationaryPointerCannotStealKeyboardSelectionDuringScroll() {
        let input = TextRowSelectionInput()
        let point = CGPoint(x: 200, y: 300)
        XCTAssertTrue(input.acceptsPointer(at: point))
        input.useKeyboard(at: point)
        XCTAssertFalse(input.acceptsPointer(at: point))
        XCTAssertFalse(input.acceptsPointer(at: CGPoint(x: 200.5, y: 300)))
        input.useKeyboard(at: point)
        XCTAssertFalse(input.acceptsPointer(at: point))
        XCTAssertTrue(input.acceptsPointer(at: CGPoint(x: 202, y: 300)))
        XCTAssertTrue(input.acceptsPointer(at: CGPoint(x: 202, y: 300)))
    }
    func testExplicitClickCanTakeOverWithoutPointerMotion() {
        let input = TextRowSelectionInput()
        let point = CGPoint.zero
        input.useKeyboard(at: point)
        XCTAssertFalse(input.acceptsPointer(at: point))
        input.usePointer()
        XCTAssertTrue(input.acceptsPointer(at: point))
    }
}
