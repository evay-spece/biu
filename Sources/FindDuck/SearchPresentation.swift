import Foundation

enum ResultCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "全部", folders = "文件夹", pdf = "PDF", images = "图片", video = "视频", spreadsheets = "表格", slides = "PPT", word = "Word", archives = "压缩包"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "doc"
        case .folders: "folder.fill"
        case .pdf: "doc.text"
        case .images: "photo"
        case .video: "film"
        case .spreadsheets: "tablecells"
        case .slides: "rectangle.on.rectangle"
        case .word: "doc.richtext"
        case .archives: "archivebox"
        }
    }
    static func kind(of file: FileHit) -> ResultCategory {
        if file.isDirectory { return .folders }
        if WechatLocations.isOpaqueImage(file.url) { return .images }
        switch file.url.pathExtension.lowercased() {
        case "xls", "xlsx", "xlsm", "csv", "tsv", "numbers": return .spreadsheets
        case "ppt", "pptx", "key": return .slides
        case "doc", "docx", "pages": return .word
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg", "psd", "ai": return .images
        case "mp4", "mov", "mkv", "avi", "m4v", "wmv", "webm", "flv": return .video
        case "mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg": return .all
        case "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "json", "yaml", "yml", "sh", "sql", "c", "cpp", "h", "go", "rs", "java": return .all
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": return .archives
        default: return .all
        }
    }
}
enum ResultSort: String, CaseIterable, Identifiable, Sendable {
    case relevance = "相关度", name = "名称", modified = "修改时间", recent = "最近打开"
    var id: String { rawValue }
}
enum SearchPresentation {
    static func folderHits(index: NameIndex) -> [FileHit] {
        if let directories = index.directories, !directories.isEmpty {
            return directories.filter { $0.url.path != index.root.path }.map { FileHit(url: $0.url, isDirectory: true, modified: $0.modified) }
        }
        var paths = Set<URL>()
        for file in index.files {
            var parent = file.url.deletingLastPathComponent()
            while parent.path != index.root.path && parent.path.hasPrefix(index.root.path + "/") {
                if !paths.insert(parent).inserted { break }
                parent = parent.deletingLastPathComponent()
            }
        }
        return paths.map { FileHit(url: $0, isDirectory: true) }
    }
    static func matches(index: NameIndex, term: String, category: ResultCategory, sort: ResultSort, folders: [FileHit]? = nil) -> [FileHit] {
        let directories = (category == .folders || category == .all) ? (folders ?? folderHits(index: index)) : []
        var matches: [FileHit] = []
        let source = category == .folders ? directories : category == .all ? index.files + directories : index.files
        for file in source {
            if Task<Never, Never>.isCancelled { return [] }
            if (category == .all || ResultCategory.kind(of: file) == category) && (term.isEmpty || SearchText.contains(file.name,term)) { matches.append(file) }
        }
        func score(_ file: FileHit) -> Int {
            let name = file.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return name == key ? 0 : name.hasPrefix(key) ? 1 : 2
        }
        return matches.sorted {
            if sort == .modified, $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            if sort == .relevance {
                let a = score($0), b = score($1)
                if a != b { return a < b }
            }
            let compare = $0.name.localizedStandardCompare($1.name)
            return compare == .orderedSame ? $0.id < $1.id : compare == .orderedAscending
        }
    }
}
