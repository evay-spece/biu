import XCTest
@testable import FindDuck

final class HomeApplicationNamesTests: XCTestCase {
    private func fixture(_ root:URL)->URL {
        root.appendingPathComponent("EnglishUtility.app")
    }
    private func createApplication(_ root:URL) throws -> URL {
        let app=fixture(root)
        let resources=app.appendingPathComponent("Contents/Resources/zh-Hans.lproj")
        let executable=app.appendingPathComponent("Contents/MacOS/Utility")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        let info=["CFBundleName":"EnglishUtility","CFBundleIdentifier":"test.biu.home."+UUID().uuidString,"CFBundlePackageType":"APPL","CFBundleExecutable":"Utility"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList:["CFBundleDisplayName":"中文工具"],format:.binary,options:0).write(to:resources.appendingPathComponent("InfoPlist.strings"))
        return app
    }

    @MainActor func testPickerPinAndFileEntryAllUseSameChineseName() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=try createApplication(root)
        for method in 0..<3 {
            let home=HomeLibrary(storage:root.appendingPathComponent("home-\(method).json"),seedDefaults:false)
            switch method {
            case 0:XCTAssertTrue(home.add(title:"EnglishUtility",kind:.application,target:app.path))
            case 1:XCTAssertTrue(home.pin(app))
            default:XCTAssertTrue(home.add(title:"EnglishUtility.app",kind:.file,target:app.path))
            }
            XCTAssertEqual(home.items.first?.title,"中文工具")
            XCTAssertEqual(home.items.first?.kind,.application)
            XCTAssertEqual(home.items.first?.target,app.path)
            XCTAssertFalse(home.pin(app))
        }
    }

    @MainActor func testExistingDefaultNamesMigrateButCustomRenamePersists() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=try createApplication(root),storage=root.appendingPathComponent("home.json")
        let old=HomeShortcut(title:"EnglishUtility.app",kind:.application,target:app.path)
        struct OldSettings:Encodable {let items:[HomeShortcut];let resumeWindowSeconds:Double}
        try JSONEncoder().encode(OldSettings(items:[old],resumeWindowSeconds:120)).write(to:storage)
        let home=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertEqual(home.items.first?.title,"中文工具")
        XCTAssertEqual(home.items.first?.id,old.id)
        home.rename(home.items[0],title:"我的工作工具")
        XCTAssertEqual(HomeLibrary(storage:storage,seedDefaults:false).items.first?.title,"我的工作工具")
    }

    @MainActor func testNoChineseNameDropsAppSuffixWithoutChangingOrdinaryFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let home=HomeLibrary(storage:root.appendingPathComponent("home.json"),seedDefaults:false)
        XCTAssertTrue(home.add(title:"Plain.app",kind:.application,target:root.appendingPathComponent("Plain.app").path))
        XCTAssertEqual(home.items[0].title,"Plain")
        XCTAssertTrue(home.add(title:"报告.pdf",kind:.file,target:root.appendingPathComponent("报告.pdf").path))
        XCTAssertEqual(home.items[1].title,"报告.pdf")
    }
}
