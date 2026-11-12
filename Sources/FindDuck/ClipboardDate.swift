import Foundation
@MainActor enum ClipboardDate {
    private static let formatter:DateFormatter = {
        let value=DateFormatter();value.locale=Locale(identifier:"zh_CN");value.dateFormat="M月d日 EEE HH:mm";return value
    }()
    static func text(_ date:Date)->String {formatter.timeZone = .current;return formatter.string(from:date)}
}
