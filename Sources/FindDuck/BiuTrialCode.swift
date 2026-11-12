import CryptoKit
import Foundation

enum BiuTrialCode {
    private static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static func identifier(_ input: String, allowed: Set<String>) -> String? {
        let normalized = input.uppercased().filter { !"-‐‑‒–—−".contains($0) && !$0.isWhitespace }
        guard normalized.count == 12, normalized.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return allowed.contains(digest) ? digest : nil
    }
    static func loadPool() -> Set<String> {
        guard let url = Bundle.main.url(forResource: "biu-trial-code-hashes", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init))
    }
}

struct BiuTrialState: Codable {
    var expiry: TimeInterval = 0
    var redeemed: [String] = []
}
