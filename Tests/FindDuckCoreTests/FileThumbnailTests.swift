import XCTest
import AppKit
@testable import FindDuck

final class FileThumbnailTests: XCTestCase {
    func testIndependentTypesAndSharedOverride() {
        let image = FileHit(url: URL(fileURLWithPath: "/test/a.jpg"))
        let video = FileHit(url: URL(fileURLWithPath: "/test/a.mp4"))
        let pdf = FileHit(url: URL(fileURLWithPath: "/test/a.pdf"))
        let options = ThumbnailOptions(images: true, videos: false, shared: false)
        XCTAssertTrue(options.accepts(image, shared: false))
        XCTAssertFalse(options.accepts(video, shared: false))
        XCTAssertFalse(options.accepts(image, shared: true))
        XCTAssertFalse(options.accepts(pdf, shared: false))
        let videoOnly = ThumbnailOptions(images: false, videos: true, shared: true)
        XCTAssertTrue(videoOnly.accepts(video, shared: true))
        XCTAssertFalse(videoOnly.accepts(image, shared: true))
        XCTAssertFalse(videoOnly.accepts(FileHit(url: video.url, isDirectory: true), shared: false))
    }
    func testCancelBeforeCallbackInstallationFinishesWaiter() async {
        let pending = ThumbnailCompletion()
        pending.finish(nil)
        let result = await withCheckedContinuation { pending.install($0) }
        XCTAssertNil(result)
    }
    func testLateCallbackCannotResumeCancelledWaiterTwice() async {
        let pending = ThumbnailCompletion()
        let result = await withCheckedContinuation {
            pending.install($0)
            pending.finish(nil)
            pending.finish(Data([1]))
        }
        XCTAssertNil(result)
    }
    @MainActor func testRealImageThumbnailAndCancelledRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = root.appendingPathComponent("sample.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let service = FileThumbnails()
        let file = FileHit(url: url)
        let first = await service.image(for: file, allowShared: false)
        XCTAssertNotNil(first)
        if let first { XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 96) }
        let cached = await service.image(for: file, allowShared: false)
        XCTAssertTrue(first === cached)
        let cancelled = Task { await service.image(for: file, allowShared: false) }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
    }
    @MainActor func testRealVideoThumbnail() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "thumbnail", withExtension: "mp4", subdirectory: "Fixtures"))
        let image = await FileThumbnails().image(for: FileHit(url: url), allowShared: false)
        XCTAssertNotNil(image)
    }
}
