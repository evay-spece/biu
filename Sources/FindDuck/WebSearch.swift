import Foundation

enum WebSearch: String, CaseIterable, Identifiable {
    case baidu = "百度"
    case xiaohongshu = "小红书"
    case taobao = "淘宝"
    var id: String { rawValue }

    func url(for query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let address: String
        let parameter: String
        switch self {
        case .baidu: address = "https://www.baidu.com/s"; parameter = "wd"
        case .xiaohongshu: address = "https://www.xiaohongshu.com/search_result"; parameter = "keyword"
        case .taobao: address = "https://s.taobao.com/search"; parameter = "q"
        }
        var components = URLComponents(string: address)
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        if self == .xiaohongshu {
            components?.queryItems?.append(URLQueryItem(name: "source", value: "web_search_result_notes"))
        }
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }
}
