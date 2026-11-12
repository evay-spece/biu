import Foundation

struct ApplicationOrdering: Sendable {
    var running:Set<String> = []
    var pinned:Set<String> = []
    var recent:[String:Date] = [:]
    func tier(_ path:String)->Int {running.contains(path) && !pinned.contains(path) ? 0 : recent[path] != nil ? 1 : 2}
    func precedes(_ a:FileHit,_ b:FileHit)->Bool {
        let at=tier(a.id),bt=tier(b.id)
        if at != bt {return at < bt}
        if at == 1, recent[a.id] != recent[b.id] {return (recent[a.id] ?? .distantPast) > (recent[b.id] ?? .distantPast)}
        let compare=a.applicationDisplayName.localizedStandardCompare(b.applicationDisplayName)
        return compare == .orderedSame ? a.id < b.id : compare == .orderedAscending
    }
}
