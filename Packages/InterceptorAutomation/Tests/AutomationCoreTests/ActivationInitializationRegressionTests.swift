import Foundation
import XCTest
@testable import AutomationCore

/// The independent marker survives loss of the shared document, not simultaneous loss of both
/// authorities or restoration of an older valid v2 document.
final class ActivationInitializationRegressionTests: AutomationTestCase {
    private func shared(_ catalog: URL) -> URL { catalog.appendingPathExtension("activation") }
    private func marker(_ catalog: URL) -> URL { shared(catalog).appendingPathExtension("initialized") }
    private func coordinator(_ catalog: URL) -> InstallationCoordinator {
        InstallationCoordinator(catalogURL: catalog, activationURL: shared(catalog))
    }
    private func package(_ source: String = "// original") throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(pluginID.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"a.js"}}}],
        "read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"a.js":"\(source)"}}
        """.utf8))
    }
    private func legacy(_ file: URL, enabled: Bool = true) async throws -> (PluginPackage, InstalledRevision) {
        let p = try package(), store = AutomationStore(fileURL: file)
        let revision = try await store.importLocal(p.bytes)
        // Retained history must not displace an active-preferred legacy selection at the barrier.
        if enabled {
            _ = try await store.importLocal(package("// retained").bytes)
            let activation = PluginActivationStore(fileURL: shared(file))
            let before = try await activation.snapshot()
            _ = try await activation.activate(p, revisionID: revision.id, expectedGeneration: before.generation)
        }
        return (p, revision)
    }
    private func assertReadersReject(_ file: URL, store: PluginActivationStore) async {
        XCTAssertThrowsError(try coordinator(file).state())
        XCTAssertThrowsError(try ActivationDocument.read(CatalogFile(url: shared(file))))
        do {
            _ = try await store.snapshot()
            XCTFail("Grant reader must enforce the same initialization policy, including byte-cache hits")
        } catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
    }

    func testMissingSharedAfterDeleteCannotResurrectRetainedRevision() async throws {
        let f = tempFile(), c = coordinator(f), p = try package()
        let installed = try c.importLocal(p.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        _ = try c.delete(revisionID: installed.installed[0].id, expectedSelectionGeneration: installed.selectionGeneration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(f).path))
        try FileManager.default.removeItem(at: shared(f))
        await assertReadersReject(f, store: PluginActivationStore(fileURL: shared(f)))
    }

    func testMissingSharedAfterFailedPublicationCannotSelectStagedBytes() async throws {
        let f = tempFile(), c = coordinator(f), p = try package()
        let installed = try c.importLocal(p.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        let failing = InstallationCoordinator(catalogURL: f, activationURL: shared(f),
            catalogWriter: { try $0.replace(with: $1) }, activationWriter: { _, _ in throw AutomationError.saveFailed })
        XCTAssertThrowsError(try failing.importLocal(package("// staged").bytes,
            operation: .reinstall(selectedRevisionID: installed.installed[0].id),
            expectedSelectionGeneration: installed.selectionGeneration))
        // Use a different family so validation reaches staging rather than rejecting a changed reinstall.
        let second = try PluginPackage.validate(Data(String(decoding: p.bytes, as: UTF8.self)
            .replacingOccurrences(of: pluginID.uuidString, with: UUID().uuidString).utf8))
        XCTAssertThrowsError(try failing.importLocal(second.bytes, expectedSelectionGeneration: installed.selectionGeneration))
        XCTAssertEqual(try c.state().catalog.revisions.count, 2)
        XCTAssertEqual(try c.state().installed, installed.installed)
        try FileManager.default.removeItem(at: shared(f))
        await assertReadersReject(f, store: PluginActivationStore(fileURL: shared(f)))
    }

    func testMarkerRejectsMissingAndV1SharedEvenForCachedGrantReader() async throws {
        for downgrade in [false, true] {
            let f = tempFile(), c = coordinator(f)
            _ = try await legacy(f)
            let v1 = try Data(contentsOf: shared(f)), state = try c.state()
            let store = PluginActivationStore(fileURL: shared(f))
            _ = try await store.snapshot() // Cache v1 before another writer initializes selections.
            _ = try c.deactivate(revisionID: state.installed[0].id, expectedSelectionGeneration: state.selectionGeneration)
            if downgrade { try v1.write(to: shared(f)) }
            else { try FileManager.default.removeItem(at: shared(f)) }
            await assertReadersReject(f, store: store)
        }
    }

    func testMalformedOversizedNonregularAndSymlinkMarkerInvalidateByteCache() async throws {
        for kind in ["malformed", "unknownField", "unknownVersion", "oversized", "directory", "symlink", "danglingSymlink"] {
            let f = tempFile(), c = coordinator(f)
            _ = try c.importLocal(package().bytes, expectedSelectionGeneration: c.state().selectionGeneration)
            let store = PluginActivationStore(fileURL: shared(f))
            _ = try await store.snapshot()
            let validations = await store.validationCount
            let m = marker(f)
            if FileManager.default.fileExists(atPath: m.path) { try FileManager.default.removeItem(at: m) }
            switch kind {
            case "malformed": try Data("{}".utf8).write(to: m)
            case "unknownField": try Data("{\"version\":1,\"extra\":true}".utf8).write(to: m)
            case "unknownVersion": try Data("{\"version\":2}".utf8).write(to: m)
            case "oversized": try Data(repeating: 32, count: 4097).write(to: m)
            case "directory": try FileManager.default.createDirectory(at: m, withIntermediateDirectories: false)
            default:
                let target = m.appendingPathExtension("target")
                if kind == "symlink" { try Data("{\"version\":1}".utf8).write(to: target) }
                try FileManager.default.createSymbolicLink(at: m, withDestinationURL: target)
            }
            await assertReadersReject(f, store: store)
            let after = await store.validationCount
            XCTAssertEqual(after, validations, "Marker validation must not require revalidating unchanged package bytes")
        }
    }

    func testUnreadableMarkerFailsClosed() async throws {
        let f = tempFile(), c = coordinator(f)
        _ = try c.importLocal(package().bytes, expectedSelectionGeneration: c.state().selectionGeneration)
        let store = PluginActivationStore(fileURL: shared(f))
        _ = try await store.snapshot()
        let m = marker(f)
        if !FileManager.default.fileExists(atPath: m.path) { try Data("{\"version\":1}".utf8).write(to: m) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: m.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: m.path) }
        guard (try? Data(contentsOf: m)) == nil else { throw XCTSkip("Host can read mode-000 files; unreadability cannot be reproduced") }
        await assertReadersReject(f, store: store)
    }

    func testExactLegacyReinstallDoesNotWriteBarrierOrMarker() async throws {
        let f = tempFile(), (p, revision) = try await legacy(f), c = coordinator(f)
        let before = try c.state(), bytes = try Data(contentsOf: shared(f))
        let noWrites = InstallationCoordinator(catalogURL: f, activationURL: shared(f),
            catalogWriter: { _, _ in XCTFail("Exact reinstall must not stage") },
            activationWriter: { _, _ in XCTFail("Exact reinstall must not migrate") })
        XCTAssertEqual(try noWrites.importLocal(p.bytes, operation: .reinstall(selectedRevisionID: revision.id),
            expectedSelectionGeneration: before.selectionGeneration), before)
        XCTAssertEqual(try Data(contentsOf: shared(f)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(f).path))
    }

    func testMarkerPublicationFailurePreservesLegacyProjectionGrantsAndStagesNothing() async throws {
        let f = tempFile(), (_, revision) = try await legacy(f), c = coordinator(f)
        let before = try c.state(), catalogBytes = try Data(contentsOf: f), m = marker(f)
        let failing = InstallationCoordinator(catalogURL: f, activationURL: shared(f),
            catalogWriter: { _, _ in XCTFail("No staging before durable marker"); throw AutomationError.saveFailed },
            activationWriter: { file, bytes in
                // Sabotage only marker publication after the unchanged v2 barrier was written.
                try file.replace(with: bytes)
                try FileManager.default.createDirectory(at: m, withIntermediateDirectories: false)
            })
        let other = try PluginPackage.validate(Data(String(decoding: package("// new").bytes, as: UTF8.self)
            .replacingOccurrences(of: pluginID.uuidString, with: UUID().uuidString).utf8))
        XCTAssertThrowsError(try failing.importLocal(other.bytes, expectedSelectionGeneration: before.selectionGeneration))
        XCTAssertEqual(try Data(contentsOf: f), catalogBytes)
        let barrier = try ActivationDocument.decode(Data(contentsOf: shared(f)))
        XCTAssertEqual(barrier.activation, before.activation)
        XCTAssertEqual(barrier.selectionGeneration, before.selectionGeneration)
        XCTAssertEqual(barrier.selections?[InstallationIdentity.family(revision.id)], revision.id)
        XCTAssertEqual(barrier.selections?.count, 1)
    }

    func testFirstGrantAndDeletePrepareUnchangedBarrierWithoutCatalogStaging() async throws {
        for deleting in [false, true] {
            let f = tempFile(), (p, revision) = try await legacy(f, enabled: deleting), c = coordinator(f)
            let before = try c.state(), catalogBytes = try Data(contentsOf: f)
            let observed = InitializationWrites()
            let transaction = InstallationCoordinator(catalogURL: f, activationURL: shared(f),
                catalogWriter: { _, _ in XCTFail("Grant/delete must not stage catalog history") },
                activationWriter: { file, bytes in try observed.write(file, bytes) })
            if deleting {
                _ = try transaction.delete(revisionID: revision.id, expectedSelectionGeneration: before.selectionGeneration)
            } else {
                _ = try transaction.activate(revisionID: revision.id, expectedSelectionGeneration: before.selectionGeneration,
                    approval: .init(packageBytes: p.bytes, expectedGrantGeneration: before.activation.generation), captureConsent: { true })
            }
            let writes = observed.bytes
            XCTAssertEqual(writes.count, 2, "Unchanged v2 barrier precedes final logical publication")
            if let first = writes.first {
                let barrier = try ActivationDocument.decode(first)
                XCTAssertEqual(barrier.activation, before.activation)
                XCTAssertEqual(barrier.selectionGeneration, before.selectionGeneration)
                XCTAssertEqual(barrier.selections?[InstallationIdentity.family(revision.id)], revision.id)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker(f).path))
            XCTAssertEqual(try Data(contentsOf: f), catalogBytes)
        }
    }

    func testDirectV2WritersRecoverMissingMarkerBeforeGrantMutation() async throws {
        for operation in ["activate", "revoke", "revokeAll"] {
            let f = tempFile(), c = coordinator(f), p = try package()
            let state = try c.importLocal(p.bytes, expectedSelectionGeneration: c.state().selectionGeneration)
            let m = marker(f)
            if FileManager.default.fileExists(atPath: m.path) { try FileManager.default.removeItem(at: m) }
            let store = PluginActivationStore(fileURL: shared(f)), before = try await store.snapshot()
            XCTAssertFalse(FileManager.default.fileExists(atPath: m.path), "A read never repairs the marker")
            switch operation {
            case "activate": _ = try await store.activate(p, revisionID: state.installed[0].id, expectedGeneration: before.generation)
            case "revoke": _ = try await store.revoke(revisionID: state.installed[0].id)
            default: _ = try await store.revokeAll()
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: m.path))
            try FileManager.default.removeItem(at: shared(f))
            await assertReadersReject(f, store: store)
        }
    }
}

private final class InitializationWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    var bytes: [Data] { lock.withLock { values } }
    func write(_ file: CatalogFile, _ bytes: Data) throws {
        try lock.withLock {
            values.append(bytes)
            try file.replace(with: bytes)
        }
    }
}
