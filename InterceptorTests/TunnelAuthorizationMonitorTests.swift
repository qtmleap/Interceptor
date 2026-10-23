@testable import AutomationCore
import Foundation
@testable import Interceptor
import XCTest

final class TunnelAuthorizationMonitorTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelMonitor-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshots() async throws -> (PluginActivationSnapshot, PluginActivationSnapshot, PluginActivationSnapshot) {
        let p = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Monitor"))
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: [p], activationURL: directory.appendingPathComponent("active.json"))
        let empty = try await store.snapshot()
        let active = try await store.activate(p, revisionID: XCTUnwrap(revisions.first).id, expectedGeneration: empty.generation)
        let revoked = try await store.revokeAll()
        return (empty, active, revoked)
    }

    func testStrictSnapshotChangesAndReadFailuresStopWithAccurateReason() async throws {
        let (empty, active, revoked) = try await snapshots()
        for (admitted, current) in [(empty, active), (active, revoked), (empty, revoked)] {
            var monitor = TunnelAuthorizationMonitor(admitted: admitted)
            let id = monitor.id
            XCTAssertTrue(monitor.begin(id: id))
            XCTAssertEqual(monitor.finish(current: current, consent: true, id: id), .stop(.activationChanged))
        }
        for (admitted, current) in [(Optional(active), nil), (nil, Optional(active))] {
            var monitor = TunnelAuthorizationMonitor(admitted: admitted)
            let id = monitor.id
            XCTAssertTrue(monitor.begin(id: id))
            XCTAssertEqual(monitor.finish(current: current, consent: true, id: id), .stop(.activationChanged))
        }
    }

    func testSameGenerationChangedContentsStillStop() async throws {
        let (_, active, _) = try await snapshots()
        let altered = PluginActivationSnapshot(generation: active.generation, revisions: [])
        var monitor = TunnelAuthorizationMonitor(admitted: active)
        let id = monitor.id
        XCTAssertTrue(monitor.begin(id: id))
        XCTAssertEqual(monitor.finish(current: altered, consent: true, id: id), .stop(.activationChanged))
    }

    func testUnchangedAndInitiallyUnreadableStatesContinue() async throws {
        let (_, active, _) = try await snapshots()
        for admitted in [Optional(active), nil] {
            var monitor = TunnelAuthorizationMonitor(admitted: admitted)
            let id = monitor.id
            XCTAssertTrue(monitor.begin(id: id))
            XCTAssertEqual(monitor.finish(current: admitted, consent: true, id: id), .proceed)
            XCTAssertTrue(monitor.begin(id: id), "completion releases the in-flight slot")
        }
    }

    func testConsentTakesPrecedenceOverSimultaneousApprovalChange() async throws {
        let (empty, active, _) = try await snapshots()
        var monitor = TunnelAuthorizationMonitor(admitted: empty)
        let id = monitor.id
        XCTAssertTrue(monitor.begin(id: id))
        XCTAssertEqual(monitor.finish(current: active, consent: false, id: id), .stop(.consentRequired))
    }

    func testInFlightAndStaleChecksCannotOverwriteNewMonitorState() async throws {
        let (empty, active, _) = try await snapshots()
        var monitor = TunnelAuthorizationMonitor(admitted: empty)
        let old = monitor.id
        XCTAssertTrue(monitor.begin(id: old))
        XCTAssertFalse(monitor.begin(id: old))
        monitor.invalidate()
        let current = monitor.id
        XCTAssertFalse(monitor.begin(id: old))
        XCTAssertTrue(monitor.begin(id: current))
        XCTAssertEqual(monitor.finish(current: active, consent: false, id: old), .ignore)
        XCTAssertFalse(monitor.begin(id: current), "old completion cannot release the new check's slot")
        XCTAssertEqual(monitor.finish(current: empty, consent: true, id: current), .proceed)
        XCTAssertEqual(monitor.finish(current: active, consent: false, id: current), .ignore)
    }

    func testChangeDuringTunnelStartupUsesPreStartupAdmission() async throws {
        let (beforeStart, afterStart, _) = try await snapshots()
        // The provider retains beforeStart across MITM startup and network-setting awaits.
        var monitor = TunnelAuthorizationMonitor(admitted: beforeStart)
        let id = monitor.id
        XCTAssertTrue(monitor.begin(id: id))
        XCTAssertEqual(monitor.finish(current: afterStart, consent: true, id: id), .stop(.activationChanged))
    }

    func testConsentPreflightStopsWhileAnApprovalReadIsInFlight() {
        var monitor = TunnelAuthorizationMonitor(admitted: nil)
        let id = monitor.id
        XCTAssertEqual(monitor.begin(id: id, consent: true), .proceed)
        XCTAssertEqual(monitor.begin(id: id, consent: true), .ignore)
        XCTAssertEqual(monitor.begin(id: id, consent: false), .stop(.consentRequired))
        monitor.invalidate()
        XCTAssertEqual(monitor.begin(id: id, consent: false), .ignore, "a stale timer cannot stop a new tunnel")
    }
}
