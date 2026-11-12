import AppKit
import SwiftUI

enum ToolWindowFocusDecision:Equatable {case cancel,wait,hide}
enum ToolWindowPolicy {
    static func decision(visible:Bool,key:Bool,pinned:Bool,modal:Bool)->ToolWindowFocusDecision {
        if !visible || key || pinned {return .cancel}
        return modal ? .wait : .hide
    }
}

@MainActor final class ToolWindowHideTimer {
    private var task:Task<Void,Never>?
    func cancel() {task?.cancel();task=nil}
    func schedule(delay:Double,decision:@escaping ()->ToolWindowFocusDecision,hide:@escaping ()->Void) {
        cancel()
        task=Task { @MainActor in
            do {try await Task.sleep(for:.seconds(max(0,delay)))} catch {return}
            while !Task.isCancelled {
                switch decision() {
                case .cancel:return
                case .hide:hide();return
                case .wait:
                    do {try await Task.sleep(for:.milliseconds(250))} catch {return}
                }
            }
        }
    }
}

struct ToolWindowChrome:ViewModifier {
    @AppStorage private var pinned:Bool
    @AppStorage("biuToolWindowHideDelay") private var delay:Double = 3
    private let keyTitle:String
    private let pinKey:String
    init(key:String) {_pinned=AppStorage(wrappedValue:false,key);pinKey=key;keyTitle=key.contains("Clipboard") ? "剪贴板历史" : "常用文本"}
    func body(content:Content)->some View {
        content
            .toolbar {
                ToolbarItem(placement:.principal) {Text(keyTitle).font(.headline)}

            }
            .background(ToolWindowFocusObserver(pinned:pinned,delay:delay,key:pinKey))
    }
}

private struct ToolWindowFocusObserver:NSViewRepresentable {
    let pinned:Bool
    let delay:Double
    let key:String
    func makeNSView(context:Context)->Surface {Surface()}
    func updateNSView(_ view:Surface,context:Context) {view.update(pinned:pinned,delay:delay,key:key)}
    static func dismantleNSView(_ view:Surface,coordinator:()) {view.stop()}
    final class Surface:NSView {
        private var accessory:NSTitlebarAccessoryViewController?
        private var pinButton:NSButton?
        private var pinKey=""
        private var pinned=false
        private var delay:Double=3
        private var observers:[NSObjectProtocol]=[]
        private let timer=ToolWindowHideTimer()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();stop()
            guard let window else {return}
            window.titleVisibility = .hidden
            let accessory=NSTitlebarAccessoryViewController();accessory.layoutAttribute = .right
            let button=NSButton(frame:NSRect(x:0,y:0,width:32,height:28));button.isBordered=false;button.target=self;button.action=#selector(togglePin)
            accessory.view=button;window.addTitlebarAccessoryViewController(accessory)
            self.accessory=accessory;self.pinButton=button;refreshPin()
            let center=NotificationCenter.default
            observers.append(center.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in Task { @MainActor in self?.schedule() }})
            observers.append(center.addObserver(forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main) { [weak self] _ in Task { @MainActor in self?.cancel() }})
        }
        func update(pinned:Bool,delay:Double,key:String) {
            self.pinKey=key
            self.pinned=pinned;self.delay=min(max(delay,0),60)
            refreshPin()
            if pinned {cancel()}
        }
        @objc private func togglePin() {UserDefaults.standard.set(!pinned,forKey:pinKey)}
        private func refreshPin() {
            pinButton?.image=NSImage(systemSymbolName:pinned ? "pin.fill" : "pin",accessibilityDescription:pinned ? "取消固定窗口" : "固定窗口")
            pinButton?.contentTintColor=pinned ? .controlAccentColor : .secondaryLabelColor
            pinButton?.toolTip=pinned ? "取消固定窗口" : "固定窗口"
            pinButton?.setAccessibilityLabel(pinned ? "取消固定窗口" : "固定窗口")
            pinButton?.setAccessibilityValue(pinned ? "已固定" : "未固定")
        }
        private func cancel() {timer.cancel()}
        private func schedule() {
            cancel();guard !pinned else {return}
            timer.schedule(delay:delay,decision:{ [weak self] in
                guard let self,let window=self.window else {return .cancel}
                let activeChild=window.childWindows?.contains(where:{$0.isKeyWindow || $0.attachedSheet != nil}) == true
                return ToolWindowPolicy.decision(visible:window.isVisible,key:window.isKeyWindow,pinned:self.pinned,modal:window.attachedSheet != nil || NSApp.modalWindow != nil || activeChild)
            },hide:{ [weak self] in self?.window?.orderOut(nil) })
        }
        func stop() {if let accessory,let window=accessory.view.window,let index=window.titlebarAccessoryViewControllers.firstIndex(of:accessory) {window.removeTitlebarAccessoryViewController(at:index)};accessory=nil;pinButton=nil;cancel();for observer in observers {NotificationCenter.default.removeObserver(observer)};observers=[]}
    }
}
