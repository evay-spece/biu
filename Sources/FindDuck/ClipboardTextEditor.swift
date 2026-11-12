import SwiftUI

struct ClipboardTextEditor:View {
    let entry:ClipboardEntry
    @ObservedObject var store:ClipboardHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text:String
    init(entry:ClipboardEntry,store:ClipboardHistoryStore) {
        self.entry=entry;self.store=store;_text=State(initialValue:entry.text ?? "")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("编辑剪贴板文本").font(.headline)
            TextEditor(text:$text).font(.system(size:13)).frame(minHeight:180)
                .overlay(RoundedRectangle(cornerRadius:6).stroke(Color.primary.opacity(0.1)))
                .accessibilityLabel("剪贴板文本内容")
            if entry.richText != nil {Text("保存后，此条记录将以纯文本保存。可用 ⌘Z 撤销修改。")
                .font(.caption).foregroundStyle(.secondary)}
            if !store.error.isEmpty {Text(store.error).font(.caption).foregroundStyle(.red)}
            HStack {
                Button("取消") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {if store.updateText(entry,text:text) {dismiss()}}
                    .keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }.padding(20).frame(width:440)
    }
}
