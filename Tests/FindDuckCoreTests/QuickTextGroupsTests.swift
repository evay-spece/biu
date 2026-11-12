import XCTest
@testable import FindDuck

@MainActor final class QuickTextGroupsTests: XCTestCase {
    func testLegacyTextsSurviveGroupingRenameAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quick-texts.json")
        let legacy = Data("[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"title\":\"问候\",\"text\":\"你好\"}]".utf8)
        try legacy.write(to: file)
        let library = QuickTextLibrary(file: file)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertNil(library.items[0].group)
        XCTAssertTrue(library.createGroup("工作"))
        var item = library.items[0]
        item.group = "工作"
        XCTAssertTrue(library.save(item))
        XCTAssertEqual(QuickTextLibrary(file: file).items[0].group, "工作")
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("before-groups")), legacy)
        XCTAssertFalse(library.createGroup(" 工作 "))
        XCTAssertTrue(library.renameGroup("工作", to: "客户"))
        XCTAssertEqual(QuickTextLibrary(file: file).items[0].group, "客户")
        XCTAssertTrue(library.removeGroup("客户"))
        let loaded = QuickTextLibrary(file: file)
        XCTAssertNil(loaded.items[0].group)
        XCTAssertEqual(loaded.items[0].text, "你好")
        XCTAssertEqual(loaded.items[0].id, item.id)
        XCTAssertTrue(loaded.groups.isEmpty)
    }

    func testUnreadableFileIsNotOverwrittenAndEmptyGroupsPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("texts.json")
        let library = QuickTextLibrary(file: file)
        XCTAssertTrue(library.createGroup("回复"))
        XCTAssertEqual(QuickTextLibrary(file: file).groups, ["回复"])
        let invalid = Data("invalid".utf8)
        try invalid.write(to: file)
        let damaged = QuickTextLibrary(file: file)
        XCTAssertFalse(damaged.save(QuickText(title: "测试", text: "内容")))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
    func testDragReorderAndMoveAcrossGroupsPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("texts.json")
        let library = QuickTextLibrary(file: file)
        let first = QuickText(title: "一", text: "1", group: "工作")
        let hidden = QuickText(title: "二", text: "2", group: "生活")
        let last = QuickText(title: "三", text: "3", group: "工作")
        for item in [first, hidden, last] { XCTAssertTrue(library.save(item)) }
        XCTAssertTrue(library.move(last.id, relativeTo: first.id, after: false))
        XCTAssertEqual(library.items.map(\.id), [last.id, first.id, hidden.id])
        XCTAssertTrue(library.move(last.id, relativeTo: first.id, after: true))
        XCTAssertEqual(library.items.map(\.id), [first.id, last.id, hidden.id])
        XCTAssertTrue(library.move(first.id, toGroup: "生活"))
        XCTAssertEqual(library.items.map(\.id), [last.id, hidden.id, first.id])
        XCTAssertEqual(library.items.last?.group, "生活")
        XCTAssertTrue(library.move(first.id, toGroup: nil))
        let reloaded = QuickTextLibrary(file: file)
        XCTAssertEqual(reloaded.items, library.items)
        XCTAssertNil(reloaded.items.last?.group)
        let before = reloaded.items
        XCTAssertFalse(reloaded.move(first.id, toGroup: "不存在"))
        XCTAssertFalse(reloaded.move(UUID(), relativeTo: last.id, after: true))
        XCTAssertFalse(reloaded.move(first.id, relativeTo: first.id, after: true))
        XCTAssertEqual(reloaded.items, before)
        XCTAssertNil(QuickTextDrag.identifier(["plain text"]))
        XCTAssertNil(QuickTextDrag.identifier([QuickTextDrag.prefix + "invalid"]))
        XCTAssertEqual(QuickTextDrag.identifier([QuickTextDrag.prefix + first.id.uuidString]), first.id)
    }

    func testFailedDragSaveLeavesInMemoryOrderAndGroupsIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("storage")
        let library = QuickTextLibrary(file: directory.appendingPathComponent("texts.json"))
        let first = QuickText(title: "一", text: "1")
        let second = QuickText(title: "二", text: "2", group: "工作")
        XCTAssertTrue(library.save(first))
        XCTAssertTrue(library.save(second))
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("backup"))
        try Data().write(to: directory)
        let before = library.items
        XCTAssertFalse(library.move(second.id, relativeTo: first.id, after: false))
        XCTAssertEqual(library.items, before)
        XCTAssertFalse(library.move(first.id, toGroup: "工作"))
        XCTAssertEqual(library.items, before)
    }

    func testClipboardAssociationPersistsAndFollowsEditsAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("texts.json")
        let clipboardID = UUID()
        let library = QuickTextLibrary(file: file)
        var item = QuickText(title: "地址", text: "初始内容", sourceClipboardID: clipboardID)
        XCTAssertTrue(library.save(item))
        let reloaded = QuickTextLibrary(file: file)
        XCTAssertEqual(reloaded.item(fromClipboard: clipboardID)?.id, item.id)
        item.text = "更新后的常用文本"
        XCTAssertTrue(reloaded.save(item))
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(QuickTextLibrary(file: file).item(fromClipboard: clipboardID)?.text, item.text)
        reloaded.remove(item)
        XCTAssertNil(QuickTextLibrary(file: file).item(fromClipboard: clipboardID))
    }

}
