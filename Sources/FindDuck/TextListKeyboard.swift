import SwiftUI
import AppKit

struct TextListKeyboard:NSViewRepresentable {
    let requestDelete:()->Bool
    let confirmDelete:()->Bool
    func makeNSView(context:Context)->Surface {Surface()}
    func updateNSView(_ view:Surface,context:Context) {view.requestDelete=requestDelete;view.confirmDelete=confirmDelete}
    static func dismantleNSView(_ view:Surface,coordinator:()) {view.stop()}
    final class Surface:NSView {
        var requestDelete:(()->Bool)?
        var confirmDelete:(()->Bool)?
        private var monitor:Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();stop()
            guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self,let window=self.window,event.window === window,window.attachedSheet == nil else {return event}
                if let text=window.firstResponder as? NSTextView,text.isEditable {return event}
                guard event.modifierFlags.intersection([.command,.option,.control]).isEmpty else {return event}
                if [51,117].contains(event.keyCode),self.requestDelete?() == true {return nil}
                if [36,76,49].contains(event.keyCode),self.confirmDelete?() == true {return nil}
                return event
            }
        }
        func stop() {if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil}
    }
}
