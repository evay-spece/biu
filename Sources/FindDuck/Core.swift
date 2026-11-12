import Foundation

struct FileHit: Identifiable, Codable, Hashable, Sendable {
    let url: URL
    var modified: Date?
    var created: Date?
    var added: Date?
    var isDirectory: Bool = false
    var applicationNames: ApplicationNames? = nil
    init(url: URL, isDirectory: Bool = false, modified: Date? = nil, created: Date? = nil, added: Date? = nil) { self.url = url; self.isDirectory = isDirectory; self.modified=modified;self.created=created;self.added=added }
    enum CodingKeys: String, CodingKey { case url, isDirectory, modified, created, added, applicationNames }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified)
        created = try values.decodeIfPresent(Date.self, forKey: .created)
        added = try values.decodeIfPresent(Date.self, forKey: .added)
        isDirectory = try values.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        applicationNames = try values.decodeIfPresent(ApplicationNames.self, forKey: .applicationNames)
    }
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var applicationDisplayName: String { applicationNames?.displayName ?? url.deletingPathExtension().lastPathComponent }
}
struct DirectoryRecord: Codable, Sendable {
    let url: URL
    var checked: Date?
    var due: Date
    var hotUntil: Date?
    var modified: Date? = nil
}
struct NameIndex: Codable, Sendable {
    let root: URL
    let created: Date
    let files: [FileHit]
    // Optional so indexes produced by versions 0.3 / 0.4 remain readable.
    var directories: [DirectoryRecord]?
    var metadataVersion: Int? = nil
    var unreadablePaths: [String]? = nil
    var scanConfiguration: String? = nil
}
struct IndexFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ScanPolicy: Sendable {
    var excludedPaths: [URL] = []
    var localScope: LocalIndexScope? = nil
    var hotInterval: TimeInterval = 60
    var coldInterval: TimeInterval = 1800
    var hotLifetime: TimeInterval = 1800
    var retryInterval: TimeInterval = 60
    var fullScanPause: Duration = .milliseconds(20)
}
struct DirectoryListing: Sendable {
    let url: URL
    let files: [FileHit]
    let children: [URL]
    var modified: Date? = nil
}
struct ListingResult: Sendable {
    let url: URL
    let listing: DirectoryListing?
    let error: String?
}
struct IndexCatalog: Sendable {
    let root: URL
    var records: [String: DirectoryRecord]
    var files: [String: FileHit]
    var changed: Date
    var scanConfiguration: String?
    private var fileIDsByParent: [String: Set<String>] = [:]
    private var childIDsByParent: [String: Set<String>] = [:]
    init(_ index: NameIndex) {
        root = index.root
        records = Dictionary((index.directories ?? []).map { ($0.url.path, $0) }, uniquingKeysWith: { _, newer in newer })
        files = Dictionary(index.files.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        changed = index.created
        scanConfiguration = index.scanConfiguration
        for (id,file) in files {fileIDsByParent[file.url.deletingLastPathComponent().path,default:[]].insert(id)}
        for (id,record) in records where record.url != root {childIDsByParent[record.url.deletingLastPathComponent().path,default:[]].insert(id)}
    }
    var complete: Bool { !records.isEmpty && records.values.allSatisfy { $0.checked != nil } }
    func snapshot() -> NameIndex {
        NameIndex(root: root, created: changed,
                  files: files.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                  directories: records.values.sorted { $0.url.path < $1.url.path }, metadataVersion: 1, scanConfiguration: scanConfiguration)
    }
    func batch(now: Date, dirty: Set<String>, limit: Int) -> [URL] {
        let due = records.values.filter { $0.due <= now || dirty.contains($0.url.path) }
        let ordinary = due.sorted {
            let left = $0.checked ?? .distantPast, right = $1.checked ?? .distantPast
            return left == right ? $0.url.path < $1.url.path : left < right
        }
        let notified = due.filter { dirty.contains($0.url.path) }.sorted { $0.due < $1.due }
        // Reserve the first slot for the oldest unchecked directory: notification bursts
        // must not prevent cold / newly discovered directories from being reconciled.
        var result: [URL] = []
        if let first = ordinary.first { result.append(first.url) }
        for item in notified + ordinary where result.count < limit {
            if !result.contains(item.url) { result.append(item.url) }
        }
        return result
    }
    mutating func markAllDue(_ now: Date) {
        for key in Array(records.keys) { records[key]?.due = now }
    }
    mutating func retry(_ url: URL, now: Date, policy: ScanPolicy) {
        records[url.path]?.due = now.addingTimeInterval(policy.retryInterval)
    }
    @discardableResult mutating func apply(_ listing: DirectoryListing, now: Date, policy: ScanPolicy) -> Bool {
        guard records[listing.url.path] != nil else { return false }
        let oldIDs=fileIDsByParent[listing.url.path] ?? []
        let oldFiles=oldIDs.compactMap {files[$0]}
        let oldChildren=childIDsByParent[listing.url.path] ?? []
        let newChildren = Set(listing.children.map(\.path))
        let didChange = Set(oldFiles) != Set(listing.files) || oldChildren != newChildren
        for child in oldChildren.subtracting(newChildren) {
            var pending=[child]
            while let path=pending.popLast() {
                pending.append(contentsOf:childIDsByParent.removeValue(forKey:path) ?? [])
                for id in fileIDsByParent.removeValue(forKey:path) ?? [] {files.removeValue(forKey:id)}
                records.removeValue(forKey:path)
            }
        }
        for file in oldFiles { files.removeValue(forKey: file.id) }
        for file in listing.files { files[file.id] = file }
        fileIDsByParent[listing.url.path]=Set(listing.files.map(\.id))
        childIDsByParent[listing.url.path]=newChildren
        for child in listing.children where records[child.path] == nil {
            records[child.path] = DirectoryRecord(url: child, checked: nil, due: now, hotUntil: now.addingTimeInterval(policy.hotLifetime))
        }
        var record = records[listing.url.path]!
        record.checked = now
        record.modified = listing.modified
        if didChange { record.hotUntil = now.addingTimeInterval(policy.hotLifetime); changed = now }
        let hot = listing.url.path == root.path || (record.hotUntil ?? .distantPast) > now
        record.due = now.addingTimeInterval(hot ? policy.hotInterval : policy.coldInterval)
        records[listing.url.path] = record
        return didChange
    }
    func watchCandidates(limit: Int) -> [URL] {
        Array(records.values.sorted {
            if $0.url == root { return $1.url != root }
            if $1.url == root { return false }
            let left = $0.hotUntil ?? .distantPast, right = $1.hotUntil ?? .distantPast
            return left == right ? $0.url.path < $1.url.path : left > right
        }.prefix(limit).map(\.url))
    }
}

enum DirectoryReader {
    static func available(_ folder: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue && FileManager.default.isReadableFile(atPath: folder.path)
    }
    static func read(_ folder: URL, policy: ScanPolicy = ScanPolicy()) throws -> DirectoryListing {
        try Task<Never, Never>.checkCancellation()
        let exclusions = DuckExclusions(policy.excludedPaths)
        if exclusions.contains(folder) || policy.localScope?.excludes(folder,isDirectory:true) == true || policy.localScope?.stopsAtPackage(folder) == true { return DirectoryListing(url: folder, files: [], children: []) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var files: [FileHit] = [], directories: [URL] = []
        for url in children {
            if ["/System/Volumes", "/dev"].contains(url.path) || (url.path == "/Volumes" && folder.path == "/") { continue }
            if exclusions.contains(url) { continue }
            try Task<Never, Never>.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            // Never follow a link outside the selected search scope or create cycles.
            if values.isSymbolicLink == true { continue }
            let isDirectory=values.isDirectory == true
            if policy.localScope?.excludes(url,isDirectory:isDirectory) == true { continue }
            if isDirectory && policy.localScope?.stopsAtPackage(url) != true { directories.append(url) }
            else if isDirectory || values.isRegularFile == true {
                files.append(FileHit(url: url, modified: values.contentModificationDate, created: values.creationDate, added: values.addedToDirectoryDate))
            }
        }
        return DirectoryListing(url: folder, files: files, children: directories, modified: try? folder.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)
    }
    static func full(_ folder: URL, policy: ScanPolicy, progress: @Sendable (Int, Int) -> Void) async throws -> NameIndex {
        guard available(folder) else { throw IndexFailure(message: "共享文件夹不可用，请检查连接。") }
        var queue = [folder], position = 0
        var lastProgress = ContinuousClock.now - .seconds(1)
        var visited = Set<String>()
        var files: [FileHit] = [], records: [DirectoryRecord] = [], unreadable: [String] = []
        while position < queue.count {
            try Task<Never, Never>.checkCancellation()
            let directory = queue[position]; position += 1
            guard visited.insert(directory.path).inserted else { continue }
            let listing: DirectoryListing
            do { listing = try read(directory, policy: policy) }
            catch {
                if error is CancellationError { throw error }
                if directory == folder { throw error }
                unreadable.append(directory.path)
                records.append(DirectoryRecord(url:directory,checked:nil,due:Date().addingTimeInterval(policy.retryInterval),hotUntil:nil))
                continue
            }
            files.append(contentsOf: listing.files)
            queue.append(contentsOf: listing.children)
            let now = Date()
            records.append(DirectoryRecord(url: directory, checked: now, due: now.addingTimeInterval(directory == folder ? policy.hotInterval : policy.coldInterval), hotUntil: nil, modified: listing.modified))
            if ContinuousClock.now - lastProgress >= .milliseconds(200) {
                progress(files.count, records.count)
                lastProgress = .now
            }
            if policy.fullScanPause > .zero { try await Task.sleep(for: policy.fullScanPause) }
            else if position % 64 == 0 { await Task.yield() }
        }
        progress(files.count, records.count)
        guard available(folder) else { throw IndexFailure(message: "扫描时连接中断，未替换原索引。") }
        var result=IndexCatalog(NameIndex(root: folder, created: Date(), files: files, directories: records)).snapshot()
        result.unreadablePaths=unreadable
        result.scanConfiguration=policy.localScope?.fingerprint
        return result
    }
}
