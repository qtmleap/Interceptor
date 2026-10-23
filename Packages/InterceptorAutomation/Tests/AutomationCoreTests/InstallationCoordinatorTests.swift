import Foundation
import XCTest
@testable import AutomationCore

private final class InstallationWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var fail = false
    var count: Int { lock.withLock { writes } }
    var failing: Bool { get { lock.withLock { fail } } set { lock.withLock { fail = newValue } } }
    func write(_ file: CatalogFile, _ data: Data) throws {
        try lock.withLock {
            writes += 1
            if fail { throw AutomationError.saveFailed }
            try file.replace(with: data)
        }
    }
}

final class InstallationCoordinatorTests: AutomationTestCase {
    private func coordinator(_ file: URL, stage: InstallationWrites? = nil, shared: InstallationWrites? = nil) -> InstallationCoordinator {
        InstallationCoordinator(catalogURL: file, activationURL: file.appendingPathExtension("activation"),
                                catalogWriter: { f, d in if let stage { try stage.write(f, d) } else { try f.replace(with: d) } },
                                activationWriter: { f, d in if let shared { try shared.write(f, d) } else { try f.replace(with: d) } })
    }
    private func package(_ id: UUID = pluginID, source: String = "// original") throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method","host"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """.utf8))
    }
    private func request(_ p: PluginPackage, file: URL, sequence: Int = 1,
                         operation: InstallationOperation = .add) async throws -> InstallationRequest {
        let s = try snap(indexJSON(sequence: sequence, pkg: p.bytes))
        let r = try await AutomationStore(fileURL: file).accept(s, acknowledgeUnverified: true, now: now)
        return InstallationRequest(package: p, snapshot: s, expectedSourceGeneration: r.generation, operation: operation)
    }
    private func approved(_ state: InstallationState, _ p: PluginPackage) -> InstallationApproval {
        .init(packageBytes: p.bytes, expectedGrantGeneration: state.activation.generation)
    }

    func testDisabledInstallKeepsGrantSnapshotAndSameBytesReinstallWritesNothing() async throws {
        let f = tempFile(), stage = InstallationWrites(), shared = InstallationWrites()
        let c = coordinator(f, stage: stage, shared: shared), p = try package()
        let req = try await request(p, file: f)
        let before = try c.state()
        let installed = try c.batch([req], expectedSelectionGeneration: before.selectionGeneration, now: now)
        XCTAssertEqual(installed.activation, before.activation)
        XCTAssertEqual(installed.installed.map(\.package.bytes), [p.bytes])
        let active = try c.activate(revisionID: installed.installed[0].id, expectedSelectionGeneration: installed.selectionGeneration,
                                    approval: approved(installed, p), captureConsent: { true })
        let n = stage.count, m = shared.count
        let reinstall = InstallationRequest(package: p, snapshot: req.snapshot, expectedSourceGeneration: req.expectedSourceGeneration,
                                            operation: .reinstall(selectedRevisionID: active.installed[0].id))
        XCTAssertEqual(try c.batch([reinstall], expectedSelectionGeneration: active.selectionGeneration, now: now), active)
        XCTAssertEqual(stage.count, n)
        XCTAssertEqual(shared.count, m)
    }

    func testFailedSharedPublishAfterStageStaysHiddenAfterRevokeAndRestart() async throws {
        let f = tempFile(), shared = InstallationWrites(), c = coordinator(f, shared: shared)
        let old = try package(), new = try package(source: "// changed")
        var s = try c.importLocal(old.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        s = try c.activate(revisionID: s.installed[0].id, expectedSelectionGeneration: s.selectionGeneration,
                           approval: approved(s, old), captureConsent: { true })
        let req = try await request(new, file: f)
        shared.failing = true
        XCTAssertThrowsError(try c.batch([req], expectedSelectionGeneration: s.selectionGeneration, now: now))
        XCTAssertEqual(try c.state().installed, s.installed)
        XCTAssertEqual(try c.state().activation, s.activation)
        shared.failing = false
        _ = try await PluginActivationStore(fileURL: f.appendingPathExtension("activation")).revokeAll()
        let restarted = try coordinator(f).state()
        XCTAssertEqual(restarted.installed, s.installed)
        XCTAssertTrue(restarted.activation.revisions.isEmpty)
        XCTAssertEqual(restarted.catalog.revisions.count, 2, "failed publication leaves only hidden cache history")
    }

    func testFirstInstallFailureAndStageFailureNeverBecomeLegacySelection() async throws {
        for failStage in [true, false] {
            let f = tempFile(), stage = InstallationWrites(), shared = InstallationWrites()
            let c = coordinator(f, stage: stage, shared: shared)
            // Initialize with a disabled local family; this exercises the explicit v2 barrier too.
            let empty = try c.state()
            XCTAssertFalse(empty.selectionsInitialized)
            let req = try await request(package(), file: f)
            if failStage { stage.failing = true } else {
                // The second shared write is publication; the first is the migration barrier.
                let failing = InstallationCoordinator(catalogURL: f, activationURL: f.appendingPathExtension("activation"),
                    catalogWriter: { try $0.replace(with: $1) }, activationWriter: { file, data in
                        if FileManager.default.fileExists(atPath: file.url.path) { throw AutomationError.saveFailed }
                        try file.replace(with: data)
                    })
                XCTAssertThrowsError(try failing.batch([req], expectedSelectionGeneration: empty.selectionGeneration, now: now))
                XCTAssertTrue(try coordinator(f).state().installed.isEmpty)
                _ = try await PluginActivationStore(fileURL: f.appendingPathExtension("activation")).revokeAll()
                XCTAssertTrue(try coordinator(f).state().installed.isEmpty)
                continue
            }
            XCTAssertThrowsError(try c.batch([req], expectedSelectionGeneration: empty.selectionGeneration, now: now))
            XCTAssertTrue(try coordinator(f).state().installed.isEmpty)
        }
    }

    func testBatchLastInvalidAndStaleQueuePreserveBothAuthorities() async throws {
        let f = tempFile(), c = coordinator(f), p = try package()
        let req = try await request(p, file: f), before = try c.state()
        let invalid = InstallationRequest(package: try package(UUID(), source: "// not in reviewed index"), snapshot: req.snapshot,
                                          expectedSourceGeneration: req.expectedSourceGeneration, operation: .add)
        XCTAssertThrowsError(try c.batch([req, invalid], expectedSelectionGeneration: before.selectionGeneration, now: now))
        XCTAssertEqual(try c.state(), before)
        let installed = try c.batch([req], expectedSelectionGeneration: before.selectionGeneration, now: now)
        XCTAssertThrowsError(try c.batch([req], expectedSelectionGeneration: before.selectionGeneration, now: now))
        XCTAssertEqual(try c.state(), installed)
    }

    func testEnabledUpdateCASConsentAndExactApprovalThenAtomicReplacement() async throws {
        let f = tempFile(), c = coordinator(f), p = try package(), next = try package(source: "// new permissions and bytes")
        let req = try await request(p, file: f)
        var s = try c.batch([req], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        s = try c.activate(revisionID: s.installed[0].id, expectedSelectionGeneration: s.selectionGeneration,
                           approval: approved(s, p), captureConsent: { true })
        let update = try await request(next, file: f, sequence: 2), base = s.installed[0].id
        for approval in [nil, approved(s, p), InstallationApproval(packageBytes: next.bytes, expectedGrantGeneration: UUID())] {
            XCTAssertThrowsError(try c.update(update, baseRevisionID: base, expectedSelectionGeneration: s.selectionGeneration,
                                              approval: approval, now: now, captureConsent: { true }))
            XCTAssertEqual(try c.state().installed, s.installed)
            XCTAssertEqual(try c.state().activation, s.activation)
        }
        XCTAssertThrowsError(try c.update(update, baseRevisionID: base, expectedSelectionGeneration: s.selectionGeneration,
                                          approval: approved(s, next), now: now, captureConsent: { false }))
        XCTAssertEqual(try c.state().activation, s.activation)
        let result = try c.update(update, baseRevisionID: base, expectedSelectionGeneration: s.selectionGeneration,
                                  approval: approved(s, next), now: now, captureConsent: { true })
        XCTAssertEqual(result.installed.map(\.package.bytes), [next.bytes])
        XCTAssertEqual(result.activation.revisions.map(\.package.bytes), [next.bytes])
        XCTAssertThrowsError(try c.update(update, baseRevisionID: base, expectedSelectionGeneration: result.selectionGeneration,
                                          approval: approved(result, next), now: now, captureConsent: { true }))
    }

    func testDeleteThenLegacyMutationCannotReappearAndReadsReload() async throws {
        let f = tempFile(), c = coordinator(f), p = try package()
        let installed = try c.importLocal(p.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        let observer = AutomationStore(fileURL: f)
        _ = try await observer.load()
        _ = try c.delete(revisionID: installed.installed[0].id, expectedSelectionGeneration: installed.selectionGeneration)
        _ = try await observer.importLocal(try package(source: "// legacy edit").bytes)
        XCTAssertTrue(try c.state().installed.isEmpty)
        let reloaded = try await observer.load()
        XCTAssertEqual(reloaded.revisions.count, 2)
    }

    func testLegacyProjectionActivePreferredReadOnlyAndCorruptV2Blocks() async throws {
        let f = tempFile(), p = try package(), next = try package(source: "// last history")
        let store = AutomationStore(fileURL: f)
        let old = try await store.importLocal(p.bytes)
        _ = try await store.importLocal(next.bytes)
        let activation = PluginActivationStore(fileURL: f.appendingPathExtension("activation"))
        _ = try await activation.activate(p, revisionID: old.id, expectedGeneration: activation.snapshot().generation)
        let bytes = try Data(contentsOf: f.appendingPathExtension("activation")), c = coordinator(f)
        XCTAssertEqual(try c.state().installed.map(\.id), [old.id])
        XCTAssertFalse(try c.state().selectionsInitialized)
        XCTAssertEqual(try Data(contentsOf: f.appendingPathExtension("activation")), bytes)
        _ = try c.deactivate(revisionID: old.id, expectedSelectionGeneration: c.state().selectionGeneration)
        let shared = f.appendingPathExtension("activation")
        var root = try XCTUnwrap(JSONValue(parsing: Data(contentsOf: shared)).objectValue)
        root["selections"] = .array([.object(["family": .string("local|forged"), "revisionID": .string(old.id)])])
        let bad = try JSONValue.object(root).data()
        try bad.write(to: shared)
        XCTAssertThrowsError(try c.state())
        XCTAssertThrowsError(try c.delete(revisionID: old.id, expectedSelectionGeneration: UUID()))
        XCTAssertEqual(try Data(contentsOf: shared), bad)
    }
}
