import Foundation
import OilFindCore

enum SearchText {
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "。", with: ".").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).precomposedStringWithCanonicalMapping
    }
    static func contains(_ text: String, _ term: String) -> Bool { fold(text).contains(fold(term)) }
    static func query(_ term: String, store: IndexStore) -> Query {
        var query = Query.parse(term, store: store)
        for c in query.clauses.indices {
            for a in query.clauses[c].alternatives.indices {
                if case .name(let needle, let sensitive) = query.clauses[c].alternatives[a].matcher {
                    let text = String(decoding: needle, as: UTF8.self)
                    if text.contains(".") || text.contains("。") {
                        let pattern = text.map { ($0 == "." || $0 == "。") ? "[.。]" : NSRegularExpression.escapedPattern(for: String($0)) }.joined()
                        if let regex = try? NSRegularExpression(pattern: pattern, options: sensitive ? [] : [.caseInsensitive]) {
                            query.clauses[c].alternatives[a].matcher = .regex(regex, onPath: false)
                        }
                    }
                }
            }
        }
        return query
    }
}
