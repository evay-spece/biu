import XCTest
@testable import FindDuck

final class ApplicationNamesTests: XCTestCase {
    func testSystemStyleLocalizationTablePrefersSimplifiedChinese() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Calculator.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Calculator", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let table = ["zh_TW": ["CFBundleDisplayName": "計算機"], "en": ["CFBundleDisplayName": "Calculator"], "zh_CN": ["CFBundleDisplayName": "计算器"]]
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        let names = ApplicationNames.read(app)
        XCTAssertEqual(names.displayName, "计算器")
        XCTAssertTrue(names.matches("Calculator"))
        XCTAssertTrue(names.matches("计算器"))
    }
    func testChineseDisplayAndEnglishAliasesFromBundleWithoutRenamingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("EnglishUtility.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.biu.names." + UUID().uuidString,
                    "CFBundleName": "Utility", "CFBundleDisplayName": "English Utility", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for (language, name) in [("zh-Hant", "工具繁體"), ("zh-Hans", "中文工具"), ("en", "English Utility")] {
            let folder = resources.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": name], format: .binary, options: 0)
                .write(to: folder.appendingPathComponent("InfoPlist.strings"))
        }
        let names = ApplicationNames.read(app)
        XCTAssertEqual(names.displayName, "中文工具")
        for term in ["中文", "工具繁體", "english utility", "EnglishUtility", "Utility", ""] {
            XCTAssertTrue(names.matches(term), term)
        }
        XCTAssertFalse(names.matches("Unrelated"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testCatalogSearchFindsSameApplicationThroughChineseAndEnglishNames() async {
        var app = FileHit(url: URL(fileURLWithPath: "/Applications/EnglishUtility.app"))
        app.applicationNames = ApplicationNames(displayName: "中文工具", aliases: ["EnglishUtility", "中文工具"])
        let engine = OilQueryEngine(applicationCatalog: [app])
        for term in ["EnglishUtility", "中文", ""] {
            let result = await engine.search(local: [], sharedSnapshot: nil, term: term, category: .all,
                sort: .name, preferences: DuckPreferences(), opened: [:], limit: 20,
                scopeRoot: URL(fileURLWithPath: "/Applications"))
            XCTAssertEqual(result.hits.map(\.id), [app.id])
            XCTAssertEqual(result.hits.first?.applicationDisplayName, "中文工具")
        }
    }

    func testIndexedApplicationKeepsChineseNameWhenSortedByName() async {
        let raw = FileHit(url: URL(fileURLWithPath: "/Applications/EnglishUtility.app"))
        var app = raw
        app.applicationNames = ApplicationNames(displayName: "中文工具", aliases: ["EnglishUtility", "中文工具"])
        let engine = OilQueryEngine(applicationCatalog: [app])
        let snapshot = NameIndex(root: URL(fileURLWithPath: "/"), created: Date(), files: [raw])
        let result = await engine.search(local: [], sharedSnapshot: snapshot, term: "EnglishUtility", category: .all,
            sort: .name, preferences: DuckPreferences(), opened: [:], limit: 20)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.applicationDisplayName, "中文工具")
    }

    func testMissingMetadataFallsBackToOriginalNameAndOldIndexesDecode() throws {
        let url = URL(fileURLWithPath: "/no-such-directory/PlainUtility.app")
        let names = ApplicationNames.read(url)
        XCTAssertEqual(names.displayName, "PlainUtility")
        XCTAssertTrue(names.matches("plainutility"))
        let old = Data(#"{"url":"file:///Applications/Old.app"}"#.utf8)
        let file = try JSONDecoder().decode(FileHit.self, from: old)
        XCTAssertNil(file.applicationNames)
        XCTAssertEqual(file.applicationDisplayName, "Old")
        var updated = file
        updated.applicationNames = names
        XCTAssertEqual(try JSONDecoder().decode(FileHit.self, from: JSONEncoder().encode(updated)), updated)
    }
}
