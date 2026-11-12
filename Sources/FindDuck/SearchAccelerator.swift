import Foundation
import Darwin

struct AcceleratedResults: Sendable { let hits:[FileHit];let total:Int }
actor SearchAccelerator {
    private struct Entry: Sendable {
        let file:FileHit
        let name:String
        let key:String
        let kind:ResultCategory
        init(_ file:FileHit) {
            self.file=file;name=file.name
            var normalized=SearchAccelerator.fold(name);normalized.makeContiguousUTF8();key=normalized
            kind=ResultCategory.kind(of:file)
        }
    }
    private struct SnapshotKey: Equatable {
        let created:Date;let files:Int;let directories:Int
        init(_ index:NameIndex) {created=index.created;files=index.files.count;directories=index.directories?.count ?? -1}
    }
    private struct Candidate {let entry:Int;let score:Int;let opened:Date}
    private var snapshotKey:SnapshotKey?
    private var entries:[Entry]=[]
    private var previousTerm=""
    private var previousMatches:[Int]=[]
    private static func fold(_ text:String) -> String {SearchText.fold(text)}
    @inline(__always) private static func contains(_ text:String,_ needle:[UInt8]) -> Bool {
        if needle.isEmpty {return true}
        return text.utf8.withContiguousStorageIfAvailable { bytes in
            guard bytes.count >= needle.count else {return false}
            return needle.withUnsafeBufferPointer { key in
                memmem(bytes.baseAddress,bytes.count,key.baseAddress,key.count) != nil
            }
        } ?? false
    }
    @discardableResult func prepare(_ index:NameIndex) -> Bool {
        let key=SnapshotKey(index)
        if key == snapshotKey {return true}
        var prepared:[Entry]=[];prepared.reserveCapacity(index.files.count+(index.directories?.count ?? 0))
        for file in index.files {
            if Task.isCancelled {return false}
            prepared.append(Entry(file))
        }
        for folder in SearchPresentation.folderHits(index:index) {
            if Task.isCancelled {return false}
            prepared.append(Entry(folder))
        }
        guard !Task.isCancelled else {return false}
        entries=prepared;snapshotKey=key;previousTerm="";previousMatches=[]
        return true
    }
    func search(index:NameIndex,term:String,category:ResultCategory,sort:ResultSort,quick:QuickScope,
                preferences:DuckPreferences,opened:[String:Date],download:URL,extra:[FileHit]=[],limit:Int=200) -> AcceleratedResults {
        guard prepare(index), !Task.isCancelled else {return AcceleratedResults(hits:[],total:0)}
        let needle=Self.fold(term)
        let needleBytes=Array(needle.utf8)
        // Annotation changes can add matches without changing the filename snapshot.
        var matches=Array(entries.indices).filter {needle.isEmpty || Self.contains(entries[$0].key,needleBytes) || SearchText.contains(preferences.annotationText(entries[$0].file.id),term)}
        let exclusions=DuckExclusions(preferences.effectiveBlacklist)
        func eligible(_ entry:Entry) -> Bool {
            if exclusions.contains(entry.file.url) || preferences.blockedFiles?.contains(entry.file.id) == true  {return false}
            if WechatLocations.isOutsideChatAttachments(entry.file.url) {return false}
            return !preferences.hidesExtension(entry.file.url) && (!preferences.suppressNoise || !DuckRules.suspicious(name:entry.name,path:entry.file.url.path) || WechatLocations.isSearchableChatAttachment(entry.file.url))
        }
        func inScope(_ entry:Entry) -> Bool {
            if quick == .none {return true}
            guard !entry.file.isDirectory else {return false}
            switch quick {
            case .none:return true
            case .recent:return entry.file.url.pathExtension.lowercased() != "app" && opened[entry.file.id] != nil
            case .modified:return entry.file.modified.map {Calendar.current.isDateInToday($0)} == true
            case .downloads:return DuckRules.under(entry.file.url,download) && DuckRules.today(entry.file)
            case .wechat:
                guard let root=preferences.wechatFolder else {return false}
                let common=["xwechat_files","WeChat Files"].contains(root.lastPathComponent)
                let attachment = !common || WechatLocations.isChatAttachment(entry.file.url)
                return attachment && DuckRules.under(entry.file.url,root) && DuckRules.today(entry.file)
            }
        }
        // Extra results only come from explicit shared-drive deep search.
        var active=entries
        if !extra.isEmpty {
            var seen=Set(matches.map {entries[$0].file.id})
            for file in extra where seen.insert(file.id).inserted {
                let entry=Entry(file)
                if quick == .recent || needle.isEmpty || Self.contains(entry.key,needleBytes) {matches.append(active.count);active.append(entry)}
            }
        }
        // The latest 50 eligible files are selected BEFORE keyword/type filtering.
        if quick == .recent {
            var recent:[Int]=[]
            for i in active.indices {
                if Task.isCancelled {return AcceleratedResults(hits:[],total:0)}
                if inScope(active[i]) && eligible(active[i]) {recent.append(i)}
            }
            recent.sort {
                let a=opened[active[$0].file.id] ?? .distantPast,b=opened[active[$1].file.id] ?? .distantPast
                return a == b ? active[$0].file.id < active[$1].file.id : a > b
            }
            matches=Array(recent.prefix(50)).filter {needle.isEmpty || Self.contains(active[$0].key,needleBytes) || SearchText.contains(preferences.annotationText(active[$0].file.id),term)}
        }
        func better(_ a:Candidate,_ b:Candidate) -> Bool {
            let left=active[a.entry],right=active[b.entry]
            let lt=preferences.annotated(left.file.id),rt=preferences.annotated(right.file.id);if lt != rt {return lt}
            if sort == .relevance && a.score != b.score {return a.score < b.score}
            if sort == .modified && left.file.modified != right.file.modified {return (left.file.modified ?? .distantPast) > (right.file.modified ?? .distantPast)}
            if sort == .recent && a.opened != b.opened {return a.opened > b.opened}
            // Recent order has always used a path tie-break; retain that behavior.
            if sort == .recent {return left.file.id < right.file.id}
            let order=left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.file.id < right.file.id : order == .orderedAscending
        }
        // A bounded heap ranks the visible page; the count still includes every match.
        var heap:[Candidate]=[];heap.reserveCapacity(max(1,limit));var total=0
        func insert(_ candidate:Candidate) {
            if heap.count < max(1,limit) {
                heap.append(candidate);var child=heap.count-1
                while child > 0 {
                    let parent=(child-1)/2
                    if !better(heap[parent],heap[child]) {break}
                    heap.swapAt(parent,child);child=parent
                }
            } else if let worst=heap.first,better(candidate,worst) {
                heap[0]=candidate;var parent=0
                while parent*2+1 < heap.count {
                    var child=parent*2+1
                    if child+1 < heap.count && better(heap[child],heap[child+1]) {child += 1}
                    if !better(heap[parent],heap[child]) {break}
                    heap.swapAt(parent,child);parent=child
                }
            }
        }
        for i in matches {
            if Task.isCancelled {return AcceleratedResults(hits:[],total:0)}
            let entry=active[i]
            guard (category == .all || entry.kind == category),inScope(entry),eligible(entry),preferences.acceptsTag(entry.file.id) else {continue}
            total += 1
            let score=entry.key == needle ? 0 : entry.key.hasPrefix(needle) ? 1 : 2
            insert(Candidate(entry:i,score:score,opened:sort == .recent ? opened[entry.file.id] ?? .distantPast : .distantPast))
        }
        guard !Task.isCancelled else {return AcceleratedResults(hits:[],total:0)}
        return AcceleratedResults(hits:heap.sorted(by:better).map {active[$0.entry].file},total:total)
    }
}
