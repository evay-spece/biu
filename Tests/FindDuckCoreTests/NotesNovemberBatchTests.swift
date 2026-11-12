import XCTest
import AppKit
@testable import FindDuck

final class NotesNovemberBatchTests:XCTestCase {
    func testCurrencyAliasesAreEquivalent() {
        for text in ["人民币100","100人民币","rmb100","100rmb","CNY 100"] {
            let value=CurrencySearchQuery.parse(text)
            XCTAssertEqual(value?.amount,100);XCTAssertEqual(value?.from,"CNY");XCTAssertEqual(value?.to,"USD")
        }
        for text in ["美元100","100美元","usd100","100usd"] {
            let value=CurrencySearchQuery.parse(text)
            XCTAssertEqual(value?.amount,100);XCTAssertEqual(value?.from,"USD");XCTAssertEqual(value?.to,"CNY")
        }
        XCTAssertNil(CurrencySearchQuery.parse("人民币报表"));XCTAssertNil(CurrencySearchQuery.parse("100"))
    }
    func testWechatVideoPathsAndThumbnailExclusion() {
        let base="/Users/test/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/account/msg/video/2026-11/"
        let video=URL(fileURLWithPath:base+"a.mp4"),image=URL(fileURLWithPath:base+"a_thumb.jpg")
        XCTAssertEqual(DisplayPath.parent(video),"微信视频/2026-11")
        XCTAssertTrue(WechatLocations.isSearchableChatAttachment(video))
        XCTAssertFalse(WechatLocations.isSearchableChatAttachment(image))
        XCTAssertTrue(WechatLocations.isOutsideChatAttachments(image))
        XCTAssertFalse(WechatLocations.isVideoThumbnail(URL(fileURLWithPath:"/Users/test/Movies/video/a.jpg")))
        XCTAssertTrue(WechatLocations.isSearchableChatAttachment(URL(fileURLWithPath:base.replacingOccurrences(of:"/video/",with:"/file/")+"photo.jpg")))
    }
    func testQuickTextsMatchTitlesAndKeepStableOrder() {
        let a=QuickText(title:"收货地址",text:"正文"),b=QuickText(title:"其他",text:"地址")
        XCTAssertEqual(QuickTextSearch.matches([a,b],query:"地址").map(\.id),[a.id])
        XCTAssertTrue(QuickTextSearch.matches([a,b],query:" ").isEmpty)
        XCTAssertEqual(QuickTextSearch.matches([a,b],query:"收货 地址").map(\.id),[a.id])
    }
    @MainActor func testFileCopyWritesFileURLsForMultipleSelection() {
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        let urls=[URL(fileURLWithPath:"/tmp/测试报表.xlsx"),URL(fileURLWithPath:"/tmp/测试.pdf")]
        XCTAssertTrue(ResultFileCopy.copy(urls.map {FileHit(url:$0)},to:board))
        let copied=board.readObjects(forClasses:[NSURL.self],options:nil) as? [URL]
        XCTAssertEqual(copied,urls)
        XCTAssertFalse(ResultFileCopy.copy([],to:board))
        XCTAssertEqual(board.readObjects(forClasses:[NSURL.self],options:nil) as? [URL],urls)
    }
}
