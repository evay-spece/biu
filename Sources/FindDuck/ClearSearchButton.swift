import SwiftUI

struct ClearSearchButton: View {
    @Binding var text:String
    var label:String = "清除搜索"
    var onClear:()->Void = {}
    var body:some View {
        if !text.isEmpty {
            Button {
                onClear()
                text=""
            } label: {
                Image(systemName:"xmark.circle.fill")
                    .font(.system(size:12,weight:.medium))
                    .foregroundStyle(.secondary)
                    .frame(width:18,height:20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
        }
    }
}

struct InlineSearchField:View {
    let prompt:String
    @Binding var text:String
    var accessibilityName:String? = nil
    var clearLabel:String = "清除搜索"
    @FocusState private var focused:Bool
    init(prompt:String,text:Binding<String>,accessibilityName:String?=nil,clearLabel:String="清除搜索") {
        self.prompt=prompt;self._text=text;self.accessibilityName=accessibilityName;self.clearLabel=clearLabel
    }
    var body:some View {
        HStack(spacing:0) {
            TextField(prompt,text:$text)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel(accessibilityName ?? prompt)
                .padding(.leading,7)
                .padding(.trailing,text.isEmpty ? 6 : 2)
                .padding(.vertical,4)
                .layoutPriority(1)
            ClearSearchButton(text:$text,label:clearLabel) {focused=true}
                .padding(.trailing,text.isEmpty ? 0 : 4)
        }
        .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:5))
        .overlay {RoundedRectangle(cornerRadius:5).stroke(focused ? Color.accentColor.opacity(0.7) : Color(nsColor:.separatorColor),lineWidth:focused ? 1 : 0.7).allowsHitTesting(false)}
    }
}
