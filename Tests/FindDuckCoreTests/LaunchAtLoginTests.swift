import XCTest
import ServiceManagement
@testable import FindDuck

@MainActor final class LaunchAtLoginTests: XCTestCase {
    func testRequiresApprovalIsShownAsRequestedAndRefreshesExternalChange() {
        var actual: SMAppService.Status = .notRegistered
        let model = LaunchAtLogin(readStatus: { actual }, register: { actual = .requiresApproval }, unregister: { actual = .notRegistered })
        XCTAssertFalse(model.requested)
        model.setEnabled(true)
        XCTAssertTrue(model.requested)
        XCTAssertTrue(model.needsApproval)
        actual = .enabled; model.refresh()
        XCTAssertTrue(model.requested)
        XCTAssertFalse(model.needsApproval)
        model.setEnabled(false)
        XCTAssertFalse(model.requested)
    }
    func testFailedRegistrationAndRemovalRetainSystemTruth() {
        var actual: SMAppService.Status = .notRegistered
        let failure = NSError(domain: "test", code: 1)
        let model = LaunchAtLogin(readStatus: { actual }, register: { throw failure }, unregister: { throw failure })
        model.setEnabled(true)
        XCTAssertFalse(model.requested)
        XCTAssertFalse(model.error.isEmpty)
        actual = .enabled; model.refresh()
        model.setEnabled(false)
        XCTAssertTrue(model.requested)
        XCTAssertFalse(model.error.isEmpty)
    }
}
