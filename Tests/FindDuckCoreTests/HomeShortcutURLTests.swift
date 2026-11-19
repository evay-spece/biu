import XCTest
import Foundation
@testable import FindDuck

@MainActor final class HomeShortcutURLTests:XCTestCase {
    func testWebsiteShortcutsStayWebURLsAcrossRepeatedReloads() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let storage=root.appendingPathComponent("home.json")
        var home=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertTrue(home.add(title:"HTTPS site",kind:.website,target:"https://example.com/path"))
        XCTAssertTrue(home.add(title:"HTTP site",kind:.website,target:"http://example.org"))

        for _ in 0..<10 {home=HomeLibrary(storage:storage,seedDefaults:false)}
        let websites=home.items.filter {$0.kind == .website}
        XCTAssertEqual(websites.count,2)
        XCTAssertNil(websites[0].localFileURL)
        XCTAssertNil(websites[0].annotationURL)
        XCTAssertEqual(websites[0].openURL?.absoluteString,"https://example.com/path")
        XCTAssertEqual(websites[1].openURL?.absoluteString,"http://example.org")
    }

    func testLocalFileAndFolderKeepAnnotationAndOpenURLs() {
        let file=HomeShortcut(title:"Report",kind:.file,target:"/tmp/Report.pdf")
        let folder=HomeShortcut(title:"Projects",kind:.folder,target:"/tmp/Projects")
        XCTAssertEqual(file.annotationURL?.path,"/tmp/Report.pdf")
        XCTAssertEqual(file.openURL?.path,"/tmp/Report.pdf")
        XCTAssertEqual(folder.annotationURL?.path,"/tmp/Projects")
        XCTAssertEqual(folder.openURL?.path,"/tmp/Projects")
    }

    func testActionsDoNotProduceFileURLs() {
        let action=HomeShortcut(title:"Settings",kind:.action,target:"设置")
        XCTAssertNil(action.localFileURL)
        XCTAssertNil(action.annotationURL)
        XCTAssertNil(action.openURL)
    }
}
