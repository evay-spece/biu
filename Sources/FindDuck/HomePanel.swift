import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomePanel:View {
    @ObservedObject var home:HomeLibrary
    @ObservedObject var model:SearchLibrary
    @ObservedObject var hotKeys:HotKeyManager
    @ObservedObject var recentApps:RecentAppLibrary
    @ObservedObject var clipboard:ClipboardHistoryStore
    @State private var tool:HomeTool?
    @State private var showRecentApps=false
    @State private var hoveredRecentApp:String?
    @State private var isFileDropTargeted=false
    @StateObject private var badges=DockBadgeStore()
    @StateObject private var reorder=HomeReorderState()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reorderAnimation:Animation? {reduceMotion ? nil : .easeInOut(duration:0.18)}
    private let columns=[GridItem(.adaptive(minimum:135,maximum:175),spacing:12)]
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Spacer()
                    Menu {
                        Button("添加软件…") {choose(.application)}
                        Button("添加网站…") {addWebsite()}
                        Button("添加文件或文件夹…") {choose(.file)}
                        Button("添加功能…") {addAction()}
                    } label: {Label("添加入口",systemImage:"plus")}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("添加主页入口")
                }
                HStack(spacing:12) {
                    Button {openWindow(id:"quick-text")} label: {Label("常用文本",systemImage:"text.quote")}
                    Button {openWindow(id:"clipboard")} label: {Label("剪贴板历史",systemImage:"doc.on.clipboard")}
                    Button {tool = .rates} label: {Label("人民币汇率",systemImage:"yensign.arrow.circlepath")}
                    Button {tool = .world} label: {Label("世界时间",systemImage:"globe")}
                }.buttonStyle(.bordered)
                if !badges.trusted {Button {badges.requestPermission()} label: {Label("开启辅助功能权限以显示软件通知角标",systemImage:"bell.badge")}.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)}
                section("常用软件",group:0)
                section("常用文件",group:3)
                section("常用网站",group:1)
                section("快捷功能",group:2)
                if !home.error.isEmpty {Text(home.error).font(.caption).foregroundStyle(.secondary)}
            }.padding(.horizontal,20).padding(.vertical,10)
        }.accessibilityLabel("Biu主页").sheet(item:$tool) {tool in QuickToolsPanel(tool:tool)}.task {await badges.watch()}
    }
    private var recentApplicationsList:some View {
        let entries=recentApps.visible(excluding:home.items)
        return VStack(alignment:.leading,spacing:12) {
                    Text("最近打开 App").font(.headline)
                    if entries.isEmpty {Text("打开软件后会显示在这里，已固定的软件不重复显示。").font(.caption).foregroundStyle(.secondary).padding(.vertical,12)}
                    ForEach(entries) {entry in
                        HStack(spacing:10) {
                            Button {showRecentApps=false;launch(HomeShortcut(title:entry.name,kind:.application,target:entry.path))} label: {
                                HStack(spacing:10) {HomeApplicationIcon(path:entry.path,size:28);Text(entry.name).font(.system(size:13)).lineLimit(1);Spacer()}.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(entry.path).accessibilityLabel("打开最近App："+entry.name)
                                .padding(5).background(hoveredRecentApp == entry.path ? FindDuckHighlight.soft : .clear,in:RoundedRectangle(cornerRadius:8))
                                .onHover {hoveredRecentApp=$0 ? entry.path : nil}
                            Button {_=home.add(title:entry.name,kind:.application,target:entry.path)} label: {Image(systemName:"plus.circle")}.buttonStyle(.plain).foregroundStyle(.secondary).help("固定到常用软件").accessibilityLabel("固定到常用软件："+entry.name)
                        }.padding(.vertical,3)
                    }
                }.padding(16).frame(width:290).onExitCommand {showRecentApps=false}
    }
    @ViewBuilder private func section(_ title:String,group:Int)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
            let entries=reorder.entries(home.items,group:group)
            if entries.isEmpty && group != 0 {
                HStack {Text(group == 1 ? "把常用网站放在这里" : "添加你常用的入口").font(.system(size:12)).foregroundStyle(.tertiary);Spacer();Button(group == 1 ? "添加网站" : "添加入口") {if group == 1 {addWebsite()} else {choose(group == 0 ? .application : .folder)}}.buttonStyle(.plain).font(.system(size:12)).foregroundStyle(Color.accentColor)}
                    .padding(14).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            } else {
                LazyVGrid(columns:group == 0 ? [GridItem(.adaptive(minimum:78,maximum:100),spacing:14,alignment:.top)] : columns,alignment:.leading,spacing:12) {
                    ForEach(entries) {item in
                        HomeTile(item:item,tags:model.tags(FileHit(url:URL(fileURLWithPath:item.target))),note:model.preferences.fileNotes?[item.target],badge:item.kind == .application ? badges.badge(for:item.target) : nil,isDragging:reorder.draggedID == item.id,action:{launch(item)},menu:{itemMenu(item)},accept:{id in reorder.accepts(id,group:item.group)},drop:{_ in withAnimation(reorderAnimation) {reorder.commit(to:home)}},frameChanged:{reorder.record(item.id,provider:$0)},dragBegan:{reorder.begin(item.id,items:home.items)},dragMoved:{point in withAnimation(reorderAnimation) {reorder.update(point)}},dragEnded:{withAnimation(reorderAnimation) {reorder.end()}})
                            .popover(isPresented:Binding(get:{item.target == HomeShortcut.recentAppsTarget && showRecentApps},set:{showRecentApps=$0}),arrowEdge:.bottom) {recentApplicationsList}
                    }

                }.animation(reorderAnimation,value:entries.map(\.id))
            }
        }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:group == 3 ? $isFileDropTargeted : nil) {providers in
            guard group == 3,!providers.isEmpty else {return false}
            for provider in providers {
                _=provider.loadObject(ofClass:NSURL.self) {object,_ in
                    guard let url=object as? URL,url.isFileURL else {return}
                    Task { @MainActor in _=home.pin(url) }
                }
            }
            return true
        }
        .overlay {if group == 3 && isFileDropTargeted {
            RoundedRectangle(cornerRadius:12).fill(Color.accentColor.opacity(0.16))
                .overlay {Label("松开以添加到常用文件",systemImage:"plus.circle.fill").font(.headline).padding(12).background(.regularMaterial,in:Capsule())}
                .allowsHitTesting(false)
        }}
    }
    private func launch(_ item:HomeShortcut) {
        if item.isLauncher {
            if item.target == HomeShortcut.recentAppsTarget {showRecentApps.toggle()}
            else {model.category = .all;model.resultSort = .relevance;model.pinnedApplications=Set(home.items.filter {$0.kind == .application}.map(\.target));model.recentApplications=Dictionary(recentApps.items.map {($0.path,$0.openedAt)},uniquingKeysWith:max);model.activateDirectory(URL(fileURLWithPath:"/Applications"));hotKeys.focusSearchInput()}
            return
        }
        if item.kind == .action {
            guard let action=HomeAction(rawValue:item.target) else {return}
            switch action {
            case .downloads:model.activateQuick(.downloads)
            case .wechat:model.activateQuick(.wechat)
            case .recent:model.activateQuick(.recent)
            case .settings:hotKeys.openSettings?()
            case .desktop:model.activateDirectory(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
            }
            if action != .settings {hotKeys.focusSearchInput()};return
        }
        let url=item.kind == .website ? HomeLibrary.websiteURL(item.target) : URL(fileURLWithPath:item.target)
        guard let url else {return}
        if NSWorkspace.shared.open(url) {hotKeys.hideSearch()} else {model.status="无法打开："+item.title}
    }
    private func choose(_ kind:HomeKind) {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=kind != .application;panel.canChooseFiles=kind != .folder
        panel.treatsFilePackagesAsDirectories=false;panel.prompt="添加到主页"
        if kind == .application {panel.directoryURL=URL(fileURLWithPath:"/Applications");panel.allowedContentTypes=[.applicationBundle]}
        if panel.runModal() == .OK,let url=panel.url {if kind == .file {_=home.pin(url)} else {_=home.add(title:kind == .application ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,kind:kind,target:url.path)}}
    }
    private func addWebsite() {
        let alert=NSAlert();alert.messageText="添加常用网站";alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
        let name=NSTextField(frame:NSRect(x:0,y:44,width:330,height:24));name.placeholderString="网站名称";name.setAccessibilityLabel("网站名称")
        let url=NSTextField(frame:NSRect(x:0,y:8,width:330,height:24));url.placeholderString="https://";url.setAccessibilityLabel("网站网址")
        let view=NSView(frame:NSRect(x:0,y:0,width:330,height:76));view.addSubview(name);view.addSubview(url);name.nextKeyView=url;alert.accessoryView=view;alert.window.initialFirstResponder=name
        if alert.runModal() == .alertFirstButtonReturn {_=home.add(title:name.stringValue.isEmpty ? (HomeLibrary.websiteURL(url.stringValue)?.host ?? "网站") : name.stringValue,kind:.website,target:url.stringValue)}
    }
    private func addAction() {
        let alert=NSAlert();alert.messageText="添加快捷功能";alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:300,height:28));picker.addItems(withTitles:HomeAction.allCases.map(\.rawValue));alert.accessoryView=picker
        if alert.runModal() == .alertFirstButtonReturn,let title=picker.titleOfSelectedItem {_=home.add(title:title,kind:.action,target:title)}
    }
    private func itemMenu(_ item:HomeShortcut)->NSMenu {
        let menu=NSMenu()
        menu.addItem(ResultMenus.item("打开") {launch(item)})
        menu.addItem(ResultMenus.item("重命名…") {rename(item)})
        menu.addItem(ResultMenus.item("前移") {home.move(item,by:-1)})
        menu.addItem(ResultMenus.item("后移") {home.move(item,by:1)})
        menu.addItem(.separator());menu.addItem(ResultMenus.item("移除主页入口") {home.remove(item)})
        return menu
    }
    private func rename(_ item:HomeShortcut) {
        let alert=NSAlert();alert.messageText="重命名主页入口";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:26));field.stringValue=item.title;alert.accessoryView=field;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {home.rename(item,title:field.stringValue)}
    }
}
private typealias HomeState<Value> = SwiftUI.State<Value>
private struct HomeTile:View {
    let item:HomeShortcut
    let tags:[FileTag]
    let note:String?
    let badge:String?
    let isDragging:Bool
    let action:()->Void
    let menu:()->NSMenu
    let accept:(UUID)->Bool
    let drop:(UUID)->Void
    let frameChanged:(@escaping ()->CGRect?)->Void
    let dragBegan:()->Void
    let dragMoved:(CGPoint)->Void
    let dragEnded:()->Void
    @HomeState private var hovering=false
    private var dragImage:NSImage {
        if item.kind == .application {return HomeCalendarIcon.applicationIcon(item.target)}
        if item.isLauncher {return HomeLauncherIcon.image(item.target)}
        if item.kind == .folder || item.kind == .file {return FileIcons.shared.icon(for:FileHit(url:URL(fileURLWithPath:item.target),isDirectory:item.kind == .folder))}
        return NSImage(systemSymbolName:item.kind == .website ? "globe" : HomeAction(rawValue:item.target)?.symbol ?? "bolt",accessibilityDescription:nil) ?? NSImage()
    }
    var body:some View {
        Group {
            if item.group == 0 {
                VStack(spacing:6) {
                    if item.isLauncher {
                        Image(nsImage:HomeLauncherIcon.image(item.target)).resizable().scaledToFit().frame(width:50,height:50)
                    } else {
                    HomeApplicationIcon(path:item.target,size:50)
                        .overlay(alignment:.topTrailing) {if let badge {Text(badge).font(.system(size:10,weight:.semibold)).foregroundStyle(.white).padding(.horizontal,4).frame(minWidth:17,minHeight:17).background(.red,in:Capsule()).offset(x:6,y:-3).accessibilityLabel("通知数量："+badge)}}
                                        }
                    Text(item.title).font(.system(size:12)).lineLimit(nil)
                        .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.top)
                }.padding(8).frame(maxWidth:.infinity,minHeight:88,alignment:.top).background(Color.primary.opacity(hovering ? 0.065 : 0),in:RoundedRectangle(cornerRadius:12))
            } else {
                HStack(spacing:10) {
                    if item.kind == .folder || item.kind == .file {Image(nsImage:FileIcons.shared.icon(for:FileHit(url:URL(fileURLWithPath:item.target),isDirectory:item.kind == .folder))).resizable().scaledToFit().frame(width:30,height:30)}
                    else {Image(systemName:item.kind == .website ? "globe" : HomeAction(rawValue:item.target)?.symbol ?? "bolt").font(.system(size:22)).foregroundStyle(Color.accentColor).frame(width:30,height:30)}
                    VStack(alignment:.leading,spacing:5) {Text(item.title).font(.system(size:12,weight:.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        if item.group == 3 {HStack(spacing:4) {ForEach(tags) {tag in TagBadge(tag:tag)};if let note,!note.isEmpty {TagBadge(tag:FileTag(id:"note",name:note,color:.gray))}}}
                    };Spacer(minLength:0)
                }.padding(12).frame(maxWidth:.infinity,minHeight:56).background(Color.primary.opacity(hovering ? 0.075 : 0.035),in:RoundedRectangle(cornerRadius:12))
            }
        }.opacity(isDragging ? 0.2 : 1).accessibilityHidden(true)
            .overlay {GeometryReader {geometry in
                HomeItemInteraction(id:item.id,title:item.title,help:item.kind == .action ? item.title : item.target,dragImage:dragImage,dragSize:item.group == 0 ? 50 : 30,action:action,hover:{hovering=$0},menu:menu,accept:accept,drop:drop,frameChanged:frameChanged,dragBegan:dragBegan,dragMoved:dragMoved,dragEnded:dragEnded)
                    .frame(width:geometry.size.width,height:geometry.size.height)
            }}
    }
}
