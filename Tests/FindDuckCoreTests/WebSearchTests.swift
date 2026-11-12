import XCTest
@testable import FindDuck

final class WebSearchTests: XCTestCase {
    func testSearchPreservesChineseSpacesAndURLSpecialCharacters() throws {
        let query = "宝宝 鞋 & a+b#?/%"
        for website in WebSearch.allCases {
            let url = try XCTUnwrap(website.url(for: "  " + query + "\n"))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let parameter = website == .baidu ? "wd" : website == .taobao ? "q" : "keyword"
            XCTAssertEqual(components.queryItems?.first { $0.name == parameter }?.value, query)
            XCTAssertEqual(components.scheme, "https")
            XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true)
            XCTAssertFalse(components.percentEncodedQuery?.contains("+") == true)
        }
    }
    func testEmptySearchDoesNotProduceURL() {
        for website in WebSearch.allCases { XCTAssertNil(website.url(for: " \n ")) }
    }
}
