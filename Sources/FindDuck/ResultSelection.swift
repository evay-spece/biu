import AppKit
struct ResultSelection {
    private(set) var ids=Set<String>()
    private(set) var primary:String?
    private var anchor:String?
    mutating func replace(_ id:String?) {ids=Set(id.map {[$0]} ?? []);primary=id;anchor=id}
    mutating func select(_ id:String,ordered:[String],modifiers:NSEvent.ModifierFlags,rightClick:Bool=false) {
        if rightClick && ids.contains(id) {primary=id;return}
        if modifiers.contains(.shift),let anchor,let a=ordered.firstIndex(of:anchor),let b=ordered.firstIndex(of:id) {
            let range=Set(ordered[min(a,b)...max(a,b)])
            ids=modifiers.contains(.command) ? ids.union(range) : range;primary=id;return
        }
        if modifiers.contains(.command) {
            if ids.contains(id) {ids.remove(id);primary=ordered.first {ids.contains($0)}} else {ids.insert(id);primary=id}
            anchor=id;return
        }
        replace(id)
    }
    mutating func retain(_ available:Set<String>) {ids.formIntersection(available);if let primary,!ids.contains(primary) {self.primary=ids.sorted().first};if ids.isEmpty {anchor=nil}}
}
