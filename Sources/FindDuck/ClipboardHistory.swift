import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardEntry:Codable,Identifiable,Equatable {
    enum Kind:String,Codable {case text,image,file}
    var id=UUID()
    let kind:Kind
    var text:String?
    let imageName:String?
    var filePaths:[String]? = nil
    var fingerprint:String
    var captured:Date=Date()
    var favorite: Bool? = nil
    var sourceBundleID: String? = nil
    var richText: Data? = nil

    var webURL: URL? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              !value.contains(where: \.isWhitespace) else { return nil }
        return url
    }
}

@MainActor final class ClipboardHistoryStore:ObservableObject {
    @Published private(set) var items:[ClipboardEntry]=[] { didSet { revision &+= 1 } }
    private(set) var revision: UInt64 = 0
    @Published var error=""
    private let directory:URL
    private let pasteboard:NSPasteboard
    private var timer:Timer?
    private var lastChangeCount:Int = -1
    private let history:UserActionHistory
    private let capacity: Int
    init(directory:URL?=nil,pasteboard:NSPasteboard = .general,monitor:Bool=true, capacity: Int = 1_000_000_000,history:UserActionHistory? = nil) {
        self.history=history ?? .shared
        self.capacity = capacity
        self.directory=directory ?? BiuStorage.directory.appendingPathComponent("clipboard-history",isDirectory:true)
        self.pasteboard=pasteboard
        self.lastChangeCount=pasteboard.changeCount
        if let data=try? Data(contentsOf:self.directory.appendingPathComponent("entries.json")),
           let saved=try? JSONDecoder().decode([ClipboardEntry].self,from:data) {
            items = saved.filter { entry in
                entry.kind != .image || imageURL(for: entry).map { FileManager.default.fileExists(atPath: $0.path) } == true
            }
            if items.count != saved.count || storageSize(items) > capacity { commit(items) }
        }
        if monitor {
            timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) {[weak self] _ in Task { @MainActor in self?.capture() }}
        }
    }
    func imageURL(for entry:ClipboardEntry)->URL? {entry.imageName.map {directory.appendingPathComponent($0)}}
    func saveSourceURLs(for entry: ClipboardEntry) -> [URL] {
        switch entry.kind {
        case .text: return []
        case .image: return imageURL(for: entry).map { [$0] } ?? []
        case .file: return (entry.filePaths ?? []).map { URL(fileURLWithPath: $0) }
        }
    }

    func save(_ entry: ClipboardEntry, to destination: URL) throws {
        let sources = saveSourceURLs(for: entry)
        guard let source = sources.first, sources.count == 1 else { throw SaveError.invalidEntry }
        guard FileManager.default.fileExists(atPath: source.path) else { throw SaveError.sourceMissing }
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".findduck-save-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staged) }
            try manager.copyItem(at: source, to: staged)
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.copyItem(at: source, to: destination)
        }
    }

    func saveFiles(_ entry: ClipboardEntry, into directory: URL) throws {
        let sources = saveSourceURLs(for: entry)
        guard entry.kind == .file, sources.count > 1 else { throw SaveError.invalidEntry }
        let manager = FileManager.default
        for source in sources {
            guard manager.fileExists(atPath: source.path) else { throw SaveError.sourceMissing }
        }
        for source in sources {
            let name = source.lastPathComponent
            var destination = directory.appendingPathComponent(name)
            var suffix = 2
            while manager.fileExists(atPath: destination.path) {
                let extensionName = source.pathExtension
                let stem = source.deletingPathExtension().lastPathComponent
                let candidate = "\(stem) \(suffix)" + (extensionName.isEmpty ? "" : ".\(extensionName)")
                destination = directory.appendingPathComponent(candidate)
                suffix += 1
            }
            try manager.copyItem(at: source, to: destination)
        }
    }

    enum SaveError: LocalizedError {
        case invalidEntry, sourceMissing
        var errorDescription: String? {
            switch self {
            case .invalidEntry: "这条记录无法另存为"
            case .sourceMissing: "原文件已不存在，无法另存为"
            }
        }
    }
    func capture() {
        let count=pasteboard.changeCount
        guard count != lastChangeCount else {return}
        lastChangeCount=count
        let types=Set(pasteboard.types ?? [])
        let privateTypes=["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType"]
        guard !privateTypes.contains(where:{types.contains(NSPasteboard.PasteboardType($0))}) else {return}
        let source = pasteboard === NSPasteboard.general ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
        let paths=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []).filter(\.isFileURL).map(\.path)
        if !paths.isEmpty {
            let fingerprint=Self.fingerprint(Data(paths.joined(separator:"\n").utf8))
            if let existing=items.first(where:{$0.fingerprint == fingerprint}) {promote(existing, source: source);return}
            insert(ClipboardEntry(kind:.file,text:nil,imageName:nil,filePaths:paths,fingerprint:fingerprint,sourceBundleID:source))
        } else if (types.contains(.png) || types.contains(.tiff)),let png=pasteboard.data(forType:.png) ?? {
            guard let image=NSImage(pasteboard:pasteboard),let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff) else {return nil}
            return rep.representation(using:.png,properties:[:])
        }() {
            let fingerprint=Self.fingerprint(png)
            if let existing=items.first(where:{$0.fingerprint == fingerprint}) {promote(existing, source: source);return}
            guard png.count < capacity else { error = "图片超过剪贴板历史容量"; return }
            let id=UUID(),filename=id.uuidString+".png"
            do {try ensureDirectory();try png.write(to:directory.appendingPathComponent(filename),options:.atomic);try privateFile(directory.appendingPathComponent(filename))}
            catch {try? FileManager.default.removeItem(at:directory.appendingPathComponent(filename));self.error="图片记录保存失败："+error.localizedDescription;return}
            insert(ClipboardEntry(id:id,kind:.image,text:nil,imageName:filename,fingerprint:fingerprint,sourceBundleID:source))
        } else if let value=pasteboard.string(forType:.string),!value.isEmpty {
            let fingerprint=Self.fingerprint(Data(value.utf8))
            let richText = pasteboard.data(forType: .rtf)
            if var existing = items.first(where: { $0.fingerprint == fingerprint }) {
                existing.richText = richText
                promote(existing, source: source)
                return
            }
            insert(ClipboardEntry(kind: .text, text: value, imageName: nil, fingerprint: fingerprint,
                                  sourceBundleID: source, richText: richText))
        }
    }
    @discardableResult
    func copy(_ entry: ClipboardEntry, to board: NSPasteboard = .general, plainText: Bool = false) -> Bool {
        let item = NSPasteboardItem()
        let objects: [NSPasteboardWriting]
        switch entry.kind {
        case .text:
            guard let value = entry.text, item.setString(value, forType: .string) else { return false }
            if !plainText, let richText = entry.richText { item.setData(richText, forType: .rtf) }
            objects = [item]
        case .file:
            guard let paths = entry.filePaths, !paths.isEmpty else { return false }
            objects = paths.map { URL(fileURLWithPath: $0) as NSURL }
        case .image:
            guard let url = imageURL(for: entry), let data = try? Data(contentsOf: url),
                  item.setData(data, forType: .png) else { return false }
            objects = [item]
        }
        board.clearContents()
        let written = board.writeObjects(objects)
        if board === pasteboard { lastChangeCount = board.changeCount }
        return written
    }

    func clearHistory() { commit([]) }

    func remove(_ entry: ClipboardEntry) {
        guard let position=items.firstIndex(where:{$0.id == entry.id}) else {return}
        let backup:UndoMediaBackup
        do {backup=try UndoMediaBackup(imageURL(for:entry).map {[$0]} ?? [])} catch {self.error="无法备份删除内容";return}
        if commit(items.filter { $0.id != entry.id }) {
            history.record("删除剪贴板记录",cost:backup.byteCount) { [weak self] in
                guard let self else {return false}
                do {try backup.restore()} catch {return false}
                var restored=self.items;restored.removeAll {$0.id == entry.id};restored.insert(entry,at:min(position,restored.count))
                return self.commit(restored,keeping:entry.id)
            }
        }
    }

    @discardableResult func updateText(_ entry:ClipboardEntry,text:String)->Bool {
        guard entry.kind == .text,!text.isEmpty,let index=items.firstIndex(where:{$0.id == entry.id}) else {error="这条记录已不存在或文本为空";return false}
        let previous=items[index]
        guard previous.text != text else {return true}
        var updated=items
        updated[index].text=text
        updated[index].fingerprint=Self.fingerprint(Data(text.utf8))
        updated[index].richText=nil
        guard commit(updated) else {return false}
        history.record("编辑剪贴板文本") { [weak self] in
            guard let self,let current=self.items.firstIndex(where:{$0.id == previous.id}) else {return false}
            var restored=self.items;restored[current].text=previous.text;restored[current].fingerprint=previous.fingerprint;restored[current].richText=previous.richText
            return self.commit(restored)
        }
        return true
    }

    func toggleFavorite(_ entry: ClipboardEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = items
        updated[index].favorite = updated[index].favorite != true
        if commit(updated) {history.record("收藏") { [weak self] in
            guard let self,let i=self.items.firstIndex(where:{$0.id == entry.id}) else {return false}
            var restored=self.items;restored[i].favorite=entry.favorite;return self.commit(restored)
        }}
    }

    private func promote(_ entry: ClipboardEntry, source: String?) {
        var updated = entry
        updated.captured = Date()
        updated.sourceBundleID = source
        insert(updated)
    }

    private func insert(_ entry: ClipboardEntry) {
        let proposed = [entry] + items.filter { $0.id != entry.id }
        guard commit(proposed, keeping: entry.id) else {
            if !items.contains(where: { $0.id == entry.id }) { removeImage(entry) }
            return
        }
    }

    private func imageSize(_ entry: ClipboardEntry) -> Int {
        guard let url = imageURL(for: entry) else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func storageSize(_ entries: [ClipboardEntry]) -> Int {
        let indexSize = (try? JSONEncoder().encode(entries).count) ?? 0
        return indexSize + entries.reduce(0) { $0 + imageSize($1) }
    }

    @discardableResult private func commit(_ proposed: [ClipboardEntry], keeping newest: UUID? = nil) -> Bool {
        do {
            let encoder = JSONEncoder()
            var kept = proposed
            var data = try encoder.encode(kept)
            let imageSizes = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, imageSize($0)) })
            var total = data.count + imageSizes.values.reduce(0, +)
            if total > capacity {
                var evicted = Set<UUID>()
                for entry in kept.reversed() where entry.favorite != true && entry.id != newest {
                    total -= try encoder.encode(entry).count + (imageSizes[entry.id] ?? 0)
                    // Removing a row also removes one comma unless it was the last row.
                    if kept.count - evicted.count > 1 { total -= 1 }
                    evicted.insert(entry.id)
                    if total <= capacity { break }
                }
                guard total <= capacity else {
                    error = "剪贴板历史空间不足，请删除部分记录后再试"
                    return false
                }
                kept.removeAll { evicted.contains($0.id) }
                data = try encoder.encode(kept)
            }
            try ensureDirectory()
            let url = directory.appendingPathComponent("entries.json")
            try data.write(to: url, options: .atomic)
            let retained = Set(kept.map(\.id))
            for entry in items where !retained.contains(entry.id) { removeImage(entry) }
            items = kept
            try privateFile(url)
            error = ""
            return true
        } catch {
            self.error = "剪贴板历史保存失败：" + error.localizedDescription
            return false
        }
    }

    private func removeImage(_ entry:ClipboardEntry) {if let url=imageURL(for:entry) {try? FileManager.default.removeItem(at:url)}}
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
    }
    private func privateFile(_ url:URL) throws {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    private static func fingerprint(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
}

struct ClipboardSession: Identifiable {
    let entries: [ClipboardEntry]
    var id: UUID { entries[entries.count - 1].id }

    enum DayPart: String {
        case morning = "早上", afternoon = "下午", evening = "晚上"
        static func at(_ date: Date, calendar: Calendar) -> DayPart {
            switch calendar.component(.hour, from: date) {
            case 0..<12: return .morning
            case 12..<18: return .afternoon
            default: return .evening
            }
        }
    }

    static func group(_ entries: [ClipboardEntry], now: Date = Date(), calendar: Calendar = .current) -> [ClipboardSession] {
        var batches: [[ClipboardEntry]] = []
        for entry in entries.sorted(by: { $0.captured > $1.captured }) {
            if let previous = batches.last?.last,
               calendar.isDate(previous.captured, inSameDayAs: entry.captured) {
                let today = calendar.isDate(entry.captured, inSameDayAs: now)
                let joins = today ? previous.captured.timeIntervalSince(entry.captured) <= 600 :
                    DayPart.at(previous.captured, calendar: calendar) == DayPart.at(entry.captured, calendar: calendar)
                if joins { batches[batches.count - 1].append(entry); continue }
            }
            batches.append([entry])
        }
        return batches.map { ClipboardSession(entries: $0) }
    }

    var timeRange: String { title() }
    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        let first = entries[entries.count - 1].captured
        let last = entries[0].captured
        let today = calendar.isDate(first, inSameDayAs: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map {
            calendar.isDate(first, inSameDayAs: $0)
        } ?? false
        let date = DateFormatter(); date.calendar = calendar; date.timeZone = calendar.timeZone
        date.dateFormat = "M月d日"
        let day = today ? "今天" : yesterday ? "昨天" : date.string(from: first)
        if !today { return "\(day) · \(DayPart.at(first, calendar: calendar).rawValue)" }
        let time = DateFormatter(); time.calendar = calendar; time.timeZone = calendar.timeZone
        time.dateStyle = .none; time.timeStyle = .short
        let start = time.string(from: first), end = time.string(from: last)
        return start == end ? "\(day) · \(start)" : "\(day) · \(start)–\(end)"
    }

}

enum ClipboardCopyFeedback: String, CaseIterable, Identifiable {
    case text = "行右侧文字"
    case icon = "行右侧图标"
    case center = "行中央动画"
    var id: Self { self }
}

struct ClipboardHistoryView:View {
    @ObservedObject var store:ClipboardHistoryStore
    @ObservedObject var quickTexts: QuickTextLibrary
    @State private var saveDraft: SaveDraft?
    @Environment(\.openWindow) private var openWindow
    @State private var copyStatus = ClipboardCopyStatus()
    @State private var openedEntries=Set<UUID>()
    @State private var savedFiles = Set<UUID>()
    @State private var interactedIDs=Set<UUID>()
    @State private var editingEntry:ClipboardEntry?

    private struct SaveDraft: Identifiable {
        let id: UUID
        let text: QuickText
        var imageData: Data? = nil
    }
    @AppStorage("findduckClipboardCopyFeedback") private var copyFeedback = ClipboardCopyFeedback.center
    @State private var copied = ""
    @State private var copiedEntryID: UUID?
    @State private var selectionInput = TextRowSelectionInput()
    @State private var conditions = FilterCancellation<String>()
    @State private var rowSelection = ClipboardRowSelection()
    private var selected: UUID? {
        get { rowSelection.selectedID }
        nonmutating set { rowSelection.select(newValue) }
    }
    @State private var copyFeedbackID: UUID?
    @FocusState private var listFocused: Bool
    @State private var query=""
    @State private var filter:ClipboardFilter = .all
    @State private var period: ClipboardHistoryPeriod = .all
    @State private var groupingDate = Date()
    @State private var visibleCache = MemoizedValue<ClipboardListKey, [ClipboardEntry]>()

    private func listKey(expansion: [UUID: Bool] = [:]) -> ClipboardListKey {
        ClipboardListKey(revision: store.revision, query: query, filter: filter.rawValue,
                         period: period.rawValue, day: Calendar.current.startOfDay(for: groupingDate), expansion: expansion)
    }

    private enum ClipboardFilter: String, CaseIterable, Identifiable {
        case all = "全部", text = "文字", links = "链接", images = "图片", files = "文件", favorites = "收藏"
        var id: String { rawValue }
    }

    private var visible: [ClipboardEntry] {
        visibleCache.value(for: listKey()) {
            let now = Date()
            let calendar = Calendar.current
            return store.items.filter { entry in
                guard period.includes(entry.captured, now: now, calendar: calendar) else { return false }
                if !query.isEmpty {
                    let text = entry.text ?? entry.filePaths?.joined(separator: " ") ?? "图片"
                    if !text.localizedStandardContains(query) { return false }
                }
                return switch filter {
                case .all: true
                case .text: entry.kind == .text && entry.webURL == nil
                case .links: entry.webURL != nil
                case .images: entry.kind == .image
                case .files: entry.kind == .file
                case .favorites: entry.favorite == true
                }
            }
        }
    }
    var body: some View {
        let matches = visible
        let navigable = matches
        ScrollViewReader { proxy in
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                ForEach(ClipboardFilter.allCases) {option in Button {filter=option} label: {Text(option.rawValue).font(.system(size:11,weight:.medium)).padding(.horizontal,8).padding(.vertical,5).foregroundStyle(filter == option ? Color.accentColor : Color.primary).background(filter == option ? FindDuckHighlight.soft : Color.primary.opacity(0.05),in:Capsule())}.buttonStyle(.plain)}
                Spacer(minLength:0)
                InlineSearchField(prompt:"搜索",text:$query).frame(minWidth:80,maxWidth:120)
                Menu {
                    Picker("时间筛选",selection:$period) {
                        ForEach(ClipboardHistoryPeriod.allCases) {option in Text(option.rawValue).tag(option)}
                    }.pickerStyle(.inline)
                } label: {
                    if period == .all {Image(systemName:"calendar").foregroundStyle(.secondary)}
                    else {Text(period.rawValue).foregroundStyle(Color.accentColor)}
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("时间筛选")
                .accessibilityValue(period.rawValue)
                .help(period.rawValue)
            }
            if matches.isEmpty {ContentUnavailableView(store.items.isEmpty ? "暂无剪贴板记录" : "这个分类暂无记录",systemImage:"doc.on.clipboard",description:Text("拷贝文字、链接、图片或文件后会出现在这里。")).frame(maxWidth: .infinity, maxHeight: .infinity)}
            else { historyList(matches: matches) }
            HStack {Text("↑↓ 选择 · 回车或双击拷贝").font(.caption).foregroundStyle(.secondary);Spacer();if !store.error.isEmpty {Text(store.error).font(.caption).foregroundStyle(.red)}}
        }
        .sheet(item: $saveDraft) { draft in
            QuickTextEditor(item:draft.text,library:quickTexts,initialImageData:draft.imageData)
        }
        .sheet(item:$editingEntry) { entry in ClipboardTextEditor(entry:entry,store:store) }
        .onAppear { groupingDate = Date() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            if !Calendar.current.isDate(date, inSameDayAs: groupingDate) {
                groupingDate = date; selected = nil
            }
        }
        .onChange(of: store.revision) { rowSelection.retain(Set(store.items.map(\.id))) }
        .background(TextListKeyboard(requestDelete:{
            guard let id=selected else {return false};rowSelection.setConfirmation(true,for:id);return true
        },confirmDelete:{
            guard let id=rowSelection.confirmingID,let entry=store.items.first(where:{$0.id == id}) else {return false}
            rowSelection.setConfirmation(false,for:id);store.remove(entry);return true
        }))
        .onChange(of: query) { selected = nil; conditions.record("query", active: !query.isEmpty) }
        .onChange(of: filter) { selected = nil; listFocused = true; conditions.record("filter", active: filter != .all) }
        .onChange(of: period) { selected = nil; conditions.record("period", active: period != .all) }
        .onExitCommand {
            if let id = rowSelection.confirmingID {
                rowSelection.setConfirmation(false, for: id)
                return
            }
            if let condition = conditions.pop() {
                switch condition {
                case "query": query = ""
                case "filter": filter = .all
                default: period = .all
                }
            } else { selected = nil; NSApp.keyWindow?.orderOut(nil) }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            if copyStatus.invalidateIfChanged(NSPasteboard.general.changeCount) {
                copiedEntryID = nil
                copyFeedbackID = nil
            }
        }
        .onChange(of: copyFeedback) { copiedEntryID = nil; copyFeedbackID = nil }
        .task(id: copyFeedbackID) {
            guard copyFeedbackID != nil, copyFeedback == .center else { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.16)) { copiedEntryID = nil }
        }
            .onKeyPress(keys:[.delete,.deleteForward],phases:.down) { _ in
                guard let id=selected else {return .ignored};rowSelection.setConfirmation(true,for:id);return .handled
            }
            .onKeyPress(.space,phases:.down) { _ in
                guard let id=rowSelection.confirmingID,let entry=store.items.first(where:{$0.id == id}) else {return .ignored}
                rowSelection.setConfirmation(false,for:id);store.remove(entry);return .handled
            }
            .onKeyPress(.downArrow) { moveSelection(1, entries: navigable, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(-1, entries: navigable, proxy: proxy) }
            .onKeyPress(.return, phases: .down) { _ in
                if let id=rowSelection.confirmingID,let entry=store.items.first(where:{$0.id == id}) {rowSelection.setConfirmation(false,for:id);store.remove(entry);return .handled}
                guard let entry = navigable.first(where: { $0.id == selected }) else { return .ignored }
                copy(entry, keepSelection: true)
                return .handled
            }
        }
    }
    private func historyList(matches: [ClipboardEntry]) -> some View {
        List {historyRows(matches)}
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focusable().focusEffectDisabled().focused($listFocused).defaultFocus($listFocused,true)
    }

    private func historyRows(_ entries: [ClipboardEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { number, entry in
            ClipboardSelectableRow(flag: rowSelection.flag(for: entry.id)) { isSelected in
                historyRow(entry, number: number + 1, isSelected: isSelected)
            }
                .overlay {
                    if copyFeedback == .center, copiedEntryID == entry.id {
                        copyIndicator
                            .padding(.horizontal, 16)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    if case .active = phase, selectionInput.acceptsPointer(at: NSEvent.mouseLocation), selected != entry.id {
                        selected = entry.id
                    }
                }
                .onTapGesture(count: 2) { selectionInput.usePointer(); selected = entry.id; copy(entry, keepSelection: true) }
                .onTapGesture { selectionInput.usePointer(); selected = entry.id; focusList() }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
                        .padding(.horizontal, 8).allowsHitTesting(false)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .id(entry.id)
        }
    }

    private func moveSelection(_ offset: Int, entries: [ClipboardEntry], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard rowSelection.confirmingID == nil else { return .handled }
        guard !entries.isEmpty else { return .ignored }
        selectionInput.useKeyboard(at: NSEvent.mouseLocation)
        let current = entries.firstIndex { $0.id == selected }
        let index = current.map { min(max($0 + offset, 0), entries.count - 1) }
            ?? (offset < 0 ? entries.count - 1 : 0)
        let id = entries[index].id
        selected = id
        listFocused = true
        proxy.scrollTo(id)
        return .handled
    }

    private func historyRow(_ entry: ClipboardEntry, number: Int, isSelected: Bool) -> some View {
        let isLink = entry.webURL != nil
        let title = entry.kind == .image ? "图片" : entry.kind == .file ? "文件" : isLink ? "链接" : "文本"
        let symbol = entry.kind == .image ? "photo" : entry.kind == .file ? "doc" : isLink ? "link" : "text.alignleft"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .monospacedDigit()
                .foregroundStyle(Color(red: 8.0 / 255, green: 88.0 / 255, blue: 240.0 / 255))
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let bundleID = entry.sourceBundleID,
                       let icon = ClipboardVisualAssets.shared.applicationIcon(bundleID) {
                        Image(nsImage: icon)
                            .resizable().scaledToFit().frame(width: 16, height: 16)
                            .help(bundleID)
                    } else {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    }
                    Text(title)
                    if entry.kind == .image, let url = store.imageURL(for: entry) {
                        ClipboardImageSize(url: url)
                    } else if let detail = metadata(entry) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Text(ClipboardDate.text(entry.captured))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                Group {
                    if entry.kind == .image {
                        if let url = store.imageURL(for: entry) {
                            ClipboardImagePreview(url: url)
                        } else {
                            Text("图片预览不可用").foregroundStyle(.secondary)
                        }
                    } else if entry.kind == .file {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array((entry.filePaths ?? []).prefix(3).enumerated()), id: \.offset) { _, path in
                                let url = URL(fileURLWithPath: path)
                                HStack(spacing: 8) {
                                    Image(nsImage: ClipboardVisualAssets.shared.fileIcon(path))
                                        .resizable().scaledToFit().frame(width: 18, height: 18)
                                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                }
                                .help(path)
                            }
                        }
                    } else {
                        Text(entry.text ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(isLink ? Color.accentColor : Color.primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 64, alignment: .topLeading)
                .clipped()

            }
            }
            Spacer(minLength: 0)
            actionBar(entry, expanded: isSelected)
        }
        .padding(8)
        .frame(height: 132, alignment: .topLeading)
        .clipped()

    }

    private func actionBar(_ entry: ClipboardEntry, expanded: Bool) -> some View {
        let copied = copyStatus.isActive(entry.id,plainText:false)
        let plainCopied = copyStatus.isActive(entry.id,plainText:true)
        let favorite = entry.favorite == true
        let favoriteGold = Color(red: 0.91, green: 0.64, blue: 0.04)
        let linkedText = quickTexts.item(fromClipboard: entry.id)
        let saved = linkedText != nil
        let visible=expanded || interactedIDs.contains(entry.id) || copied || plainCopied || favorite || saved || savedFiles.contains(entry.id) || openedEntries.contains(entry.id)
        return HStack(spacing: 5) {
            if visible || copied {
                rowAction("拷贝", symbol: copied ? "checkmark" : "doc.on.doc", active: copied, preserveTitle: true) { copy(entry, keepSelection: true) }
            }
            if let text = entry.text {
                if entry.webURL == nil && (visible || plainCopied) {
                    rowAction("纯文本", symbol: plainCopied ? "checkmark" : "t.square", active: plainCopied, preserveTitle: true) {
                        copy(entry, plainText: true, keepSelection: true)
                    }
                }
                if visible || saved {
                    rowAction("加入常用文本…", symbol: saved ? "checkmark" : "text.badge.plus", active: saved, goldStatus: true) {
                        if let linkedText {
                            quickTexts.revealID = linkedText.id
                            openWindow(id: "quick-text")
                            return
                        }
                        let title = String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).prefix(24))
                        saveDraft = SaveDraft(id: entry.id, text: QuickText(title: title, text: text, sourceClipboardID: entry.id))
                    }
                }
            }
            if entry.kind == .image && (visible || saved) {
                rowAction("加入常用文本…",symbol:saved ? "checkmark" : "text.badge.plus",active:saved,goldStatus:true) {
                    if let linkedText {quickTexts.revealID=linkedText.id;openWindow(id:"quick-text");return}
                    guard let url=store.imageURL(for:entry),let data=try? Data(contentsOf:url) else {return}
                    saveDraft=SaveDraft(id:entry.id,text:QuickText(title:"剪贴板图片",text:"",sourceClipboardID:entry.id),imageData:data)
                }
            }
            if entry.kind != .text && (visible || savedFiles.contains(entry.id)) {
                rowAction("另存为…",
                          symbol: savedFiles.contains(entry.id) ? "checkmark" : "square.and.arrow.down",
                          active: savedFiles.contains(entry.id)) { saveAs(entry) }
            }
            if visible {
                if let target=entry.webURL {
                    rowAction("打开",symbol:"link",active:openedEntries.contains(entry.id)) {
                        if NSWorkspace.shared.open(target) {openedEntries.insert(entry.id)}
                    }
                }
                if entry.kind == .text {
                    rowAction("编辑",symbol:"square.and.pencil",active:false) {editingEntry=entry}
                }
            }
            if visible || favorite {
                Button { focusList();store.toggleFavorite(entry) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundStyle(favorite ? favoriteGold : Color.secondary)
                        Text("收藏")
                            .foregroundStyle(Color.primary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).frame(height: 24)
                    .background(favorite ? favoriteGold.opacity(0.18) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).modifier(ActionHover())
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel(favorite ? "取消收藏" : "收藏")
                .accessibilityValue(favorite ? "已收藏" : "未收藏")
                .help(favorite ? "取消收藏" : "收藏这条记录")
            }
            Spacer(minLength: 0)
            if visible {
                ConfirmDeleteButton(isPresented: Binding(
                    get: { rowSelection.flag(for: entry.id).deleteConfirmation },
                    set: { rowSelection.setConfirmation($0, for: entry.id) }),
                    delete: { store.remove(entry) }) {
                    Image(systemName: "trash").frame(width: 28, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).modifier(ActionHover())
                .foregroundStyle(Color.red)
                .layoutPriority(1)
                .accessibilityLabel("删除")
                .help("删除这条记录")
            }
        }
        .frame(height: 24)
    }

    private func focusList() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        listFocused=true
    }

    private func rowAction(_ title: String, symbol: String, active: Bool, preserveTitle: Bool = false, goldStatus: Bool = false, action: @escaping () -> Void) -> some View {
        let statusColor = goldStatus ? Color(red: 0.91, green: 0.64, blue: 0.04) : Color.blue
        return Button {focusList();action()} label: {
            HStack(spacing: 3) {
                if active && symbol == "checkmark" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Color(red: 0.12, green: 0.62, blue: 0.30), in: Circle())
                } else {
                    Image(systemName: symbol).frame(width: 15)
                }
                Text(title)
            }
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .foregroundStyle(active && !goldStatus ? Color.blue : Color.primary)
                .background(active ? statusColor.opacity(goldStatus ? 0.18 : 0.14) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: active && preserveTitle, vertical: false)
        .layoutPriority(active && preserveTitle ? 3 : active ? 1 : 0)
        .modifier(ActionHover())
        .help(title)
        .accessibilityLabel(title)
    }

    private func saveAs(_ entry: ClipboardEntry) {
        let sources = store.saveSourceURLs(for: entry)
        guard !sources.isEmpty else { store.error = "这条记录无法另存为"; return }
        do {
            if sources.count == 1 {
                let panel = NSSavePanel()
                if entry.kind == .image {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.timeZone = .current
                    formatter.dateFormat = "yyyyMMdd_HHmmss"
                    panel.nameFieldStringValue = "剪贴板图片_\(formatter.string(from: Date())).png"
                } else {
                    panel.nameFieldStringValue = sources[0].lastPathComponent
                }
                if entry.kind == .image { panel.allowedContentTypes = [.png] }
                panel.prompt = "另存为"
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try store.save(entry, to: destination)
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "保存到这里"
                guard panel.runModal() == .OK, let directory = panel.url else { return }
                try store.saveFiles(entry, into: directory)
            }
            store.error = ""
            savedFiles.insert(entry.id)
        } catch {
            store.error = "另存为失败：" + error.localizedDescription
        }
    }

    private var copyIndicator: some View {
        Text(copied)
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.blue.opacity(0.14), in: Capsule())
            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
    }

    private func copy(_ entry: ClipboardEntry, plainText: Bool = false, keepSelection: Bool = false) {
        guard store.copy(entry, plainText: plainText) else {
            store.error = "拷贝失败，原记录可能已不可用"
            return
        }
        store.error = ""
        selected = keepSelection ? entry.id : nil
        interactedIDs.insert(entry.id)
        copyStatus = ClipboardCopyStatus(entryID: entry.id, plainText: plainText, changeCount: NSPasteboard.general.changeCount)
        copied = plainText ? "已拷贝纯文本" : "已拷贝"
        withAnimation(copyFeedback == .center ? .easeOut(duration: 0.16) : nil) { copiedEntryID = entry.id }
        copyFeedbackID = UUID()
    }

    private func metadata(_ entry: ClipboardEntry) -> String? {
        if entry.kind == .file, let paths = entry.filePaths { return "\(paths.count) 个文件" }
        return nil
    }

}
