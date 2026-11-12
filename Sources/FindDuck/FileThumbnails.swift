import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import QuickLookThumbnailing

struct ThumbnailOptions: Equatable {
    var images = true
    var videos = true
    var shared = true
    func accepts(_ file: FileHit, shared: Bool) -> Bool {
        guard !file.isDirectory, !shared || self.shared,
              let type = UTType(filenameExtension: file.url.pathExtension) else { return false }
        return (images && type.conforms(to: .image)) || (videos && type.conforms(to: .movie))
    }
}

// The system may suppress its callback after cancellation. Complete our waiter once
// independently so cancelled or timed-out requests cannot occupy a loading slot.
final class ThumbnailCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false
    func install(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: nil) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ data: Data?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation; continuation = nil
        lock.unlock()
        waiting?.resume(returning: data)
    }
}

private struct ThumbnailMetadata: Sendable {
    let modified: Date?
    let size: Int
    let local: Bool
    let cloudOnly: Bool
}

@MainActor final class FileThumbnails {
    static let shared = FileThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var failures: [String: Date] = [:]
    private var active = 0
    init() { cache.countLimit = 300; cache.totalCostLimit = 16 * 1024 * 1024 }

    func image(for file: FileHit, allowShared: Bool) async -> NSImage? {
        do {
            // Waiting and generation are cancellable; scrolling never queues a full result set.
            while active >= 2 { try await Task.sleep(for: .milliseconds(40)) }
            try Task.checkCancellation()
            active += 1
            defer { active -= 1 }
            let metadata = await Task.detached(priority: .utility) {
                guard let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return Optional<ThumbnailMetadata>.none }
                return ThumbnailMetadata(modified: values.contentModificationDate, size: values.fileSize ?? 0,
                                         local: values.volumeIsLocal == true,
                                         cloudOnly: values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded)
            }.value
            try Task.checkCancellation()
            guard let metadata, allowShared || metadata.local else { return nil }
            // Do not cause cloud-only files to download just to decorate a search result.
            if metadata.cloudOnly { return nil }
            let key = file.id + "|\(metadata.modified?.timeIntervalSince1970 ?? 0)|\(metadata.size)|96"
            if let image = cache.object(forKey: key as NSString) { return image }
            if let failed = failures[key], Date().timeIntervalSince(failed) < 30 { return nil }
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 48, height: 48), scale: 2, representationTypes: .thumbnail)
            let completion = ThumbnailCompletion()
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                QLThumbnailGenerator.shared.cancel(request)
                completion.finish(nil)
            }
            defer { timeout.cancel() }
            let data: Data? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    completion.install(continuation)
                    guard !Task.isCancelled else { completion.finish(nil); return }
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                        completion.finish(representation?.nsImage.tiffRepresentation)
                    }
                }
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
                completion.finish(nil)
            }
            try Task.checkCancellation()
            guard let data, let image = NSImage(data: data) else {
                if failures.count >= 300 { failures.removeAll() }
                failures[key] = Date(); return nil
            }
            cache.setObject(image, forKey: key as NSString, cost: 96 * 96 * 4)
            return image
        } catch { return nil }
    }
}

struct SearchResultIcon: View {
    let file: FileHit
    let shared: Bool
    @AppStorage("biuImageThumbnails") private var images = true
    @AppStorage("biuVideoThumbnails") private var videos = true
    @AppStorage("biuSharedThumbnails") private var sharedPreviews = true
    @State private var thumbnail: NSImage?
    private var options: ThumbnailOptions { ThumbnailOptions(images: images, videos: videos, shared: sharedPreviews) }
    private var enabled: Bool { options.accepts(file, shared: shared) }
    private var requestID: String { "\(file.id)|\(file.modified?.timeIntervalSince1970 ?? 0)|\(images)|\(videos)|\(sharedPreviews)|\(shared)" }
    var body: some View {
        Image(nsImage: enabled ? thumbnail ?? FileIcons.shared.icon(for: file) : FileIcons.shared.icon(for: file))
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: 30, height: 32).padding(.horizontal, 2)
            .accessibilityLabel(enabled && thumbnail != nil ? "文件预览图" : file.isDirectory ? "文件夹" : "默认打开软件图标")
            .task(id: requestID) {
                thumbnail = nil
                guard enabled else { return }
                let loaded = await FileThumbnails.shared.image(for: file, allowShared: sharedPreviews)
                guard !Task.isCancelled else { return }
                thumbnail = loaded
            }
    }
}
