import AppKit
import SwiftUI

@MainActor final class UserActionHistory {
    static let shared=UserActionHistory()
    private struct Entry {let name:String;let cost:Int;let action:()->Bool}
    private var entries:[Entry]=[]
    var canUndo:Bool {!entries.isEmpty}
    func record(_ name:String,cost:Int=0,_ action:@escaping ()->Bool) {
        entries.append(Entry(name:name,cost:cost,action:action))
        while entries.count > 40 || (entries.count > 1 && entries.reduce(0,{$0+$1.cost}) > 128*1024*1024) {entries.removeFirst()}
    }
    @discardableResult func undo()->Bool {
        guard let entry=entries.last else {return false}
        guard entry.action() else {return false}
        entries.removeLast();return true
    }
    static func undoFocusedAction() {
        if let text=NSApp.keyWindow?.firstResponder as? NSTextView,let manager=text.undoManager,manager.canUndo {manager.undo()}
        else {_=shared.undo()}
    }
}

final class UndoMediaBackup {
    private let folder:URL
    private var files:[(URL,URL)]=[]
    init(_ urls:[URL]) throws {
        folder=FileManager.default.temporaryDirectory.appendingPathComponent("biu-undo-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for (index,url) in urls.enumerated() where FileManager.default.fileExists(atPath:url.path) {
            let backup=folder.appendingPathComponent(String(index));try FileManager.default.copyItem(at:url,to:backup);files.append((url,backup))
        }
    }
    var byteCount:Int {files.reduce(0) {$0 + ((try? $1.1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}}
    func restore() throws {
        for (target,backup) in files where !FileManager.default.fileExists(atPath:target.path) {
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:backup,to:target)
        }
    }
    deinit {try? FileManager.default.removeItem(at:folder)}
}

struct ActionHover:ViewModifier {
    @State private var hovered=false
    func body(content:Content)->some View {content.overlay {RoundedRectangle(cornerRadius:6).fill(Color.accentColor.opacity(hovered ? 0.12 : 0)).allowsHitTesting(false)}.onHover {hovered=$0}}
}
