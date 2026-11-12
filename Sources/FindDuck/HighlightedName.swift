import SwiftUI
import AppKit

enum KeywordHighlights {
    static func ranges(_ name:String,query:String)->[NSRange] {
        var result:[NSRange]=[]
        for term in query.split(whereSeparator:{$0.isWhitespace}).map(String.init) {
            var cursor=name.startIndex
            while cursor<name.endIndex,let r=name.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:cursor..<name.endIndex) {result.append(NSRange(r,in:name));cursor=r.upperBound}
        }
        return result
    }
}
struct HighlightedName:NSViewRepresentable {
    let name:String
    let query:String
    var fontSize:CGFloat=14
    var inverted=false
    func makeNSView(context:Context)->Surface {let view=Surface();view.setContentHuggingPriority(.defaultHigh,for:.horizontal);view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return view}
    func updateNSView(_ view:Surface,context:Context) {if view.name != name || view.query != query || view.fontSize != fontSize || view.inverted != inverted {view.name=name;view.query=query;view.fontSize=fontSize;view.inverted=inverted;view.refresh()};view.setAccessibilityLabel(name)}
    final class Surface: NSTextField {
        var name = ""
        var query = ""
        var fontSize: CGFloat = 14
        var inverted = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            isEditable = false
            isSelectable = false
            isBordered = false
            drawsBackground = false
            maximumNumberOfLines = 1
            lineBreakMode = .byTruncatingTail
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func refresh() {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            self.font = font
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let value = NSMutableAttributedString(string: name, attributes: [
                .font: font, .foregroundColor: inverted ? NSColor.white : NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
            for range in KeywordHighlights.ranges(name, query: query) {
                value.addAttributes([
                    .foregroundColor: inverted ? NSColor.white : NSColor.linkColor
                ], range: range)
            }
            attributedStringValue = value
            invalidateIntrinsicContentSize();needsDisplay=true
        }

        override func draw(_ dirtyRect:NSRect) {
            guard let font else {super.draw(dirtyRect);return}
            NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:bounds).addClip()
            let textRect=cell?.drawingRect(forBounds:bounds) ?? bounds
            let height=font.ascender-font.descender+2
            for range in KeywordHighlights.ranges(name,query:query) {
                let prefix=(name as NSString).substring(to:range.location)
                let word=(name as NSString).substring(with:range)
                let x=textRect.minX+(prefix as NSString).size(withAttributes:[.font:font]).width
                let width=(word as NSString).size(withAttributes:[.font:font]).width
                let rect=NSRect(x:x-1,y:bounds.midY-height/2,width:width+2,height:height)
                (inverted ? NSColor.white.withAlphaComponent(0.26) : NSColor(FindDuckHighlight.soft)).setFill()
                NSBezierPath(roundedRect:rect,xRadius:4,yRadius:4).fill()
            }
            NSGraphicsContext.restoreGraphicsState();super.draw(dirtyRect)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refresh()
        }
    }
}
