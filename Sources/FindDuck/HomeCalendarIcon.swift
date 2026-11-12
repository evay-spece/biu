import AppKit
import SwiftUI

struct HomeCalendarDay: Equatable {
    let key: String
    let day: Int
    let weekday: String
    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        day = parts.day ?? 1
        weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][(parts.weekday ?? 1) - 1]
        key = "\(timeZone.identifier)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(day)"
    }
}

/// Calendar's bundle icon is static. Draw its live date using TaskDock's native silhouette approach.
@MainActor enum HomeCalendarIcon {
    private static let nativeIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
    private static var calendarPaths: [String: Bool] = [:]
    private static var cached: (key: String, image: NSImage)?
    static func isCalendar(_ path: String) -> Bool {
        if let value = calendarPaths[path] { return value }
        let value = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.apple.iCal"
        calendarPaths[path] = value
        return value
    }
    static func image(for date: Date) -> NSImage {
        let key = HomeCalendarDay(date: date).key
        if let cached, cached.key == key { return cached.image }
        let image = render(for: date)
        cached = (key, image)
        return image
    }
    static func applicationIcon(_ path: String) -> NSImage {
        isCalendar(path) ? image(for: Date()) : NSWorkspace.shared.icon(forFile: path)
    }
    private static func render(for date: Date) -> NSImage {
        let parts = HomeCalendarDay(date: date)
        let day = parts.day
        let weekdayName = parts.weekday
        let size = NSSize(width: 256, height: 256)

        let face = NSImage(size: size, flipped: false) { rect in
            if let nativeIcon {
                // Reuse macOS Calendar's alpha silhouette, including its continuous corners.
                nativeIcon.draw(in: rect)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .sourceIn
                NSGradient(starting: NSColor(calibratedWhite: 0.965, alpha: 1), ending: .white)?
                    .draw(in: rect, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 25, y: 25, width: 206, height: 206),
                             xRadius: 55, yRadius: 55).fill()
            }

            let rim = NSBezierPath(roundedRect: NSRect(x: 25.5, y: 25.5, width: 205, height: 205),
                                   xRadius: 55, yRadius: 55)
            rim.lineWidth = 1.5
            NSColor(calibratedWhite: 0.75, alpha: 0.40).setStroke()
            rim.stroke()

            let title = weekdayName as NSString
            let titleFont = NSFont.systemFont(ofSize: 50, weight: .bold)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.systemRed
            ]
            let titleSize = title.size(withAttributes: titleAttributes)
            title.draw(at: NSPoint(x: rect.midX - titleSize.width / 2, y: 167),
                       withAttributes: titleAttributes)

            let number = String(day) as NSString
            let numberFont = NSFont.systemFont(ofSize: 139, weight: .regular)
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor(calibratedWhite: 0.06, alpha: 1)
            ]
            let numberSize = number.size(withAttributes: numberAttributes)
            number.draw(at: NSPoint(x: rect.midX - numberSize.width / 2,
                                    y: day < 10 ? 25 : 31),
                        withAttributes: numberAttributes)
            return true
        }
        guard let cgImage = face.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return face }
        let raster = NSImage(cgImage: cgImage, size: size)
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            raster.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}

struct HomeApplicationIcon: View {
    let path: String
    let size: CGFloat
    @State private var day = HomeCalendarDay(date: Date())
    @State private var date = Date()
    var body: some View {
        Group {
            if HomeCalendarIcon.isCalendar(path) {
                Image(nsImage: HomeCalendarIcon.image(for: date)).resizable()
                    .onAppear { refresh() }
                    .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { refresh($0) }
                    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
                    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
                    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in refresh() }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            }
        }.scaledToFit().frame(width: size, height: size)
    }
    private func refresh(_ now: Date = Date()) {
        let next = HomeCalendarDay(date: now)
        guard next != day else { return }
        day = next
        date = now
    }
}
