import SwiftUI
import AppKit

struct TagBadge:View {
    let tag:FileTag
    var highlighted=false
    var prominent=false
    var inverted=false
    @State private var hovering=false
    var body:some View {
        Group {
            Text(tag.displayName).font(.system(size:prominent ? 18 : 11,weight:.medium)).lineLimit(1).padding(.horizontal,prominent ? 10 : 8).padding(.vertical,prominent ? 5 : 3)
                .foregroundStyle(inverted ? Color.white : tag.color.labelColor).background(inverted ? Color.white.opacity(0.18) : tag.color.tagBackground(highlighted:hovering || highlighted),in:RoundedRectangle(cornerRadius:prominent ? 9 : 6))
                .overlay(RoundedRectangle(cornerRadius:prominent ? 9 : 6).strokeBorder(inverted ? Color.white.opacity(0.65) : tag.color.color.opacity(0.45),lineWidth:1))
        }.onHover {hovering=$0}.help(tag.displayName).accessibilityLabel("Biu标签："+tag.displayName)
    }
}
struct FileTagEditor:View {
    @ObservedObject var model:SearchLibrary
    let file:FileHit
    let create:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("文件标签").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                ForEach(FileMarkColor.palette.map(FileTag.builtin)) {tag in
                    Button {model.toggleTag(file,tag)} label: {
                        HStack(spacing: 3) {
                            if model.hasTag(file,tag) { Image(systemName: "checkmark").font(.caption2) }
                            TagBadge(tag: tag)
                        }
                    }.buttonStyle(.plain).accessibilityLabel(tag.color.rawValue+"标签").help(model.hasTag(file,tag) ? "移除"+tag.color.rawValue : "添加"+tag.color.rawValue)
                }
            }
            if let custom=model.preferences.customTags,!custom.isEmpty {
                ForEach(custom) {tag in
                    Button {model.toggleTag(file,tag)} label: {HStack {TagBadge(tag:tag);Spacer();if model.hasTag(file,tag) {Image(systemName:"checkmark").font(.caption)}}}
                        .buttonStyle(.plain).accessibilityLabel("标签："+tag.name)
                }
            }
            Divider()
            Button(action:create) {Label("自定义标签…",systemImage:"tag")}.buttonStyle(.plain)
        }.padding(16).frame(width:260)
    }
}
// A native menu view keeps all color choices directly visible, as in Finder.
@MainActor final class TagColorPalette:NSView {
    private var buttons:[ColorChoiceButton]=[]
    private let colors:[FileMarkColor]
    private let selected:()->Set<FileMarkColor>
    private let toggle:(FileMarkColor)->Void
    init(colors:[FileMarkColor]=FileMarkColor.palette,selected:@escaping ()->Set<FileMarkColor>,toggle:@escaping (FileMarkColor)->Void) {
        self.colors=colors;self.selected=selected;self.toggle=toggle;super.init(frame:NSRect(x:0,y:0,width:280,height:36))
        setAccessibilityElement(false)
        for (index,color) in colors.enumerated() {
            let button=ColorChoiceButton(frame:NSRect(x:4+index*45,y:4,width:41,height:28))
            button.isBordered=false;button.imagePosition = .imageOnly;button.bezelStyle = .regularSquare;button.tag=index
            button.target=self;button.action=#selector(pressed(_:));button.toolTip=color.rawValue
            button.setAccessibilityLabel(color.rawValue+"标签");addSubview(button);buttons.append(button)
        }
        refresh()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    @objc private func pressed(_ sender:NSButton) {toggle(colors[sender.tag]);refresh()}
    private func refresh() {
        let values=selected()
        for (index,button) in buttons.enumerated() {
            let color=colors[index],chosen=values.contains(color)
            button.markColor=color;button.chosen=chosen;button.needsDisplay=true
            button.setAccessibilityValue(chosen ? "已添加" : "未添加")
        }
    }
}

@MainActor final class NamedTagsMenuView:NSView {
    private let tags:[FileTag]
    private let selected:(FileTag)->Bool
    private let toggle:(FileTag)->Void
    private var buttons:[TagHoverButton]=[]
    init(tags:[FileTag],selected:@escaping (FileTag)->Bool,toggle:@escaping (FileTag)->Void) {
        self.tags=tags;self.selected=selected;self.toggle=toggle
        let font=NSFont.systemFont(ofSize:12,weight:.medium)
        var placements:[(CGFloat,Int,CGFloat)]=[]
        var x:CGFloat=10,row=0
        for tag in tags {
            let width=min(220,max(60,(tag.name as NSString).size(withAttributes:[.font:font]).width+42))
            if x+width>235 {row += 1;x=10}
            placements.append((x,row,width));x += width+8
        }
        let height=CGFloat(row+1)*30
        super.init(frame:NSRect(x:0,y:0,width:245,height:height));setAccessibilityElement(false)
        for (index,tag) in tags.enumerated() {
            let (left,line,width)=placements[index]
            let button=TagHoverButton(frame:NSRect(x:left,y:height-CGFloat(line+1)*30+4,width:width,height:22))
            button.tag=index;button.isBordered=false;button.wantsLayer=true;button.layer?.cornerRadius=6
            button.layer?.backgroundColor=NSColor(tag.color.tagBackground()).cgColor
            button.layer?.borderColor=NSColor(tag.color.color).withAlphaComponent(0.45).cgColor;button.layer?.borderWidth=1
            button.font=font;button.target=self;button.action=#selector(pressed(_:))
            button.setAccessibilityLabel("标签："+tag.name);addSubview(button);buttons.append(button)
        }
        refresh()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    @objc private func pressed(_ sender:NSButton) {toggle(tags[sender.tag]);refresh()}
    private func refresh() {
        for (index,button) in buttons.enumerated() {
            let tag=tags[index],chosen=selected(tag)
            button.attributedTitle=NSAttributedString(string:(chosen ? "✓ " : "")+tag.name,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor(tag.color.labelColor)])
            button.setAccessibilityValue(chosen ? "已添加" : "未添加")
        }
    }
}

struct TagManager:View {
    @ObservedObject var model:SearchLibrary
    let file:FileHit
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("自定义标签").font(.headline);Spacer();Button("完成") {dismiss()}}
            Text("修改名称或颜色会更新所有使用此标签的文件。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.preferences.customTags ?? []) {tag in
                    HStack {
                        Button {model.toggleTag(file,tag)} label: {HStack {Image(systemName:model.hasTag(file,tag) ? "checkmark.circle.fill" : "circle");TagBadge(tag:tag)}}.buttonStyle(.plain)
                        Spacer();Button("编辑") {model.chooseEditTag(tag)}
                        Button("删除") {model.deleteTag(tag)}
                    }.padding(.vertical,4)
                }
            }.frame(minHeight:160)
            Button {model.chooseCustomTag(file)} label: {Label("新建标签…",systemImage:"plus")}
        }.padding(20).frame(width:420,height:340)
    }
}

