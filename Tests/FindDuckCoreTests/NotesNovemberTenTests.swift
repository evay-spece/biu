import XCTest
import AppKit
@testable import FindDuck

final class NotesNovemberTenTests:XCTestCase {
    func testCommandAndShiftSelectionAndContextClickPreservesGroup() {
        let ids=["a","b","c","d","e"]
        var selection=ResultSelection()
        selection.select("b",ordered:ids,modifiers:[])
        selection.select("d",ordered:ids,modifiers:.shift)
        XCTAssertEqual(selection.ids,["b","c","d"])
        selection.select("c",ordered:ids,modifiers:[],rightClick:true)
        XCTAssertEqual(selection.ids,["b","c","d"])
        selection.select("a",ordered:ids,modifiers:.command)
        XCTAssertEqual(selection.ids,["a","b","c","d"])
        selection.select("b",ordered:ids,modifiers:.command)
        XCTAssertEqual(selection.ids,["a","c","d"])
        selection.select("e",ordered:ids,modifiers:[],rightClick:true)
        XCTAssertEqual(selection.ids,["e"])
    }
    func testAllProgramOrderingRunningUnpinnedThenRecentThenOthers() {
        let apps=["Other","RecentOld","PinnedRunning","Running","RecentNew"].map {FileHit(url:URL(fileURLWithPath:"/Applications/\($0).app"))}
        let order=ApplicationOrdering(running:[apps[2].id,apps[3].id],pinned:[apps[2].id],recent:[apps[1].id:Date(timeIntervalSince1970:1),apps[4].id:Date(timeIntervalSince1970:2)])
        XCTAssertEqual(apps.sorted(by:order.precedes).map(\.name),["Running.app","RecentNew.app","RecentOld.app","Other.app","PinnedRunning.app"])
    }
    @MainActor func testOldHomeRecentAppLauncherRemovedAndAllProgramsRenamed() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        struct Old:Encodable {let items:[HomeShortcut];let resumeWindowSeconds:Int;let builtinLaunchersAdded:Bool}
        let app=HomeShortcut(title:"用户入口",kind:.application,target:"/Applications/Fixture.app")
        let old=Old(items:[app,HomeShortcut(title:"最近打开 App",kind:.action,target:HomeShortcut.recentAppsTarget),HomeShortcut(title:"应用程序",kind:.action,target:HomeShortcut.applicationsTarget)],resumeWindowSeconds:120,builtinLaunchersAdded:true)
        let path=root.appendingPathComponent("home.json");try JSONEncoder().encode(old).write(to:path)
        let home=HomeLibrary(storage:path,history:UserActionHistory())
        XCTAssertEqual(home.items.first?.id,app.id)
        XCTAssertFalse(home.items.contains {$0.target == HomeShortcut.recentAppsTarget})
        XCTAssertEqual(home.items.last?.title,"所有程序")
    }
    @MainActor func testGroupDeletionWithContentsAndUndoRestoresMediaAndPosition() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let history=UserActionHistory(),library=QuickTextLibrary(file:root.appendingPathComponent("texts.json"),history:history)
        XCTAssertTrue(library.createGroup("A"));XCTAssertTrue(library.createGroup("B"));XCTAssertTrue(library.moveGroup("B",before:"A"));XCTAssertEqual(library.groups,["B","A"])
        let image=NSImage(size:NSSize(width:2,height:2));image.lockFocus();NSColor.red.setFill();NSRect(x:0,y:0,width:2,height:2).fill();image.unlockFocus()
        let item=QuickText(title:"图片",text:"",group:"A")
        XCTAssertTrue(library.save(item,imageData:try XCTUnwrap(image.tiffRepresentation)))
        let saved=try XCTUnwrap(library.items.first),url=try XCTUnwrap(library.imageURL(saved));let data=try Data(contentsOf:url)
        XCTAssertTrue(library.removeGroup("A",deleteContents:true));XCTAssertTrue(library.items.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertTrue(history.undo());XCTAssertEqual(library.groups,["B","A"]);XCTAssertEqual(library.items,[saved]);XCTAssertEqual(try Data(contentsOf:url),data)
        XCTAssertEqual(QuickTextLibrary(file:root.appendingPathComponent("texts.json")).items,[saved])
    }
    @MainActor func testRemoveOnlyGroupAndUndoKeepsTexts() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let history=UserActionHistory(),library=QuickTextLibrary(file:root.appendingPathComponent("texts.json"),history:history)
        XCTAssertTrue(library.save(QuickText(title:"one",text:"text",group:"Group")))
        XCTAssertTrue(library.removeGroup("Group"));XCTAssertNil(library.items.first?.group)
        XCTAssertTrue(history.undo());XCTAssertEqual(library.items.first?.group,"Group")
    }
    @MainActor func testClipboardDeleteAndFavoriteUndoPreservesNewerCopies() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let history=UserActionHistory(),board=NSPasteboard.withUniqueName()
        defer {board.releaseGlobally()}
        let store=ClipboardHistoryStore(directory:root,pasteboard:board,monitor:false,history:history)
        board.clearContents();XCTAssertTrue(board.setString("first",forType:.string));store.capture()
        let first=try XCTUnwrap(store.items.first)
        store.toggleFavorite(first);XCTAssertEqual(store.items.first?.favorite,true)
        XCTAssertTrue(history.undo());XCTAssertNotEqual(store.items.first?.favorite,true)
        store.remove(first);XCTAssertTrue(store.items.isEmpty)
        board.clearContents();board.setString("new",forType:.string);store.capture()
        XCTAssertTrue(history.undo());XCTAssertEqual(Set(store.items.compactMap(\.text)),["first","new"])
    }
    @MainActor func testAddedQuickTextAndHomeEntryAreUndoable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let history=UserActionHistory(),texts=QuickTextLibrary(file:root.appendingPathComponent("texts.json"),history:history),home=HomeLibrary(storage:root.appendingPathComponent("home.json"),seedDefaults:false,history:history)
        XCTAssertTrue(texts.save(QuickText(title:"test",text:"text")))
        XCTAssertTrue(home.add(title:"Folder",kind:.folder,target:root.path))
        XCTAssertTrue(history.undo());XCTAssertTrue(home.items.isEmpty);XCTAssertEqual(texts.items.count,1)
        XCTAssertTrue(history.undo());XCTAssertTrue(texts.items.isEmpty)
    }
    @MainActor func testClipboardDateHasWeekdayAndNoYear() {
        let value=ClipboardDate.text(Date(timeIntervalSince1970:1794268800))
        XCTAssertTrue(value.contains("月"));XCTAssertTrue(value.contains("日"));XCTAssertTrue(value.contains("周"));XCTAssertFalse(value.contains("2026"))
    }
}
