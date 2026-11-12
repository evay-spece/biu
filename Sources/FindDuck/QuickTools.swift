import AppKit
import SwiftUI

// A small arithmetic grammar; no script evaluation or external process is involved.
enum DuckCalculator {
    static func preview(_ text: String) -> (value: String, complete: Bool)? {
        if let value = evaluate(text) { return (value, true) }
        var prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let operators = "+-*/^%×÷"
        guard let last = prefix.last, operators.contains(last) else { return nil }
        while let last = prefix.last, operators.contains(last) || last.isWhitespace { prefix.removeLast() }
        if let value = evaluate(prefix) { return (value, false) }
        if let amount = CurrencyMath.amount(prefix) { return (NSDecimalNumber(decimal: amount).stringValue, false) }
        return nil
    }

    static func evaluate(_ text:String)->String? {
        let raw=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"×",with:"*").replacingOccurrences(of:"÷",with:"/")
        guard raw.count <= 256,raw.contains(where:{"+-*/^%".contains($0)}),raw.allSatisfy({$0.isNumber || $0.isWhitespace || ".()+-*/^%".contains($0)}) else {return nil}
        var parser=Parser(chars:Array(raw.filter {!$0.isWhitespace}))
        guard let value=parser.expression(),parser.index == parser.chars.count,value.isFinite else {return nil}
        return String(format:"%.12g",value == 0 ? 0 : value)
    }
    private struct Parser {
        let chars:[Character];var index=0
        mutating func take(_ c:Character)->Bool {if index < chars.count,chars[index] == c {index += 1;return true};return false}
        mutating func expression()->Double? {
            guard var v=product() else {return nil}
            while index < chars.count {if take("+") {guard let b=product() else {return nil};v += b} else if take("-") {guard let b=product() else {return nil};v -= b} else {break}}
            return v
        }
        mutating func product()->Double? {
            guard var v=unary() else {return nil}
            while index < chars.count {if take("*") {guard let b=unary() else {return nil};v *= b} else if take("/") {guard let b=unary(),b != 0 else {return nil};v /= b} else {break}}
            return v
        }
        mutating func unary()->Double? {if take("+") {return unary()};if take("-") {return unary().map {-$0}};return power()}
        mutating func power()->Double? {guard var v=atom() else {return nil};while take("%") {v /= 100};if take("^") {guard let b=unary() else {return nil};v=pow(v,b)};return v}
        mutating func atom()->Double? {
            if take("(") {guard let v=expression(),take(")") else {return nil};return v}
            let start=index;while index < chars.count,chars[index].isNumber || chars[index] == "." {index += 1}
            guard index > start else {return nil};return Double(String(chars[start..<index]))
        }
    }
}
struct QuickText: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var group: String? = nil
    var sourceClipboardID: UUID? = nil
    var imageName: String? = nil
}

@MainActor final class QuickTextLibrary: ObservableObject {
    private struct Document: Codable {
        var items: [QuickText]
        var groups: [String]
    }
    @Published private(set) var items: [QuickText] = []
    @Published private(set) var groups: [String] = []
    @Published var error = ""
    @Published var revealID: UUID?
    func item(fromClipboard id: UUID) -> QuickText? { items.first { $0.sourceClipboardID == id } }
    private let file: URL
    private var groupIDs:[String:UUID]=[:]
    func groupDragID(_ name:String)->UUID {if let id=groupIDs[name] {return id};let id=UUID();groupIDs[name]=id;return id}
    private let history:UserActionHistory
    private var unreadable = false

