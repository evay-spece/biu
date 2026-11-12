import AppKit

@MainActor enum HomeLauncherIcon {
    private static var cache: [String: NSImage] = [:]
    static func image(_ target: String) -> NSImage {
        if let image = cache[target] { return image }
        let name = target == HomeShortcut.recentAppsTarget ? "clock.arrow.circlepath" : "square.grid.2x2"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 29, weight: .medium))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = NSImage(size: NSSize(width: 50, height: 50), flipped: false) { rect in
            NSColor.systemBlue.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            if let symbol {
                let scale = min(31 / symbol.size.width, 31 / symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: (50-size.width)/2, y: (50-size.height)/2, width: size.width, height: size.height))
            }
            return true
        }
        cache[target] = image
        return image
    }
}
