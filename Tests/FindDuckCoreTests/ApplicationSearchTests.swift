import XCTest
@testable import FindDuck

final class ApplicationSearchTests: XCTestCase {
    private let scope = URL(fileURLWithPath: "/Applications")
    private var apps: [FileHit] {
        ["Safari.app", "Excel.app", "Utilities/Terminal.app"].map {
            FileHit(url: scope.appendingPathComponent($0))
        }
    }

    func testApplicationEntryListsAppsWithoutKeywordOrFileIndex() async {
        let engine = OilQueryEngine(applicationCatalog: apps)
        let result = await engine.search(local: [], sharedSnapshot: nil, term: "", category: .all,
            sort: .name, preferences: DuckPreferences(), opened: [:], limit: 200, scopeRoot: scope)
        XCTAssertEqual(result.hits.map(\.name), ["Excel.app", "Safari.app", "Terminal.app"])
        XCTAssertEqual(result.total, 3)
    }

    func testApplicationEntryFiltersKeywordThenReturnsToFullList() async {
        let engine = OilQueryEngine(applicationCatalog: apps)
        for (term, expected) in [("EXCEL", 1), ("not-installed", 0), ("", 3)] {
            let result = await engine.search(local: [], sharedSnapshot: nil, term: term, category: .all,
                sort: .name, preferences: DuckPreferences(), opened: [:], limit: 200, scopeRoot: scope)
            XCTAssertEqual(result.hits.count, expected, term)
            if term == "EXCEL" { XCTAssertEqual(result.hits.first?.name, "Excel.app") }
        }
    }

    func testEmptyApplicationEntryStillRespectsExclusionsAndBlockedFiles() async {
        let engine = OilQueryEngine(applicationCatalog: apps)
        var preferences = DuckPreferences()
        preferences.blacklist = [scope.appendingPathComponent("Utilities")]
        preferences.blockedFiles = [apps[0].id]
        let result = await engine.search(local: [], sharedSnapshot: nil, term: "", category: .all,
            sort: .name, preferences: preferences, opened: [:], limit: 200, scopeRoot: scope)
        XCTAssertEqual(result.hits.map(\.name), ["Excel.app"])
    }
}
