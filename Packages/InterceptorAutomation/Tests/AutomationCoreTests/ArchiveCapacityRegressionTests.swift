import Foundation
import XCTest
@testable import AutomationCore

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

/// The hidden catalogue history has one replacement slot beyond the 32 installable families.
/// These tests pin the observable contract: history never blocks install/update, locked selected and granted
/// bytes survive every failure, and only unreferenced history is pruned, only before staging a later mutation.
final class ArchiveCapacityRegressionTests: AutomationTestCase {
    private let archiveLimit = Limits.revisions + 1

    private func coordinator(_ f: URL, catalogWriter: InstallationCoordinator.Writer? = nil,
                             activationWriter: InstallationCoordinator.Writer? = nil) -> InstallationCoordinator {
        InstallationCoordinator(catalogURL: f, activationURL: f.appendingPathExtension("activation"),
                                catalogWriter: catalogWriter ?? { try $0.replace(with: $1) },
                                activationWriter: activationWriter ?? { try $0.replace(with: $1) })
    }
    private func failStage(_ f: URL) -> InstallationCoordinator {
        coordinator(f, catalogWriter: { _, _ in throw AutomationError.saveFailed })
    }
    private func failPublish(_ f: URL) -> InstallationCoordinator {
        coordinator(f, activationWriter: { _, _ in throw AutomationError.saveFailed })
    }
    private func package(_ id: UUID = pluginID, source: String, requestBody: Bool = false) throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":\(requestBody),"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """.utf8))
    }
    private func request(_ p: PluginPackage, at source: RepositoryURL = url(), file: URL, sequence: Int = 1) async throws -> InstallationRequest {
        let s = try RepositoryEnvelope.verify(envelope: envelope(indexJSON(sequence: sequence, pkg: p.bytes)), url: source, now: now)
        let record = try await AutomationStore(fileURL: file).accept(s, acknowledgeUnverified: true, now: now)
        return .init(package: p, snapshot: s, expectedSourceGeneration: record.generation, operation: .add)
    }
    private func approval(_ p: PluginPackage, _ s: InstallationState) -> InstallationApproval {
        .init(packageBytes: p.bytes, expectedGrantGeneration: s.activation.generation)
    }
    private func bytes(_ f: URL) throws -> Data { try Data(contentsOf: f) }
    private func archived(_ state: InstallationState) -> [Data] { state.catalog.revisions.map(\.package.bytes) }

    /// A repository family at version `next` replacing `state`'s repository selection.
    private func update(_ c: InstallationCoordinator, _ f: URL, _ state: InstallationState, to p: PluginPackage,
                        sequence: Int, enabled: Bool) async throws -> InstallationState {
        let base = try XCTUnwrap(state.installed.first { !$0.id.hasPrefix("local|") })
        let r = try await request(p, file: f, sequence: sequence)
        return try c.update(r, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
                            approval: enabled ? approval(p, state) : nil, now: now, captureConsent: { true })
    }
    private func fullState(_ f: URL, enabled: Bool, base: PluginPackage) async throws -> InstallationState {
        let c = coordinator(f)
        var state = try c.batch([await request(base, file: f)], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        if enabled {
            state = try c.activate(revisionID: state.installed[0].id, expectedSelectionGeneration: state.selectionGeneration,
                                   approval: approval(base, state), captureConsent: { true })
        }
        for i in 0..<(Limits.revisions - 1) {
            state = try c.importLocal(package(UUID(), source: "// local \(i)").bytes, expectedSelectionGeneration: state.selectionGeneration)
        }
        XCTAssertEqual(state.installed.count, Limits.revisions)
        XCTAssertEqual(state.installed.filter { $0.id.hasPrefix("local|") }.count, Limits.revisions - 1)
        return state
    }

    func testLocalInstallDeleteCyclesBeyondArchiveCapRemainPossible() throws {
        let f = tempFile(), c = coordinator(f)
        var state = try c.state()
        for i in 0..<(Limits.revisions + 8) {
            let p = try package(source: "// cycle \(i)")
            state = try c.importLocal(p.bytes, expectedSelectionGeneration: state.selectionGeneration)
            XCTAssertEqual(state.installed.map(\.package.bytes), [p.bytes], "cycle \(i)")
            let beforeDelete = state.activation
            state = try c.delete(revisionID: state.installed[0].id, expectedSelectionGeneration: state.selectionGeneration)
            XCTAssertTrue(state.installed.isEmpty)
            XCTAssertTrue(state.activation.revisions.isEmpty, "disabled cycle never grants execution")
            XCTAssertNotEqual(state.activation.generation, beforeDelete.generation, "delete cancels outstanding approvals even when disabled")
            XCTAssertLessThanOrEqual(state.catalog.revisions.count, archiveLimit)
        }
        let last = try package(source: "// final")
        state = try c.importLocal(last.bytes, expectedSelectionGeneration: state.selectionGeneration)
        XCTAssertEqual(try coordinator(f).state().installed.map(\.package.bytes), [last.bytes])
        XCTAssertLessThanOrEqual(state.catalog.revisions.count, archiveLimit)
    }

    func testRepeatedSameFamilyRepositoryUpdatesBeyondArchiveCapRemainPossible() async throws {
        let f = tempFile(), c = coordinator(f)
        var state = try c.batch([await request(package(source: "// v0"), file: f)],
                                expectedSelectionGeneration: c.state().selectionGeneration, now: now)
        let grants = state.activation
        for i in 1...(Limits.revisions + 2) {
            let next = try package(source: "// v\(i)")
            state = try await update(c, f, state, to: next, sequence: i + 1, enabled: false)
            XCTAssertEqual(state.installed.map(\.package.bytes), [next.bytes], "update \(i)")
            XCTAssertEqual(state.activation, grants)
            XCTAssertLessThanOrEqual(state.catalog.revisions.count, archiveLimit)
        }
        XCTAssertEqual(try coordinator(f).state().installed, state.installed)
    }

    func testFull32UpdateWithInjectedFailuresPreservesSelectedBytesProvenanceAndGrants() async throws {
        for enabled in [false, true] {
            let f = tempFile(), old = try package(source: "// old", requestBody: false)
            let state = try await fullState(f, enabled: enabled, base: old)
            let sharedBefore = try bytes(f.appendingPathExtension("activation"))
            let next = try package(source: "// next", requestBody: false)

            for failing in [failStage(f), failPublish(f)] {
                let base = try XCTUnwrap(state.installed.first { !$0.id.hasPrefix("local|") })
                let r = try await request(next, file: f, sequence: 2)
                XCTAssertThrowsError(try failing.update(r, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
                    approval: enabled ? approval(next, state) : nil, now: now, captureConsent: { true })) {
                    XCTAssertEqual($0 as? AutomationError, .saveFailed, "full-32 update must reach the injected writer")
                }
                let after = try coordinator(f).state()
                XCTAssertEqual(after.installed, state.installed, "selected bytes and provenance")
                XCTAssertEqual(after.activation, state.activation, "grant snapshot, enabled=\(enabled)")
                XCTAssertEqual(after.selectionGeneration, state.selectionGeneration)
                XCTAssertEqual(try bytes(f.appendingPathExtension("activation")), sharedBefore)
                for revision in state.catalog.revisions {
                    XCTAssertTrue(after.catalog.revisions.contains(revision), "published-old history survives failed mutation")
                }
                XCTAssertLessThanOrEqual(after.catalog.revisions.count, archiveLimit)
            }
            XCTAssertLessThanOrEqual(try bytes(f).count, Limits.catalogBytes)
        }
    }

    func testFull32UpdateSucceedsAndLaterMutationReclaimsFailedPublicationOrphan() async throws {
        for enabled in [false, true] {
            let f = tempFile(), old = try package(source: "// old")
            let state = try await fullState(f, enabled: enabled, base: old)
            let orphan = try package(source: "// orphan"), final = try package(source: "// final")
            let r = try await request(orphan, file: f, sequence: 2)
            let base = try XCTUnwrap(state.installed.first { !$0.id.hasPrefix("local|") })
            XCTAssertThrowsError(try failPublish(f).update(r, baseRevisionID: base.id, expectedSelectionGeneration: state.selectionGeneration,
                approval: enabled ? approval(orphan, state) : nil, now: now, captureConsent: { true }))
            let hidden = try coordinator(f).state()
            XCTAssertEqual(hidden.installed, state.installed)
            XCTAssertTrue(archived(hidden).contains(orphan.bytes), "failed publication leaves hidden history")

            let c = coordinator(f)
            let updated = try await update(c, f, hidden, to: final, sequence: 3, enabled: enabled)
            XCTAssertEqual(updated.installed.count, Limits.revisions)
            XCTAssertEqual(updated.installed.filter { $0.package.bytes == final.bytes }.count, 1)
            XCTAssertEqual(updated.installed.filter { $0.id.hasPrefix("local|") }, state.installed.filter { $0.id.hasPrefix("local|") })
            XCTAssertFalse(archived(updated).contains(orphan.bytes), "unreferenced orphan pruned before staging")
            XCTAssertLessThanOrEqual(updated.catalog.revisions.count, archiveLimit)
            XCTAssertEqual(updated.activation.revisions.count, enabled ? 1 : 0)
        }
    }

    func testFailedMultiEntryBatchOrphansAreReclaimedByLaterMutationButNotByExactReinstall() async throws {
        let f = tempFile(), c = coordinator(f), kept = try package(UUID(), source: "// kept")
        let installed = try c.importLocal(kept.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        let p = try package(source: "// batch")
        let a = try await request(p, at: url(), file: f)
        let b = try await request(p, at: RepositoryURL(parsing: "https://second.example/repository.json"), file: f)
        XCTAssertThrowsError(try failPublish(f).batch([a, b], expectedSelectionGeneration: installed.selectionGeneration, now: now))
        let hidden = try coordinator(f).state()
        XCTAssertEqual(hidden.installed, installed.installed)
        XCTAssertEqual(hidden.catalog.revisions.count, 3)
        let orphanIDs = Set(hidden.catalog.revisions.map(\.id)).subtracting(installed.installed.map(\.id))
        XCTAssertEqual(orphanIDs.count, 2)

        let catalogWrites = WriteCounter(), sharedWrites = WriteCounter()
        let counting = coordinator(f, catalogWriter: { catalogWrites.bump(); try $0.replace(with: $1) },
                                   activationWriter: { sharedWrites.bump(); try $0.replace(with: $1) })
        let same = try counting.importLocal(kept.bytes, operation: .reinstall(selectedRevisionID: installed.installed[0].id),
                                            expectedSelectionGeneration: hidden.selectionGeneration)
        XCTAssertEqual(same, hidden)
        XCTAssertEqual(catalogWrites.count, 0)
        XCTAssertEqual(sharedWrites.count, 0)
        XCTAssertEqual(try coordinator(f).state().catalog.revisions.count, 3, "exact reinstall performs no cleanup write")

        let other = try package(UUID(), source: "// other")
        let next = try counting.importLocal(other.bytes, expectedSelectionGeneration: hidden.selectionGeneration)
        XCTAssertEqual(Set(next.catalog.revisions.map(\.id)).intersection(orphanIDs), [])
        XCTAssertEqual(Set(next.installed.map(\.package.bytes)), [kept.bytes, other.bytes])
        XCTAssertEqual(next.catalog.revisions.count, 2)
        XCTAssertEqual(catalogWrites.count, 1)
        XCTAssertEqual(sharedWrites.count, 1)
        XCTAssertEqual(next.activation, installed.activation)
    }

    func testThirtyThirdSelectedFamilyIsRejectedWithoutWrites() throws {
        let f = tempFile(), c = coordinator(f)
        var state = try c.state()
        for i in 0..<Limits.revisions {
            state = try c.importLocal(package(UUID(), source: "// local \(i)").bytes, expectedSelectionGeneration: state.selectionGeneration)
        }
        let sharedBefore = try bytes(f.appendingPathExtension("activation")), catalogBefore = try bytes(f)
        XCTAssertThrowsError(try c.importLocal(package(UUID(), source: "// 33rd").bytes, expectedSelectionGeneration: state.selectionGeneration)) {
            XCTAssertEqual($0 as? AutomationError, .limitExceeded)
        }
        XCTAssertEqual(try coordinator(f).state(), state)
        XCTAssertEqual(try bytes(f.appendingPathExtension("activation")), sharedBefore)
        XCTAssertEqual(try bytes(f), catalogBefore)
    }
}
