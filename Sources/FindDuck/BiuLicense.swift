import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

private struct BiuLicenseKeychain {
    let service: String
    func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
}

@MainActor final class BiuLicense: ObservableObject {
    @Published private(set) var deviceID = ""
    @Published private(set) var unlocked = false
    @Published private(set) var activated = false
    @Published private(set) var daysRemaining = 0
    @Published private(set) var message = ""
    private let store: BiuLicenseKeychain
    private let publicKey: SecKey?
    private let clock: () -> Date
    private let shortCodeHashes: Set<String>
    private static let universalDigest = "d25b1b53feda3bd5298742338b4b0b745647d877dd381129bd2c0aeafe8ff64c"
    private static func digest(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var timer: Timer?

    init(service: String = "com.rocketduck.biu.license", publicKey: SecKey? = nil, clock: @escaping () -> Date = Date.init, startTimer: Bool = true, shortCodeHashes: Set<String>? = nil) {
        store = BiuLicenseKeychain(service: service); self.clock = clock
        self.shortCodeHashes = shortCodeHashes ?? BiuTrialCode.loadPool()
        if let publicKey { self.publicKey = publicKey }
        else if let url = Bundle.main.url(forResource: "biu-license-public", withExtension: "der"),
                let data = try? Data(contentsOf: url) {
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            self.publicKey = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
        } else { self.publicKey = nil }
        refresh()
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
    func refresh() {
        do {
            if let existing = try store.read("device-id"), UUID(uuidString: existing) != nil { deviceID = existing }
            else { deviceID = UUID().uuidString.lowercased(); try store.write(deviceID, account: "device-id") }
            if try store.read("universal-activation") == Self.universalDigest {
                activated = true; unlocked = true; daysRemaining = 0; message = "已激活，可离线使用。"; return
            }
            if let token = try store.read("license-token"), let publicKey,
               BiuLicenseVerifier.verify(token: token, deviceID: deviceID, publicKey: publicKey) {
                activated = true; unlocked = true; daysRemaining = 0; message = "已激活，可离线使用。"; return
            }
            activated = false
            let now = clock().timeIntervalSince1970
            let lastSeen = try store.read("last-seen").flatMap(Double.init) ?? now
            guard now >= lastSeen - 300 else { unlocked = false; message = "系统时间异常，请校准日期后重试。"; return }
            let start: Double
            if let existing = try store.read("trial-start").flatMap(Double.init) { start = existing }
            else { start = now; try store.write(String(start), account: "trial-start") }
            try store.write(String(max(now,lastSeen)), account: "last-seen")
            let trialState = try readTrialState()
            let remaining = max(0, max(start + 15 * 86400, trialState.expiry) - max(now,lastSeen))
            daysRemaining = Int(ceil(remaining / 86400)); unlocked = remaining > 0
            message = unlocked ? "试用剩余 \(daysRemaining) 天" : "试用已结束，请输入激活码。"
        } catch { unlocked = false; message = "无法读取或保存授权状态，请检查钥匙串权限。" }
    }
    private func readTrialState() throws -> BiuTrialState {
        guard let encoded = try store.read("trial-code-state") else { return BiuTrialState() }
        return try JSONDecoder().decode(BiuTrialState.self, from: Data(encoded.utf8))
    }
    @discardableResult func activate(_ raw: String) -> Bool {
        let token = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        if Self.digest(token) == Self.universalDigest {
            do { try store.write(Self.universalDigest, account: "universal-activation"); refresh(); return activated }
            catch { message = "无法保存激活状态，请检查钥匙串权限。"; return false }
        }
        if !token.contains(".") {
            guard let id = BiuTrialCode.identifier(raw, allowed: shortCodeHashes) else {
                message = "试用码无效，请检查后重试。"; return false
            }
            guard !activated else { message = "已永久激活，无需使用试用码。"; return false }
            do {
                var state = try readTrialState()
                guard !state.redeemed.contains(id) else { message = "此试用码已在本机使用过。"; return false }
                let now = clock().timeIntervalSince1970
                let lastSeen = try store.read("last-seen").flatMap(Double.init) ?? now
                guard now >= lastSeen - 300 else { message = "系统时间异常，请校准日期后重试。"; return false }
                guard let start = try store.read("trial-start").flatMap(Double.init) else {
                    message = "无法读取试用状态，请检查钥匙串。"; return false
                }
                state.expiry = max(max(now, lastSeen), max(start + 15 * 86400, state.expiry)) + 15 * 86400
                state.redeemed.append(id)
                try store.write(String(decoding: JSONEncoder().encode(state), as: UTF8.self), account: "trial-code-state")
                refresh()
                guard unlocked else { return false }
                message = "试用码兑换成功，已增加 15 天。试用剩余 \(daysRemaining) 天。"; return true
            } catch { message = "无法保存试用状态，请检查钥匙串权限。"; return false }
        }
        guard let publicKey, !deviceID.isEmpty, BiuLicenseVerifier.verify(token: token, deviceID: deviceID, publicKey: publicKey) else {
            message = "激活码无效或不属于这台 Mac，请核对后重试。"; return false
        }
        do { try store.write(token, account: "license-token"); refresh(); return activated }
        catch { message = "激活码有效，但无法保存到钥匙串。"; return false }
    }
}

struct BiuLicenseView: View {
    @ObservedObject var license: BiuLicense
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(license.activated ? "Biu 已激活" : "Biu 授权").font(.title2.bold())
            Text(license.message).foregroundStyle(license.unlocked ? .secondary : .primary)
            if !license.activated {
                Text("本机申请码").font(.headline)
                HStack { Text(license.deviceID).textSelection(.enabled); Button("拷贝") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(license.deviceID, forType: .string)
                }}
                Text("试用码可直接兑换 15 天；永久激活需提供本机申请码。换 Mac 后永久授权需要重新申请。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("输入试用码或永久激活码", text: $code).textFieldStyle(.roundedBorder)
                Button("兑换或激活") { if license.activate(code) { code = "" } }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct BiuLicenseGate: ViewModifier {
    @ObservedObject var license: BiuLicense
    func body(content: Content) -> some View {
        content.disabled(!license.unlocked)
            .overlay { if !license.unlocked { BiuLicenseView(license: license).background(.regularMaterial) } }
    }
}