struct TagRegionKey:PreferenceKey {
    static let defaultValue:[String:[String:CGRect]]=[:]
    static func reduce(value:inout [String:[String:CGRect]],nextValue:()->[String:[String:CGRect]]) {
        for (file,regions) in nextValue() {value[file,default:[:]].merge(regions,uniquingKeysWith:{$1})}
    }
}
@MainActor final class TagHoverButton:NSButton {
    private var area:NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let area {removeTrackingArea(area)}
        let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);area=next;addTrackingArea(next)
    }
    override func mouseEntered(with event:NSEvent) {alphaValue=0.7}
    override func mouseExited(with event:NSEvent) {alphaValue=1}
}

@MainActor final class ColorChoiceButton:NSButton {
    var markColor:FileMarkColor = .red
    var chosen=false
    private var hovering=false,area:NSTrackingArea?
    override func updateTrackingAreas() {super.updateTrackingAreas();guard area == nil else {return};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);area=next;addTrackingArea(next)}
    override func mouseEntered(with event:NSEvent) {hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent) {hovering=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(markColor.tagBackground(highlighted: hovering || chosen)).setFill()
        path.fill()
        NSColor(markColor.color).withAlphaComponent(chosen ? 1 : 0.45).setStroke()
        path.lineWidth = chosen ? 1.5 : 1
        path.stroke()
        let text = markColor.rawValue as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: chosen ? .bold : .medium),
            .foregroundColor: NSColor(markColor.labelColor)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }
}
