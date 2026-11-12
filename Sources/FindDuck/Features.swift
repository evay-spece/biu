import AppKit
import SwiftUI

struct DuckPreferences: Codable {
 var calculatorEnabled: Bool? = nil
 var linkCleanerEnabled: Bool? = nil
 var idToLinkEnabled: Bool? = nil
 var productLinksEnabled: Bool? = nil
 var productLinksOn: Bool { productLinksEnabled ?? ((linkCleanerEnabled ?? true) || (idToLinkEnabled ?? true)) }
 var calculatorOn: Bool { calculatorEnabled ?? true }
 var linkCleanerOn: Bool { productLinksOn }
 var idToLinkOn: Bool { productLinksOn }
 var blacklist: [URL] = []
 var blacklistDefaultsVersion: Int? = nil
 var developerBlacklist: [URL]? = nil
 var effectiveBlacklist: [URL] { Array(Set(blacklist + (developerBlacklist ?? []))) }
 var localIndexOptions: LocalIndexOptions? = nil
 var suppressNoise = true
 var hiddenExtensions:[String]? = nil
 static let normalHiddenExtensions:[String] = ["log","tmp","cache","db","sqlite","sqlite3","lock","plist","dylib","so","o","pyc","class"]
 var effectiveHiddenExtensions:Set<String> {Set(hiddenExtensions ?? Self.normalHiddenExtensions)}
 func hidesExtension(_ url:URL)->Bool {suppressNoise && effectiveHiddenExtensions.contains(url.pathExtension.lowercased())}
 var recentOpened: [String: Date] = [:]
 var colorMarks: [String:FileMarkColor]? = nil // Legacy single-color storage, migrated on load.
 var customTags: [FileTag]? = nil
 var fileTags: [String:Set<String>]? = nil
 var fileNotes: [String:String]? = nil
 var blockedFiles: Set<String>? = nil
 var tagFilter: String? = nil
 var tagFilters:[String]? = nil
 var selectedTagIDs:[String] {if let tagFilters,!tagFilters.isEmpty {return tagFilters};return tagFilter.map {[$0]} ?? []}
 func annotated(_ path:String)->Bool { !(fileTags?[path] ?? []).isEmpty || !(fileNotes?[path] ?? "").isEmpty }
 func acceptsTag(_ path:String)->Bool {let selected=selectedTagIDs;guard !selected.isEmpty else {return true};return selected.contains("*") ? annotated(path) : !(fileTags?[path] ?? []).isDisjoint(with:selected) || (fileNotes?[path].map { selected.contains(FileTag.noteID($0)) } ?? false)}
 func annotationText(_ path:String)->String { let ids=fileTags?[path] ?? [];return (FileTag.defaults+(customTags ?? [])).filter {ids.contains($0.id)}.map(\.displayName).joined(separator:" ")+" "+(fileNotes?[path] ?? "") }
 var annotatedPaths:Set<String> {Set((fileTags ?? [:]).filter {!$0.value.isEmpty}.keys).union((fileNotes ?? [:]).filter {!$0.value.isEmpty}.keys)}
 mutating func migrateColorTags()->Bool {
  guard let legacy=colorMarks else {return false}
  var memberships=fileTags ?? [:]
  for (path,color) in legacy {memberships[path,default:[]].insert(FileTag.builtin(color).id)}
  fileTags=memberships;colorMarks=nil;return true
 }
 var wechatFolder: URL?
 mutating func installDefaultBlacklist() -> Bool {
  if developerBlacklist != nil {
   guard (blacklistDefaultsVersion ?? 0) < 3 else { return false }
   if let position=developerBlacklist?.firstIndex(where: { $0.standardizedFileURL.path == "/System" }) {
    developerBlacklist?[position]=URL(fileURLWithPath:"/System/Volumes",isDirectory:true)
   }
   blacklistDefaultsVersion=3
   return true
  }
  let defaults=DuckDefaults.blacklist()
  let paths=Set(defaults.map { $0.standardizedFileURL.path } + ["/System"])
  developerBlacklist = blacklistDefaultsVersion == nil ? defaults : blacklist.filter { paths.contains($0.standardizedFileURL.path) }.map { $0.standardizedFileURL.path == "/System" ? URL(fileURLWithPath:"/System/Volumes",isDirectory:true) : $0 }
  blacklist.removeAll { paths.contains($0.standardizedFileURL.path) }
  blacklistDefaultsVersion = 3
  return true
 }
}
enum DuckDefaults {
 static func blacklist(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
  let system = ["/System/Volumes", "/private", "/usr", "/bin", "/sbin", "/dev", "/cores",
                "/Library/Caches", "/Library/Logs", "/Library/Updates", "/Library/Developer"]
  let user = ["Library/Caches", "Library/Logs", "Library/Saved Application State",
              "Library/HTTPStorages", "Library/WebKit", "Library/Cookies",
              "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator",
              "Library/Metadata/CoreSpotlight", "Library/Application Support/\(BiuStorage.identifier)",
              "Library/Application Support/\(BiuStorage.legacyIdentifier)",
              ".cache", ".npm", ".gradle/caches"]
  return system.map { URL(fileURLWithPath: $0, isDirectory: true) } + user.map { home.appendingPathComponent($0, isDirectory: true) }
 }
}
enum QuickScope: String, CaseIterable, Hashable, Sendable { case none = "全部文件", wechat = "今天微信文件", downloads = "今天下载", modified = "今天修改的文件", recent = "最近打开文件" }
struct DuckExclusions: Sendable {
 private let roots: [String]
 init(_ paths: [URL]) { roots=paths.map { $0.standardizedFileURL.path } }
 func contains(_ url: URL) -> Bool {
  guard !roots.isEmpty else { return false }
  let path=url.standardizedFileURL.path
  return roots.contains { root in path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
 }
}
enum DuckRules {
 static func under(_ url: URL, _ root: URL) -> Bool { let a=url.standardizedFileURL.path,b=root.standardizedFileURL.path;return a == b || a.hasPrefix(b == "/" ? "/" : b + "/") }
 static func excluded(_ url: URL, paths: [URL]) -> Bool { DuckExclusions(paths).contains(url) }
 static func suspicious(_ file: FileHit) -> Bool { suspicious(name:file.name,path:file.url.path) }
 static func suspicious(name:String,path:String) -> Bool {
  if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
  if !path.hasPrefix("/System/Applications/"), ["/System/","/private/var/","/usr/","/bin/","/sbin/"].contains(where:path.hasPrefix) { return true }
  let name=(name as NSString).deletingPathExtension
  let bytes=Array(name.utf8)
  func hex(_ b:UInt8) -> Bool {(48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b)}
  if bytes.count >= 24 && bytes.allSatisfy(hex) { return true }
  if bytes.count == 36 && bytes.enumerated().allSatisfy({ [8,13,18,23].contains($0.offset) ? $0.element == 45 : hex($0.element) }) { return true }
  guard bytes.count >= 40 else { return false }
  var number=false,lower=false,upper=false
  for b in bytes {
   if (48...57).contains(b) {number=true}
   else if (97...122).contains(b) {lower=true}
   else if (65...90).contains(b) {upper=true}
   else if ![95,43,61,45].contains(b) {return false}
  }
  return number && lower && upper
 }
 static func today(_ file: FileHit, now:Date = Date()) -> Bool { guard let date=file.added ?? file.created else {return false};return Calendar.current.isDate(date,inSameDayAs:now) }
}
@MainActor final class SystemRecents {
 private var query:NSMetadataQuery?
 private var observer:NSObjectProtocol?
 private var token=UUID()
 private var completion: (([String:Date])->Void)?
 func load(scopes:[URL], completion:@escaping ([String:Date])->Void) {
  if let observer {NotificationCenter.default.removeObserver(observer)};query?.stop()
  self.completion=completion;let token=UUID();self.token=token
  let q=NSMetadataQuery();query=q;q.searchScopes=scopes.map(\.path)
  q.predicate=NSPredicate(format:"kMDItemLastUsedDate >= %@",Date(timeIntervalSince1970:0) as NSDate)
  observer=NotificationCenter.default.addObserver(forName:.NSMetadataQueryDidFinishGathering,object:q,queue:.main) { [weak self] _ in
   Task { @MainActor in
    guard let self,self.token == token,let q=self.query else {return};q.disableUpdates()
    var records:[String:Date]=[:]
    // Read bounded batches so system-history refresh does not freeze the search panel.
    for position in 0..<q.resultCount {
     if position % 100 == 0 {
      await Task.yield()
      guard self.token == token else { return }
     }
     guard let item=q.result(at:position) as? NSMetadataItem else { continue }
     if let path=item.value(forAttribute:"kMDItemPath") as? String,let date=item.value(forAttribute:"kMDItemLastUsedDate") as? Date {records[path]=date}
    }
    q.stop();self.completion?(records)
   }
  };q.start()
 }
}

enum DuckDeepSearch {
 static func run(roots:[URL],term:String,policy:ScanPolicy) -> ([FileHit],[String]) {
                var found:[FileHit]=[],errors:[String]=[]
                let exclusions=DuckExclusions(policy.excludedPaths)
                for root in roots {
                    guard DirectoryReader.available(root) else {errors.append(root.path);continue}
                    guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.contentModificationDateKey],options:[.skipsHiddenFiles],errorHandler:{url,_ in errors.append(url.path);return true}) else {errors.append(root.path);continue}
                    for case let url as URL in e {
                        if Task<Never,Never>.isCancelled {return(found,errors)}
                        if exclusions.contains(url) {e.skipDescendants();continue}
                        if SearchText.contains(url.lastPathComponent,term),let v=try? url.resourceValues(forKeys:[.isRegularFileKey,.contentModificationDateKey]),v.isRegularFile == true {found.append(FileHit(url:url,modified:v.contentModificationDate))}
                    }
                };return(found,errors)

 }
}

