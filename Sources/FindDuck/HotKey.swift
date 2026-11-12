import AppKit
import Carbon
import SwiftUI

struct HotKeySettings: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    var enabled: Bool
    var defaultRevision: Int? = nil
    static let standard = HotKeySettings(keyCode: 49, modifiers: UInt32(optionKey), label: "空格", enabled: true)
    static let fn = HotKeySettings(keyCode: UInt32(kVK_Function), modifiers: 0, label: "Fn", enabled: true)
    static let standardSecondary = HotKeySettings(keyCode: UInt32(kVK_Function), modifiers: 0, label: "Fn", enabled: false)
    var isFn: Bool { keyCode == UInt32(kVK_Function) && modifiers == 0 }
    static let standardQuickText = HotKeySettings(keyCode: 17, modifiers: UInt32(controlKey | optionKey), label: "T", enabled: true)
    static let standardClipboard = HotKeySettings(keyCode: 9, modifiers: UInt32(controlKey | optionKey), label: "V", enabled: true)
    var display: String {
        let parts: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return parts.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }
    static let functionKeys:Set<UInt32>=[122,120,99,118,96,97,98,100,101,109,103,111]
    static func allowed(keyCode:UInt32,modifiers:UInt32)->Bool {modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || (modifiers == 0 && functionKeys.contains(keyCode))}
    static func from(_ event: NSEvent) -> HotKeySettings? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard allowed(keyCode:UInt32(event.keyCode),modifiers:modifiers) else {return nil}
        let special: [UInt16: String] = [49:"空格",36:"↩",48:"⇥",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty else { return nil }
        return HotKeySettings(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label, enabled: true)
    }
}
private final class CarbonResources: @unchecked Sendable {
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var fnMonitors: [Any] = []
    func stopFnMonitoring() {
        for monitor in fnMonitors { NSEvent.removeMonitor(monitor) }
        fnMonitors.removeAll()
    }
    deinit {
        stopFnMonitoring()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
private let hotKeySignature: OSType = 0x534D4253
private let callback: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
    guard identifier.id == manager.identifier else { return OSStatus(eventNotHandledErr) }
    Task { @MainActor in manager.toggleWindow() }
    return noErr
}

@MainActor final class HotKeyManager: ObservableObject {
    enum Purpose {case search, secondarySearch, clipboard, quickText}
    let purpose:Purpose
    private var isSearch: Bool { purpose == .search || purpose == .secondarySearch }
    private var targetName: String {
        switch purpose {
        case .search, .secondarySearch: "搜索"
        case .clipboard: "剪贴板"
        case .quickText: "常用文本"
        }
    }
    @Published private(set) var settings: HotKeySettings
    @Published var isRecording = false
    @Published var message = ""
    @Published var hasError = false
    @Published var focusRequest = 0
    weak var otherSearchShortcut: HotKeyManager?
    private var fnPressedAt: TimeInterval?
    private var defaultSettings: HotKeySettings {
        switch purpose {
        case .search: .standard
        case .secondarySearch: .standardSecondary
        case .clipboard: .standardClipboard
        case .quickText: .standardQuickText
        }
    }
    var openSearch: (() -> Void)?
    var openTool:(() -> Void)?
    weak var toolWindow:NSWindow?
    var prepareSearch: ((TimeInterval?) -> Bool)?
    private var savedSelection: NSRange?
    private var lastHiddenAt:Date?
    private var lastInvokedAt:Date?
    var openSettings: (() -> Void)?
    weak var searchWindow: NSWindow?
    weak var searchField: NSTextField?
    nonisolated let identifier = UInt32.random(in: 1...UInt32.max)
    private let storage: URL
    private let resources = CarbonResources()
    private(set) var isRegistered = false
    init(storage: URL? = nil,purpose:Purpose = .search) {
        self.purpose=purpose
        let filename: String
        let fallback: HotKeySettings
        switch purpose {
        case .search: (filename, fallback) = ("hotkey.json", .standard)
        case .secondarySearch: (filename, fallback) = ("secondary-hotkey.json", .standardSecondary)
        case .clipboard: (filename, fallback) = ("clipboard-hotkey.json", .standardClipboard)
        case .quickText: (filename, fallback) = ("quick-text-hotkey.json", .standardQuickText)
        }
        self.storage = storage ?? BiuStorage.directory.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: self.storage),
           let saved = try? JSONDecoder().decode(HotKeySettings.self, from: data) {
            settings = saved
        } else {
            settings = fallback
        }
        if purpose == .search, settings.defaultRevision == nil, settings.keyCode == 49,
           [UInt32(controlKey), UInt32(controlKey | optionKey)].contains(settings.modifiers) {
            let enabled = settings.enabled
            settings = .standard
            settings.enabled = enabled
            settings.defaultRevision = 1
            if let data = try? JSONEncoder().encode(settings) { try? data.write(to: self.storage, options: .atomic) }
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &resources.handler)
        guard result == noErr else { message = "无法初始化全局快捷键（\(result)）"; hasError = true; return }
        registerCurrent()
    }
    private func systemConflict(_ candidate: HotKeySettings) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let raw = array?.takeRetainedValue() else { return false }
        guard let keys = raw as? [[String: Any]] else { return false }
        return keys.contains {
            ($0["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true &&
            ($0["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value == candidate.keyCode &&
            ($0["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value == candidate.modifiers
        }
    }
    private func registerCurrent() {
        guard settings.enabled else { hasError = false; message = "全局快捷键已停用"; return }
        if settings.isFn, isSearch {
            registerFn()
            return
        }
        if systemConflict(settings) { message = "该组合键与 macOS 系统快捷键冲突，请换一个。"; hasError = true; return }
        let result = RegisterEventHotKey(settings.keyCode, settings.modifiers, EventHotKeyID(signature: hotKeySignature, id: identifier), GetApplicationEventTarget(), 0, &resources.hotKey)
        isRegistered = result == noErr
        hasError = result != noErr
        message = result == noErr ? "已生效：\(settings.display) 呼出\(targetName)" : "该组合键被占用或无法注册（\(result)），请换一个。"
    }
    private func registerFn() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .systemDefined]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleFn(event)
            return event
        }) { resources.fnMonitors.append(local) }
        let trusted = AXIsProcessTrusted()
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFn(event) }
        }
        if let global { resources.fnMonitors.append(global) }
        isRegistered = !resources.fnMonitors.isEmpty
        hasError = !trusted || global == nil
        message = hasError ? "Fn 已保存。跨应用使用需在系统设置 → 隐私与安全性 → 辅助功能中允许 Biu，授权后重新启用。" : "单按并松开 Fn 呼出搜索。"
    }

    private func handleFn(_ event: NSEvent) {
        guard !isRecording, otherSearchShortcut?.isRecording != true else { fnPressedAt = nil; return }
        guard event.type == .flagsChanged, UInt32(event.keyCode) == HotKeySettings.fn.keyCode else {
            fnPressedAt = nil
            return
        }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.modifierFlags.contains(.function) {
            fnPressedAt = modifiers.isEmpty ? event.timestamp : nil
        } else {
            let began = fnPressedAt
            fnPressedAt = nil
            if let began, modifiers.isEmpty, (0...0.6).contains(event.timestamp - began) { toggleWindow() }
        }
    }

    private func unregister() {
        resources.stopFnMonitoring()
        fnPressedAt = nil
        if let key = resources.hotKey { UnregisterEventHotKey(key); resources.hotKey = nil }
        isRegistered = false
    }
    func beginRecording() { unregister(); isRecording = true; hasError = false; message = isSearch ? "请按下新快捷键组合，或单按 F1–F12、🌐 Fn 设置快捷键。按 Esc 取消录制。" : "请按下新快捷键组合，或单按 F1–F12。按 Esc 取消录制。" }
    func cancelRecording() { guard isRecording else { return }; isRecording = false; registerCurrent() }
    func capture(_ event: NSEvent) {
        if event.keyCode == 53 { cancelRecording(); return }
        guard let candidate = HotKeySettings.from(event) else { hasError = true; message = "F1–F12可单独使用，其他按键请搭配Control、Option或Command。"; return }
        apply(candidate)
    }
    func captureFn(_ event: NSEvent) {
        guard isRecording, isSearch,
              UInt32(event.keyCode) == HotKeySettings.fn.keyCode, event.modifierFlags.contains(.function),
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return }
        apply(.fn)
    }

    func apply(_ requested: HotKeySettings) {
        var candidate = requested
        if purpose == .search { candidate.defaultRevision = 1 }
        guard HotKeySettings.allowed(keyCode:candidate.keyCode,modifiers:candidate.modifiers) ||
                (isSearch && candidate.isFn) else {
            hasError = true; message = "F1–F12可单独使用，其他按键请搭配Control、Option或Command。"; return
        }
        if candidate.enabled, let other = otherSearchShortcut?.settings, other.enabled,
           other.keyCode == candidate.keyCode, other.modifiers == candidate.modifiers {
            hasError = true
            message = "另一套启动快捷键已使用这个按键。"
            return
        }
        let old = settings
        unregister(); isRecording = false
        settings = candidate
        hasError = false
        registerCurrent()
        guard !candidate.enabled || isRegistered else {
            let reason = message
            settings = old; registerCurrent()
            hasError = true; message = reason + " 原设置已保留。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: storage, options: .atomic)
        } catch {
            unregister(); settings = old; registerCurrent()
            hasError = true; message = "保存失败，原设置已保留：\(error.localizedDescription)"
        }
    }
    func setEnabled(_ value: Bool) { var candidate = settings; candidate.enabled = value; apply(candidate) }
    func restoreDefault() { apply(defaultSettings) }
    func toggleWindow() {
        if purpose == .secondarySearch { otherSearchShortcut?.toggleWindow(); return }
        let window = isSearch ? searchWindow : toolWindow
        if NSApp.isActive, window?.isKeyWindow == true {
            if isSearch { hideSearch() } else { window?.orderOut(nil) }
        } else {
            invoke()
        }
    }

    func invoke() {
        if purpose == .secondarySearch { otherSearchShortcut?.invoke(); return }
        if !isSearch {
            if toolWindow == nil {openTool?()}
            NSApp.activate(ignoringOtherApps:true)
            if let window = toolWindow {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        let now = Date()
        let reference = lastHiddenAt ?? lastInvokedAt
        let elapsed = searchWindow?.isVisible == true && lastInvokedAt != nil
            ? 0 : reference.map { now.timeIntervalSince($0) }
        let reset = prepareSearch?(elapsed) ?? true
        lastInvokedAt=now;lastHiddenAt=nil
        if searchWindow == nil { openSearch?() }
        NSApp.activate(ignoringOtherApps: true)
        if let window = searchWindow {
            if reset { resetSearchFrame(window) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        focusRequest += 1
        let selection = reset ? nil : savedSelection
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if reset || selection != nil { self.focusSearchInput() }
            if let selection, let editor = self.searchField?.currentEditor() {
                let length = (editor.string as NSString).length
                let start = min(selection.location, length)
                editor.selectedRange = NSRange(location: start, length: min(selection.length, length - start))
            }
        }
    }
    func focusSearchInput(selectAll: Bool = false) {
        guard let searchField, let window = searchField.window else { return }
        window.makeFirstResponder(searchField)
        if selectAll { searchField.currentEditor()?.selectAll(nil) }
    }
    func resetSearchFrame(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? window.screen else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(760, visible.width - 40), height: min(580, visible.height - 60))
        window.setContentSize(size)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    func hideSearch() {
        savedSelection = searchField?.currentEditor()?.selectedRange
        lastHiddenAt = Date()
        searchWindow?.orderOut(nil)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var manager: HotKeyManager
    func makeNSView(context: Context) -> RecorderView { RecorderView(manager: manager) }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.manager = manager
        if manager.isRecording, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        else if !manager.isRecording, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
    final class RecorderView: NSView {
        var manager: HotKeyManager
        init(manager: HotKeyManager) { self.manager = manager; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func flagsChanged(with event: NSEvent) { manager.captureFn(event) }
        override func keyDown(with event: NSEvent) { manager.capture(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard manager.isRecording else { return false }; manager.capture(event); return true
        }
        override func resignFirstResponder() -> Bool { manager.cancelRecording(); return true }
    }
}
