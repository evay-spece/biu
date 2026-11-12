import XCTest
@testable import FindDuck

final class NotesNovemberNineTests: XCTestCase {
    func testPeriodsMatchBothWaysAcrossNativeAndShortcutSearches() async {
        let root=URL(fileURLWithPath:"/Volumes/PunctuationTest")
        let files=["方案.终稿.pdf","方案。终稿.pdf","A。B.C.txt","A.B。C.txt","别的文档.pdf"].map {FileHit(url:root.appendingPathComponent($0))}
        let index=NameIndex(root:root,created:Date(),files:files,directories:[])
        var prefs=DuckPreferences();prefs.suppressNoise=false
        let engine=OilQueryEngine(),compact=SearchAccelerator()
        for term in ["方案.","方案。"] {
            let native=await engine.search(local:[],sharedSnapshot:index,term:term,category:.all,sort:.relevance,preferences:prefs,opened:[:],limit:20)
            let shortcut=await compact.search(index:index,term:term,category:.all,sort:.relevance,quick:.none,preferences:prefs,opened:[:],download:root)
            XCTAssertEqual(Set(native.hits.map(\.name)),Set(files.prefix(2).map(\.name)))
            XCTAssertEqual(Set(shortcut.hits.map(\.name)),Set(files.prefix(2).map(\.name)))
        }
        let mixed=await engine.search(local:[],sharedSnapshot:index,term:"A.B.C",category:.all,sort:.relevance,preferences:prefs,opened:[:],limit:20)
        XCTAssertEqual(Set(mixed.hits.map(\.name)),Set(files[2...3].map(\.name)))
        let unpunctuated=await engine.search(local:[],sharedSnapshot:index,term:"别的",category:.pdf,sort:.relevance,preferences:prefs,opened:[:],limit:20)
        XCTAssertEqual(unpunctuated.hits.map(\.name),["别的文档.pdf"])
    }
    @MainActor func testBeijingReturnsFirstEvenIfPreviouslyHiddenAndCannotBeRemoved() {
        let suite="biu-beijing-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set([WorldTimes.zones[0].id,WorldTimes.zones[1].id],forKey:"findduck.world-clock.hidden-default-cities")
        let library=WorldClockLibrary(defaults:defaults)
        XCTAssertEqual(library.zones.first,WorldTimes.zones[0])
        library.remove(WorldTimes.zones[0]);XCTAssertEqual(library.zones.first,WorldTimes.zones[0])
        XCTAssertFalse(library.zones.contains(WorldTimes.zones[1]))
    }
    @MainActor func testRemovedDefaultCityHasVisibleConversionFallback() {
        let suite="biu-city-selection-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let library=WorldClockLibrary(defaults:defaults)
        let beijing=WorldTimes.zones[0],newYork=WorldTimes.zones[5]
        library.remove(newYork)
        let target=library.validSelection(newYork.id,excluding:beijing.id)
        XCTAssertTrue(library.zones.contains {$0.id == target})
        XCTAssertNotEqual(target,beijing.id)
        for city in library.zones where city.id != beijing.id {library.remove(city)}
        XCTAssertEqual(library.validSelection(newYork.id,excluding:beijing.id),beijing.id)
    }
    @MainActor func testLauncherMigrationAndReorderingPersistWithoutResettingUserEntries() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let storage=folder.appendingPathComponent("home.json")
        let original=HomeShortcut(title:"用户 App",kind:.application,target:"/Applications/Test.app")
        struct OldSettings:Encodable {let items:[HomeShortcut];let resumeWindowSeconds:Double}
        try JSONEncoder().encode(OldSettings(items:[original],resumeWindowSeconds:99)).write(to:storage)
        let home=HomeLibrary(storage:storage)
        XCTAssertEqual(home.items.first,original);XCTAssertEqual(home.resumeWindowSeconds,99)
        let apps=home.items.filter {$0.group == 0}
        XCTAssertEqual(apps.count,2)
        XCTAssertEqual(apps.filter(\.isLauncher).count,1)
        let ids=apps.reversed().map(\.id);home.reorder(group:0,ids:ids)
        let loaded=HomeLibrary(storage:storage)
        XCTAssertEqual(loaded.items.filter {$0.group == 0}.map(\.id),ids)
        let builtin=try XCTUnwrap(loaded.items.first {$0.target == HomeShortcut.applicationsTarget})
        loaded.remove(builtin)
        XCTAssertFalse(HomeLibrary(storage:storage).items.contains {$0.id == builtin.id})
    }
}
