import SwiftUI
import Combine

@MainActor final class ClipboardRowSelectionFlag: ObservableObject {
    @Published private(set) var isSelected: Bool
    @Published fileprivate(set) var deleteConfirmation = false
    init(selected: Bool = false) { isSelected = selected }
    fileprivate func setSelected(_ value: Bool) {
        guard value != isSelected else { return }
        isSelected = value
    }
}

// Intentionally not ObservableObject: selecting a row never invalidates the list owner.
@MainActor final class ClipboardRowSelection {
    private(set) var selectedID: UUID?
    private(set) var confirmingID: UUID?
    private var rows: [UUID: ClipboardRowSelectionFlag] = [:]
    func flag(for id: UUID) -> ClipboardRowSelectionFlag {
        if let existing = rows[id] { return existing }
        let flag = ClipboardRowSelectionFlag(selected: selectedID == id)
        rows[id] = flag
        return flag
    }
    func select(_ id: UUID?) {
        guard confirmingID == nil || confirmingID == id else { return }
        guard selectedID != id else { return }
        if let previous = selectedID { rows[previous]?.setSelected(false) }
        selectedID = id
        if let id { rows[id]?.setSelected(true) }
    }
    func setConfirmation(_ presented: Bool, for id: UUID) {
        if presented {
            if let previous = confirmingID, previous != id { setConfirmation(false, for: previous) }
            select(id)
            confirmingID = id
            flag(for: id).deleteConfirmation = true
        } else {
            if confirmingID == id { confirmingID = nil }
            rows[id]?.deleteConfirmation = false
        }
    }
    func retain(_ ids: Set<UUID>) {
        if let confirmingID, !ids.contains(confirmingID) { setConfirmation(false, for: confirmingID) }
        if let selectedID, !ids.contains(selectedID) { select(nil) }
        rows = rows.filter { ids.contains($0.key) }
    }
}

struct ClipboardSelectableRow<Content: View>: View {
    @ObservedObject var flag: ClipboardRowSelectionFlag
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        content(flag.isSelected)
            .accessibilityAddTraits(flag.isSelected ? .isSelected : [])
            .contentShape(Rectangle())
            .modifier(TextRowSelectionHighlight(selected: flag.isSelected))
    }
}
