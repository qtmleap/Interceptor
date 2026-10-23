import AutomationCore
import XCTest
@testable import Interceptor

final class PluginIconLoaderTests: XCTestCase {
    private enum Failure: Error { case missing }
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func isWaiting() -> Bool { entered }
        func open() { continuation?.resume(); continuation = nil }
    }
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private func icon(corrupt: Bool = false) throws -> PluginIcon {
        let valid = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let invalid = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAA0lEQVRiYWSEoK5LAAAAAElFTkSuQmCC"
        return try .validate(data: XCTUnwrap(Data(base64Encoded: corrupt ? invalid : valid)), path: "icon.png")
    }

    func testConcurrentRequestsShareActualDecodeAndCachedThumbnail() async throws {
        let loader = PluginIconLoader(), counter = Counter(), icon = try icon()
        let source = PluginIconSource(id: "a", cacheKey: "a") {
            await counter.increment()
            await Task.yield()
            return icon
        }
        async let a = loader.image(for: source)
        async let b = loader.image(for: source)
        let images = await (a, b)
        XCTAssertEqual(images.0?.image.cgImage?.width, 1)
        XCTAssertEqual(images.1?.image.cgImage?.height, 1)
        _ = await loader.image(for: source)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testMalformedCompressedImageRemainsBoundedAndDoesNotDecodeRepeatedly() async throws {
        let loader = PluginIconLoader(), counter = Counter(), icon = try icon(corrupt: true)
        let source = PluginIconSource(id: "bad", cacheKey: "bad") { await counter.increment(); return icon }
        let first = await loader.image(for: source)
        let second = await loader.image(for: source)
        // ImageIO may recover a bounded image from corrupt data instead of returning nil.
        // Both decoder outcomes are valid; the display cache must bound and reuse the result.
        if let first {
            XCTAssertLessThanOrEqual(first.image.cgImage!.width, 192)
            XCTAssertLessThanOrEqual(first.image.cgImage!.height, 192)
        }
        XCTAssertEqual(first == nil, second == nil)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testMissingCatalogContentCanBeLoadedAfterBackfill() async throws {
        let loader = PluginIconLoader(), icon = try icon()
        let missing = PluginIconSource(id: "sha:1", cacheKey: "sha") { throw Failure.missing }
        let available = PluginIconSource(id: "sha:2", cacheKey: "sha") { icon }
        let first = await loader.image(for: missing)
        let second = await loader.image(for: available)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
    }

    func testBackfillGenerationDoesNotShareAnOlderMissingRequest() async throws {
        let loader = PluginIconLoader(), gate = Gate(), icon = try icon()
        let old = PluginIconSource(id: "sha:old", cacheKey: "sha") {
            await gate.wait()
            throw Failure.missing
        }
        let pending = Task { await loader.image(for: old) }
        while !(await gate.isWaiting()) { await Task.yield() }
        let ready = expectation(description: "new generation finishes before the old read")
        let next = Task {
            let image = await loader.image(for: .init(id: "sha:new", cacheKey: "sha") { icon })
            ready.fulfill()
            return image
        }
        await fulfillment(of: [ready], timeout: 2)
        await gate.open()
        let current = await next.value
        XCTAssertNotNil(current)
        _ = await pending.value
        let cached = await loader.image(for: .init(id: "sha:new", cacheKey: "sha") { throw Failure.missing })
        XCTAssertNotNil(cached)
    }

    func testValidNoIconPackageCachesFallback() async {
        let loader = PluginIconLoader(), counter = Counter()
        let source = PluginIconSource(id: "no-icon", cacheKey: "no-icon") { await counter.increment(); return nil }
        _ = await loader.image(for: source)
        _ = await loader.image(for: source)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testActualLosslessWebPDecodesWithItsNonSquareDimensions() async throws {
        let data = Data(base64Encoded: "UklGRjAAAABXRUJQVlA4TCMAAAAvA0AAEB8gEEjaH3qN+RcQFPk/moCg4P/ogs2kwqFeI/ofAQA=")!
        let icon = try PluginIcon.validate(data: data, path: "icon.webp")
        let decoded = await PluginIconLoader().image(for: .init(id: "webp", cacheKey: "webp") { icon })
        XCTAssertEqual(decoded?.image.cgImage?.width, 4)
        XCTAssertEqual(decoded?.image.cgImage?.height, 2)
    }

    func testNoIconCatalogDoesNotChurnTheImageCacheLimit() async {
        let loader = PluginIconLoader(countLimit: 2), counter = Counter()
        for _ in 0..<2 {
            for index in 0..<100 {
                let key = String(index)
                _ = await loader.image(for: .init(id: key, cacheKey: key) { await counter.increment(); return nil })
            }
        }
        let count = await counter.value
        XCTAssertEqual(count, 100)
    }

    func testCountAndCostLimitsEvictOldEntries() async throws {
        let icon = try icon(), counter = Counter()
        let loader = PluginIconLoader(countLimit: 2)
        for key in ["a", "b", "c", "a"] {
            _ = await loader.image(for: .init(id: key, cacheKey: key) { await counter.increment(); return icon })
        }
        let count = await counter.value
        XCTAssertEqual(count, 4)
        let noStorage = PluginIconLoader(costLimit: 0), costCounter = Counter()
        let source = PluginIconSource(id: "one", cacheKey: "one") { await costCounter.increment(); return icon }
        _ = await noStorage.image(for: source)
        _ = await noStorage.image(for: source)
        let costCount = await costCounter.value
        XCTAssertEqual(costCount, 2)
    }
}
