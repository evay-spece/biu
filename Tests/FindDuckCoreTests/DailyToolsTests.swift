import XCTest
import AppKit
@testable import FindDuck

@MainActor final class DailyToolsTests:XCTestCase {
    func testTodayModifiedUsesIndexDatesAndRetainsTypeAndKeywordFiltering() async {
        let now=Calendar.current.startOfDay(for:Date()).addingTimeInterval(12*3600),root=URL(fileURLWithPath:"/Volumes/DailyToolsFixture"),actor=OilQueryEngine()
        let today=root.appendingPathComponent("今天报表.xlsx")
        let yesterday=root.appendingPathComponent("昨天报表.xlsx")
        let pdf=root.appendingPathComponent("今天合同.pdf")
        let future=root.appendingPathComponent("未来报表.xlsx")
        let hidden=root.appendingPathComponent(".cache/今天日志.json")
        let application=root.appendingPathComponent("今天软件.app")
        let officeTemp=root.appendingPathComponent("~$今天合同.docx")
        let wechatDatabase=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/test/db_storage/message.db")
        let wechatAttachment=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/test/msg/file/2026-11/今天附件.pdf")
        let snapshot=NameIndex(root:URL(fileURLWithPath:"/"),created:now,files:[
            FileHit(url:today,modified:now),
            FileHit(url:yesterday,modified:Calendar.current.date(byAdding:.day,value:-1,to:now)),
            FileHit(url:pdf,modified:now.addingTimeInterval(-60)),
            FileHit(url:future,modified:Calendar.current.date(byAdding:.day,value:1,to:now)),
            FileHit(url:hidden,modified:now),
            FileHit(url:application,modified:now),
            FileHit(url:officeTemp,modified:now),
            FileHit(url:wechatDatabase,modified:now),
            FileHit(url:wechatAttachment,modified:now)
        ],directories:[])
        let filtered=await actor.modifiedTodaySnapshot(local:[],sharedSnapshot:snapshot,now:now)
        XCTAssertEqual(Set(filtered.files.map(\.id)),Set([today.path,pdf.path,wechatAttachment.path]))
        let results=await SearchAccelerator().search(index:filtered,term:"报表",category:.spreadsheets,sort:.modified,quick:.none,preferences:DuckPreferences(),opened:[:],download:root)
        XCTAssertEqual(results.hits.map(\.id),[today.path])
    }
    func testClipboardSessionsSplitOnlyAfterMoreThanTenMinutes() {
        let start = Date(timeIntervalSince1970: 10000)
        func entry(_ offset: TimeInterval) -> ClipboardEntry {
            ClipboardEntry(kind: .text, text: "sample", imageName: nil,
                           fingerprint: String(offset), captured: start.addingTimeInterval(offset))
        }
        let first = entry(0)
        let atBoundary = entry(600)
        let newSession = entry(1201)
        let groups = ClipboardSession.group([atBoundary, first, newSession], now: start.addingTimeInterval(1800))
        XCTAssertEqual(groups.map { $0.entries.map(\.id) },
                       [[newSession.id], [atBoundary.id, first.id]])
    }

