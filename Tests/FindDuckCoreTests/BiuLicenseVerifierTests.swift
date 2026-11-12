import XCTest
import Security
import CryptoKit
@testable import FindDuck

final class BiuLicenseVerifierTests: XCTestCase {
    @MainActor func testTrialExpiryActivationAndReload() throws {
        let service = "com.rocketduck.biu.test.\(UUID().uuidString)"
        defer {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let license = BiuLicense(service: service, publicKey: publicKey, clock: { now }, startTimer: false)
        XCTAssertTrue(license.unlocked)
        XCTAssertEqual(license.daysRemaining, 15)
        let device = license.deviceID
        now = now.addingTimeInterval(15 * 86400)
        license.refresh()
        XCTAssertFalse(license.unlocked)
        license.activate("bad-code")
        XCTAssertFalse(license.unlocked)
        func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let header = encode(try JSONSerialization.data(withJSONObject: ["alg": "RS256"]))
        let body = encode(try JSONSerialization.data(withJSONObject: ["iss": "biu-offline", "version": 1, "product": "biu", "tier": "perpetual", "device_id": device]))
        let message = "\(header).\(body)"
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil) as Data?)
        license.activate("\(message).\(encode(signature))")
        XCTAssertTrue(license.activated)
        let reloaded = BiuLicense(service: service, publicKey: publicKey, clock: { now }, startTimer: false)
        XCTAssertEqual(reloaded.deviceID, device)
        XCTAssertTrue(reloaded.unlocked)
        XCTAssertTrue(reloaded.activated)
    }
    @MainActor func testShortCodesExtendAndPersistWithoutDuplicateRedemption() throws {
        let service = "com.rocketduck.biu.test.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let code = "ABCD2345EFGH", other = "JKLM6789NPQR", afterExpiry = "STUV2345WXYZ"
        func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let pool: Set<String> = [digest(code), digest(other), digest(afterExpiry)]
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = BiuLicense(service: service, clock: { now }, startTimer: false, shortCodeHashes: pool)
        XCTAssertEqual(first.daysRemaining, 15)
        XCTAssertTrue(first.activate("abcd-2345-efgh"))
        XCTAssertEqual(first.daysRemaining, 30)
        XCTAssertFalse(first.activate(code))
        XCTAssertEqual(first.daysRemaining, 30)
        let restored = BiuLicense(service: service, clock: { now }, startTimer: false, shortCodeHashes: pool)
        XCTAssertEqual(restored.daysRemaining, 30)
        XCTAssertFalse(restored.activate(code))
        XCTAssertTrue(restored.activate(other))
        XCTAssertEqual(restored.daysRemaining, 45)
        XCTAssertFalse(restored.activate("ABCD-2345-EFGJ"))
        now = now.addingTimeInterval(46 * 86400)
        restored.refresh(); XCTAssertFalse(restored.unlocked)
        XCTAssertFalse(restored.activate(code))
        XCTAssertTrue(restored.activate(afterExpiry))
        XCTAssertEqual(restored.daysRemaining, 15)
    }
    func testSignedLicenseIsBoundToDeviceAndProduct() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        func encoded(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        func token(product: String) throws -> String {
            let header = encoded(try JSONSerialization.data(withJSONObject: ["alg": "RS256"]))
            let body = encoded(try JSONSerialization.data(withJSONObject: ["iss": "biu-offline", "version": 1,
                "product": product, "tier": "perpetual", "device_id": "test-device"]))
            let message = "\(header).\(body)"
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                               Data(message.utf8) as CFData, nil) as Data?)
            return "\(message).\(encoded(signature))"
        }
        let valid = try token(product: "biu")
        XCTAssertTrue(BiuLicenseVerifier.verify(token: valid, deviceID: "test-device", publicKey: publicKey))
        XCTAssertFalse(BiuLicenseVerifier.verify(token: valid, deviceID: "other-device", publicKey: publicKey))
        XCTAssertFalse(BiuLicenseVerifier.verify(token: try token(product: "taskdock"), deviceID: "test-device", publicKey: publicKey))
        XCTAssertFalse(BiuLicenseVerifier.verify(token: valid + "x", deviceID: "test-device", publicKey: publicKey))
        XCTAssertFalse(BiuLicenseVerifier.verify(token: "invalid", deviceID: "test-device", publicKey: publicKey))
    }
}
