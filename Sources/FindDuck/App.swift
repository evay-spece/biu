import SwiftUI
import AppKit
import Darwin

private typealias ViewState<Value> = SwiftUI.State<Value>

private enum QuickEntryVisibility {
    static let history = 1 << 0
    static let wechat = 1 << 1
    static let downloads = 1 << 2
    static let modified = 1 << 3
    static let recent = 1 << 4
    static let shared = 1 << 5
    static let directories = 1 << 6
    static let addDirectory = 1 << 7
    static let all = 0xff
}

private struct WindowBridge: NSViewRepresentable {
    let ready: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { ready(window) } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct SearchPanel: View {
    @ObservedObject var model: SearchLibrary
    @ObservedObject var hotKeys: HotKeyManager
    @ObservedObject var clipboardKeys: HotKeyManager
    @ObservedObject var quickTextKeys: HotKeyManager
    @ObservedObject var home:HomeLibrary
    @ObservedObject var recentApps:RecentAppLibrary
    @ObservedObject var clipboard:ClipboardHistoryStore
    @StateObject private var categoryOrder = CategoryOrder()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var selected: String? = nil
    @ViewState private var multiSelection=ResultSelection()
    @ViewState private var hovering: String? = nil
    @ViewState private var hoveredTag:String?
    @ViewState private var tagRegions:[String:[String:CGRect]]=[:]
    @ViewState private var keyboardTarget:String? = nil
    @ViewState private var previewArmed=false
    @ViewState private var showTags=false
    @ViewState private var showTagHelp=false
    @AppStorage("findduckHistoryPlacement") private var historyPlacement=0
    @AppStorage("findduckQuickEntryVisibility") private var quickEntryVisibility=QuickEntryVisibility.all
    @AppStorage("findduckDeveloperTagsEnabled") private var tagsEnabled=false
    @ViewState private var tagManagerFile:FileHit?
    @ViewState private var debounce: Task<Void, Never>? = nil
    @ViewState private var currencyRates: [ExchangeRate] = []
    @ViewState private var currencyError = false

    @State private var copyNotice=""
    @State private var noticeTask:Task<Void,Never>?
    @ObservedObject var quickTexts:QuickTextLibrary
    private var currencyQuery:(amount:Decimal,from:String,to:String)? {CurrencySearchQuery.parse(model.query)}
    private var matchingQuickTexts:[QuickText] {QuickTextSearch.matches(quickTexts.items,query:model.query)}
    private func notifyCopy(_ success:Bool) {
        copyNotice=success ? "已拷贝" : "拷贝失败";noticeTask?.cancel()
        noticeTask=Task {try? await Task.sleep(for:.seconds(2));guard !Task.isCancelled else {return};copyNotice=""}
    }
    private func copySelectedFiles() {
        let files=multiSelection.ids.isEmpty ? model.hits.filter {$0.id == selected} : model.hits.filter {multiSelection.ids.contains($0.id)}
        notifyCopy(ResultFileCopy.copy(files))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .medium)).foregroundStyle(.secondary)
                if let title=model.scopeTitle {
                    HStack(spacing:7) {
                        Image(systemName:"folder.fill").foregroundStyle(Color.accentColor)
                        Text(title).lineLimit(1).truncationMode(.middle)
                        Button {model.clearScope();hotKeys.focusSearchInput()} label: {Image(systemName:"xmark").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)}
                            .buttonStyle(.plain).help("清除搜索范围").accessibilityLabel("清除搜索范围")
                    }.font(.system(size:20,weight:.medium)).padding(.horizontal,10).padding(.vertical,5)
                        .background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
                        .fixedSize(horizontal:true,vertical:true)
                        .help(model.directoryScope?.path ?? title).accessibilityElement(children:.contain).accessibilityLabel("搜索范围："+title)
                }
                ZStack(alignment:.trailing) {
                    PanelSearchField(text: $model.query, manager: hotKeys, onSubmit: { openSelection(reveal: $0) }, onMove: { moveSelection($0) }, onDeleteScope: {guard model.scopeTitle != nil else {return false};model.clearScope();return true}, onEscape: escapeSearch,onPreview:previewSelection,onCopyFiles:copySelectedFiles)
                        .padding(.trailing,model.query.isEmpty ? 0 : 22)
                        .help("关键词输入框")
                    ClearSearchButton(text:$model.query) {
                        if let editor=hotKeys.searchField?.currentEditor() as? NSTextView {editor.unmarkText();editor.string=""}
                        hotKeys.searchField?.stringValue=""
                        hotKeys.focusSearchInput()
                    }
                }.frame(maxWidth:.infinity).frame(height:30)
                HStack(spacing: 5) {
                    ForEach(WebSearch.allCases) { website in
                        Button(website.rawValue) {
                            guard let url = website.url(for: model.query) else { return }
                            if NSWorkspace.shared.open(url) { model.rememberSearch(model.query) }
                            else { model.status = "无法打开浏览器，请稍后重试。" }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("用" + website.rawValue + "搜索当前关键词")
                        .accessibilityLabel("用" + website.rawValue + "搜索")
                    }
                }.fixedSize()
                if historyPlacement == 1 && showsQuickEntry(QuickEntryVisibility.history) {historyMenu}
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            if !matchingQuickTexts.isEmpty {
                VStack(spacing:6) {ForEach(matchingQuickTexts) {item in
                    HStack(spacing:10) {Image(systemName:"text.quote");Text(item.title).lineLimit(1);Spacer();Button("拷贝") {notifyCopy(quickTexts.copy(item))}.buttonStyle(.bordered)}
                }}.font(.system(size:12)).padding(.horizontal,24).padding(.vertical,8)
            }
            if !copyNotice.isEmpty {Text(copyNotice).font(.caption).foregroundStyle(Color.accentColor).padding(.horizontal,24).accessibilityLabel(copyNotice)}
            if model.preferences.calculatorOn, let calculation = DuckCalculator.preview(model.query) {
                utilityResult(symbol: "plus.forwardslash.minus", value: calculation.value,
                              detail: calculation.complete ? nil : "继续输入算式",
                              copyable: calculation.complete)
            }
            if let query = currencyQuery {
                if let amount = CurrencyMath.convert(query.amount, from: query.from, to: query.to, rates: currencyRates) {
                    utilityResult(symbol: "arrow.left.arrow.right",
                                  value: CurrencyMath.formatted(amount) + " " + (query.to == "CNY" ? "RMB" : "USD"),
                                  detail: currencyRates.first(where: { $0.quote == "USD" })?.date,
                                  copyable: true)
                } else {
                    Label(currencyError ? "暂时无法获取汇率" : "正在获取汇率…", systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
                }
            }
            if let link=shoppingLink {HStack(spacing:10) {Image(systemName:"link");Text(link.platform.rawValue+"商品链接");Button(link.url) {if let url=URL(string:link.url) {NSWorkspace.shared.open(url)}}.lineLimit(1).truncationMode(.middle);Spacer();Button("拷贝 ID") {copyResult(link.productID)};Button("拷贝链接") {copyResult(link.url)}}.buttonStyle(.bordered).font(.system(size:12)).padding(.horizontal,24).padding(.vertical,9)}
            if let id=productID {HStack(spacing:12) {Image(systemName:"number");Text("商品 ID："+id);Spacer();Button("拷贝 ID") {copyResult(id)};Button("拷贝天猫链接") {copyResult(TmallLinkParser.canonicalLink(for:id))};Button("拷贝京东链接") {copyResult(TmallLinkParser.canonicalJDLink(for:id))}}.buttonStyle(.bordered).font(.system(size:12)).padding(.horizontal,24).padding(.vertical,9)}
            Divider().opacity(0.55)
            if showsQuickEntryRow {
                QuickEntryFlow(spacing: 8) {
                    if historyPlacement == 0 && showsQuickEntry(QuickEntryVisibility.history) {historyMenu}
                    if showsQuickEntry(QuickEntryVisibility.wechat) {quickEntry("今天微信收发的文件", scope: .wechat)}
                    if showsQuickEntry(QuickEntryVisibility.downloads) {quickEntry("今天下载的文件", scope: .downloads)}
                    if showsQuickEntry(QuickEntryVisibility.modified) {quickEntry("今天修改的文件", scope: .modified).help("搜索已索引位置中今天修改的文件，可继续按名称和类型筛选")}
                    if showsQuickEntry(QuickEntryVisibility.recent) {quickEntry("最近打开文件", scope: .recent).help("仅保留最近50个文件，可在其中继续筛选")}
                    if showsQuickEntry(QuickEntryVisibility.shared) {scopeEntry("共享盘",active:model.scopeTitle == "共享盘" && model.directoryScope == nil) {model.toggleShared()}.contextMenu {hideQuickEntry(QuickEntryVisibility.shared)}}
                    if historyPlacement == 2 && showsQuickEntry(QuickEntryVisibility.history) {historyMenu}
                    if showsQuickEntry(QuickEntryVisibility.directories) {ForEach(model.directoryShortcuts,id:\.self) {url in
                        scopeEntry(DisplayPath.name(url),active:model.directoryScope == url) {model.toggleDirectory(url)}
                            .help(url.path).contextMenu {Button("移除快捷入口") {model.removeDirectoryShortcut(url)}}
                    }}
                    if showsQuickEntry(QuickEntryVisibility.addDirectory) {Button {model.chooseDirectoryShortcut();hotKeys.focusSearchInput()} label: {Label("增加目录",systemImage:"plus")}
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,8).frame(height:30).accessibilityLabel("增加目录")
                        .contextMenu {hideQuickEntry(QuickEntryVisibility.addDirectory)}
                    }
                }.font(.system(size:11)).padding(.horizontal,20).padding(.vertical,10)
            }
            if tagsEnabled && !model.availableAnnotationPaths.isEmpty {tagFilters}
            if !model.isHome {
            HStack(spacing: 5) {
                ForEach(categoryOrder.categories) { category in
                    Button { model.category = category;hotKeys.focusSearchInput() } label: {
                        Text(category.rawValue).font(.system(size: 12, weight: model.category == category ? .semibold : .regular))
                            .frame(minWidth:48,minHeight:34).padding(.horizontal,3).contentShape(Capsule())
                            .foregroundStyle(model.category == category ? Color.accentColor : Color.secondary)
                            .background(model.category == category ? FindDuckHighlight.soft : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                    .help("类型筛选栏 · 拖动可调整分类顺序")
                    .overlay(Capsule().stroke(categoryOrder.dropTarget == category ? Color.accentColor : .clear, lineWidth: 1))
                    .onDrag { NSItemProvider(object: ("findduck-category:" + category.rawValue) as NSString) }
                    .dropDestination(for: String.self) { values, _ in
                        withAnimation(.easeInOut(duration: 0.18)) { categoryOrder.drop(values, on: category) }
                    } isTargeted: { targeted in
                        if targeted { categoryOrder.dropTarget = category }
                        else if categoryOrder.dropTarget == category { categoryOrder.dropTarget = nil }
                    }
                }
                Spacer(minLength: 8)
                resultModeSwitch
                Menu {
                    ForEach(ResultSort.allCases) {sort in
                        Toggle(sort.rawValue,isOn:Binding(get:{model.resultSort == sort},set:{if $0 {model.resultSort=sort;hotKeys.focusSearchInput()}}))
                    }
                } label: {
                    HStack(spacing: 4) { Text(model.resultSort.rawValue); Image(systemName: "arrow.up.arrow.down") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("排序菜单").accessibilityLabel("排序："+model.resultSort.rawValue)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            if !model.quickRefreshStatus.isEmpty {Text(model.quickRefreshStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20)}
            if !model.deepStatus.isEmpty {Text(model.deepStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20)}
            if !categoryOrder.error.isEmpty {Text(categoryOrder.error).font(.caption).foregroundStyle(.red)}
            if !model.status.isEmpty {Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal,20)}
            if model.isHome {
                HomePanel(home:home,model:model,hotKeys:hotKeys,recentApps:recentApps,clipboard:clipboard).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if model.hits.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List {
                        ForEach(model.hits) { file in
                            resultRow(file)
                                .id(file.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        if model.hasMoreResults {
                            Button("继续加载（已显示 \(model.hits.count) / \(model.resultCount)）") { model.loadMoreResults() }
                                .frame(maxWidth:.infinity).padding(.vertical,8).disabled(model.isSearching)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                        .onChange(of: keyboardTarget) { _, id in if let id { scroll.scrollTo(id) } }
                }
            }

        }
        .background {
            if #available(macOS 15.0, *) {
                Color(nsColor: .textBackgroundColor).gesture(WindowDragGesture())
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 700, minHeight: 500)
        .background(WindowBridge { window in
            window.styleMask.insert([.titled, .fullSizeContentView])
            window.backgroundColor = .textBackgroundColor
            window.hasShadow = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            hotKeys.searchWindow = window
            hotKeys.resetSearchFrame(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        })
        .sheet(item:$tagManagerFile) {file in TagManager(model:model,file:file)}
        .onAppear {
            refreshApplicationOrder()
            if !tagsEnabled {model.clearTagSelection()}
            hotKeys.openSearch = { openWindow(id: "search") }
            clipboardKeys.openTool = {openWindow(id:"clipboard")}
            quickTextKeys.openTool = {openWindow(id:"quick-text")}
            hotKeys.prepareSearch = { elapsed in
                let reset = HomeLibrary.shouldShowHome(elapsed: elapsed, resumeWindow: home.resumeWindowSeconds)
                if reset { model.showHome(); selected = nil; hovering = nil; hoveredTag = nil; previewArmed = false }
                return reset
            }
            hotKeys.openSettings = { openSettings() }
            model.didOpenResult = {hotKeys.hideSearch()}
        }
        .onChange(of:home.items) {_,_ in refreshApplicationOrder()}
        .onChange(of:recentApps.items) {_,_ in refreshApplicationOrder()}
        .task(id: currencyQuery != nil) {
            guard currencyQuery != nil else { return }
            currencyError = false
            do { currencyRates = try await ExchangeRates.load() }
            catch { if !Task.isCancelled { currencyError = true } }
        }
        .onChange(of:tagsEnabled) {_,enabled in if !enabled {model.clearTagSelection()}}
        .onChange(of: model.query) { old, query in
            previewArmed=false
            debounce?.cancel()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if model.isHome { model.clearResults(); selected = nil } else if !model.isSearching { model.search() }; return }
            debounce = Task {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard !Task.isCancelled else { return }; model.search()
            }
        }
        .onChange(of: model.hits) { _, hits in
            multiSelection.retain(Set(hits.map(\.id)))
            if !hits.contains(where: { $0.id == selected }) { selected = hits.first?.id }
            if multiSelection.ids.isEmpty {multiSelection.replace(selected)}
        }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { openSelection(reveal: true); return .handled }
            return .ignored
        }
        .onExitCommand {escapeSearch()}
    }
    private func showsQuickEntry(_ entry:Int)->Bool {quickEntryVisibility & entry != 0}
    private var showsQuickEntryRow:Bool {
        let inSearchField = historyPlacement == 1 ? QuickEntryVisibility.history : 0
        let rowEntries = quickEntryVisibility & ~inSearchField
        return rowEntries & ~QuickEntryVisibility.directories != 0 ||
            (showsQuickEntry(QuickEntryVisibility.directories) && !model.directoryShortcuts.isEmpty)
    }
    private func quickEntry(_ title: String, scope: QuickScope) -> some View {
        let active = model.quickScope == scope && model.directoryScope == nil
        return Button { model.toggleQuick(scope);hotKeys.focusSearchInput() } label: {
            Label(title, systemImage: "magnifyingglass")
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? FindDuckHighlight.soft : Color.primary.opacity(0.055), in: Capsule())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .contextMenu {hideQuickEntry(visibilityBit(scope))}
    }
    private func visibilityBit(_ scope:QuickScope)->Int {
        switch scope {case .wechat:QuickEntryVisibility.wechat;case .downloads:QuickEntryVisibility.downloads;case .modified:QuickEntryVisibility.modified;case .recent:QuickEntryVisibility.recent;case .none:0}
    }
    private func hideQuickEntry(_ bit:Int)->some View {
        Button("隐藏快捷入口",systemImage:"eye.slash") {quickEntryVisibility &= ~bit}
    }
    private var historyMenu:some View {
        Menu {
            if model.searchHistory.isEmpty {Text("暂无历史搜索")}
            ForEach(model.searchHistory,id:\.self) {term in Button(term) {model.recallSearch(term);hotKeys.focusSearchInput()}}
            if !model.searchHistory.isEmpty {Divider();Button("清空历史搜索") {model.clearSearchHistory()}}
        } label: {Label("历史搜索",systemImage:"clock.arrow.circlepath").font(.system(size:12)).padding(.horizontal,12).padding(.vertical,6).background(Color.primary.opacity(0.055),in:Capsule())}
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("历史搜索")
            .contextMenu {hideQuickEntry(QuickEntryVisibility.history)}
    }
    private var resultModeSwitch: some View {
        Toggle("精简结果", isOn: Binding(get: { model.preferences.suppressNoise },
                                       set: { model.toggleNoise($0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11))
            .fixedSize()
            .help("关闭后显示精简时隐藏的结果。搜索排除规则仍生效。")
    }
    private func scopeEntry(_ title:String,active:Bool,action:@escaping ()->Void) -> some View {
        Button {action();hotKeys.focusSearchInput()} label: {
            Label(title,systemImage:"magnifyingglass").font(.system(size:12,weight:active ? .semibold : .regular))
                .padding(.horizontal,12).padding(.vertical,6)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? FindDuckHighlight.soft : Color.primary.opacity(0.055),in:Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private var footer: String {
        if model.isIndexing { return "正在建立索引 · 已扫描 \(model.scanned) 条记录" }
        if model.connectionUnavailable { return model.query.isEmpty ? "离线索引 · \(model.indexedFileCount) 个文件" : "\(model.resultCount) 个结果 · 离线索引" }
        if !model.hasIndex { return "请在设置中添加搜索文件夹" }
        if !model.query.isEmpty || model.scopeTitle != nil { return "\(model.resultCount) 个结果 · \(model.scopeTitle ?? model.sourceFilter.rawValue)" }
        return "已索引 \(model.indexedFileCount) 个文件"
    }
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.query.isEmpty ? "magnifyingglass" : "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
            Text((model.quickScope == .downloads || model.quickScope == .wechat || model.quickScope == .modified) ? "没有找到符合条件的文件" : !model.hasIndex && !model.sources.isEmpty ? "正在载入或建立索引…" : !model.hasIndex ? "添加本地或共享盘文件夹" : model.quickScope == .recent ? "暂无匹配的最近打开记录" : model.isHome ? "输入文件名开始搜索" : "没有找到匹配结果")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            if !model.hasIndex {
                SettingsLink { Text("打开设置") }.buttonStyle(.bordered)
            } else if !model.query.isEmpty {
                Text("新文件会在后台目录检查后收录，可在设置中查看进度。")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }
    private func resultRow(_ file: FileHit) -> some View {
        return HStack(spacing: 13) {
            SearchResultIcon(file: file, shared: model.sources.contains { $0.kind == .shared && DuckRules.under(file.url, $0.url) })
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing:6) {
                    if ResultCategory.kind(of:file) == .images || ResultCategory.kind(of:file) == .video {Image(systemName:ResultCategory.kind(of:file) == .images ? "photo" : "film").font(.system(size:12)).foregroundStyle(.secondary)}
                    HighlightedName(name:isInstalledApplication(file) ? file.applicationDisplayName : file.name,query:model.query,fontSize:isInstalledApplication(file) ? 16 : 14).frame(height:21)
                    if tagsEnabled {ForEach(model.tags(file)) {tag in trackedTag(tag,file:file)}
                    if let note=model.preferences.fileNotes?[file.id],!note.isEmpty {trackedTag(FileTag(id:"note",name:note,color:.gray),file:file)}}
                }
                if !isInstalledApplication(file) {HStack(spacing:4) {Image(systemName:model.sources.contains(where:{$0.kind == .shared && DuckRules.under(file.url,$0.url)}) ? "network" : WechatLocations.isChatAttachment(file.url) ? "bubble.left.and.bubble.right" : "internaldrive");Text(DisplayPath.parent(file.url)).lineLimit(1).truncationMode(.middle)}.font(.system(size:12)).foregroundStyle(.secondary).help(file.url.deletingLastPathComponent().path)}
            }
            Spacer(minLength: 16)
            VStack(alignment:.trailing,spacing:4) {
                Text(file.modified.map {$0.formatted(date:.numeric,time:.shortened)} ?? "修改时间待更新").font(.system(size:11)).foregroundStyle(.secondary)
            Text(file.isDirectory ? "文件夹" : file.url.pathExtension.isEmpty ? "文件" : file.url.pathExtension.uppercased())
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background((multiSelection.ids.contains(file.id) || selected == file.id) ? FindDuckHighlight.selected : hovering == file.id ? FindDuckHighlight.hover : .clear, in: RoundedRectangle(cornerRadius: 22))
        .coordinateSpace(name:file.id)
        .onPreferenceChange(TagRegionKey.self) {value in if tagRegions[file.id] != value[file.id] {tagRegions[file.id]=value[file.id]}}
        .contentShape(Rectangle())
        .overlay {
            ImmediateResultClick(select:{modifiers,right in if let editor=hotKeys.searchField?.currentEditor() as? NSTextView,!editor.hasMarkedText() {editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))};previewArmed=true;multiSelection.select(file.id,ordered:model.hits.map(\.id),modifiers:modifiers,rightClick:right);selected=multiSelection.primary},hover:{point in
                if let point {hovering=file.id;let match=tagRegions[file.id]?.first(where:{$0.value.contains(point)}).map {file.id+"|"+$0.key};if hoveredTag != match {hoveredTag=match}}
                else if hovering == file.id {hovering=nil;hoveredTag=nil}
            },open:{reveal in openResult(file,reveal:reveal)},menu:{fileMenu(file)})
        }
    }
    private func trackedTag(_ tag:FileTag,file:FileHit)->some View {
        TagBadge(tag:tag,highlighted:selected == file.id || hoveredTag == file.id+"|"+tag.id)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .zIndex(1)
            .background(GeometryReader {proxy in Color.clear.preference(key:TagRegionKey.self,value:[file.id:[tag.id:proxy.frame(in:.named(file.id))]])})
    }
    private func isInstalledApplication(_ file:FileHit)->Bool {file.applicationNames != nil || (file.url.pathExtension.lowercased() == "app" && ["/Applications/","/System/Applications/","/System/Library/CoreServices/","/System/Volumes/Preboot/Cryptexes/App/System/Applications/"].contains(where:file.url.path.hasPrefix))}
    @ViewBuilder private var selectedActions:some View {
        if let file=model.hits.first(where:{$0.id == selected}) {
            HStack(spacing:12) {
                Button {showTags.toggle()} label: {Image(systemName:"tag")}
                    .buttonStyle(.plain).help("文件标签").accessibilityLabel("文件标签")
                    .popover(isPresented:$showTags) {
                        FileTagEditor(model:model,file:file,create:{showTags=false;DispatchQueue.main.async {tagManagerFile=file}})
                    }
                Button {model.requestTrash(file)} label: {Image(systemName:"trash")}.buttonStyle(.plain).help("移到废纸篓").accessibilityLabel("删除选中文件")
            }
        }
    }
    private func fileMenu(_ file:FileHit)->NSMenu {
        let files=multiSelection.ids.contains(file.id) ? model.hits.filter {multiSelection.ids.contains($0.id)} : [file]
        let menu=NSMenu()
        if files.count > 1 {let title=NSMenuItem(title:"已选择 \(files.count) 项",action:nil,keyEquivalent:"");title.isEnabled=false;menu.addItem(title)}
        menu.addItem(ResultMenus.item("打开") {for item in files {openResult(item,reveal:false)}})
        menu.addItem(ResultMenus.item("在 Finder 中显示") {NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))})
        menu.addItem(ResultMenus.item("添加到首页常用文件") {for item in files {_=home.pin(item.url)}})
        menu.addItem(ResultMenus.item("拷贝") {notifyCopy(ResultFileCopy.copy(files))})
        menu.addItem(ResultMenus.item("拷贝路径") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(files.map(\.id).joined(separator:"\n"),forType:.string)})
        menu.addItem(.separator())
        if tagsEnabled {
            func toggle(_ tag:FileTag) {let enabled = !files.allSatisfy {model.hasTag($0,tag)};model.setTags(files,tag,enabled:enabled)}
            let palette=NSMenuItem();palette.view=TagColorPalette(colors:FileMarkColor.palette,selected:{Set(FileMarkColor.palette.filter {color in files.allSatisfy {model.hasTag($0,FileTag.builtin(color))}})},toggle:{toggle(FileTag.builtin($0))});menu.addItem(palette)
            if let tags=model.preferences.customTags,!tags.isEmpty {
                let item=NSMenuItem();item.view=NamedTagsMenuView(tags:tags,selected:{tag in files.allSatisfy {model.hasTag($0,tag)}},toggle:toggle);menu.addItem(item)
            }
            menu.addItem(ResultMenus.item("自定义标签…") {
                if files.count == 1 {tagManagerFile=file} else {
                    let previous=Set((model.preferences.customTags ?? []).map(\.id));model.chooseCustomTag(file)
                    if let tag=model.preferences.customTags?.last(where:{!previous.contains($0.id)}) {model.setTags(files,tag,enabled:true)}
                }
            })
        }
        menu.addItem(ResultMenus.item("备注…") {model.chooseNotes(files)})
        menu.addItem(ResultMenus.item("隐藏所选内容") {
            let alert=NSAlert();alert.messageText="隐藏所选的 \(files.count) 项？";alert.informativeText="文件夹及内容会移出搜索范围，可在搜索排除设置中恢复。";alert.addButton(withTitle:"取消");alert.addButton(withTitle:"隐藏")
            if alert.runModal() == .alertSecondButtonReturn {for item in files {if item.isDirectory {model.addBlacklist(item.url)} else {model.blockFile(item)}}}
        })
        menu.addItem(.separator())
        let trash=ResultMenus.item("移到废纸篓…") {model.requestTrash(files)};trash.image=NSImage(systemSymbolName:"trash",accessibilityDescription:nil);menu.addItem(trash)
        return menu
    }
    @ViewBuilder private var tagFilters:some View {
        ScrollView(.horizontal) {
            HStack(spacing:8) {
                ForEach(model.visibleTags) {tag in
                    Button {model.toggleTagSelection(tag.id);hotKeys.focusSearchInput()} label: {HStack(spacing:5) {TagBadge(tag:tag)}.padding(.horizontal,8).frame(height:30).background(model.selectedTagIDs.contains(tag.id) ? FindDuckHighlight.soft : Color.clear,in:Capsule()).contentShape(Capsule())}.buttonStyle(.plain).help(tag.displayName)
                }
            }
        }.scrollIndicators(.hidden).frame(height:32).padding(.horizontal,20).padding(.bottom,6)
    }
    private func refreshApplicationOrder() {
        model.pinnedApplications=Set(home.items.filter {$0.kind == .application}.map(\.target))
        model.recentApplications=Dictionary(recentApps.items.map {($0.path,$0.openedAt)},uniquingKeysWith:max)
        if model.directoryScope?.standardizedFileURL.path == "/Applications",model.resultSort == .relevance {model.search()}
    }
    private func previewSelection()->Bool {guard previewArmed || model.query.isEmpty else {return false};guard let file=model.hits.first(where:{$0.id == selected}) else {return false};FilePreview.shared.show(file,owner:hotKeys.searchWindow,onMove:moveSelection);return true}
    private func escapeSearch() {if FilePreview.shared.isPresenting {FilePreview.shared.hide();hotKeys.focusSearchInput();return};if model.consumeEscape() {hotKeys.focusSearchInput()} else {hotKeys.hideSearch()}}
    private func moveSelection(_ delta: Int) {
        previewArmed=true
        guard !model.hits.isEmpty else { return }
        let current = model.hits.firstIndex { $0.id == selected } ?? -1
        selected = model.hits[min(max(current + delta, 0), model.hits.count - 1)].id
        multiSelection.replace(selected)
        keyboardTarget=selected
        if let file=model.hits.first(where:{$0.id == selected}) {FilePreview.shared.update(file)}
    }
    private func openSelection(reveal: Bool) {
        guard let file = model.hits.first(where: { $0.id == selected }) ?? model.hits.first else { model.search(); return }
        openResult(file,reveal:reveal)
    }
    private func openResult(_ file:FileHit,reveal:Bool) {
        if reveal {model.reveal(file)} else {model.open(file)}
    }
    private func utilityResult(symbol: String, value: String, detail: String?, copyable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("拷贝结果") { copyResult(value) }
                .buttonStyle(.bordered).disabled(!copyable)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func copyResult(_ value:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)}
    private var shoppingLink:CleanedProductLink? {guard model.preferences.linkCleanerOn, model.query.range(of:#"[a-z]"#,options:.regularExpression) != nil else {return nil};return try? TmallLinkParser.analyze(model.query)}
    private var productID:String? {guard model.preferences.idToLinkOn else {return nil};let value=model.query.trimmingCharacters(in:.whitespacesAndNewlines);return value.range(of:#"^[0-9]{5,20}$"#,options:.regularExpression) == nil ? nil : value}
}

struct SearchSettings: View {
    @ObservedObject var license: BiuLicense
    @ObservedObject var updates: AppUpdates
    @ObservedObject var model: SearchLibrary
    @ObservedObject var hotKeys: HotKeyManager
    @ObservedObject var secondaryKeys: HotKeyManager
    @ObservedObject var clipboardKeys:HotKeyManager
    @ObservedObject var quickTextKeys:HotKeyManager
    @ObservedObject var clipboard:ClipboardHistoryStore
    @AppStorage("findduckClipboardCopyFeedback") private var copyFeedback = ClipboardCopyFeedback.center
    @ViewState private var confirmClearClipboard = false
    @ObservedObject var home:HomeLibrary
    @AppStorage("findduckDeveloperEntryVisibleV1") private var developerEntryVisible = false
    @AppStorage("findduckHistoryPlacement") private var historyPlacement=0
    @AppStorage("findduckQuickEntryVisibility") private var quickEntryVisibility=QuickEntryVisibility.all
    @AppStorage("findduckDeveloperTagsEnabled") private var tagsEnabled=false
    @AppStorage("biuDarkMode") private var darkMode = false
    @AppStorage("biuImageThumbnails") private var imageThumbnails = true
    @AppStorage("biuVideoThumbnails") private var videoThumbnails = true
    @AppStorage("biuSharedThumbnails") private var sharedThumbnails = true
    @AppStorage("biuToolWindowHideDelay") private var toolWindowHideDelay:Double = 3
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @ViewState private var selectedSettingsTab = "search"
    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            appearanceOptions.tabItem { Label("通用", systemImage: "gearshape") }.tag("appearance")
            searchOptions.tabItem {Label("搜索",systemImage:"magnifyingglass")}.tag("search")
            exclusions.tabItem {Label("搜索排除",systemImage:"folder.badge.minus")}.tag("exclusions")
            keyboard.tabItem { Label("快捷键", systemImage: "keyboard") }.tag("keyboard")
            clipboardOptions.tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }.tag("clipboard")
            about.tabItem { Label("关于", systemImage: "info.circle") }.tag("about")
            if developerEntryVisible {
                developer.tabItem { Label("开发者", systemImage: "hammer") }.tag("developer")
            }
        }.padding(18).frame(width: 610, height: 440)
            .onAppear { if updates.aboutRequest > 0 { selectedSettingsTab = "about" } }
            .onChange(of: updates.aboutRequest) { selectedSettingsTab = "about" }
            .onDisappear { hotKeys.cancelRecording();secondaryKeys.cancelRecording();clipboardKeys.cancelRecording();quickTextKeys.cancelRecording() }
    }
    private var appearanceOptions: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 Biu", isOn: Binding(get: { launchAtLogin.requested }, set: { launchAtLogin.setEnabled($0) }))
                Text("开启后，在登录 Mac 时自动运行并常驻菜单栏。Biu 不在 Dock 显示图标，可通过菜单栏或全局快捷键呼出。")
                    .font(.caption).foregroundStyle(.secondary)
                if launchAtLogin.needsApproval {
                    Text("需要在系统的登录项设置中允许 Biu。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("打开系统登录项设置") { launchAtLogin.openSystemSettings() }
                }
                if !launchAtLogin.error.isEmpty {
                    Text(launchAtLogin.error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("外观") {
                Toggle("深色模式", isOn: $darkMode)
                    .onChange(of: darkMode) { BiuAppearance.apply(darkMode) }
                Text("默认使用浅色外观，开启后所有 Biu 窗口使用深色外观。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .onAppear { launchAtLogin.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in launchAtLogin.refresh() }
    }
    @ViewBuilder private var indexControls: some View {
            Section("搜索位置") {
                ForEach(model.sources) { source in
                    HStack(alignment: .top) {
                        Image(systemName: source.kind == .local ? "internaldrive" : "network")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.path == "/" ? "全盘搜索" : WechatLocations.isContainer(source.url) ? "微信收发文件" : DisplayPath.name(source.url)).fontWeight(.medium)
                            if source.url.path != "/" {Text(DisplayPath.localized(source.url)).help(source.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                            Text(source.url.path == "/" ? "已包含下载等普通文件夹；系统目录和用户资源库按索引设置排除。"+model.summary(source) : WechatLocations.isContainer(source.url) ? "只索引聊天收发文件、可直接打开的图片和视频；排除缓存、数据库、备份与无法按原名搜索的加密 .dat 图片。"+model.summary(source) : model.summary(source)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if source.kind == .shared {Text("共享盘").font(.caption).foregroundStyle(.secondary).frame(width:50)}
                        Button("移除") { model.remove(source) }.help("只移出搜索范围，不删除文件")
                    }
                }
                HStack {
                    Button("完成磁盘授权") { model.diskAuthorization() }
                    Button("添加共享盘文件夹…") { model.chooseFolder(kind: .shared) }
                }
                Text("本地磁盘自动加入搜索范围；授权后重启Biu会重新核对索引。共享盘先在 Finder 连接，再从上方添加。微信文件位置自动识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文件名索引") {
                Text(model.indexSummary).foregroundStyle(.secondary)
                Toggle("自动更新索引",isOn:$model.autoUpdate)
                Text("本地监听文件变化并补齐历史事件；共享盘按目录分批检查。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isIndexing {
                    HStack {ProgressView().controlSize(.small);Text("已扫描 \(model.scanned) 个文件 / \(model.scannedDirectories) 个目录");Spacer();Button("停止") {model.cancelIndex()}}
                } else {
                    Button(model.hasIndex ? "立即完整核对" : "建立文件名索引") {model.buildIndex()}.disabled(model.folder == nil)
                }
            }
    }
    private var searchOptions:some View {
        Form {
            indexControls
            Section("搜索框工具") {
                Toggle("计算功能",isOn:Binding(get:{model.preferences.calculatorOn},set:{model.preferences.calculatorEnabled=$0;model.savePreferences()}))
                Toggle("商品链接工具", isOn: Binding(get: { model.preferences.productLinksOn }, set: {
                    model.preferences.productLinksEnabled = $0
                    model.savePreferences()
                }))
            }
            Section("主页") {
                Picker("保留上次窗口状态",selection:$home.resumeWindowSeconds) {
                    Text("30 秒").tag(30.0);Text("2 分钟").tag(120.0);Text("5 分钟").tag(300.0);Text("10 分钟").tag(600.0)
                }
                Text("在这段时间内恢复窗口的位置、大小、搜索条件和光标。超过后以默认大小和位置打开主页。").font(.caption).foregroundStyle(.secondary)
            }
            Section("结果精简") {
                Toggle("精简结果", isOn: Binding(get: { model.preferences.suppressNoise },
                                               set: { model.toggleNoise($0) }))
                Text("精简时隐藏疑似系统或随机命名的项目，以及下方选中的扩展名。关闭精简后可查看这些结果。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("精简时隐藏的扩展名").font(.caption.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74))], alignment: .leading, spacing: 6) {
                    ForEach(DuckPreferences.normalHiddenExtensions, id: \.self) { ext in
                        let hidden = model.preferences.effectiveHiddenExtensions.contains(ext)
                        Button {
                            var values = model.preferences.effectiveHiddenExtensions
                            if hidden { values.remove(ext) } else { values.insert(ext) }
                            model.preferences.hiddenExtensions = values.sorted()
                            model.savePreferences()
                            model.search()
                        } label: {
                            Text(".\(ext)").font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(hidden ? Color.accentColor : Color.secondary)
                                .background(hidden ? FindDuckHighlight.soft : Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(hidden ? .isSelected : [])
                    }
                }
            }
            Section("共享盘深度搜索") {
                InlineSearchField(prompt:"关键词",text:$model.query)
                Button(model.deepSearching ? "停止深度搜索" : "开始深度搜索") {model.deepSearch()}
                Text("直接遍历已添加的共享盘目录查找文件名。目录范围仍生效，搜索期间可停止。").font(.caption).foregroundStyle(.secondary)
                if !model.deepStatus.isEmpty {Text(model.deepStatus).font(.caption).foregroundStyle(.secondary)}
            }
            Section("文件操作") {Text("标签只保存在Biu，支持同一文件添加多个颜色和文字标签。删除使用废纸篓；不支持废纸篓的磁盘不会改用永久删除。").font(.caption).foregroundStyle(.secondary)}
        }.formStyle(.grouped)
    }
    private var exclusions: some View {
        Form {
            Section("排除的文件夹") {
                if model.preferences.blacklist.isEmpty { Text("暂无排除的文件夹").foregroundStyle(.secondary) }
                ForEach(model.preferences.blacklist,id:\.path) {url in
                    HStack {Text(url.path).font(.caption).textSelection(.enabled);Spacer();Button("取消排除") {model.removeBlacklist(url)}}
                }
                Button("添加文件夹…") {model.chooseBlacklist()}
                Text("排除这些文件夹及其子目录，适用于所有搜索。").font(.caption).foregroundStyle(.secondary)
            }
            Section("隐藏的单项") {
                ForEach(Array(model.preferences.blockedFiles ?? []).sorted(),id:\.self) {path in HStack {Text(path).font(.caption).lineLimit(2);Spacer();Button("取消隐藏") {model.unblockFile(path)}}}
            }

        }.formStyle(.grouped)
    }
    private var about: some View {
        ScrollView {
            VStack(spacing: 14) {
                DeveloperUnlockLogo { developerEntryVisible = true }.frame(width: 72, height: 72)
                Text("BIU——！！").font(.system(size: 24, weight: .semibold))
                Text("本地与共享盘文件搜索").font(.callout).foregroundStyle(.secondary)
                Text("版本 \(appVersion) · 构建 \(appBuild)").font(.caption).foregroundStyle(.secondary)
                Text("本地索引与搜索基于 Oil Find 开源核心（MIT）").font(.caption).foregroundStyle(.secondary)
                if license.activated { Text(license.message).font(.callout) }
                else { BiuLicenseView(license: license).frame(maxWidth: 500) }
                Button {
                    Task { await updates.check(manual: true) }
                } label: {
                    HStack(spacing: 6) {
                        Text(updates.checking ? "正在检查…" : "检查更新")
                        if updates.hasSmallUpdate { Circle().fill(.red).frame(width: 7, height: 7) }
                    }
                }
                .disabled(updates.checking)
                .accessibilityHint(updates.hasSmallUpdate ? "有小版本更新" : "")
                if let release = updates.release {
                    Link("查看 Biu \(release.version) 更新", destination: release.page)
                }
                if !updates.status.isEmpty {
                    Text(updates.status).font(.caption).foregroundStyle(.secondary)
                }
                Button("界面组件说明") {if let url=Bundle.main.url(forResource:"找鸭-界面组件说明",withExtension:"txt") {NSWorkspace.shared.open(url)}}
                Button("开源许可证") {if let url=Bundle.main.url(forResource:"OilFind-LICENSE",withExtension:"txt") {NSWorkspace.shared.open(url)}}
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("快速查找文件名，支持多位置索引、分类筛选、修改时间及最近打开排序。")
                    LabeledContent("当前快捷键", value: hotKeys.settings.enabled ? hotKeys.settings.display : "已停用")
                    LabeledContent("搜索范围", value: "\(model.sources.count) 个位置")
                    Text("索引和设置保存在这台 Mac，文件名搜索不上传文件内容。共享盘文件需连接后打开。").font(.caption).foregroundStyle(.secondary)
                    Text("索引状态").font(.caption.weight(.medium))
                    Text(model.indexStatus.isEmpty ? "等待添加搜索位置。" : model.indexStatus).font(.caption).foregroundStyle(.secondary)
                    if !model.coverage.isEmpty { Text(model.coverage).font(.caption).foregroundStyle(.secondary) }
                    Text("索引保存位置").font(.caption.weight(.medium))
                    Text(DisplayPath.localized(indexStorage)).help(indexStorage.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("打开索引文件夹") { NSWorkspace.shared.open(indexStorage) }
                        .disabled(!FileManager.default.fileExists(atPath: indexStorage.path))
                    Button("拷贝版本信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Biu \(appVersion) (\(appBuild)) · \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                    }
                }.padding(.top, 3)
            }.padding(22)
        }
    }
    private var developer: some View {
        Form {
            Section("工具窗口") {
                Stepper(value:$toolWindowHideDelay,in:0...60,step:1) {
                    Text(toolWindowHideDelay == 0 ? "失焦后立即隐藏" : "失焦后 \(Int(toolWindowHideDelay)) 秒隐藏")
                }
                Text("剪贴板和常用文本窗口均生效；窗口固定后不会自动隐藏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("界面试验") {
                Picker("历史搜索位置",selection:$historyPlacement) {Text("快捷入口最前").tag(0);Text("搜索框右侧").tag(1);Text("快捷入口末尾").tag(2)}
            }
            Section("结果预览") {
                Toggle("图片预览图", isOn: $imageThumbnails)
                Toggle("视频预览图", isOn: $videoThumbnails)
                Toggle("共享盘预览图", isOn: $sharedThumbnails)
                Text("仅为可见结果后台加载小预览图，失败时显示文件图标。共享盘预览同时遵循图片、视频开关，开启后会额外读取共享盘文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("标签试验") {
                Toggle("启用标签功能",isOn:Binding(get:{tagsEnabled},set:{tagsEnabled=$0;if !$0 {model.clearTagSelection()}}))
                Text("默认关闭。开启后可在搜索结果右键菜单添加颜色或文字标签。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("快捷入口显示") {
                Toggle("历史搜索",isOn:quickEntryOption(QuickEntryVisibility.history))
                Toggle("今天微信收发的文件",isOn:quickEntryOption(QuickEntryVisibility.wechat))
                Toggle("今天下载的文件",isOn:quickEntryOption(QuickEntryVisibility.downloads))
                Toggle("今天修改的文件",isOn:quickEntryOption(QuickEntryVisibility.modified))
                Toggle("最近打开文件",isOn:quickEntryOption(QuickEntryVisibility.recent))
                Toggle("共享盘",isOn:quickEntryOption(QuickEntryVisibility.shared))
                Toggle("已添加的目录",isOn:quickEntryOption(QuickEntryVisibility.directories))
                Toggle("增加目录",isOn:quickEntryOption(QuickEntryVisibility.addDirectory))
                Text("只控制入口显示；已经选中的搜索范围仍会显示在搜索框里，可以从那里清除。").font(.caption).foregroundStyle(.secondary)
            }
            Section("运行状态") {
                LabeledContent("版本", value: "\(appVersion)（\(appBuild)）")
                LabeledContent("本地内核",value:"OilFindCore（MIT）")
                LabeledContent("索引状态", value: model.isIndexing ? "正在扫描" : "空闲")
                LabeledContent("已索引文件", value: "\(model.indexedFileCount)")
                LabeledContent("本轮扫描", value: "\(model.scanned) 个文件 · \(model.scannedDirectories) 个目录")
                LabeledContent("自动更新", value: model.autoUpdate ? "已开启" : "已关闭")
                LabeledContent("全局快捷键", value: hotKeys.isRegistered ? "已注册" : "未注册")
                LabeledContent("黑名单", value: "用户 \(model.preferences.blacklist.count) 项 · 开发者 \(model.preferences.developerBlacklist?.count ?? 0) 项")
            }
            Section("本地索引范围") {
                Text("默认按 Oil Find 的范围规则跳过系统、资源库、依赖目录和包内部。微信接收目录、iCloud 和网盘文件保留。").font(.caption).foregroundStyle(.secondary)
                Toggle("扫描系统目录", isOn: localOption(\.indexSystemDirs))
                Toggle("扫描用户资源库", isOn: localOption(\.indexUserLibrary))
                Toggle("扫描开发依赖目录", isOn: localOption(\.indexDependencyDirs))
                Toggle("扫描应用和文档包内部", isOn: localOption(\.indexPackageContents))
                Text("调整后重新核对本地索引；两套黑名单仍优先生效。共享盘保持原扫描策略。").font(.caption).foregroundStyle(.secondary)
            }
            Section("内置目录排除") {
                Text("与用户添加的目录排除规则同时生效。").font(.caption).foregroundStyle(.secondary)
                ForEach(model.preferences.developerBlacklist ?? [], id: \.path) { url in
                    HStack {
                        Text(url.path).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("移除") { model.removeBlacklist(url, developer:true) }
                    }
                }
                Button("添加内置排除目录…") { model.chooseBlacklist(developer:true) }
            }
            Section("本机诊断") {
                Text(model.indexStatus.isEmpty ? "暂无索引状态" : model.indexStatus).font(.caption).textSelection(.enabled)
                Button("拷贝诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText, forType: .string)
                }
                Text("诊断信息包含版本和运行状态，不包含文件名或搜索内容。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("隐藏开发者入口") {
                    selectedSettingsTab = "about"
                    developerEntryVisible = false
                }
            }
        }.formStyle(.grouped)
    }
    private func localOption(_ keyPath: WritableKeyPath<LocalIndexOptions,Bool>) -> Binding<Bool> {
        Binding(get: { (model.preferences.localIndexOptions ?? LocalIndexOptions())[keyPath:keyPath] },set: { enabled in
            var options=model.preferences.localIndexOptions ?? LocalIndexOptions()
            options[keyPath:keyPath]=enabled;model.setLocalOptions(options)
        })
    }
    private func quickEntryOption(_ entry:Int)->Binding<Bool> {
        Binding(get:{quickEntryVisibility & entry != 0},set:{enabled in
            if enabled {quickEntryVisibility |= entry} else {quickEntryVisibility &= ~entry}
        })
    }
    private var diagnosticText: String {
        ["Biu \(appVersion)（\(appBuild)）", ProcessInfo.processInfo.operatingSystemVersionString,
         "索引中：\(model.isIndexing)；已索引：\(model.indexedFileCount)",
         "本轮扫描：\(model.scanned) 文件 / \(model.scannedDirectories) 目录",
         "搜索位置：\(model.sources.count)；用户黑名单：\(model.preferences.blacklist.count)；开发者黑名单：\(model.preferences.developerBlacklist?.count ?? 0)",
         "自动更新：\(model.autoUpdate)；快捷键注册：\(hotKeys.isRegistered)"].joined(separator: "\n")
    }
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知" }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知" }
    private var indexStorage: URL { BiuStorage.directory.appendingPathComponent("NameIndexes", isDirectory: true) }
    private var clipboardOptions: some View {
        Form {
            Section("拷贝成功提示（测试）") {
                Picker("提示样式", selection: $copyFeedback) {
                    ForEach(ClipboardCopyFeedback.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("历史记录") {
                Button("清空剪贴板历史…", role: .destructive) { confirmClearClipboard = true }
                    .disabled(clipboard.items.isEmpty)
                if !clipboard.error.isEmpty { Text(clipboard.error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .alert("清空剪贴板历史？", isPresented: $confirmClearClipboard) {
            Button("取消", role: .cancel) {}
            Button("清空全部", role: .destructive) { clipboard.clearHistory() }
        } message: {
            Text("所有历史记录和收藏都会被删除，无法撤销。")
        }
    }

    private func shortcutRow(_ title: String, manager: HotKeyManager) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                Button(manager.isRecording ? "按下新快捷键…" : (manager.settings.enabled ? manager.settings.display : "设置快捷键")) {
                    for other in [hotKeys, secondaryKeys, clipboardKeys, quickTextKeys] where other !== manager {
                        other.cancelRecording()
                    }
                    manager.beginRecording()
                }
                .frame(minWidth: 215, alignment: .trailing)
                .background(ShortcutRecorder(manager: manager).frame(width: 1, height: 1))
            }
            if manager.hasError || manager.isRecording {
                Text(manager.message)
                    .font(.caption)
                    .foregroundStyle(manager.hasError ? Color.red : Color.secondary)
            }
        }
    }

    private var keyboard: some View {
        Form {
            Section("搜索启动快捷键") {
                shortcutRow("快捷键1", manager: hotKeys)
                shortcutRow("快捷键2", manager: secondaryKeys)
            }
            Section("工具快捷键") {
                shortcutRow("剪贴板历史", manager: clipboardKeys)
                shortcutRow("常用文本", manager: quickTextKeys)
            }

        }.formStyle(.grouped)
    }
}
@MainActor final class SearchAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var hotKeys: HotKeyManager?
    weak var secondaryKeys: HotKeyManager?
    weak var clipboardKeys: HotKeyManager?
    weak var quickTextKeys: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var instanceLock: Int32 = -1
    weak var library:SearchLibrary?
    func applicationWillTerminate(_ notification:Notification) {library?.shutdown()}
    private var windowObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    private func hideWindowControls(_ window:NSWindow) {
        guard window.title == "Biu" || window.identifier?.rawValue == "search" else {return}
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
            window.standardWindowButton(kind)?.superview?.isHidden = true
        }
    }
    let updates = AppUpdates()
    private var updateTask: Task<Void, Never>?

    @objc private func checkForUpdates() {
        updates.aboutRequest += 1
        showPreferences()
        Task { await updates.check(manual: true) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updates.presentUpdateIfNeeded()
    }

    private func installMenuBar() {
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = DuckMenuBarIcon.load()
        item.button?.toolTip="Biu"
        let menu=NSMenu()
        menu.delegate = self
        populateStatusMenu(menu)
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateStatusMenu(menu)
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items: [(String, Selector, [HotKeyManager?])] = [
            ("显示搜索", #selector(showSearch), [hotKeys, secondaryKeys]),
            ("剪贴板历史", #selector(showClipboard), [clipboardKeys]),
            ("常用文本", #selector(showQuickText), [quickTextKeys]),
            ("检查更新…", #selector(checkForUpdates), []),
            ("设置…", #selector(showPreferences), []),
            ("退出Biu", #selector(quitApp), [])
        ]
        let rows = items.map { title, action, managers in
            let keys = managers.compactMap { manager in
                manager?.settings.enabled == true ? manager?.settings.display : nil
            }
            return (title: title, action: action, shortcut: keys.joined(separator: " / "))
        }
        let font = NSFont.menuFont(ofSize: 0)
        let fontAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let titleWidth = rows.map { ($0.title as NSString).size(withAttributes: fontAttributes).width }.max() ?? 0
        let shortcutWidth = rows.map { ($0.shortcut as NSString).size(withAttributes: fontAttributes).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titleWidth + shortcutWidth + 24))]

        for row in rows {
            let entry = NSMenuItem(title: row.title, action: row.action, keyEquivalent: "")
            if !row.shortcut.isEmpty {
                entry.attributedTitle = NSAttributedString(
                    string: row.title + "\t" + row.shortcut,
                    attributes: [.font: font, .paragraphStyle: paragraph]
                )
            }
            if row.action == #selector(checkForUpdates), updates.hasSmallUpdate {
                let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "有小版本更新")
                entry.image = dot?.withSymbolConfiguration(.init(pointSize: 7, weight: .regular)
                    .applying(.init(paletteColors: [.systemRed])))
                entry.image?.isTemplate = false
            }
            entry.target = self
            menu.addItem(entry)
        }
    }

    @objc func showClipboard() { clipboardKeys?.invoke() }
    @objc func showQuickText() { quickTextKeys?.invoke() }
    @objc func showPreferences() {NSApp.activate(ignoringOtherApps:true);hotKeys?.openSettings?()}
    @objc func quitApp() {NSApp.terminate(nil)}
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--verify-startup") {FileHandle.standardError.write(Data("DID_FINISH_LAUNCH\n".utf8))}
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("biu-rocketduck-\(getuid()).lock").path
        instanceLock = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
            close(instanceLock)
            instanceLock = -1
            NSRunningApplication.runningApplications(withBundleIdentifier: BiuStorage.identifier)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        installMenuBar()
        if !CommandLine.arguments.contains("--verify-startup") {
            updateTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(3))
                    while !Task.isCancelled {
                        await self?.updates.check()
                        try await Task.sleep(for: .seconds(6 * 60 * 60))
                    }
                } catch {}
            }
        }
        windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in for window in NSApp.windows {self?.hideWindowControls(window)} }
        }
        windowResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            let number = (notification.object as? NSWindow)?.windowNumber
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.hotKeys?.searchWindow,
                      window.windowNumber == number, window.isVisible,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !FilePreview.shared.isPresenting else { return }
                self.hotKeys?.hideSearch()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.showSearch() }
        if CommandLine.arguments.contains("--verify-startup") {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                let windows=NSApp.windows.filter {$0.identifier?.rawValue == "search" || $0.title == "Biu"}
                for window in windows {self.hideWindowControls(window)}
                print("NATIVE_WINDOW_FRAME=\(windows.allSatisfy {$0.styleMask.contains(.titled) && $0.hasShadow && !$0.isOpaque})")
                print("WINDOW_CONTROLS_HIDDEN=\(windows.allSatisfy {window in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].allSatisfy {window.standardWindowButton($0)?.isHidden != false}})")
                print("MENU_BAR_CREATED=\(self.statusItem?.button != nil)")
                print("DOCK_ICON_HIDDEN=\(NSApp.activationPolicy() == .accessory)")
                print("MENU_BAR_TEMPLATE=\(self.statusItem?.button?.image?.isTemplate == true)")
                print("MENU_BAR_LOGICAL_SIZE=\(self.statusItem?.button?.image?.size == NSSize(width:20,height:20))")
                print("MENU_BAR_REPRESENTATIONS=\(self.statusItem?.button?.image?.representations.count ?? 0)")
                print("STARTUP_WINDOW_COUNT=\(windows.count) VISIBLE=\(windows.contains {$0.isVisible}) KEY=\(windows.contains {$0.isKeyWindow})")
                fflush(stdout)
                self.hotKeys?.hideSearch()
                print("HIDDEN=\(windows.allSatisfy {!$0.isVisible})")
                print("MENU_BAR_AFTER_HIDE=\(self.statusItem?.button != nil)")
                print("HOTKEY_AFTER_HIDE=\(self.hotKeys?.isRegistered == true)")
                self.showSearch()
                print("RESHOWN=\(windows.contains {$0.isVisible})")
                windows.first?.close()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                    self.showSearch()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        let reopened=NSApp.windows.filter {$0.title == "Biu" || $0.identifier?.rawValue == "search"}
                        print("REOPENED=\(reopened.contains {$0.isVisible}) VISIBLE_COUNT=\(reopened.filter {$0.isVisible}.count)")
                        fflush(stdout);NSApp.terminate(nil)
                    }
                }
            }
        }
    }
    @objc func showSearch() {
        if let hotKeys { hotKeys.invoke(); return }
        NSApp.activate(ignoringOtherApps:true)
        if let window=NSApp.windows.first(where: {$0.title == "Biu" || $0.identifier?.rawValue == "search"}) {window.center();window.makeKeyAndOrderFront(nil)}
    }
    func applicationDidResignActive(_ notification: Notification) {
        guard let window = hotKeys?.searchWindow, window.isVisible,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        hotKeys?.hideSearch()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {if flag {return true};showSearch();return false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct SMBSearchApp: App {
    init() {
        BiuStorage.migratePreferences()
        BiuAppearance.apply(UserDefaults.standard.bool(forKey: "biuDarkMode"))
    }

    @AppStorage("biuDarkMode") private var darkMode = false
    @NSApplicationDelegateAdaptor(SearchAppDelegate.self) private var appDelegate
    @StateObject private var model = SearchLibrary()
    @StateObject private var hotKeys = HotKeyManager()
    @StateObject private var secondaryKeys = HotKeyManager(purpose: .secondarySearch)
    @StateObject private var quickTextKeys = HotKeyManager(purpose: .quickText)
    @StateObject private var clipboardKeys = HotKeyManager(purpose:.clipboard)
    @StateObject private var home = HomeLibrary()
    @StateObject private var recentApps = RecentAppLibrary()
    @StateObject private var clipboard = ClipboardHistoryStore()
    @StateObject private var quickTexts = QuickTextLibrary()
    @StateObject private var license = BiuLicense()
    var body: some Scene {
        WindowGroup("Biu", id: "search") { SearchPanel(model: model, hotKeys: hotKeys,clipboardKeys:clipboardKeys, quickTextKeys:quickTextKeys, home: home,recentApps:recentApps,clipboard:clipboard,quickTexts:quickTexts).modifier(BiuLicenseGate(license: license)).preferredColorScheme(darkMode ? .dark : .light).onAppear { hotKeys.otherSearchShortcut = secondaryKeys; secondaryKeys.otherSearchShortcut = hotKeys; appDelegate.hotKeys = hotKeys; appDelegate.secondaryKeys = secondaryKeys; appDelegate.clipboardKeys = clipboardKeys; appDelegate.quickTextKeys = quickTextKeys; appDelegate.library = model; if CommandLine.arguments.contains("--verify-startup") {DispatchQueue.main.asyncAfter(deadline:.now()+0.7) {model.refreshRecents()}} } }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 760, height: 580)
            .commands {
                CommandGroup(replacing:.undoRedo) {Button("撤销") {UserActionHistory.undoFocusedAction()}.keyboardShortcut("z",modifiers:.command)}
                CommandGroup(replacing: .newItem) { Button("显示搜索") { hotKeys.invoke() }.keyboardShortcut("f", modifiers: [.command, .shift]) }
            }
        WindowGroup("剪贴板历史",id:"clipboard") {ClipboardHistoryView(store:clipboard, quickTexts:quickTexts).modifier(BiuLicenseGate(license: license)).modifier(ToolWindowChrome(key:"biuClipboardWindowPinned")).preferredColorScheme(darkMode ? .dark : .light).padding(12).frame(minWidth:477,minHeight:480).background(WindowBridge {window in clipboardKeys.toolWindow=window;window.title="剪贴板历史";window.titlebarSeparatorStyle = .none;window.makeKeyAndOrderFront(nil)})}.defaultSize(width:477,height:640)
        Window("常用文本", id: "quick-text") {
            QuickTextsView(model: quickTexts)
                .modifier(BiuLicenseGate(license: license))
                .modifier(ToolWindowChrome(key:"biuQuickTextWindowPinned"))
                .preferredColorScheme(darkMode ? .dark : .light)
                .padding(12)
                .frame(minWidth: 420, minHeight: 480)
                .background(WindowBridge { window in
                    quickTextKeys.toolWindow = window
                    window.titlebarSeparatorStyle = .none
                })

        }.defaultSize(width: 440, height: 640)
        Settings { SearchSettings(license: license, updates: appDelegate.updates, model: model, hotKeys: hotKeys,secondaryKeys: secondaryKeys,clipboardKeys:clipboardKeys, quickTextKeys:quickTextKeys, clipboard:clipboard, home: home).preferredColorScheme(darkMode ? .dark : .light) }
    }
}
