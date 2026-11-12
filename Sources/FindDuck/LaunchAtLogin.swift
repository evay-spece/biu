import AppKit
import ServiceManagement
import Combine

@MainActor final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error = ""
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus; self.register = register; self.unregister = unregister
        refresh()
    }
    var requested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    func refresh() { status = readStatus() }
    func setEnabled(_ enabled: Bool) {
        error = ""
        do {
            if enabled { try register() } else if requested { try unregister() }
        } catch {
            self.error = "无法修改登录启动设置：" + error.localizedDescription
        }
        // The switch reflects the OS registration state, including failed operations.
        refresh()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
