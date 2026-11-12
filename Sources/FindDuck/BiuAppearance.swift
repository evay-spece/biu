import AppKit

@MainActor enum BiuAppearance {
    static func apply(_ dark: Bool) {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}
