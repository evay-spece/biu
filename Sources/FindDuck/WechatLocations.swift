import Foundation

enum WechatLocations {
    private static let attachmentSuffixes=["msg/file","msg/attach","msg/video","FileStorage/File","FileStorage/Image","FileStorage/Video","FileStorage/MsgAttach"]
    static func isChatAttachment(_ url:URL)->Bool {
        let path=url.standardizedFileURL.path.lowercased()
        return attachmentSuffixes.contains {path.contains("/"+$0.lowercased()+"/")}
    }
    static func isOpaqueImage(_ url:URL)->Bool {
        let path=url.path.lowercased()
        guard path.contains("/msg/attach/") || path.contains("/filestorage/msgattach/") else {return false}
        if url.pathExtension.lowercased() == "dat" {return true}
        let name=url.lastPathComponent.lowercased()
        return url.pathExtension.isEmpty &&
            (name.allSatisfy(\.isNumber) || name.hasSuffix("_t") && name.dropLast(2).allSatisfy(\.isNumber))
    }
    static func isSearchableChatAttachment(_ url:URL)->Bool {
        isChatAttachment(url) && !isOpaqueImage(url) && !isVideoThumbnail(url)
    }
    static func isVideoThumbnail(_ url:URL)->Bool {
        let path=url.path.lowercased()
        return (path.contains("/msg/video/") || path.contains("/filestorage/video/")) && ["jpg","jpeg","png","gif","webp","heic","heif","bmp","tiff"].contains(url.pathExtension.lowercased())
    }
    static func isOutsideChatAttachments(_ url:URL)->Bool {
        let path=url.path.lowercased()
        let wechat=path.contains("/com.tencent.xinwechat/") || path.contains("/xwechat_files/") || path.contains("/wechat files/")
        return wechat && !isSearchableChatAttachment(url)
    }
    static func isContainer(_ url:URL)->Bool {
        ["xwechat_files","WeChat Files"].contains(url.lastPathComponent)
    }
    static func attachmentRoots(in folder:URL)->[URL] {
        let root=folder.standardizedFileURL
        if attachmentSuffixes.contains(where:root.path.hasSuffix) {return [root]}
        let accounts:[URL]
        if isContainer(root) {
            let children=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
            accounts=[root]+children.filter {child in
                let name=child.lastPathComponent
                return !["all_users","old_backup","Backup","WMPF"].contains(name) &&
                    (try? child.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
            }
        } else {accounts=[root]}
        let candidates=accounts.flatMap {account in attachmentSuffixes.map {account.appendingPathComponent($0,isDirectory:true)} }
        let found=Array(Set(candidates.filter {DirectoryReader.available($0)}.map(\.standardizedFileURL)))
            .sorted {$0.path < $1.path}
        return found.isEmpty && !isContainer(root) ? [root] : found
    }
    static func locate(home:URL,existing:URL?=nil)->URL? {
        // Keep a working detected/cached location, and recover when it moves or disappears.
        if let existing,DirectoryReader.available(existing) {return existing}
        let paths=["Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                   "Library/Containers/com.tencent.xinWeChat/Data/Documents/WeChat Files",
                   "Documents/xwechat_files","Documents/WeChat Files"]
        return paths.map {home.appendingPathComponent($0)}.first {DirectoryReader.available($0)}
    }
}
