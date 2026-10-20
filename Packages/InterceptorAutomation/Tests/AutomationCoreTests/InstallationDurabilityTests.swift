import Foundation
import XCTest
@testable import AutomationCore

final class InstallationDurabilityTests: AutomationTestCase {
    private func coordinator(_ f: URL) -> InstallationCoordinator {
        .init(catalogURL: f, activationURL: f.appendingPathExtension("activation"))
    }
    private func request(_ p: PluginPackage, at source: RepositoryURL, file: URL, sequence: Int = 1) async throws -> InstallationRequest {
        let s = try RepositoryEnvelope.verify(envelope: envelope(indexJSON(sequence: sequence, pkg: p.bytes)), url: source, now: now)
        let record = try await AutomationStore(fileURL: file).accept(s, acknowledgeUnverified: true, now: now)
        return .init(package: p, snapshot: s, expectedSourceGeneration: record.generation, operation: .add)
    }
    private func routed(_ source: String = "// approved", requestBody: Bool = false) throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(pluginID.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":\(requestBody),"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """.utf8))
    }

    func testCollidingUUIDsAreDistinctAcrossSourcesAndLocalAndSourceRemovalDoesNotUninstall() async throws {
        let f = tempFile(), c = coordinator(f), p = try PluginPackage.validate(packageBytes())
        let second = try RepositoryURL(parsing: "https://another.example/repository.json")
        let a = try await request(p, at: url(), file: f), b = try await request(p, at: second, file: f)
        let state = try c.batch([a, b], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        XCTAssertEqual(state.installed.count, 2)
        let local = try c.importLocal(p.bytes, expectedSelectionGeneration: state.selectionGeneration)
        XCTAssertEqual(local.installed.count, 3)
        XCTAssertEqual(Set(local.installed.map(\.id)).count, 3)
        try await AutomationStore(fileURL: f).remove(second)
        XCTAssertEqual(try c.state().installed, local.installed)
        XCTAssertEqual(try c.state().activation, state.activation)
    }

    func testDisabledUpdateStaysDisabledAndSourceExpiryGenerationAndQueueBoundAreChecked() async throws {
        let f = tempFile(), c = coordinator(f), p = try PluginPackage.validate(packageBytes())
        let a = try await request(p, at: url(), file: f)
        let old = try c.batch([a], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        let next = try PluginPackage.validate(packageBytes(source: "// next"))
        let b = try await request(next, at: url(), file: f, sequence: 2)
        XCTAssertThrowsError(try c.batch([a], expectedSelectionGeneration: old.selectionGeneration, now: now))
        XCTAssertThrowsError(try c.update(b, baseRevisionID: old.installed[0].id, expectedSelectionGeneration: old.selectionGeneration,
                                        approval: nil, now: now.addingTimeInterval(3 * 86_400), captureConsent: { false }))
        XCTAssertThrowsError(try c.batch(Array(repeating: b, count: Limits.revisions + 1), expectedSelectionGeneration: old.selectionGeneration, now: now))
        let new = try c.update(b, baseRevisionID: old.installed[0].id, expectedSelectionGeneration: old.selectionGeneration,
                               approval: nil, now: now, captureConsent: { false })
        XCTAssertEqual(new.activation, old.activation)
        XCTAssertEqual(new.installed.map(\.package.bytes), [next.bytes])
    }

    func testEnabledReplacementAtFourActiveAndFailedSharedWriteKeepExactOldGrant() async throws {
        let f = tempFile(), c = coordinator(f), p = try routed()
        var requests: [InstallationRequest] = []
        for i in 0..<4 {
            let source = try RepositoryURL(parsing: "https://source\(i).example/repository.json")
            requests.append(try await request(p, at: source, file: f))
        }
        var state = try c.batch(requests, expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        for revision in state.installed {
            state = try c.activate(revisionID: revision.id, expectedSelectionGeneration: state.selectionGeneration,
                                   approval: .init(packageBytes: p.bytes, expectedGrantGeneration: state.activation.generation), captureConsent: { true })
        }
        XCTAssertEqual(state.activation.revisions.count, 4)
        let next = try routed("// update", requestBody: true), source = requests[0].snapshot.url
        let updatedRequest = try await request(next, at: source, file: f, sequence: 2)
        let base = try XCTUnwrap(state.installed.first { $0.id.hasPrefix(source.canonical + "|") })
        XCTAssertThrowsError(try c.update(updatedRequest, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
            approval: nil, now: now, captureConsent: { true }))
        XCTAssertThrowsError(try c.update(updatedRequest, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
            approval: .init(packageBytes: next.bytes, expectedGrantGeneration: state.activation.generation), now: now, captureConsent: { false }))
        XCTAssertEqual(try c.state().activation, state.activation)
        let failing = InstallationCoordinator(catalogURL: f, activationURL: f.appendingPathExtension("activation"),
            catalogWriter: { try $0.replace(with: $1) }, activationWriter: { _, _ in throw AutomationError.saveFailed })
        XCTAssertThrowsError(try failing.update(updatedRequest, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
            approval: .init(packageBytes: next.bytes, expectedGrantGeneration: state.activation.generation), now: now, captureConsent: { true }))
        XCTAssertEqual(try c.state().installed, state.installed)
        XCTAssertEqual(try c.state().activation, state.activation)
        let updated = try c.update(updatedRequest, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
            approval: .init(packageBytes: next.bytes, expectedGrantGeneration: state.activation.generation), now: now, captureConsent: { true })
        XCTAssertEqual(updated.activation.revisions.count, 4)
        XCTAssertFalse(updated.activation.contains(revisionID: base.id))
        XCTAssertEqual(updated.installed.filter { $0.package.bytes == next.bytes }.count, 1)
    }

    func testTwoEntryBatchWriterFailuresLeaveBothSelectionsAndGrantsUnchanged() async throws {
        for failStage in [true, false] {
            let f = tempFile(), c = coordinator(f), p = try PluginPackage.validate(packageBytes())
            _ = try c.importLocal(p.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
            let a = try await request(p, at: url(), file: f)
            let b = try await request(p, at: RepositoryURL(parsing: "https://second.example/repository.json"), file: f)
            let before = try c.state()
            let sharedBefore = try Data(contentsOf: f.appendingPathExtension("activation"))
            let failing = InstallationCoordinator(catalogURL: f, activationURL: f.appendingPathExtension("activation"),
                catalogWriter: { file, bytes in
                    if failStage { throw AutomationError.saveFailed }
                    try file.replace(with: bytes)
                }, activationWriter: { _, _ in throw AutomationError.saveFailed })
            XCTAssertThrowsError(try failing.batch([a, b], expectedSelectionGeneration: before.selectionGeneration, now: now))
            let restarted = try coordinator(f).state()
            XCTAssertEqual(restarted.installed, before.installed)
            XCTAssertEqual(restarted.selectionGeneration, before.selectionGeneration)
            XCTAssertEqual(restarted.activation, before.activation)
            XCTAssertEqual(try Data(contentsOf: f.appendingPathExtension("activation")), sharedBefore)
            XCTAssertEqual(restarted.catalog.revisions.count, failStage ? 1 : 3)
        }
    }

    func testConcurrentControllersOnlyOneWinsSelectionCAS() async throws {
        let f = tempFile(), a = coordinator(f), b = coordinator(f), p = try PluginPackage.validate(packageBytes())
        let req = try await request(p, at: url(), file: f), initial = try a.state()
        let results = await withTaskGroup(of: Bool.self) { group in
            for c in [a, b] {
                group.addTask {
                    do { _ = try c.batch([req], expectedSelectionGeneration: initial.selectionGeneration, now: now); return true }
                    catch { return false }
                }
            }
            var successes = 0
            for await success in group { if success { successes += 1 } }
            return successes
        }
        XCTAssertEqual(results, 1)
        XCTAssertEqual(try a.state().installed.count, 1)
    }

    func testLegacyLastRevisionReadOnlyAndMissingSelectedBytesOrCorruptV1NeverRepaired() async throws {
        let f = tempFile(), store = AutomationStore(fileURL: f), c = coordinator(f)
        _ = try await store.importLocal(packageBytes())
        let last = try await store.importLocal(packageBytes(source: "// last"))
        let initial = try c.state()
        XCTAssertEqual(initial.installed.map(\.id), [last.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.appendingPathExtension("activation").path))
        _ = try c.delete(revisionID: last.id, expectedSelectionGeneration: initial.selectionGeneration)
        let imported = try c.importLocal(last.package.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        try await store.deleteRevision(last.id)
        XCTAssertThrowsError(try c.state(), "orphan v2 selected bytes fail closed")
        XCTAssertThrowsError(try c.delete(revisionID: last.id, expectedSelectionGeneration: imported.selectionGeneration))
        let shared = f.appendingPathExtension("activation")
        let corrupt = Data(#"{"version":1,"generation":"00000000-0000-0000-0000-000000000000","revisions":[]}"#.utf8)
        try corrupt.write(to: shared)
        XCTAssertThrowsError(try c.state())
        do { _ = try await PluginActivationStore(fileURL: shared).revokeAll(); XCTFail("corrupt v1 must remain untouched") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: shared), corrupt)
    }

    func testLegacyRevocationFreezesActivePreferredSelectionInsteadOfSelectingLastHistory() async throws {
        for all in [false, true] {
            let f = tempFile(), c = coordinator(f), p = try routed(), newer = try routed("// later history")
            let store = AutomationStore(fileURL: f)
            let old = try await store.importLocal(p.bytes)
            _ = try await store.importLocal(newer.bytes)
            let shared = f.appendingPathExtension("activation")
            let legacy = PluginActivationStore(fileURL: shared)
            let initial = try await legacy.snapshot()
            _ = try await legacy.activate(p, revisionID: old.id, expectedGeneration: initial.generation)
            XCTAssertEqual(try c.state().installed.map(\.id), [old.id])
            do { _ = try await legacy.revokeAll(); XCTFail("legacy revoke needs catalog context, not a guessed projection") }
            catch { XCTAssertEqual(error as? InstallationError, .activationUnavailable) }
            let configured = PluginActivationStore(fileURL: shared, catalogURL: f)
            if all { _ = try await configured.revokeAll() }
            else { _ = try await configured.revoke(revisionID: old.id) }
            let restarted = try coordinator(f).state()
            XCTAssertEqual(restarted.installed.map(\.id), [old.id])
            XCTAssertTrue(restarted.selectionsInitialized)
            XCTAssertTrue(restarted.activation.revisions.isEmpty)
        }
    }

    func testMissingSharedURLBlocksMutationsAndExplicitRevokeInvalidatesApprovals() async throws {
        let f = tempFile(), c = InstallationCoordinator(catalogURL: f, activationURL: nil)
        XCTAssertThrowsError(try c.importLocal(packageBytes(), expectedSelectionGeneration: c.state().selectionGeneration))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        let store = PluginActivationStore(fileURL: f.appendingPathExtension("activation"))
        let before = try await store.snapshot()
        let after = try await store.revokeAll()
        XCTAssertNotEqual(before.generation, after.generation)
        XCTAssertTrue(after.revisions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.appendingPathExtension("activation").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }
}
