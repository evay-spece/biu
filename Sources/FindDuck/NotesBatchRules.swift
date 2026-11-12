import AppKit
import Foundation

enum CurrencySearchQuery {
    static func parse(_ raw:String)->(amount:Decimal,from:String,to:String)? {
        let input=raw.uppercased().filter {!$0.isWhitespace}
        for (alias,code) in [("人民币","CNY"),("美元","USD"),("RMB","CNY"),("CNY","CNY"),("USD","USD")] {
            let number:String
            if input.hasPrefix(alias) {number=String(input.dropFirst(alias.count))}
            else if input.hasSuffix(alias) {number=String(input.dropLast(alias.count))}
            else {continue}
            guard !number.isEmpty,let amount=CurrencyMath.amount(number) else {return nil}
            return (amount,code,code == "USD" ? "CNY" : "USD")
        }
        return nil
    }
}
enum QuickTextSearch {
    static func matches(_ items:[QuickText],query:String)->[QuickText] {
        let terms=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        guard !terms.isEmpty else {return []}
        return Array(items.filter {item in terms.allSatisfy {item.title.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) != nil}}.prefix(5))
    }
}
@MainActor enum ResultFileCopy {
    static func copy(_ files:[FileHit],to board:NSPasteboard = .general)->Bool {
        guard !files.isEmpty else {return false}
        board.clearContents()
        return board.writeObjects(files.map {$0.url as NSURL})
    }
}
