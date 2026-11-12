import AppKit
import SwiftUI

struct QuickTextDragInteraction: NSViewRepresentable {
    var id: UUID? = nil
    let title: String
    var trailingControlsWidth: CGFloat = 0
    let action: (Bool) -> Void
    var hover: (Bool) -> Void = { _ in }
    let accepts: (UUID) -> Bool
    let drop: (UUID, CGPoint) -> Bool
    let targeted: (Bool) -> Void
    var position: (CGPoint?) -> Void = { _ in }
    var contextMenu:(()->NSMenu)? = nil

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.itemID = id
        view.title = title
        view.trailingControlsWidth = trailingControlsWidth
        view.action = action
        view.hover = hover
        view.accepts = accepts
        view.drop = drop
        view.targeted = targeted
        view.position = position
        view.makeMenu=contextMenu
    }

    final class Surface: NSView, NSDraggingSource {
        var itemID: UUID?
        var title = ""
        var trailingControlsWidth: CGFloat = 0
        var action: ((Bool) -> Void)?
        var hover: ((Bool) -> Void)?
        var accepts: ((UUID) -> Bool)?
        var drop: ((UUID, CGPoint) -> Bool)?
        var targeted: ((Bool) -> Void)?
        var position: ((CGPoint?) -> Void)?
        var makeMenu:(()->NSMenu)?
        private var down: NSEvent?
        private var dragged = false
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), !isHidden else { return nil }
            if itemID != nil, bounds.height > 60, local.y >= bounds.height - 34 { return nil }
            if trailingControlsWidth > 0, local.y < 36, local.x > bounds.width - trailingControlsWidth { return nil }
            return self
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            tracking = area
            addTrackingArea(area)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        override func mouseMoved(with event: NSEvent) { hover?(true) }
        override func mouseEntered(with event: NSEvent) { hover?(true) }
        override func mouseExited(with event: NSEvent) { hover?(false) }
        override func rightMouseDown(with event:NSEvent) {
            if let menu=makeMenu?() {NSMenu.popUpContextMenu(menu,with:event,for:self)} else {super.rightMouseDown(with:event)}
        }
        override func mouseDown(with event: NSEvent) { down = event; dragged = false }
        override func mouseUp(with event: NSEvent) {
            defer { down = nil }
            if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { action?(event.clickCount == 2) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let id = itemID, let down, !dragged,
                  hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
            dragged = true
            let item = NSDraggingItem(pasteboardWriter: (QuickTextDrag.prefix + id.uuidString) as NSString)
            let image = NSImage(size: NSSize(width: 220, height: 36), flipped: true) { rect in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                (self.title as NSString).draw(in: rect.insetBy(dx: 10, dy: 9), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: style
                ])
                return true
            }
            let point = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 40, y: point.y - 18, width: 220, height: 36), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            down = nil; hover?(false); targeted?(false)
        }
        private func source(_ sender: any NSDraggingInfo) -> UUID? {
            guard let text = sender.draggingPasteboard.string(forType: .string),
                  let id = QuickTextDrag.identifier([text]), accepts?(id) == true else { return nil }
            return id
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard source(sender) != nil else { return [] }
            targeted?(true)
            position?(convert(sender.draggingLocation, from: nil))
            return .move
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard source(sender) != nil else { return [] }
            position?(convert(sender.draggingLocation, from: nil))
            return .move
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted?(false) }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { source(sender) != nil }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            targeted?(false)
            guard let id = source(sender) else { return false }
            return drop?(id, convert(sender.draggingLocation, from: nil)) ?? false
        }
    }
}
