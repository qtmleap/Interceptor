import AutomationCore
import AutomationRepository
import CryptoKit
import XCTest
@testable import Interceptor

@MainActor
final class DefaultRepositoryTests: XCTestCase {
    private var storeURL = AutomationFixtures.tempStoreURL()
    private let key = Curve25519.Signing.PrivateKey()
    private var package: PluginPackage!
    private var snapshot: VerifiedSnapshot!
    private var descriptor: DefaultRepository!

    override func setUp() async throws {
        storeURL = AutomationFixtures.tempStoreURL()
        package = try AutomationFixtures.package(name: "Official")
        snapshot = try AutomationFixtures.snapshot(packages: [package], key: key)
        let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        descriptor = DefaultRepository(url: AutomationFixtures.url, repositoryID: snapshot.index.id, fingerprint: fingerprint)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

    private func makeClient() -> FakeRepositoryClient { FakeRepositoryClient(snapshot: snapshot, packages: [package]) }

    private func controller(_ client: FakeRepositoryClient, default repo: DefaultRepository?) -> AutomationController {
        AutomationController(store: AutomationStore(fileURL: storeURL), client: client, executor: FakeScriptRunner(),
                             clock: { AutomationFixtures.now }, defaultRepository: repo)
    }

    func testNoDefaultMeansNoFetch() async {
        let client = makeClient()
        let c = controller(client, default: nil)
        await c.load()
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertTrue(c.repositories.isEmpty)
        XCTAssertNil(c.storeError)
    }

    func testDefaultIsSeededPinnedFromMetadataOnly() async throws {
        let client = makeClient()
        let c = controller(client, default: descriptor)
        await c.load()
        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(client.packageCount, 0, "seeding must never fetch packages")
        XCTAssertTrue(c.scripts.isEmpty)
        let record = try XCTUnwrap(c.repositories.first)
        XCTAssertEqual(c.repositories.count, 1)
        XCTAssertEqual(record.url, descriptor.url)
        guard case .pinned(let pinned) = record.trust else { return XCTFail("default repository must be pinned") }
        XCTAssertEqual(pinned.hex, descriptor.fingerprint)
        XCTAssertNil(c.storeError); XCTAssertNil(c.actionError)
        let persisted = try await AutomationStore(fileURL: storeURL).load()
        XCTAssertEqual(persisted.record(for: descriptor.url), record)
        XCTAssertTrue(persisted.revisions.isEmpty)
    }

    func testExistingRecordSkipsNetwork() async {
        let first = makeClient()
        await controller(first, default: descriptor).load()
        XCTAssertEqual(first.previewCount, 1)
        let second = makeClient()
        let c = controller(second, default: descriptor)
        await c.load()
        XCTAssertEqual(second.previewCount, 0)
        XCTAssertEqual(c.repositories.count, 1)
    }

    func testRemovedDefaultStaysRemovedAndSkipsNetwork() async {
        let first = controller(makeClient(), default: descriptor)
        await first.load()
        await first.deleteRepository(descriptor.url)
        XCTAssertTrue(first.repositories.isEmpty)
        let client = makeClient()
        let relaunched = controller(client, default: descriptor)
        await relaunched.load()
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertTrue(relaunched.repositories.isEmpty)
        XCTAssertNil(relaunched.storeError)
    }

    func testTransientFailureIsActionErrorAndRetriedOnNextLoad() async {
        let client = makeClient()
        client.previewError = URLError(.notConnectedToInternet)
        let c = controller(client, default: descriptor)
        await c.load()
        XCTAssertNil(c.storeError, "offline seeding must not block the store")
        XCTAssertNotNil(c.actionError)
        XCTAssertTrue(c.repositories.isEmpty)
        XCTAssertTrue(c.isLoaded)
        client.previewError = nil
        await c.load()
        XCTAssertEqual(client.previewCount, 2)
        XCTAssertEqual(c.repositories.count, 1)
        XCTAssertNil(c.storeError)
        XCTAssertNil(c.actionError)
    }

    func testCorruptStoreStaysBlockingWithoutFetch() async throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("not a catalog".utf8)
        try garbage.write(to: storeURL)
        let client = makeClient()
        let c = controller(client, default: descriptor)
        await c.load()
        XCTAssertNotNil(c.storeError)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(try Data(contentsOf: storeURL), garbage)
    }

    func testCancelledLoadDoesNotMutateStore() async throws {
        let client = makeClient()
        client.delayNanoseconds = 2_000_000_000
        let c = controller(client, default: descriptor)
        let task = Task { await c.load() }
        let started = await waitUntil { client.previewCount == 1 }
        XCTAssertTrue(started)
        task.cancel()
        await task.value
        XCTAssertTrue(c.repositories.isEmpty)
        let persisted = try await AutomationStore(fileURL: storeURL).load()
        XCTAssertTrue(persisted.repositories.isEmpty)
    }

    func testConcurrentLoadsCommitSingleDefault() async {
        let client = makeClient()
        client.delayNanoseconds = 200_000_000
        let c = controller(client, default: descriptor)
        async let a: Void = c.load()
        async let b: Void = c.load()
        _ = await (a, b)
        XCTAssertEqual(c.repositories.count, 1)
        XCTAssertNil(c.storeError)
    }

    func testImmediateReentryAfterCancellationStillRegistersDefault() async {
        let client = makeClient()
        client.delayNanoseconds = 50_000_000
        let c = controller(client, default: descriptor)
        let first = Task { await c.load() }
        let started = await waitUntil { client.previewCount == 1 }
        XCTAssertTrue(started)
        first.cancel()
        await c.load()
        await first.value
        XCTAssertEqual(c.repositories.count, 1)
        XCTAssertNil(c.storeError)
        XCTAssertNil(c.actionError)
    }

    #if DEBUG
    func testLiveControllerWithIsolatedTestStoreDoesNotFetchOfficialFeed() async {
        let name = "INTERCEPTOR_TEST_AUTOMATION_STORE"
        let previous = ProcessInfo.processInfo.environment[name]
        let testName = "Interceptor.UITests.DefaultSources.\(UUID().uuidString)"
        let owned = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: testName)
        setenv(name, testName, 1)
        defer {
            if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
            try? FileManager.default.removeItem(at: owned)
        }
        guard AutomationController.defaultStoreURL().path.hasPrefix(owned.path + "/") else {
            return XCTFail("live controller must use the isolated test directory")
        }
        let c = AutomationController.live()
        await c.load()
        XCTAssertTrue(c.repositories.isEmpty)
        XCTAssertNil(c.storeError)
        XCTAssertNil(c.actionError)
    }
    #endif
}
