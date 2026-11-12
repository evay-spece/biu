import Foundation

struct ClipboardCopyStatus {
    var entryID: UUID? = nil
    var plainText = false
    var changeCount = -1

    func isActive(_ id:UUID,plainText:Bool)->Bool {entryID == id && self.plainText == plainText}

    mutating func invalidateIfChanged(_ currentCount: Int) -> Bool {
        guard entryID != nil, currentCount != changeCount else { return false }
        entryID = nil
        changeCount = currentCount
        return true
    }
}
