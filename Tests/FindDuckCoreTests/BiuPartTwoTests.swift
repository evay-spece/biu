import XCTest
import AppKit
@testable import FindDuck

final class BiuPartTwoTests:XCTestCase {
    func testOnlyOneCopyOrPlainTextStateAcrossAllRecords() {
        let a=UUID(),b=UUID()
        var status=ClipboardCopyStatus(entryID:a,plainText:false,changeCount:1)
        XCTAssertTrue(status.isActive(a,plainText:false))
        XCTAssertFalse(status.isActive(a,plainText:true))
        status=ClipboardCopyStatus(entryID:b,plainText:true,changeCount:2)
        XCTAssertFalse(status.isActive(a,plainText:false))
        XCTAssertFalse(status.isActive(b,plainText:false))
        XCTAssertTrue(status.isActive(b,plainText:true))
        XCTAssertTrue(status.invalidateIfChanged(3))
        XCTAssertFalse(status.isActive(b,plainText:true))
    }
    func testDateRangesUseCalendarDaysAndNow() throws {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=try XCTUnwrap(TimeZone(identifier:"Europe/Paris"))
        func date(_ d:Int,_ h:Int=12)->Date {calendar.date(from:DateComponents(year:2026,month:3,day:d,hour:h))!}
        let now=date(30)
        XCTAssertTrue(ClipboardHistoryPeriod.today.includes(date(30,0),now:now,calendar:calendar))
        XCTAssertTrue(ClipboardHistoryPeriod.yesterday.includes(date(29),now:now,calendar:calendar))
        XCTAssertFalse(ClipboardHistoryPeriod.yesterday.includes(date(28),now:now,calendar:calendar))
        XCTAssertTrue(ClipboardHistoryPeriod.week.includes(date(24,0),now:now,calendar:calendar))
        XCTAssertFalse(ClipboardHistoryPeriod.week.includes(date(23),now:now,calendar:calendar))
        XCTAssertFalse(ClipboardHistoryPeriod.week.includes(date(31),now:now,calendar:calendar))
    }
    @MainActor func testEditedClipboardTextPersistsAndUndoRestoresRichTextWithoutRemovingNewerRecords() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        let history=UserActionHistory(),store=ClipboardHistoryStore(directory:root,pasteboard:board,monitor:false,history:history)
        board.clearContents();XCTAssertTrue(board.setString("原文",forType:.string));XCTAssertTrue(board.setData(Data("old-rtf".utf8),forType:.rtf));store.capture()
        let original=try XCTUnwrap(store.items.first)
        XCTAssertNotNil(original.richText)
        XCTAssertTrue(store.updateText(original,text:"编辑后的文字"))
        XCTAssertEqual(store.items.first?.text,"编辑后的文字")
        XCTAssertNil(store.items.first?.richText)
        let loaded=ClipboardHistoryStore(directory:root,pasteboard:board,monitor:false,history:UserActionHistory())
        XCTAssertEqual(loaded.items.first?.text,"编辑后的文字")
        board.clearContents();XCTAssertTrue(board.setString("新复制的内容",forType:.string));store.capture()
        XCTAssertTrue(history.undo())
        XCTAssertEqual(store.items.first(where:{$0.id == original.id})?.text,"原文")
        XCTAssertEqual(store.items.first(where:{$0.id == original.id})?.richText,original.richText)
        XCTAssertTrue(store.items.contains {$0.text == "新复制的内容"})
    }
    @MainActor func testFocusTimerCancelsWhenFocusReturnsAndWaitsForDialog() async throws {
        let timer=ToolWindowHideTimer()
        var state=ToolWindowFocusDecision.hide
        var hidden=0
        timer.schedule(delay:0.03,decision:{state},hide:{hidden += 1})
        state = .cancel
        try await Task.sleep(for:.milliseconds(90))
        XCTAssertEqual(hidden,0)
        state = .wait
        timer.schedule(delay:0.01,decision:{state},hide:{hidden += 1})
        try await Task.sleep(for:.milliseconds(70))
        XCTAssertEqual(hidden,0)
        state = .hide
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertEqual(hidden,1)
        timer.schedule(delay:0.03,decision:{.hide},hide:{hidden += 1})
        timer.cancel()
        try await Task.sleep(for:.milliseconds(90))
        XCTAssertEqual(hidden,1)
    }
    func testPinnedAndFocusedWindowsNeverAutoHide() {
        XCTAssertEqual(ToolWindowPolicy.decision(visible:true,key:false,pinned:true,modal:false),.cancel)
        XCTAssertEqual(ToolWindowPolicy.decision(visible:true,key:true,pinned:false,modal:false),.cancel)
        XCTAssertEqual(ToolWindowPolicy.decision(visible:true,key:false,pinned:false,modal:true),.wait)
        XCTAssertEqual(ToolWindowPolicy.decision(visible:true,key:false,pinned:false,modal:false),.hide)
        XCTAssertEqual(ToolWindowPolicy.decision(visible:false,key:false,pinned:false,modal:false),.cancel)
    }
}