    init(file: URL? = nil,history:UserActionHistory? = nil) {
        self.history=history ?? .shared
        self.file = file ?? BiuStorage.directory.appendingPathComponent("quick-texts.json")
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            let data = try Data(contentsOf: self.file)
            if let document = try? JSONDecoder().decode(Document.self, from: data) {
                items = document.items
                groups = document.groups
            } else {
                items = try JSONDecoder().decode([QuickText].self, from: data)
            }
            for group in items.compactMap(\.group) where !groups.contains(group) { groups.append(group) }
        } catch {
            unreadable = true
            self.error = "常用文本读取失败，原文件已保留。"+error.localizedDescription
        }
    }

    @discardableResult
    func save(_ item: QuickText) -> Bool {
        var item = item
        let enteredName = item.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = groups.first(where: { $0.caseInsensitiveCompare(enteredName) == .orderedSame }) ?? enteredName
        item.group = name.isEmpty ? nil : name
        var updated = items
        if let index = updated.firstIndex(where: { $0.id == item.id }) { updated[index] = item }
        else { updated.append(item) }
        var updatedGroups = groups
        if !name.isEmpty, !updatedGroups.contains(name) { updatedGroups.append(name) }
        let old=items.first {$0.id == item.id}
        let result=persist(updated, groups: updatedGroups)
        if result,let old,old.imageName != item.imageName,let oldURL=imageURL(old) {try? FileManager.default.removeItem(at:oldURL)}
        return result
    }

    var mediaDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("quick-text-media",isDirectory:true) }
    func imageURL(_ item: QuickText) -> URL? {
        guard let name=item.imageName,!name.hasPrefix("."),name.lowercased().hasSuffix(".png"),name == URL(fileURLWithPath:name).lastPathComponent else {return nil}
        return mediaDirectory.appendingPathComponent(name)
    }
    @discardableResult func save(_ item: QuickText, imageData: Data?) -> Bool {
        guard let imageData else {return save(item)}
        guard let png=QuickTextImages.png(imageData) else {error="无法读取图片";return false}
        var updated=item
        let old=imageURL(item)
        let name=UUID().uuidString+".png",url=mediaDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at:mediaDirectory,withIntermediateDirectories:true)
            try png.write(to:url,options:.atomic)
            updated.imageName=name
            guard save(updated) else {try? FileManager.default.removeItem(at:url);return false}
            if let old,old != url {try? FileManager.default.removeItem(at:old)}
            return true
        } catch {self.error="图片保存失败："+error.localizedDescription;return false}
    }
    func copy(_ item: QuickText, to board:NSPasteboard = .general) -> Bool {
        if let url=imageURL(item) {
            guard let data=try? Data(contentsOf:url),let image=NSImage(data:data) else {error="图片不可用，原内容已保留";return false}
            board.clearContents()
            guard board.writeObjects([image]) else {error="拷贝失败";return false}
            if !item.text.isEmpty {_=board.setString(item.text,forType:.string)}
            error="";return true
        }
        board.clearContents()
        let result=board.setString(item.text,forType:.string)
        error=result ? "" : "拷贝失败"
        return result
    }
    func remove(_ item: QuickText) {
        if persist(items.filter { $0.id != item.id }, groups: groups),let url=imageURL(item) {try? FileManager.default.removeItem(at:url)}
    }

    @discardableResult
    func createGroup(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validGroup(name) else { return false }
        return persist(items, groups: groups + [name])
    }

    @discardableResult
    func renameGroup(_ original: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard groups.contains(original) else { return false }
        if original == name { return true }
        guard validGroup(name) else { return false }
        let updated = items.map { item in
            var item = item
            if item.group == original { item.group = name }
            return item
        }
        return persist(updated, groups: groups.map { $0 == original ? name : $0 })
    }

    @discardableResult
    func removeGroup(_ name: String,deleteContents:Bool=false) -> Bool {
        if deleteContents {
            let removed=items.filter {$0.group == name}
            let success=persist(items.filter {$0.group != name},groups:groups.filter {$0 != name})
            if success {for item in removed {if let url=imageURL(item) {try? FileManager.default.removeItem(at:url)}}}
            return success
        }
        let updated = items.map { item in
            var item = item
            if item.group == name { item.group = nil }
            return item
        }
        return persist(updated, groups: groups.filter { $0 != name })
    }

    @discardableResult
    func move(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let source = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == target }) else { return false }
        var updated = items
        let item = updated.remove(at: source)
        guard let destination = updated.firstIndex(where: { $0.id == target }) else { return false }
        updated.insert(item, at: destination + (after ? 1 : 0))
        return persist(updated, groups: groups)
    }

    @discardableResult
    func move(_ id: UUID, toGroup group: String?) -> Bool {
        if let group, !groups.contains(group) { return false }
        guard let source = items.firstIndex(where: { $0.id == id }) else { return false }
        var updated = items
        var item = updated.remove(at: source)
        item.group = group
        let destination = updated.lastIndex(where: { $0.group == group }).map { $0 + 1 } ?? updated.endIndex
        updated.insert(item, at: destination)
        return persist(updated, groups: groups)
    }

    @discardableResult func moveGroup(_ name:String,before target:String)->Bool {
        guard name != target,groups.contains(name),groups.contains(target) else {return false}
        var updated=groups.filter {$0 != name};updated.insert(name,at:updated.firstIndex(of:target)!)
        return persist(items,groups:updated)
    }

    private func validGroup(_ name: String) -> Bool {
        guard !name.isEmpty else { error = "请输入分组名称"; return false }
        guard !groups.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            error = "已有同名分组"; return false
        }
        return true
    }

    private func persist(_ updated: [QuickText], groups: [String],recordUndo:Bool=true) -> Bool {
        guard !unreadable else { return false }
        do {
            let previousItems=items,previousGroups=self.groups
            let removedMedia=previousItems.filter {old in updated.first(where:{$0.id == old.id})?.imageName != old.imageName}.compactMap(imageURL)
            let mediaBackup=recordUndo ? try UndoMediaBackup(removedMedia) : nil
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = file.appendingPathExtension("before-groups")
            if manager.fileExists(atPath: file.path), !manager.fileExists(atPath: backup.path) {
                try manager.copyItem(at: file, to: backup)
            }
            try JSONEncoder().encode(Document(items: updated, groups: groups)).write(to: file, options: .atomic)
            items = updated
            self.groups = groups
            if recordUndo {history.record("常用文本操作",cost:mediaBackup?.byteCount ?? 0) { [weak self] in
                guard let self else {return false}
                do {try mediaBackup?.restore()} catch {return false}
                let removed=self.items.filter {current in !previousItems.contains {$0.imageName == current.imageName}}
                guard self.persist(previousItems,groups:previousGroups,recordUndo:false) else {return false}
                for item in removed {if let url=self.imageURL(item) {try? FileManager.default.removeItem(at:url)}}
                return true
            }}
            error = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
enum HomeTool: String, Identifiable {
    case rates = "人民币汇率", world = "世界时间"
    var id: String { rawValue }
}

struct QuickToolsPanel: View {
    let tool: HomeTool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tool.rawValue).font(.headline); Spacer(); Button("完成") { dismiss() } }
            switch tool {
            case .rates: ExchangeRatesView()
            case .world: WorldClockView()
            }
        }.padding(20).frame(width: tool == .rates ? 470 : 560).fixedSize(horizontal:false,vertical:true)
    }
}
enum QuickTextDrag {
    static let prefix = "biu-quick-text:"
    static func identifier(_ values: [String]) -> UUID? {
        guard values.count == 1, let value = values.first, value.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
    }
}

