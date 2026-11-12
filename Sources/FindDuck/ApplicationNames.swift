import Foundation

struct ApplicationNames: Codable, Hashable, Sendable {
    let displayName: String
    let aliases: [String]

    func matches(_ term: String) -> Bool {
        term.isEmpty || aliases.contains { SearchText.contains($0, term) }
    }

    static func read(_ url: URL) -> Self {
        let bundle = Bundle(url: url)
        let original = url.deletingPathExtension().lastPathComponent
        let finderDisplay = FileManager.default.displayName(atPath: url.path)
        let finderName = finderDisplay.lowercased().hasSuffix(".app") ? String(finderDisplay.dropLast(4)) : finderDisplay
        func names(_ info: [String: Any]?) -> [String] {
            ["CFBundleDisplayName", "CFBundleName"].compactMap { key in
                guard let value = info?[key] as? String else { return nil }
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty || clean == key ? nil : clean
            }
        }
        var chinese: [String] = []
        var localized: [String] = []
        let priorities = ["zh-hans", "zh_cn", "zh-cn", "zh", "zh-hant", "zh_tw", "zh-tw", "zh_hk", "zh-hk"]
        func languageOrder(_ a: String, _ b: String) -> Bool {
            let ar = priorities.firstIndex(of: a.lowercased()) ?? 99
            let br = priorities.firstIndex(of: b.lowercased()) ?? 99
            return ar == br ? a < b : ar < br
        }
        if let resources = bundle?.resourceURL,
           let data = try? Data(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")),
           let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String: Any]] {
            for language in table.keys.sorted(by: languageOrder) {
                guard language.lowercased().hasPrefix("zh") || language.lowercased().hasPrefix("en") else { continue }
                let values = names(table[language])
                localized += values
                if language.lowercased().hasPrefix("zh") { chinese += values.filter(hasChinese) }
            }
        }
        if let resources = bundle?.resourceURL,
           let directories = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
            let languages = directories.filter { $0.pathExtension == "lproj" }.sorted {
                let a = $0.deletingPathExtension().lastPathComponent.lowercased()
                let b = $1.deletingPathExtension().lastPathComponent.lowercased()
                return languageOrder(a, b)
            }
            for directory in languages {
                let language = directory.deletingPathExtension().lastPathComponent.lowercased()
                guard language.hasPrefix("zh") || language.hasPrefix("en") else { continue }
                let file = directory.appendingPathComponent("InfoPlist.strings")
                guard let data = try? Data(contentsOf: file),
                      let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                let values = names(info)
                localized += values
                if language.hasPrefix("zh") { chinese += values.filter(hasChinese) }
            }
        }
        let candidates = names(bundle?.localizedInfoDictionary) + [finderName] + names(bundle?.infoDictionary) + [original]
        let display = chinese.first ?? candidates.first(where: hasChinese) ?? candidates.first ?? original
        let aliases = Array(Set(chinese + localized + candidates + [display, original])).sorted()
        return Self(displayName: display, aliases: aliases)
    }

    private static func hasChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) }
    }
}
