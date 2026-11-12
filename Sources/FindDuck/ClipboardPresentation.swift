import AppKit
import ImageIO
import SwiftUI

// Reference-only memoization: changing the selection must not invalidate these caches.
final class MemoizedValue<Key: Equatable, Value> {
    private var cached: (Key, Value)?
    func value(for key: Key, build: () -> Value) -> Value {
        if let cached, cached.0 == key { return cached.1 }
        let value = build(); cached = (key, value); return value
    }
}

struct ClipboardListKey: Equatable {
    let revision: UInt64
    let query: String
    let filter: String
    let period: String
    let day: Date
    var expansion: [UUID: Bool] = [:]
}

@MainActor final class ClipboardVisualAssets {
    static let shared = ClipboardVisualAssets()
    private let icons = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    init() { icons.countLimit = 200 }
    func applicationIcon(_ bundleID: String) -> NSImage? {
        let key = "app:" + bundleID
        if let image = icons.object(forKey: key as NSString) { return image }
        guard !missing.contains(key) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(key); return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(image, forKey: key as NSString); return image
    }
    func fileIcon(_ path: String) -> NSImage {
        let key = ("file:" + path) as NSString
        if let image = icons.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: key); return image
    }
}

struct ClipboardPreview: Sendable {
    let data: Data
    let bytes: Int
}

// A serial background actor limits decoding work. Clipboard images are immutable UUID files.
actor ClipboardPreviewLoader {
    static let shared = ClipboardPreviewLoader()
    private var cache: [URL: ClipboardPreview] = [:]
    private var cacheBytes = 0
    func load(_ url: URL) -> ClipboardPreview? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              !Task.isCancelled,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let preview = ClipboardPreview(data: data, bytes: bytes)
        if cacheBytes + data.count > 24 * 1024 * 1024 || cache.count >= 100 {
            cache.removeAll(); cacheBytes = 0
        }
        cache[url] = preview; cacheBytes += data.count
        return preview
    }
}

struct ClipboardImagePreview: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Text("图片预览不可用").foregroundStyle(.secondary) }
            else { Color.clear }
        }
        .frame(maxWidth: 320, maxHeight: 64, alignment: .leading)
        .task(id: url) {
            let preview = await ClipboardPreviewLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            image = preview.flatMap { NSImage(data: $0.data) }
            failed = image == nil
        }
    }
}

struct ClipboardImageSize: View {
    let url: URL
    @State private var size: String?
    var body: some View {
        Group { if let size { Text(size).foregroundStyle(.secondary) } }
            .task(id: url) {
                let preview = await ClipboardPreviewLoader.shared.load(url)
                guard !Task.isCancelled else { return }
                size = preview.map { ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file) }
            }
    }
}
