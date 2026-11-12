import SwiftUI
import AppKit

struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var manager: HotKeyManager
    let onSubmit: (Bool) -> Void
    let onMove: (Int) -> Void
    let onDeleteScope: () -> Bool
    let onEscape: () -> Void
    let onPreview: () -> Bool
    var onCopyFiles:(()->Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Input {
        let field = Input()
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 21)
        field.placeholderString = "搜索"
        field.identifier = NSUserInterfaceItemIdentifier("searchField")
        field.setAccessibilityLabel("搜索文件")
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        manager.searchField = field;field.copyFiles=onCopyFiles;field.preview=onPreview
        return field
    }
    func updateNSView(_ field: Input, context: Context) {
        context.coordinator.parent = self
        field.copyFiles=onCopyFiles;field.preview=onPreview;field.synchronize(text)
        manager.searchField = field
    }
    final class Input: NSTextField {
        var preview:(()->Bool)?
        var copyFiles:(()->Void)?
        private var monitor:Any?

        func synchronize(_ value: String) {
            // The field editor owns the composing text; model refreshes must not replace it.
            if let editor = currentEditor() as? NSTextView {
                guard !editor.hasMarkedText(), editor.string != value else { return }
                stringValue = value
            } else if stringValue != value {
                stringValue = value
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            if window != nil {monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                let consumed=MainActor.assumeIsolated {
                    guard let self,event.window == self.window else {return false}
                    if event.keyCode == 8,event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command,
                       let copyFiles=self.copyFiles {
                        if let editor=self.currentEditor() as? NSTextView,editor.hasMarkedText() || editor.selectedRange().length > 0 {return false}
                        copyFiles();return true
                    }
                    guard event.keyCode == 49,event.modifierFlags.intersection([.command,.control,.option]).isEmpty,let editor=self.currentEditor() as? NSTextView,!editor.hasMarkedText(),self.preview?() == true else {return false}
                    return true
                };return consumed ? nil : event
            }}
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelSearchField
        init(_ parent: PanelSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                guard !editor.hasMarkedText() else { return }
                if parent.text != editor.string { parent.text = editor.string }
            } else if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch NSStringFromSelector(commandSelector) {
            case "deleteBackward:", "deleteForward:":
                return textView.string.isEmpty ? parent.onDeleteScope() : false
            case "moveDown:": parent.onMove(1); return true
            case "moveUp:": parent.onMove(-1); return true
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.command) == true); return true
            case "cancelOperation:": parent.onEscape(); return true
            default: return false
            }
        }
    }
}
