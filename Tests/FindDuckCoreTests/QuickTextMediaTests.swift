import XCTest
import AppKit
@testable import FindDuck

@MainActor final class QuickTextMediaTests:XCTestCase {
    private func png()->Data {
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:3,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        return image.representation(using:.png,properties:[:])!
    }
    func testLegacyTextsAndImageCopiesPersistIndependently() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("texts.json")
        try Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Legacy\",\"text\":\"Hello\"}]".utf8).write(to:file)
        let library=QuickTextLibrary(file:file)
        XCTAssertEqual(library.items.first?.text,"Hello")
        XCTAssertNil(library.items.first?.imageName)
        let origin=root.appendingPathComponent("clipboard.png"),data=png()
        try data.write(to:origin)
        let item=QuickText(title:"图片",text:"说明",sourceClipboardID:UUID())
        XCTAssertTrue(library.save(item,imageData:data))
        let saved=try XCTUnwrap(library.items.last),url=try XCTUnwrap(library.imageURL(saved))
        XCTAssertNotEqual(url,origin)
        try FileManager.default.removeItem(at:origin)
        let loaded=QuickTextLibrary(file:file),restored=try XCTUnwrap(loaded.items.last)
        XCTAssertEqual(restored.sourceClipboardID,item.sourceClipboardID)
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        XCTAssertTrue(loaded.copy(restored,to:board))
        XCTAssertNotNil(NSImage(pasteboard:board));XCTAssertEqual(board.string(forType:.string),"说明")
        loaded.remove(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertEqual(QuickTextLibrary(file:file).items.map(\.title),["Legacy"])
    }
    func testBadImageDoesNotReplaceExistingDataAndRemovalCleansMedia() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=QuickTextLibrary(file:root.appendingPathComponent("texts.json"))
        let item=QuickText(title:"Photo",text:"")
        XCTAssertTrue(library.save(item,imageData:png()))
        var saved=try XCTUnwrap(library.items.first)
        let original=try XCTUnwrap(library.imageURL(saved))
        XCTAssertFalse(library.save(saved,imageData:Data([1,2,3])))
        XCTAssertTrue(FileManager.default.fileExists(atPath:original.path))
        XCTAssertEqual(library.items.first,saved)
        saved.imageName=nil;saved.text="now text"
        XCTAssertTrue(library.save(saved))
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
    }
    func testPasteboardImageFormatsAndPlainTextValidation() throws {
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        board.clearContents();board.setString("plain text",forType:.string)
        XCTAssertFalse(QuickTextImages.canPasteImage(from:board))
        XCTAssertNil(QuickTextImages.fromPasteboard(board))
        board.clearContents();board.setData(png(),forType:.png)
        XCTAssertTrue(QuickTextImages.canPasteImage(from:board))
        XCTAssertNotNil(QuickTextImages.fromPasteboard(board))
        let view=NSView(frame:NSRect(x:0,y:0,width:10,height:10))
        let pdf=view.dataWithPDF(inside:view.bounds)
        board.clearContents();board.setData(pdf,forType:.pdf)
        XCTAssertTrue(QuickTextImages.canPasteImage(from:board))
        XCTAssertNotNil(QuickTextImages.fromPasteboard(board))
        let imageFile=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer {try? FileManager.default.removeItem(at:imageFile)}
        try png().write(to:imageFile)
        board.clearContents();board.writeObjects([imageFile as NSURL])
        XCTAssertTrue(QuickTextImages.canPasteImage(from:board))
        XCTAssertNotNil(QuickTextImages.fromPasteboard(board))
    }
    func testOnlyExecutableAppBundlesQualify() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let app=root.appendingPathComponent("Demo.app"),contents=app.appendingPathComponent("Contents")
        let executable=contents.appendingPathComponent("MacOS/Demo")
        try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
        let plist:[String:Any] = ["CFBundleExecutable":"Demo","CFBundleIdentifier":"test.demo","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:executable)
        XCTAssertFalse(OilQueryEngine.isLaunchableApplication(app))
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        XCTAssertTrue(OilQueryEngine.isLaunchableApplication(app))
        XCTAssertFalse(OilQueryEngine.isLaunchableApplication(executable))
        XCTAssertFalse(OilQueryEngine.isLaunchableApplication(contents))
    }
}
