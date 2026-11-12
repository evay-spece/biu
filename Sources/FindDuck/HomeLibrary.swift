import Foundation
import AppKit
import Combine

enum HomeKind:String,Codable,Sendable {case application,website,folder,file,action}
enum HomeAction:String,CaseIterable,Codable,Sendable,Identifiable {
    case downloads="今天下载的文件",wechat="今天微信收发的文件",recent="最近打开文件",desktop="桌面",settings="设置"
    var id:String {rawValue}
    var symbol:String {switch self {case .downloads:"arrow.down.circle";case .wechat:"bubble.left.and.bubble.right";case .recent:"clock";case .desktop:"desktopcomputer";case .settings:"gearshape"}}
}
struct HomeShortcut:Codable,Identifiable,Equatable,Sendable {
    var id=UUID()
    var title:String
    var kind:HomeKind
    var target:String
    var customTitle:Bool? = nil
    static let recentAppsTarget="biu:recent-apps"
    static let applicationsTarget="biu:applications"
    var isLauncher:Bool {kind == .action && [Self.recentAppsTarget,Self.applicationsTarget].contains(target)}
    var group:Int {if isLauncher {return 0};return switch kind {case .application:0;case .website:1;case .folder,.file:3;case .action:2}}
}
@MainActor final class HomeLibrary:ObservableObject {
    private struct Settings:Codable {var items:[HomeShortcut];var resumeWindowSeconds:Double?;var builtinLaunchersAdded:Bool?}
    @Published private(set) var items:[HomeShortcut]=[]
    @Published var resumeWindowSeconds:Double=120 {didSet {save()}}
    @Published private(set) var error=""
    private let storage:URL
    private let history:UserActionHistory
    init(storage:URL?=nil,seedDefaults:Bool=true,history:UserActionHistory?=nil) {
        self.history=history ?? .shared
        self.storage=storage ?? BiuStorage.directory.appendingPathComponent("home-shortcuts.json")
        if let data=try? Data(contentsOf:self.storage),let settings=try? JSONDecoder().decode(Settings.self,from:data) {items=settings.items;resumeWindowSeconds=settings.resumeWindowSeconds ?? 120
            if seedDefaults && settings.builtinLaunchersAdded != true {addBuiltinLaunchers();save()}
            let normalized=items.filter {$0.target != HomeShortcut.recentAppsTarget}.map {item in
                var item=item;if item.target == HomeShortcut.applicationsTarget {item.title="所有程序"};return normalizedApplication(item)
            }
            if normalized != items {items=normalized;save()}
        }
        else if seedDefaults {
            for (bundle,name) in [("com.apple.finder","访达"),("com.tencent.xinWeChat","微信"),("com.microsoft.Excel","Excel"),("com.microsoft.edgemac","Edge"),("com.apple.Notes","备忘录"),("com.apple.Safari","Safari")] {
                if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) {items.append(HomeShortcut(title:name,kind:.application,target:url.path,customTitle:false))}
            }
            for (title,address) in [("百度","https://www.baidu.com/"),("京东","https://www.jd.com/"),("天猫","https://www.tmall.com/")] {items.append(HomeShortcut(title:title,kind:.website,target:address))}
            for action in [HomeAction.downloads,.wechat,.recent,.settings] {items.append(HomeShortcut(title:action.rawValue,kind:.action,target:action.rawValue))}
            addBuiltinLaunchers();items=items.map(normalizedApplication);save()
        }
    }
    private func normalizedApplication(_ item:HomeShortcut)->HomeShortcut {
        let url=URL(fileURLWithPath:item.target)
        guard item.kind == .application || ([HomeKind.file,.folder].contains(item.kind) && OilQueryEngine.isLaunchableApplication(url)) else {return item}
        var result=item;result.kind = .application
        let names=ApplicationNames.read(url)
        func withoutExtension(_ name:String)->String {name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name}
        let generated=names.aliases.contains {SearchText.fold(withoutExtension($0)) == SearchText.fold(withoutExtension(item.title))}
        if item.customTitle == false || (item.customTitle == nil && generated) {
            result.title=withoutExtension(names.displayName);result.customTitle=false
        }
        return result
    }
    private func addBuiltinLaunchers() {
        for (title,target) in [("所有程序",HomeShortcut.applicationsTarget)] {
            if !items.contains(where:{$0.target == target}) {items.append(HomeShortcut(title:title,kind:.action,target:target))}
        }
    }
    nonisolated static func shouldShowHome(elapsed:TimeInterval?,resumeWindow:TimeInterval)->Bool {elapsed == nil || elapsed! > resumeWindow}
    nonisolated static func websiteURL(_ input:String)->URL? {
        let raw=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !raw.isEmpty else {return nil}
        let address=raw.contains("://") ? raw : "https://"+raw
        guard let url=URL(string:address),["https","http"].contains(url.scheme?.lowercased() ?? ""),let host=url.host,!host.isEmpty,url.user == nil,url.password == nil else {return nil}
        return url
    }
    @discardableResult func add(title:String,kind:HomeKind,target:String)->Bool {
        var value=target
        if kind == .website {
            guard let url=Self.websiteURL(target) else {error="请输入有效的 http 或 https 网址，不包含账户密码。";return false};value=url.absoluteString
        }
        let title=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else {error="请填写入口名称。";return false}
        var item=HomeShortcut(title:title,kind:kind,target:value)
        if kind == .application || ([HomeKind.file,.folder].contains(kind) && OilQueryEngine.isLaunchableApplication(URL(fileURLWithPath:value))) {item.customTitle=false}
        item=normalizedApplication(item)
        guard !items.contains(where:{$0.kind == item.kind && $0.target == value}) else {error="这个入口已经在主页中。";return false}
        items.append(item);error="";save()
        let id=item.id
        history.record("添加首页入口") { [weak self] in guard let self else {return false};self.items.removeAll {$0.id == id};self.save();return self.error.isEmpty }
        return true
    }
    @discardableResult func pin(_ url:URL)->Bool {
        guard url.isFileURL else {error="只能固定本机或已挂载磁盘的文件。";return false}
        let value=url.standardizedFileURL
        guard let resources=try? value.resourceValues(forKeys:[.isDirectoryKey,.isApplicationKey]) else {error="无法读取此文件。";return false}
        let kind:HomeKind=resources.isApplication == true ? .application : resources.isDirectory == true ? .folder : .file
        return add(title:value.lastPathComponent,kind:kind,target:value.path)
    }
    func remove(_ item:HomeShortcut) {items.removeAll {$0.id == item.id};save()}
    func rename(_ item:HomeShortcut,title:String) {
        guard let index=items.firstIndex(where:{$0.id == item.id}),!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        items[index].title=title.trimmingCharacters(in:.whitespacesAndNewlines);items[index].customTitle=true;save()
    }
    func move(_ item:HomeShortcut,by delta:Int) {
        let peers=items.indices.filter {items[$0].group == item.group}
        guard let position=peers.firstIndex(where:{items[$0].id == item.id}),peers.indices.contains(position+delta) else {return}
        items.swapAt(peers[position],peers[position+delta]);save()
    }
    func move(id:UUID,to target:HomeShortcut) {
        guard let from=items.firstIndex(where:{$0.id == id}),let to=items.firstIndex(where:{$0.id == target.id}),from != to,items[from].group == target.group else {return}
        let item=items.remove(at:from);items.insert(item,at:to);save()
    }
    func reorder(group:Int,ids:[UUID]) {
        let peers=items.filter {$0.group == group}
        guard ids.count == peers.count,Set(ids) == Set(peers.map(\.id)),ids != peers.map(\.id) else {return}
        let lookup=Dictionary(uniqueKeysWithValues:peers.map {($0.id,$0)})
        var iterator=ids.makeIterator()
        items=items.map {item in item.group == group ? lookup[iterator.next()!]! : item};save()
    }
    private func save() {
        do {try FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(Settings(items:items,resumeWindowSeconds:resumeWindowSeconds,builtinLaunchersAdded:true)).write(to:storage,options:.atomic)} catch {self.error="主页设置保存失败：\(error.localizedDescription)"}
    }
}
