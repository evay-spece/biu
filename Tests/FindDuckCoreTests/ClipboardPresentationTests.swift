import XCTest
import AppKit
@testable import FindDuck

final class ClipboardPresentationTests: XCTestCase {
    func testSelectionUpdatesReuseGroupingAndRelevantChangesInvalidateCache() {
        let cache = MemoizedValue<ClipboardListKey, [ClipboardSession]>()
        let now = Date()
        let entries = (0..<523).map { index in
            ClipboardEntry(kind: .text, text: "sample", imageName: nil, fingerprint: String(index),
                           captured: now.addingTimeInterval(Double(-index * 600)))
        }
        var key = ClipboardListKey(revision: 1, query: "", filter: "全部", period: "不限时间", day: Calendar.current.startOfDay(for: now))
        var builds = 0
        let start = Date()
        for _ in 0..<10000 {
            _ = cache.value(for: key) { builds += 1; return ClipboardSession.group(entries, now: now) }
        }
        print("CACHED_PRESENTATION_10000_REQUESTS_MS=\(Date().timeIntervalSince(start) * 1000), BUILDS=\(builds)")
        XCTAssertEqual(builds, 1)
        key = ClipboardListKey(revision: 2, query: "", filter: "全部", period: "不限时间", day: key.day)
        _ = cache.value(for: key) { builds += 1; return ClipboardSession.group(entries, now: now) }
        XCTAssertEqual(builds, 2)
        key = ClipboardListKey(revision: 2, query: "sample", filter: "全部", period: "不限时间", day: key.day)
        _ = cache.value(for: key) { builds += 1; return [] }
        XCTAssertEqual(builds, 3)
        key = ClipboardListKey(revision: 2, query: "sample", filter: "全部", period: "不限时间", day: key.day.addingTimeInterval(86400))
        _ = cache.value(for: key) { builds += 1; return [] }
        XCTAssertEqual(builds, 4)
    }
    @MainActor func testPreviewDownsamplesAndReusesMemoryCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try original.write(to: url)
        let loader = ClipboardPreviewLoader()
        let first = await loader.load(url)
        let preview = try XCTUnwrap(first)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: preview.data))
        XCTAssertEqual(max(decoded.pixelsWide, decoded.pixelsHigh), 640)
        XCTAssertEqual(preview.bytes, original.count)
        try FileManager.default.removeItem(at: url)
        let cached = await loader.load(url)
        XCTAssertEqual(cached?.data, preview.data)
    }
}