// App-only annotations: never write Finder tags or extended attributes.
enum FileMarkColor:String,Codable,CaseIterable,Sendable,Identifiable {
 case red="红色",orange="橙色",yellow="黄色",green="绿色",blue="蓝色",purple="紫色",gray="灰色"
 static let palette: [FileMarkColor] = [.red, .yellow, .green, .blue, .purple]
 var id:String {rawValue}
 var color:Color {switch self {case .red:.red;case .orange:.orange;case .yellow:.yellow;case .green:.green;case .blue:.blue;case .purple:.purple;case .gray:.gray}}
 func tagBackground(highlighted:Bool=false)->Color {let native=NSColor(color);return Color(nsColor:native.blended(withFraction:highlighted ? 0.68 : 0.80,of:.textBackgroundColor) ?? native)}
 var labelColor:Color {let native=NSColor(color);return Color(nsColor:native.blended(withFraction:0.30,of:.labelColor) ?? native)}
}

struct FileTag:Codable,Identifiable,Equatable,Sendable {
 var id:String
 var name:String
 var color:FileMarkColor
 static func builtin(_ color:FileMarkColor)->FileTag {FileTag(id:"color:"+String(describing:color),name:"",color:color)}
 static var defaults:[FileTag] {FileMarkColor.allCases.map(builtin)}
 static func noteID(_ text: String) -> String { "note:" + text }
 var displayName:String {name.isEmpty ? color.rawValue : name}
}
