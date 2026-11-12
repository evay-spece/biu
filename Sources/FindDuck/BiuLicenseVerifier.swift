import Foundation
import Security

/// Validates a device-bound, offline Biu license using an issuer-controlled public key.
enum BiuLicenseVerifier {
    static func verify(token: String, deviceID: String, publicKey: SecKey) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decode(String(parts[0])),
              let payloadData = decode(String(parts[1])),
              let signature = decode(String(parts[2])),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              header["alg"] as? String == "RS256",
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              payload["iss"] as? String == "biu-offline",
              payload["version"] as? Int == 1,
              payload["product"] as? String == "biu",
              payload["tier"] as? String == "perpetual",
              payload["device_id"] as? String == deviceID else { return false }
        let message = Data("\(parts[0]).\(parts[1])".utf8)
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     message as CFData, signature as CFData, nil)
    }

    private static func decode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if value.count % 4 != 0 { value += String(repeating: "=", count: 4 - value.count % 4) }
        return Data(base64Encoded: value)
    }
}
