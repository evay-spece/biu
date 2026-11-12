import AppKit
import SwiftUI

struct ImmediateResultClick: NSViewRepresentable {
    let select: (NSEvent.ModifierFlags,Bool)->Void
    let hover: (CGPoint?)->Void
    let open: (Bool)->Void
    let menu: ()->NSMenu
    func makeNSView(context:Context)->Surface {
        let view=Surface();view.setAccessibilityElement(false);return view
    }
    func updateNSView(_ view:Surface,context:Context) {view.select=select;view.hover=hover;view.open=open;view.makeMenu=menu}
    final class Surface:NSView {
        var select:((NSEvent.ModifierFlags,Bool)->Void)?
        var hover:((CGPoint?)->Void)?
        var open:((Bool)->Void)?
        var makeMenu:(()->NSMenu)?
        override var isFlipped:Bool {true}
        private var pointerTracking:NSTrackingArea?
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();window?.acceptsMouseMovedEvents=true}
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard pointerTracking == nil else {return}
            let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.inVisibleRect,.enabledDuringMouseDrag],owner:self,userInfo:nil)
            pointerTracking=area;addTrackingArea(area)
        }
        override func mouseEntered(with event:NSEvent) {hover?(convert(event.locationInWindow,from:nil))}
        override func mouseMoved(with event:NSEvent) {hover?(convert(event.locationInWindow,from:nil))}
        override func mouseExited(with event:NSEvent) {hover?(nil)}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func mouseDown(with event:NSEvent) {
            // Select on mouse-down, without waiting for the double-click interval.
            select?(event.modifierFlags,false)
            if event.clickCount == 2 {open?(event.modifierFlags.contains(.command))}
        }
        override func rightMouseDown(with event:NSEvent) {
            select?(event.modifierFlags,true)
            if let menu=makeMenu?() {NSMenu.popUpContextMenu(menu,with:event,for:self)}
        }
    }
}
@MainActor enum ResultMenus {
    private final class Action:NSObject {
        let body:()->Void
        init(_ body:@escaping ()->Void) {self.body=body}
        @objc func run(_ sender:NSMenuItem) {body()}
    }
    static func item(_ title:String,selected:Bool=false,action:@escaping ()->Void)->NSMenuItem {
        let target=Action(action),item=NSMenuItem(title:title,action:#selector(Action.run(_:)),keyEquivalent:"")
        item.target=target;item.representedObject=target;item.state=selected ? .on : .off;return item
    }
}
enum FileOperations {
    static func trash(_ url:URL) throws {
        // No fallback to removeItem: unsupported network volumes must remain unchanged.
        try FileManager.default.trashItem(at:url,resultingItemURL:nil)
    }
}
