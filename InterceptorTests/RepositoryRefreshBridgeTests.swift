import AutomationCore
import XCTest
@testable import Interceptor

/// Drives the real store through the `AutomationStoring` seam so dispatch cannot fall to the fail-closed default.
final class RepositoryRefreshBridgeTests: XCTestCase {
    func testProtocolDispatchRefreshesRealStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshBridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store: any AutomationStoring = AutomationStore(fileURL: dir.appendingPathComponent("catalog.json"))
        let first = try AutomationFixtures.snapshot(packages: [AutomationFixtures.package(name: "A")], sequence: 1)
        let second = try AutomationFixtures.snapshot(packages: [AutomationFixtures.package(name: "A")], sequence: 2)
        let accepted = try await store.accept(first, acknowledgeUnverified: true, now: AutomationFixtures.now)
        let refreshed = try await store.refresh(second, expectedGeneration: accepted.generation, acknowledgeUnverified: false, now: AutomationFixtures.now)
        XCTAssertEqual(refreshed.sequence, 2)
        XCTAssertNotEqual(refreshed.generation, accepted.generation)
        let catalog = try await store.load()
        XCTAssertEqual(catalog.record(for: second.url), refreshed)
    }
}
