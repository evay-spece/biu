import Foundation
import Darwin
@preconcurrency import OilFindCore

actor OilQueryEngine {
    private var applicationCatalog:[FileHit]=[]
    private var applicationCatalogDate=Date.distantPast
    init(applicationCatalog: [FileHit]? = nil) {
        if let applicationCatalog {
            self.applicationCatalog = applicationCatalog
            applicationCatalogDate = Date()
        }
    }
    nonisolated static func isLaunchableApplication(_ url:URL)->Bool {
        guard url.pathExtension.lowercased() == "app",let executable=Bundle(url:url)?.executableURL else {return false}
        return FileManager.default.isExecutableFile(atPath:executable.path)
    }
    private func matchingApplications(_ term:String,roots:[URL],preferences:DuckPreferences,scopeRoot:URL?)->[RankedHit] {
        if Date().timeIntervalSince(applicationCatalogDate)>3600 {
            let bases=[URL(fileURLWithPath:"/Applications",isDirectory:true),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true),URL(fileURLWithPath:"/System/Applications",isDirectory:true),URL(fileURLWithPath:"/System/Library/CoreServices",isDirectory:true),URL(fileURLWithPath:"/System/Volumes/Preboot/Cryptexes/App/System/Applications",isDirectory:true)]
            var found:[String:FileHit]=[:]
            for base in bases {
                guard let enumerator=FileManager.default.enumerator(at:base,includingPropertiesForKeys:[.contentModificationDateKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else {continue}
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    guard Self.isLaunchableApplication(url) else {continue}
                    var file=FileHit(url:url,modified:(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate)
                    file.applicationNames=ApplicationNames.read(url)
                    found[url.path]=file
                }
            }
            applicationCatalog=Array(found.values);applicationCatalogDate=Date()
        }
        let exclusions = DuckExclusions(preferences.effectiveBlacklist)
        return applicationCatalog.filter {file in
            !exclusions.contains(file.url) &&
            roots.contains {DuckRules.under(file.url,$0)} &&
            (scopeRoot == nil || DuckRules.under(file.url,scopeRoot!)) &&
            preferences.blockedFiles?.contains(file.id) != true &&
            (file.applicationNames?.matches(term) ?? (term.isEmpty || SearchText.contains(file.url.deletingPathExtension().lastPathComponent,term)))
        }.enumerated().map {RankedHit(file:$0.element,score:Int32.max,position:$0.offset)}
    }
    private static func visibleDailyFile(_ url:URL)->Bool {
        let path=url.path
        if path.split(separator:"/").contains(where:{$0.hasPrefix(".")}) {return false}
        if url.lastPathComponent.hasPrefix("~$") {return false}
        if ["/Applications/","/Library/","/System/","/private/","/usr/","/opt/","/bin/","/sbin/","/dev/","/cores/"].contains(where:path.hasPrefix) {return false}
        if path.hasPrefix("/Users/Shared/") {return false}
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home+"/Library/") {
            guard path.contains("/xwechat_files/") || path.contains("/WeChat Files/") else {return false}
            guard WechatLocations.isSearchableChatAttachment(url) else {return false}
        }
        return !["app","photoslibrary"].contains(url.pathExtension.lowercased())
    }
    private static let extensions:[ResultCategory:Set<UInt64>] = {
        let groups:[ResultCategory:[String]] = [.pdf:["pdf"],.spreadsheets:["xls","xlsx","xlsm","csv","tsv","numbers"],.slides:["ppt","pptx","key"],.word:["doc","docx","pages"]]
        return groups.mapValues {Set($0.map {ext in Array(("x."+ext).utf8).withUnsafeBufferPointer {Classifier.extensionKey($0)}})}
    }()
    private var sharedKey=""
    private var shared:OilStoreHandle?
    private var previous:[String:SearchResult]=[:]
    private var modifiedCache:(key:String,index:NameIndex)?
    struct RankedHit {let file:FileHit;let score:Int32;let position:Int}
    func sharedHandle(_ snapshot:NameIndex?) -> OilStoreHandle? {
        guard let snapshot else {shared=nil;sharedKey="";return nil}
        let key="\(snapshot.root.path):\(snapshot.created.timeIntervalSince1970):\(snapshot.files.count):\(snapshot.directories?.count ?? 0)"
        if key != sharedKey {shared=OilSnapshotStore.make(snapshot);sharedKey=key}
        return shared
    }
    private func hit(_ store:IndexStore,_ id:UInt32) -> FileHit {
        FileHit(url:URL(fileURLWithPath:store.path(id)),isDirectory:store.kind[Int(id)] == 1,modified:store.mtime[Int(id)] == 0 ? nil : store.modified(id))
    }
    func liveAnnotationPaths(local:[OilStoreHandle],sharedSnapshot:NameIndex?,paths:Set<String>)->Set<String> {
        guard !paths.isEmpty else {return []}
        let handles=local+(sharedHandle(sharedSnapshot).map {[$0]} ?? [])
        var result=Set<String>()
        for handle in handles {handle.store.read {
            for path in paths {
                if Task.isCancelled {return}
                if let id=handle.store.resolve(path:path),handle.store.isLive(id),!handle.hiddenEntryIDs.contains(id) {result.insert(path)}
            }
        }}
        return result
    }
    func recentSnapshot(local:[OilStoreHandle],sharedSnapshot:NameIndex?,opened:[String:Date],preferences:DuckPreferences) -> NameIndex {
        let handles=local + (sharedHandle(sharedSnapshot).map {[$0]} ?? [])
        let ordered=opened.sorted {$0.value == $1.value ? $0.key < $1.key : $0.value > $1.value}
        let exclusions=DuckExclusions(preferences.effectiveBlacklist)
        var pool:[String:FileHit]=[:]
        for handle in handles {
            handle.store.read {
                var count=0
                for item in ordered {
                    if Task.isCancelled || count >= 50 {break}
                    guard let id=handle.store.resolve(path:item.key),handle.store.isLive(id),handle.store.kind[Int(id)] != 1 else {continue}
                    let file=hit(handle.store,id)
                    if file.url.pathExtension.lowercased() == "app" || WechatLocations.isOutsideChatAttachments(file.url) || preferences.blockedFiles?.contains(file.id) == true || exclusions.contains(file.url) || (preferences.suppressNoise && DuckRules.suspicious(file)) {continue}
                    pool[file.id]=file;count += 1
                }
            }
        }
        let files=pool.values.sorted {let a=opened[$0.id] ?? .distantPast,b=opened[$1.id] ?? .distantPast;return a == b ? $0.id < $1.id : a > b}
        return NameIndex(root:URL(fileURLWithPath:"/"),created:Date(),files:Array(files.prefix(50)),directories:[])
    }
    func modifiedTodaySnapshot(local:[OilStoreHandle],sharedSnapshot:NameIndex?,now:Date) -> NameIndex {
        let start=Calendar.current.startOfDay(for:now).timeIntervalSince1970
        let end=Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:now))!.timeIntervalSince1970
        let handles=local+(sharedHandle(sharedSnapshot).map {[$0]} ?? [])
        let key="\(Int(start))|"+handles.map {handle in
            let version=handle.store.read {handle.store.version}
            return "\(handle.id):\(ObjectIdentifier(handle.store)):\(version)"
        }.joined(separator:"|")
        if let cache=modifiedCache,cache.key == key {return cache.index}
        var files:[String:FileHit]=[:]
        for handle in handles {
            if Task.isCancelled {break}
            handle.store.read {
                let store=handle.store
                for position in 1..<store.count {
                    if position % 4096 == 0 && Task.isCancelled {break}
                    let id=UInt32(position),modified=TimeInterval(store.mtime[position])
                    guard modified >= start,modified < end,store.isLive(id),store.kind[position] != 1,!handle.hiddenEntryIDs.contains(id) else {continue}
                    let file=hit(store,id)
                    if Self.visibleDailyFile(file.url) {files[file.id]=file}
                }
            }
        }
        let snapshot=NameIndex(root:URL(fileURLWithPath:"/"),created:now,files:Array(files.values),directories:[])
        if !Task.isCancelled {modifiedCache=(key,snapshot)}
        return snapshot
    }
    func search(local:[OilStoreHandle],sharedSnapshot:NameIndex?,term:String,category:ResultCategory,sort:ResultSort,preferences:DuckPreferences,opened:[String:Date],limit:Int,scopeRoot:URL? = nil,applicationOrder:ApplicationOrdering = ApplicationOrdering()) -> AcceleratedResults {
        let applicationScope=scopeRoot?.standardizedFileURL.path == "/Applications"
        let handles=applicationScope ? [] : local + (sharedHandle(sharedSnapshot).map {[$0]} ?? [])
        let activeIDs=Set(handles.map(\.id));previous=previous.filter {activeIDs.contains($0.key)}
        let kind:UInt8?
        switch category {
        case .folders:kind=1
        case .pdf,.spreadsheets,.slides,.word:kind=3
        case .images:kind=nil // WeChat stores some chat images as opaque .dat files.
        case .video:kind=5
        case .archives:kind=8
        case .all:kind=nil
        }
        let key:SortKey=sort == .modified ? .modified : sort == .name ? .name : .relevance
        let options=SearchOptions(sort:key,ascending:sort == .name,kind:kind,pinyin:true)
        let used=sort == .recent ? opened.sorted {$0.value > $1.value} : []
        var total=0,collected:[RankedHit]=[]
        let annotated=preferences.annotatedPaths,exclusions=DuckExclusions(preferences.effectiveBlacklist)
        for handle in handles {
            if Task.isCancelled {return AcceleratedResults(hits:[],total:0)}
            if term.isEmpty,preferences.selectedTagIDs.isEmpty,let scopeRoot {
                handle.store.read {
                    let store=handle.store
                    var scopePath=scopeRoot.standardizedFileURL.path
                    if let real=realpath(scopePath,nil) {scopePath=String(cString:real);free(real)}
                    let storeRoot=store.rootPath
                    let wholeStore=storeRoot == scopePath || storeRoot.hasPrefix(scopePath == "/" ? "/" : scopePath+"/")
                    let scopeID=wholeStore ? nil : store.resolve(path:scopePath)
                    guard wholeStore || scopeID != nil else {return}
                    for position in 1..<store.count {
                        if position % 4096 == 0 && Task.isCancelled {break}
                        let id=UInt32(position)
                        guard store.isLive(id),!handle.hiddenEntryIDs.contains(id) else {continue}
                        if !wholeStore,let scopeID {
                            if id == scopeID {continue}
                            var parent=store.parent[position]
                            while parent != 0 && parent != scopeID {parent=store.parent[Int(parent)]}
                            if parent != scopeID {continue}
                        }
                        if let extensions=Self.extensions[category],!extensions.contains(Classifier.extensionKey(store.nameBytes(id))) {continue}
                        let file=hit(store,id)
                        guard !exclusions.contains(file.url),!WechatLocations.isOutsideChatAttachments(file.url),preferences.blockedFiles?.contains(file.id) != true,
                              !preferences.hidesExtension(file.url),
                              category == .all || ResultCategory.kind(of:file) == category,
                              !preferences.suppressNoise || !DuckRules.suspicious(file) || WechatLocations.isSearchableChatAttachment(file.url) else {continue}
                        total += 1
                        collected.append(RankedHit(file:file,score:0,position:position))
                    }
                }
                continue
            }
            if !preferences.selectedTagIDs.isEmpty && term.isEmpty {
                handle.store.read {
                    for path in annotated {
                        guard preferences.acceptsTag(path),preferences.blockedFiles?.contains(path) != true,let id=handle.store.resolve(path:path),handle.store.isLive(id),!handle.hiddenEntryIDs.contains(id) else {continue}
                        let file=hit(handle.store,id)
                        guard !exclusions.contains(file.url),!WechatLocations.isOutsideChatAttachments(file.url),!preferences.hidesExtension(file.url),(category == .all || ResultCategory.kind(of:file) == category),!preferences.suppressNoise || !DuckRules.suspicious(file) || WechatLocations.isSearchableChatAttachment(file.url) else {continue}
                        if let scopeRoot,!DuckRules.under(file.url,scopeRoot) || file.url.standardizedFileURL == scopeRoot.standardizedFileURL {continue}
                        total += 1;collected.append(RankedHit(file:file,score:Int32.max,position:0))
                    }
                };continue
            }
            let query=SearchText.query(term,store:handle.store)
            guard let result=Searcher.search(query,options:options,in:handle.store,previous:previous[handle.id],isCancelled:{Task.isCancelled}) else {continue}
            previous[handle.id]=result
            var positions:[Int]=[],overrides:[UInt32:Int32]=[:]
            var taggedIDs=Set<UInt32>(),taggedMatches=Set<UInt32>(),blockedIDs=Set<UInt32>()
            var scopePath=scopeRoot?.path
            if let raw=scopePath,let real=realpath(raw,nil) {scopePath=String(cString:real);free(real)}
            let systemRoot=["/System","/private/var","/usr","/bin","/sbin"].contains {handle.store.rootPath == $0 || handle.store.rootPath.hasPrefix($0+"/")}
            handle.store.read {
                for path in annotated {if let id=handle.store.resolve(path:path) {taggedIDs.insert(id)}}
                for path in preferences.blockedFiles ?? [] {if let id=handle.store.resolve(path:path) {blockedIDs.insert(id)}}
                let storeRoot=handle.store.rootPath
                let wholeStore=scopePath.map {storeRoot == $0 || storeRoot.hasPrefix($0 == "/" ? "/" : $0+"/")} ?? true
                let scopeID=scopePath.flatMap {handle.store.resolve(path:$0)}
                if !wholeStore && scopeID == nil {return}
                for (position,id) in result.items.enumerated() {
                    if Task.isCancelled {break}
                    if !handle.store.isLive(id) || handle.hiddenEntryIDs.contains(id) || blockedIDs.contains(id) {continue}
                    if preferences.suppressNoise && preferences.effectiveHiddenExtensions.contains((handle.store.name(id) as NSString).pathExtension.lowercased()) {continue}
                    if WechatLocations.isOpaqueImage(URL(fileURLWithPath:handle.store.path(id))) {continue}
                    if WechatLocations.isOutsideChatAttachments(URL(fileURLWithPath:handle.store.path(id))) {continue}
                    if let scopeID, !wholeStore || id == scopeID {
                        if id == scopeID {continue}
                        var parent=handle.store.parent[Int(id)]
                        while parent != 0 && parent != scopeID {parent=handle.store.parent[Int(parent)]}
                        if parent != scopeID {continue}
                    }
                    if let extensions=Self.extensions[category],!extensions.contains(Classifier.extensionKey(handle.store.nameBytes(id))) {continue}
                    if category == .images && ResultCategory.kind(of:hit(handle.store,id)) != .images {continue}
                    if preferences.suppressNoise {
                        let noisy=handle.store.flags[Int(id)] & SiftFlag.noise != 0
                        if systemRoot || noisy || handle.store.nameBytes(id).count >= 24 || handle.store.nameBytes(id).first == 46 {
                            if DuckRules.suspicious(name:handle.store.name(id),path:systemRoot || noisy ? handle.store.path(id) : "") && !WechatLocations.isSearchableChatAttachment(URL(fileURLWithPath:handle.store.path(id))) {continue}
                        }
                    }
                    if taggedIDs.contains(id) {taggedMatches.insert(id)}
                    else if preferences.selectedTagIDs.isEmpty {positions.append(position)}
                }
                for id in taggedIDs where handle.store.isLive(id) && !handle.hiddenEntryIDs.contains(id) && !blockedIDs.contains(id) {
                    let file=hit(handle.store,id)
                    guard preferences.acceptsTag(file.id),!exclusions.contains(file.url),!WechatLocations.isOutsideChatAttachments(file.url),!preferences.hidesExtension(file.url),(category == .all || ResultCategory.kind(of:file) == category) else {continue}
                    if let scopeRoot,!DuckRules.under(file.url,scopeRoot) || file.url.standardizedFileURL == scopeRoot.standardizedFileURL {continue}
                    if preferences.suppressNoise && DuckRules.suspicious(file) && !WechatLocations.isSearchableChatAttachment(file.url) {continue}
                    let labels=preferences.annotationText(file.id)
                    if taggedMatches.contains(id) || term.isEmpty || SearchText.contains(labels,term) {
                        total += 1;collected.append(RankedHit(file:file,score:Int32.max,position:0))
                    }
                }
                if sort == .recent {
                    for (position,item) in used.enumerated() {
                        if let id=handle.store.resolve(path:item.key) {overrides[id]=Int32(clamping:used.count-position)}
                    }
                }
            }
            total += positions.count
            let page=Searcher.findDuckPage(result,positions:positions,limit:limit,scoreOverrides:sort == .recent ? overrides : nil)
            handle.store.read {
                for (position,item) in page.enumerated() {collected.append(RankedHit(file:hit(handle.store,item.0),score:item.1,position:position))}
            }
        }
        if category == .all && (applicationScope || (!term.isEmpty && !local.isEmpty)) {
            let roots=applicationScope ? [URL(fileURLWithPath:"/")] : local.map {handle in URL(fileURLWithPath:handle.store.read {handle.store.rootPath},isDirectory:true)}
            let apps=matchingApplications(term,roots:roots,preferences:preferences,scopeRoot:applicationScope ? nil : scopeRoot)
            total += apps.count;collected.append(contentsOf:apps)
        }
        // Individual native pages contain every candidate needed for the global page.
        let installedAppIDs=Set(applicationCatalog.map(\.id))
        let installedApps=Dictionary(uniqueKeysWithValues:applicationCatalog.map {($0.id,$0)})
        collected=collected.map { hit in
            guard let app=installedApps[hit.file.id] else {return hit}
            var file=hit.file;file.applicationNames=app.applicationNames
            return RankedHit(file:file,score:hit.score,position:hit.position)
        }
        let sorted=collected.sorted {a,b in
            if applicationScope && sort == .relevance {return applicationOrder.precedes(a.file,b.file)}
            let appA=installedAppIDs.contains(a.file.id),appB=installedAppIDs.contains(b.file.id)
            if appA != appB {return appA}
            let at=annotated.contains(a.file.id),bt=annotated.contains(b.file.id);if at != bt {return at}
            if (sort == .modified || (sort == .relevance && term.isEmpty && scopeRoot != nil)) && a.file.modified != b.file.modified {return (a.file.modified ?? .distantPast) > (b.file.modified ?? .distantPast)}
            if (sort == .relevance || sort == .recent) && a.score != b.score {return a.score > b.score}
            if sort == .name {let order=(appA ? a.file.applicationDisplayName : a.file.name).localizedStandardCompare(appB ? b.file.applicationDisplayName : b.file.name);if order != .orderedSame {return order == .orderedAscending}}
            return a.position == b.position ? a.file.id < b.file.id : a.position < b.position
        }
        var seen=Set<String>();let unique=sorted.filter {seen.insert($0.file.id).inserted}
        return AcceleratedResults(hits:unique.prefix(limit).map(\.file),total:total)
    }
}