struct QuickTextsView: View {
    @ObservedObject var model: QuickTextLibrary
    @State private var editing: QuickText?
    @State private var copied: UUID?
    @State private var selectionInput = TextRowSelectionInput()
    @State private var selected: UUID?
    @State private var deleteConfirmationID: UUID?
    @State private var query = ""
    @State private var group: String? = nil
    @State private var dropTargetGroup: String?
    @State private var groupAlertPresented=false
    @State private var groupNameInput=""
    @State private var groupBeingRenamed:String?
    @State private var dropTargetItem: UUID?
    @State private var dropAfter = false
    @State private var conditions = FilterCancellation<String>()
    @FocusState private var listFocused: Bool

    private var matches: [QuickText] {
        model.items.filter { item in
            (group == nil || (item.group ?? "") == group)
            && (query.isEmpty || item.title.localizedStandardContains(query) || item.text.localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("增加文本", systemImage: "plus") { editing = QuickText(title: "", text: "", group: nil) }
                Spacer()
                InlineSearchField(prompt:"搜索",text:$query).frame(maxWidth:140)
            }
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            groupButton("全部", value: nil).id("all")
                            groupButton("未分组", value: "").id("group:")
                                .contextMenu {Button("新建分组…") {editGroup()}}
                            ForEach(model.groups, id: \.self) { name in
                                groupButton(name, value: name).id("group:" + name)
                                    .contextMenu {
                                        Button("新建分组…") {editGroup()}
                                        Button("重命名分组…") {editGroup(name)}
                                        Button("删除分组，文本移至未分组…",role:.destructive) {confirmGroupRemoval(name,deleteContents:false)}
                                        Button("删除分组和组内文本…",role:.destructive) {confirmGroupRemoval(name,deleteContents:true)}
                                    }

                            }
                        }.padding(.vertical, 3)
                    }
                    .onChange(of: group) {
                        proxy.scrollTo(group.map { "group:" + $0 } ?? "all", anchor: .center)
                    }
                }.frame(height: 32)

            }
            if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无常用文本" : "没有找到匹配文本",
                                       systemImage: "text.quote")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                row(item, number: index + 1).id(item.id)
                            }
                        }.padding(.horizontal, 8)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .defaultFocus($listFocused, true)
                    .onKeyPress(keys:[.delete,.deleteForward],phases:.down) { _ in
                        guard let id=selected else {return .ignored};deleteConfirmationID=id;return .handled
                    }
                    .onKeyPress(.space,phases:.down) { _ in
                        guard let id=deleteConfirmationID,let item=model.items.first(where:{$0.id == id}) else {return .ignored}
                        deleteConfirmationID=nil;model.remove(item);return .handled
                    }
                    .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
                    .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                    .onKeyPress(.return, phases: .down) { _ in
                        if let id=deleteConfirmationID,let item=model.items.first(where:{$0.id == id}) {deleteConfirmationID=nil;model.remove(item);return .handled}
                        guard let item = matches.first(where: { $0.id == selected }) else { return .ignored }
                        copy(item)
                        return .handled
                    }
                }
            }
            Text(model.error.isEmpty ? "拖动排序或移入分组 · 回车或双击拷贝" : model.error)
                .font(.caption).foregroundStyle(model.error.isEmpty ? Color.secondary : Color.red)
        }
        .background(TextListKeyboard(requestDelete:{
            guard let id=selected else {return false};deleteConfirmationID=id;return true
        },confirmDelete:{
            guard let id=deleteConfirmationID,let item=model.items.first(where:{$0.id == id}) else {return false}
            deleteConfirmationID=nil;model.remove(item);return true
        }))
        .onAppear { revealRequestedText() }
        .onChange(of: model.revealID) { revealRequestedText() }
        .onChange(of: query) { selected = nil; conditions.record("query", active: !query.isEmpty) }
        .onChange(of: group) { selected = nil; conditions.record("group", active: group != nil) }
        .onExitCommand {
            if deleteConfirmationID != nil { deleteConfirmationID = nil; return }
            if let condition = conditions.pop() {
                if condition == "query" { query = "" } else { group = nil }
            } else { NSApp.keyWindow?.orderOut(nil) }
        }
        .sheet(item: $editing) { QuickTextEditor(item: $0, library:model) }
        .alert(groupBeingRenamed == nil ? "增加分组" : "重命名分组",isPresented:$groupAlertPresented) {
            TextField("分组名称",text:$groupNameInput)
            Button("取消",role:.cancel) {}
            Button(groupBeingRenamed == nil ? "增加" : "保存") {
                let saved=groupBeingRenamed.map {model.renameGroup($0,to:groupNameInput)} ?? model.createGroup(groupNameInput)
                if saved {group=groupNameInput.trimmingCharacters(in:.whitespacesAndNewlines)}
            }.disabled(groupNameInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
    }

    private func revealRequestedText() {
        guard let id = model.revealID else { return }
        editing = model.items.first { $0.id == id }
        model.revealID = nil
    }

    private func groupButton(_ title: String, value: String?) -> some View {
        Button { group = value } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(group == value ? Color.accentColor : Color.primary)
                .background(group == value ? FindDuckHighlight.soft : Color.primary.opacity(0.05),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("常用文本分组：" + title)
        .accessibilityAddTraits(group == value ? .isSelected : [])
        .overlay(Capsule().stroke(dropTargetGroup == value && value != nil ? Color.accentColor : .clear, lineWidth: 2))
        .overlay {
            QuickTextDragInteraction(id:value.flatMap {$0.isEmpty ? nil : model.groupDragID($0)},title: title, action: { _ in group = value },
                accepts: { id in value != nil && (model.items.contains(where: { $0.id == id }) || (value?.isEmpty == false && model.groups.contains {model.groupDragID($0) == id && $0 != value})) },
                drop: { id, _ in
                    guard let value else { return false }
                    if let source=model.groups.first(where:{model.groupDragID($0) == id}),!value.isEmpty {return model.moveGroup(source,before:value)}
                    return model.move(id, toGroup: value.isEmpty ? nil : value)
                }, targeted: { targeted in
                    if targeted, let value { dropTargetGroup = value }
                    else if dropTargetGroup == value { dropTargetGroup = nil }
                },contextMenu: {
                    let menu=NSMenu()
                    menu.addItem(ResultMenus.item("新建分组…") {editGroup()})
                    if let value,!value.isEmpty {
                        menu.addItem(ResultMenus.item("重命名分组…") {editGroup(value)})
                        menu.addItem(ResultMenus.item("删除分组，文本移至未分组…") {confirmGroupRemoval(value,deleteContents:false)})
                        menu.addItem(ResultMenus.item("删除分组和组内文本…") {confirmGroupRemoval(value,deleteContents:true)})
                    }
                    return menu
                })
        }
        .help(value == nil ? title : "点击筛选，或拖入常用文本")
    }

    private func confirmGroupRemoval(_ name:String,deleteContents:Bool) {
        let alert=NSAlert();alert.messageText=deleteContents ? "删除分组和组内文本？" : "删除分组并将文本移至未分组？"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"删除")
        if alert.runModal() == .alertSecondButtonReturn,model.removeGroup(name,deleteContents:deleteContents) {group=""}
    }

    private func editGroup(_ original:String? = nil) {
        groupBeingRenamed=original;groupNameInput=original ?? "";groupAlertPresented=true
    }

    private func row(_ item: QuickText, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted()).monospacedDigit()
                .foregroundStyle(Color(red: 8.0 / 255, green: 88.0 / 255, blue: 240.0 / 255))
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: item.imageName == nil ? 8 : 4) {
                HStack {
                    Text(item.title).font(.system(size:14,weight:.semibold)).lineLimit(1)
                    if group == nil, let name = item.group {
                        Text(name).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                    }
                    Spacer()
                }
                if let url=model.imageURL(item) {ClipboardImagePreview(url:url).frame(maxHeight:44,alignment:.leading)}
                Text(item.text).font(.system(size: 13)).lineLimit(item.imageName == nil ? 4 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if selected == item.id || copied == item.id {
                        Button { copy(item) } label: {
                            HStack(spacing: 3) {
                                if copied == item.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .frame(width: 15, height: 15)
                                        .background(Color(red: 0.12, green: 0.62, blue: 0.30), in: Circle())
                                } else {
                                    Image(systemName: "doc.on.doc").frame(width: 15)
                                }
                                Text("拷贝")
                            }
                        }
                            .foregroundStyle(copied == item.id ? Color.blue : Color.primary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(copied == item.id ? Color.blue.opacity(0.14) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius:6))
                            .modifier(ActionHover())
                    }
                    if selected == item.id {
                        Button { editing = item } label: { Label("编辑", systemImage: "square.and.pencil").padding(.horizontal,6).frame(height:24).background(Color.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:6)) }.modifier(ActionHover())
                        Spacer()
                        ConfirmDeleteButton(isPresented: Binding(
                            get: { deleteConfirmationID == item.id },
                            set: { shown in
                                if shown { selected = item.id; deleteConfirmationID = item.id }
                                else if deleteConfirmationID == item.id { deleteConfirmationID = nil }
                            }),
                            delete: { model.remove(item); if selected == item.id { selected = nil } }) {
                            Image(systemName: "trash").frame(width:28,height:24)
                                .background(Color.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:6))
                        }.foregroundStyle(Color.red)
                    } else {Spacer(minLength:0)}
                }.buttonStyle(.plain).font(.system(size: 11)).frame(height: 24)

            }
        }
        .font(.system(size: 12))
        .padding(8)
        .frame(height: 136, alignment: .topLeading)
        .modifier(TextRowSelectionHighlight(selected: selected == item.id))
        .onContinuousHover { phase in
            if case .active = phase { pointerSelect(item) }
        }
        .contentShape(Rectangle())
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if dropTargetItem == item.id { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
        }
        .overlay {
            QuickTextDragInteraction(id: item.id, title: item.title, trailingControlsWidth: 0,
                action: { double in
                    selectionInput.usePointer()
                    selected = item.id
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    listFocused = true
                    if double { copy(item) }
                }, hover: { if $0 { pointerSelect(item) } },
                accepts: { id in id != item.id && model.items.contains(where: { $0.id == id }) },
                drop: { id, point in model.move(id, relativeTo: item.id, after: point.y >= 68) },
                targeted: { targeted in
                    if targeted { dropTargetItem = item.id }
                    else if dropTargetItem == item.id { dropTargetItem = nil }
                }, position: { point in if let point { dropAfter = point.y >= 68 } })
        }
        .accessibilityAddTraits(selected == item.id ? .isSelected : [])
        .accessibilityAction(named: Text("拷贝")) { copy(item) }
    }

    private func pointerSelect(_ item: QuickText) {
        guard deleteConfirmationID == nil else { return }
        if selectionInput.acceptsPointer(at: NSEvent.mouseLocation), selected != item.id { selected = item.id }
    }

    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard deleteConfirmationID == nil else { return .handled }
        let items = matches
        guard !items.isEmpty else { return .ignored }
        selectionInput.useKeyboard(at: NSEvent.mouseLocation)
        let current = items.firstIndex { $0.id == selected } ?? (offset > 0 ? -1 : items.count)
        let id = items[min(max(current + offset, 0), items.count - 1)].id
        selected = id
        proxy.scrollTo(id)
        return .handled
    }

    private func copy(_ item: QuickText) {
        if model.copy(item) {
            copied = item.id
            selected = item.id
            listFocused = true
            model.error = ""
        } else {
            model.error = "拷贝失败"
        }
    }
}
struct QuickTextEditor: View {
    @State var item: QuickText
    @ObservedObject var library: QuickTextLibrary
    var initialImageData: Data? = nil
    @State private var imageData: Data?
    @State private var imagePreview: NSImage?
    @State private var saveFailed = false
    @State private var addingGroup = false
    @State private var groupName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("常用文本").font(.headline)
            if item.sourceClipboardID != nil {Text("独立副本，修改仅影响常用文本。").font(.caption).foregroundStyle(.secondary)}
            HStack(spacing:10) {
                TextField("名称",text:$item.title).textFieldStyle(.roundedBorder).accessibilityLabel("常用文本标题")
                Menu(item.group ?? "未分组") {
                    Button("未分组") {item.group=nil}
                    ForEach(library.groups,id:\.self) {name in Button(name) {item.group=name}}
                    Divider();Button("增加分组…",systemImage:"plus") {groupName="";addingGroup=true}
                }.fixedSize().accessibilityLabel("选择分组")
            }
            QuickTextContentEditor(text:$item.text,imagePasted:attachImage)
                .frame(height:imagePreview == nil ? 190 : 110)
                .overlay(RoundedRectangle(cornerRadius:6).stroke(Color.primary.opacity(0.10)))
            if let imagePreview {
                HStack(alignment:.top) {
                    Image(nsImage:imagePreview).resizable().scaledToFit().frame(maxWidth:330,maxHeight:100,alignment:.leading)
                    Spacer();Button {imageData=nil;self.imagePreview=nil;item.imageName=nil} label: {Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help("移除图片")
                }
            }
            HStack {Button("粘贴图片",systemImage:"photo.on.rectangle") {if let data=QuickTextImages.fromPasteboard() {attachImage(data)} else {library.error="剪贴板中暂无可粘贴的图片"}}}
            if saveFailed || !library.error.isEmpty {Text(library.error.isEmpty ? "保存失败，请重试" : library.error).font(.caption).foregroundStyle(.red)}
            HStack {
                Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer()
                Button("保存") {if library.save(item,imageData:imageData) {dismiss()} else {saveFailed=true}}
                    .disabled(item.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (item.text.isEmpty && imagePreview == nil))
            }
        }.padding(20).frame(width:440)
        .onAppear {
            if let initialImageData {attachImage(initialImageData)}
            else if let url=library.imageURL(item),let data=try? Data(contentsOf:url) {imagePreview=NSImage(data:data)}
        }
        .alert("增加分组",isPresented:$addingGroup) {
            TextField("分组名称",text:$groupName)
            Button("取消",role:.cancel) {}
            Button("增加") {if library.createGroup(groupName) {item.group=groupName.trimmingCharacters(in:.whitespacesAndNewlines)}}
        }
    }
    private func attachImage(_ data:Data) {
        guard let png=QuickTextImages.png(data),let preview=NSImage(data:png) else {return}
        imageData=png;imagePreview=preview
    }
}
struct ExchangeRate:Codable,Identifiable,Sendable {let date:String;let base:String;let quote:String;let rate:Double;var id:String {quote}}
enum ExchangeRates {
    static let address="https://api.frankfurter.dev/v2/rates?base=CNY&quotes=USD,EUR,JPY,GBP,HKD"
    static func load() async throws->[ExchangeRate] {
        let request=URLRequest(url:URL(string:address)!,timeoutInterval:20)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse,response.statusCode == 200 else {throw URLError(.badServerResponse)}
        let rates=try JSONDecoder().decode([ExchangeRate].self,from:data)
        guard !rates.isEmpty,rates.allSatisfy({$0.base == "CNY" && $0.rate.isFinite && $0.rate > 0}) else {throw URLError(.cannotParseResponse)}
        return rates
    }
}
enum CurrencyMath {
    static let codes=["CNY","USD","EUR","HKD","JPY","GBP"]
    static let names=["CNY":"人民币","USD":"美元","EUR":"欧元","HKD":"港币","JPY":"日元","GBP":"英镑"]
    static func amount(_ text:String)->Decimal? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count<=40,text.range(of:"^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]{0,8})?$",options:.regularExpression) != nil else {return nil}
        return Decimal(string:text.replacingOccurrences(of:",",with:""),locale:Locale(identifier:"en_US_POSIX"))
    }
    static func convert(_ amount:Decimal,from:String,to:String,rates:[ExchangeRate])->Decimal? {
        guard codes.contains(from),codes.contains(to),!amount.isNaN else {return nil}
        if from == to {return amount}
        func rate(_ code:String)->Decimal? {
            if code == "CNY" {return 1}
            guard let value=rates.first(where:{$0.base == "CNY" && $0.quote == code}),value.rate.isFinite,value.rate>0 else {return nil}
            return Decimal(string:String(value.rate),locale:Locale(identifier:"en_US_POSIX"))
        }
        guard let a=rate(from),let b=rate(to) else {return nil};let result=amount/a*b;return result.isNaN ? nil : result
    }
    static func formatted(_ value:Decimal)->String {let f=NumberFormatter();f.numberStyle = .decimal;f.minimumFractionDigits=2;f.maximumFractionDigits=4;return f.string(from:value as NSDecimalNumber) ?? "—"}
}
private struct ExchangeRatesView:View {
    @State private var rates:[ExchangeRate]=[]
    @State private var error=""
    @State private var loading=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("参考汇率 · 以1单位货币换算").font(.caption).foregroundStyle(.secondary);Spacer();Button("刷新") {Task {await refresh()}}.disabled(loading);if loading {ProgressView().controlSize(.small)}}
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.secondary)}
            VStack(alignment:.leading,spacing:9) {
                if let rate=rates.first(where:{$0.quote == "USD"}) {
                    HStack(spacing:12) {Text("人民币 CNY").frame(width:95,alignment:.leading);Text(rate.rate.formatted(.number.precision(.fractionLength(4)))+" 美元").monospacedDigit();Spacer(minLength:8);Text(rate.date).font(.caption).foregroundStyle(.secondary)}
                }
                ForEach(CurrencyMath.codes.filter {$0 != "CNY"},id:\.self) {code in
                    if let rate=rates.first(where:{$0.quote == code}) {
                        HStack(spacing:12) {Text((CurrencyMath.names[code] ?? code)+" "+code).frame(width:95,alignment:.leading);Text((1/rate.rate).formatted(.number.precision(.fractionLength(4)))+" 元").monospacedDigit();Spacer(minLength:8);Text(rate.date).font(.caption).foregroundStyle(.secondary)}
                    }
                }
            }.font(.system(size:13)).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            Divider();Text("金额换算").font(.system(size:13,weight:.semibold))
            CurrencyConversionRow(title:"第一行",source:"USD",target:"CNY",rates:rates)
            CurrencyConversionRow(title:"第二行",source:"CNY",target:"USD",rates:rates)
            HStack {Link("来源：Frankfurter",destination:URL(string:"https://frankfurter.dev/")!);Text("每日参考值，以各行日期为准").foregroundStyle(.secondary)}.font(.caption)
        }.task {await refresh()}
    }
    private func refresh() async {loading=true;defer {loading=false};do {rates=try await ExchangeRates.load();error=""} catch {self.error=rates.isEmpty ? "汇率暂时无法获取，请检查网络后重试。" : "刷新失败，仍显示上次数据。"}}
}
private struct CurrencyConversionRow:View {
    let title:String
    let rates:[ExchangeRate]
    @State private var amount="100"
    @State private var source:String
    @State private var target:String
    init(title:String,source:String,target:String,rates:[ExchangeRate]) {
        self.title=title;self.rates=rates;_source=State(initialValue:source);_target=State(initialValue:target)
    }
    private var converted:Decimal? {CurrencyMath.amount(amount).flatMap {CurrencyMath.convert($0,from:source,to:target,rates:rates)}}
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:10) {
                TextField("金额",text:$amount).textFieldStyle(.roundedBorder).frame(width:100).accessibilityLabel(title+"换算金额")
                Picker("从",selection:$source) {ForEach(CurrencyMath.codes,id:\.self) {Text((CurrencyMath.names[$0] ?? $0)+" "+$0).tag($0)}}.labelsHidden().accessibilityLabel(title+"原币种")
                Image(systemName:"arrow.right").foregroundStyle(.secondary)
                Picker("到",selection:$target) {ForEach(CurrencyMath.codes,id:\.self) {Text((CurrencyMath.names[$0] ?? $0)+" "+$0).tag($0)}}.labelsHidden().accessibilityLabel(title+"目标币种")
            }
            HStack {Text("换算结果").font(.caption).foregroundStyle(.secondary);if let converted {Text(CurrencyMath.formatted(converted)+" "+target).font(.system(size:18,weight:.semibold)).monospacedDigit().textSelection(.enabled)} else {Text(CurrencyMath.amount(amount) == nil ? "请输入有效金额" : "等待参考汇率").font(.caption).foregroundStyle(.secondary)}}
        }.padding(10).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
    }
}
struct ClockZone:Codable,Identifiable,Equatable {let name:String;let zone:String;var id:String {name+"|"+zone}}
enum WorldTimes {
    static let zones=[ClockZone(name:"北京",zone:"Asia/Shanghai"),ClockZone(name:"东京",zone:"Asia/Tokyo"),ClockZone(name:"新加坡",zone:"Asia/Singapore"),ClockZone(name:"伦敦",zone:"Europe/London"),ClockZone(name:"巴黎",zone:"Europe/Paris"),ClockZone(name:"纽约",zone:"America/New_York"),ClockZone(name:"洛杉矶",zone:"America/Los_Angeles"),ClockZone(name:"悉尼",zone:"Australia/Sydney")]
    static let suggested=[ClockZone(name:"香港",zone:"Asia/Hong_Kong"),ClockZone(name:"台北",zone:"Asia/Taipei"),ClockZone(name:"首尔",zone:"Asia/Seoul"),ClockZone(name:"曼谷",zone:"Asia/Bangkok"),ClockZone(name:"迪拜",zone:"Asia/Dubai"),ClockZone(name:"柏林",zone:"Europe/Berlin"),ClockZone(name:"莫斯科",zone:"Europe/Moscow"),ClockZone(name:"温哥华",zone:"America/Vancouver"),ClockZone(name:"旧金山",zone:"America/Los_Angeles"),ClockZone(name:"芝加哥",zone:"America/Chicago"),ClockZone(name:"多伦多",zone:"America/Toronto"),ClockZone(name:"奥克兰",zone:"Pacific/Auckland")]
    static func formatted(_ date:Date,zone:String,format:String="MM-dd HH:mm:ss")->String {let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.dateFormat=format;f.timeZone=TimeZone(identifier:zone);return f.string(from:date)}
    static func date(month:Int,day:Int,hour:Int,minute:Int,zone:String,reference:Date=Date())->Date? {
        guard let timeZone=TimeZone(identifier:zone),(1...12).contains(month),(1...31).contains(day),(0...23).contains(hour),(0...59).contains(minute) else {return nil}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        let year=calendar.component(.year,from:reference)
        guard let value=calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute)) else {return nil}
        let parts=calendar.dateComponents([.year,.month,.day,.hour,.minute],from:value)
        guard parts.year == year,parts.month == month,parts.day == day,parts.hour == hour,parts.minute == minute else {return nil};return value
    }
}
@MainActor final class WorldClockLibrary:ObservableObject {
    @Published private(set) var custom:[ClockZone]=[]
    @Published private(set) var hiddenDefaults:Set<String>=[]
    private let defaults:UserDefaults
    private let key="findduck.world-clock.custom-cities"
    private let hiddenKey="findduck.world-clock.hidden-default-cities"
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        hiddenDefaults=Set(defaults.stringArray(forKey:hiddenKey) ?? [])
        if let data=defaults.data(forKey:key),let saved=try? JSONDecoder().decode([ClockZone].self,from:data) {
            custom=saved.filter {TimeZone(identifier:$0.zone) != nil && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        }
    }
    var zones:[ClockZone] {[WorldTimes.zones[0]] + WorldTimes.zones.dropFirst().filter {!hiddenDefaults.contains($0.id)} + custom.filter {$0.id != WorldTimes.zones[0].id}}
    func validSelection(_ preferred:String,excluding:String?=nil)->String {
        if zones.contains(where:{$0.id == preferred}) {return preferred}
        return zones.first(where:{$0.id != excluding})?.id ?? WorldTimes.zones[0].id
    }
    @discardableResult func add(name:String,zone:String)->Bool {
        let city=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !city.isEmpty,city.count<=40,TimeZone(identifier:zone) != nil,
              !zones.contains(where:{$0.name.localizedCaseInsensitiveCompare(city) == .orderedSame}) else {return false}
        custom.append(ClockZone(name:city,zone:zone));persist();return true
    }
    func remove(_ city:ClockZone) {
        guard city.id != WorldTimes.zones[0].id,zones.count > 1 else {return}
        if WorldTimes.zones.contains(city) {hiddenDefaults.insert(city.id)}
        else {custom.removeAll {$0.id == city.id}}
        persist()
    }
    private func persist() {
        if let data=try? JSONEncoder().encode(custom) {defaults.set(data,forKey:key)}
        defaults.set(hiddenDefaults.sorted(),forKey:hiddenKey)
    }
}
private struct WorldClockView:View {
    @StateObject private var library=WorldClockLibrary()
    @State private var source=WorldTimes.zones[0].id
    @State private var target=WorldTimes.zones[5].id
    @State private var adding=false
    @State private var month=""
    @State private var day=""
    @State private var hour=""
    @State private var minute=""
    private var sourceZone:String {library.zones.first(where:{$0.id == source})?.zone ?? WorldTimes.zones[0].zone}
    private var targetZone:String {library.zones.first(where:{$0.id == target})?.zone ?? WorldTimes.zones[5].zone}
    private var converted:Date? {guard let m=Int(month),let d=Int(day),let h=Int(hour),let n=Int(minute) else {return nil};return WorldTimes.date(month:m,day:d,hour:h,minute:n,zone:sourceZone)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("城市时间").font(.system(size:13,weight:.semibold));Spacer();Button {adding=true} label: {Label("增加城市",systemImage:"plus")}}
            ScrollView {
                TimelineView(.periodic(from:.now,by:30)) {context in
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:4),spacing:10) {
                        ForEach(library.zones) {zone in
                            VStack(alignment:.leading,spacing:4) {
                                HStack(spacing:3) {Text(zone.name).lineLimit(1).font(.caption).foregroundStyle(.secondary);Spacer(minLength:0)
                                    if zone.id == WorldTimes.zones[0].id {Image(systemName:"pin.fill").font(.system(size:9)).foregroundStyle(.tertiary)}}
                                Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"HH:mm")).font(.system(size:17,weight:.medium)).monospacedDigit()
                                Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"MM月dd日")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(9).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                                .contextMenu {if zone.id != WorldTimes.zones[0].id {Button("删除城市",role:.destructive) {remove(zone)}}}
                        }
                    }
                }
            }.frame(height:CGFloat(min(3,(library.zones.count+3)/4))*74 + CGFloat(min(3,(library.zones.count+3)/4)-1)*10)
            Divider();Text("时间换算").font(.system(size:13,weight:.semibold))
            HStack {Picker("从",selection:$source) {ForEach(library.zones) {Text($0.name).tag($0.id)}};Button {swapCities()} label: {Image(systemName:"arrow.left.arrow.right")}.buttonStyle(.bordered).accessibilityLabel("交换两边城市");Picker("到",selection:$target) {ForEach(library.zones) {Text($0.name).tag($0.id)}}}
            HStack(spacing:7) {
                dateField("月份",text:$month);Text("月");dateField("日期",text:$day);Text("日");dateField("小时",text:$hour);Text(":");dateField("分钟",text:$minute);Spacer();Button("现在") {now()}
            }.font(.system(size:13)).monospacedDigit()
            VStack(alignment:.leading,spacing:5) {Text("换算结果").font(.caption).foregroundStyle(.secondary);Text(converted.map {WorldTimes.formatted($0,zone:targetZone,format:"MM月dd日 HH:mm")} ?? "请输入有效日期和时间").font(.system(size:21,weight:.medium)).monospacedDigit().textSelection(.enabled)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            Text("日期按当前年份计算，自动处理所选时区的夏令时。").font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            source=library.validSelection(source)
            target=library.validSelection(target,excluding:source)
            now()
        }.sheet(isPresented:$adding) {AddClockCityView(library:library)}
    }
    private func dateField(_ title:String,text:Binding<String>)->some View {TextField(title,text:text).textFieldStyle(.roundedBorder).frame(width:42).multilineTextAlignment(.center).accessibilityLabel(title)}
    private func now() {let value=Date();month=WorldTimes.formatted(value,zone:sourceZone,format:"MM");day=WorldTimes.formatted(value,zone:sourceZone,format:"dd");hour=WorldTimes.formatted(value,zone:sourceZone,format:"HH");minute=WorldTimes.formatted(value,zone:sourceZone,format:"mm")}
    private func swapCities() {
        let originalSource=source
        if let instant=converted {
            month=WorldTimes.formatted(instant,zone:targetZone,format:"MM")
            day=WorldTimes.formatted(instant,zone:targetZone,format:"dd")
            hour=WorldTimes.formatted(instant,zone:targetZone,format:"HH")
            minute=WorldTimes.formatted(instant,zone:targetZone,format:"mm")
        }
        source=target;target=originalSource
    }
    private func remove(_ zone:ClockZone) {
        library.remove(zone)
        if source == zone.id {source=library.zones.first?.id ?? WorldTimes.zones[0].id}
        if target == zone.id {target=library.zones.last?.id ?? WorldTimes.zones[0].id}
    }
}
private struct AddClockCityView:View {
    @ObservedObject var library:WorldClockLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var search=""
    @State private var selected=""
    @State private var error=""
    private var matches:[ClockZone] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else {return WorldTimes.suggested}
        let normalized=query.replacingOccurrences(of:" ",with:"_")
        let suggestions=WorldTimes.suggested.filter {$0.name.localizedCaseInsensitiveContains(query) || $0.zone.localizedCaseInsensitiveContains(normalized)}
        let known=TimeZone.knownTimeZoneIdentifiers.filter {identifier in identifier.localizedCaseInsensitiveContains(normalized) && !suggestions.contains(where:{$0.zone == identifier})}
        return suggestions+known.prefix(max(0,30-suggestions.count)).map {ClockZone(name:$0.split(separator:"/").last.map {String($0).replacingOccurrences(of:"_",with:" ")} ?? $0,zone:$0)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("增加世界时间城市").font(.headline)
            InlineSearchField(prompt:"搜索城市或时区，例如：温哥华、Vancouver",text:$search,accessibilityName:"搜索城市或时区",clearLabel:"清除城市搜索")
            Text("先从列表选择城市，Biu会自动匹配时区。").font(.caption).foregroundStyle(.secondary)
            if !selected.isEmpty {
                TextField("显示名称（可改）",text:$name).accessibilityLabel("城市显示名称")
                Text("显示名称只影响卡片文字；实际时间按已选时区 "+selected+" 计算。").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {LazyVStack(spacing:2) {ForEach(matches) {city in
                Button {selected=city.zone;if name.isEmpty {name=city.name}} label: {
                    HStack {Text(city.name);Text(city.zone).font(.caption).foregroundStyle(.secondary);Spacer();Text(WorldTimes.formatted(Date(),zone:city.zone,format:"HH:mm")).foregroundStyle(.secondary)}.padding(.horizontal,8).padding(.vertical,5).background(selected == city.zone ? FindDuckHighlight.soft : Color.clear,in:RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain).accessibilityLabel(city.name+"，"+city.zone)
            }}}.frame(height:210)
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red)}
            HStack {Spacer();Button("取消") {dismiss()};Button("添加") {if library.add(name:name,zone:selected) {dismiss()} else {error="请输入城市名称并选择时区；城市名称不能重复。"}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || selected.isEmpty)}
        }.padding(20).frame(width:440)
    }
}
