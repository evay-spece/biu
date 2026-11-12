import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum QuickTextImages {
    static func png(_ data:Data)->Data? {NSBitmapImageRep(data:data)?.representation(using:.png,properties:[:])}
    @MainActor static func canPasteImage(from board:NSPasteboard = .general)->Bool {
        board.canReadObject(forClasses:[NSImage.self],options:nil) || imageFile(from:board) != nil
    }
    @MainActor private static func imageFile(from board:NSPasteboard)->URL? {
        let urls=(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []).filter(\.isFileURL)
        guard urls.count == 1,let url=urls.first,UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true else {return nil}
        return url
    }
    @MainActor static func fromPasteboard(_ board:NSPasteboard = .general)->Data? {
        if let data=board.data(forType:.png) {return png(data)}
        if let data=board.data(forType:.tiff),let data=png(data) {return data}
        if let data=NSImage(pasteboard:board)?.tiffRepresentation {return png(data)}
        if let url=imageFile(from:board),let data=try? Data(contentsOf:url) {return png(data)}
        return nil
    }
}
struct QuickTextContentEditor:NSViewRepresentable {
    @Binding var text:String
    let imagePasted:(Data)->Void
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .noBorder
        let view=ImagePasteTextView(frame:.zero)
        view.isRichText=false;view.font = .systemFont(ofSize:13)
        view.textContainerInset=NSSize(width:8,height:8)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.autoresizingMask = [.width];view.textContainer?.widthTracksTextView=true
        view.delegate=context.coordinator;view.imagePasted=imagePasted;view.string=text
        view.setAccessibilityLabel("常用文本内容，支持粘贴图片")
        scroll.documentView=view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent=self
        guard let view=scroll.documentView as? ImagePasteTextView else {return}
        view.imagePasted=imagePasted
        if view.string != text,!view.hasMarkedText() {view.string=text}
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:QuickTextContentEditor
        init(_ parent:QuickTextContentEditor) {self.parent=parent}
        func textDidChange(_ notification:Notification) {if let view=notification.object as? NSTextView,!view.hasMarkedText() {parent.text=view.string}}
    }
    final class ImagePasteTextView:NSTextView {
        var imagePasted:((Data)->Void)?
        override func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem)->Bool {
            if item.action == #selector(paste(_:)),QuickTextImages.canPasteImage() {return true}
            return super.validateUserInterfaceItem(item)
        }
        override func paste(_ sender:Any?) {
            if let data=QuickTextImages.fromPasteboard() {imagePasted?(data)}
            else {super.paste(sender)}
        }
    }
}