    func testClipboardTextImagePersistenceDeduplicationAndRemoval() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("findduck-clipboard-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let board=NSPasteboard(name:NSPasteboard.Name("findduck-test-"+UUID().uuidString))
        defer {board.releaseGlobally()}
        let store=ClipboardHistoryStore(directory:directory,pasteboard:board,monitor:false)
        board.clearContents();board.setString("https://example.com",forType:.string);store.capture()
        XCTAssertEqual(store.items.first?.text,"https://example.com")
        board.clearContents();board.setString("另一条",forType:.string);store.capture()
        board.clearContents();board.setString("https://example.com",forType:.string);store.capture()
        XCTAssertEqual(store.items.count,2)
        XCTAssertEqual(store.items.first?.text,"https://example.com")
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let png=try XCTUnwrap(image.representation(using:.png,properties:[:]))
        board.clearContents();board.setData(png,forType:.png);store.capture()
        XCTAssertEqual(store.items.first?.kind,.image)
        let imageURL=try XCTUnwrap(store.imageURL(for:store.items[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:imageURL.path))
        XCTAssertEqual(ClipboardHistoryStore(directory:directory,pasteboard:board,monitor:false).items.count,3)
        board.clearContents();board.declareTypes([NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),.string],owner:nil)
        board.setString("private",forType:.string);store.capture()
        XCTAssertEqual(store.items.count,3)
        store.toggleFavorite(store.items[0])
        XCTAssertTrue(store.copy(store.items[0], to: board))
        XCTAssertEqual(board.data(forType: .png), png)
        store.clearHistory()
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:imageURL.path))
        XCTAssertTrue(ClipboardHistoryStore(directory:directory,pasteboard:board,monitor:false).items.isEmpty)
    }
    func testClipboardQuotaPreservesFavoritesAndRejectsOversizedCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ClipboardHistoryStore(directory: directory, pasteboard: board, monitor: false, capacity: 4500)
        func capture(_ value: String) {
            board.clearContents()
            board.setString(value, forType: .string)
            store.capture()
        }

        let favorite = String(repeating: "a", count: 1600)
        let newest = String(repeating: "c", count: 1600)
        capture(favorite)
        store.toggleFavorite(try XCTUnwrap(store.items.first))
        capture(String(repeating: "b", count: 1600))
        capture(newest)
        XCTAssertEqual(store.items.compactMap(\.text), [newest, favorite])
        capture(String(repeating: "x", count: 5000))
        XCTAssertEqual(store.items.compactMap(\.text), [newest, favorite])
        let restored = ClipboardHistoryStore(directory: directory, pasteboard: board, monitor: false, capacity: 4500)
        XCTAssertEqual(restored.items.compactMap(\.text), [newest, favorite])
        XCTAssertEqual(restored.items.last?.favorite, true)
    }

    func testLargeImageAndCopiedFileAreRetained() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("findduck-clipboard-large-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let board=NSPasteboard(name:NSPasteboard.Name("findduck-large-"+UUID().uuidString))
        defer {board.releaseGlobally()}
        let store=ClipboardHistoryStore(directory:directory,pasteboard:board,monitor:false)
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1100,pixelsHigh:1100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let bytes=try XCTUnwrap(image.bitmapData)
        var state:UInt32=123456789
        for index in 0..<(image.bytesPerRow*image.pixelsHigh) {state=state &* 1664525 &+ 1013904223;bytes[index]=UInt8(truncatingIfNeeded:state >> 24)}
        let png=try XCTUnwrap(image.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(png.count,3_000_000)
        board.clearContents();board.setData(png,forType:.png);store.capture()
        XCTAssertEqual(store.items.first?.kind,.image)
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(store.imageURL(for:store.items[0]))).count,png.count)
        let file=directory.appendingPathComponent("测试文件.txt")
        try "example".write(to:file,atomically:true,encoding:.utf8)
        board.clearContents();board.writeObjects([file as NSURL]);store.capture()
        XCTAssertEqual(store.items.first?.kind,.file)
        XCTAssertEqual(store.items.first?.filePaths,[file.path])
        XCTAssertEqual(ClipboardHistoryStore(directory:directory,pasteboard:board,monitor:false).items.first?.filePaths,[file.path])
        let restored=NSPasteboard(name:NSPasteboard.Name("findduck-restored-"+UUID().uuidString))
        defer {restored.releaseGlobally()}
        store.copy(store.items[0],to:restored)
        let copied=(restored.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        XCTAssertEqual(copied.map(\.path),[file.path])
    }
    func testClipboardImageAndFilesCanBeSavedWithoutChangingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ClipboardHistoryStore(directory: directory.appendingPathComponent("history"), pasteboard: board, monitor: false)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        board.clearContents(); board.setData(png, forType: .png); store.capture()
        let imageEntry = try XCTUnwrap(store.items.first)
        let savedImage = directory.appendingPathComponent("saved.png")
        try Data("old".utf8).write(to: savedImage)
        try store.save(imageEntry, to: savedImage)
        XCTAssertEqual(try Data(contentsOf: savedImage), png)

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        try "two".write(to: second, atomically: true, encoding: .utf8)
        board.clearContents(); board.writeObjects([first as NSURL]); store.capture()
        let singleFile = try XCTUnwrap(store.items.first)
        let renamed = directory.appendingPathComponent("renamed.txt")
        try "old".write(to: renamed, atomically: true, encoding: .utf8)
        try store.save(singleFile, to: renamed)
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "one")
        board.clearContents(); board.writeObjects([first as NSURL, second as NSURL]); store.capture()
        let multipleFiles = try XCTUnwrap(store.items.first)
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "existing".write(to: output.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try store.saveFiles(multipleFiles, into: output)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("first.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("first 2.txt"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("second.txt"), encoding: .utf8), "two")
        XCTAssertEqual(store.items.count, 3)
    }
    func testShoppingLinksAndIDs() throws {
        XCTAssertEqual(try TmallLinkParser.analyze("https://detail.tmall.com/item.htm?id=123456789&spm=test").url,"https://detail.tmall.com/item.htm?id=123456789")
        XCTAssertEqual(try TmallLinkParser.analyze("https://item.jd.com/987654321.html?abc=1").url,"https://item.jd.com/987654321.html")
        XCTAssertEqual(TmallLinkParser.canonicalJDLink(for:"987654321"),"https://item.jd.com/987654321.html")
    }
}
