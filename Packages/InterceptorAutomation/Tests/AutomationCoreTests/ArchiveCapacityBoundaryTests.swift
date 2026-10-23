import Foundation
import XCTest
@testable import AutomationCore

final class ArchiveCapacityBoundaryTests: AutomationTestCase {
    private func revision(_ index: Int, id: UUID = UUID(), padded: Bool = false) throws -> InstalledRevision {
        var bytes = Data(String(decoding: packageBytes(source: "// revision \(index)"), as: UTF8.self)
            .replacingOccurrences(of: pluginID.uuidString, with: id.uuidString).utf8)
        if padded { bytes.append(Data(repeating: 32, count: Limits.package - bytes.count)) }
        return InstalledRevision(package: try PluginPackage.validate(bytes),
                                 provenance: .init(origin: .localImport, trustAtImport: nil), enabled: false)
    }

    func testStrictArchiveDecoderAccepts33AndRejects34() throws {
        var catalog = Catalog()
        catalog.revisions = try (0..<33).map { try revision($0) }
        XCTAssertEqual(try CatalogCodec.decode(CatalogCodec.encode(catalog)), catalog)
        catalog.revisions.append(try revision(33))
        assertThrows(.corruptStore, try CatalogCodec.decode(CatalogCodec.encode(catalog)))
    }

    func testLegacyProjectionRejects33SelectedFamiliesWithoutRepair() throws {
        let f = tempFile(), shared = f.appendingPathExtension("activation")
        var catalog = Catalog()
        catalog.revisions = try (0..<33).map { try revision($0) }
        let bytes = try CatalogCodec.encode(catalog)
        try CatalogFile(url: f).replace(with: bytes)
        assertThrows(.limitExceeded, try InstallationCoordinator(catalogURL: f, activationURL: shared).state())
        XCTAssertEqual(try Data(contentsOf: f), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathExtension("initialized").path))
    }

    func testMaximumSelectedBytesAndReplacementArchiveHeadroomAreReadable() throws {
        var catalog = Catalog()
        let familyID = UUID()
        catalog.revisions = try (0..<32).map { try revision($0, id: $0 == 0 ? familyID : UUID(), padded: true) }
        let selections = Dictionary(uniqueKeysWithValues: catalog.revisions.map { (InstallationIdentity.family($0.id), $0.id) })
        XCTAssertEqual(catalog.revisions.reduce(0) { $0 + $1.package.bytes.count }, Limits.rawPackageBytes)
        catalog.revisions.append(try revision(32, id: familyID, padded: true))
        XCTAssertEqual(catalog.revisions.reduce(0) { $0 + $1.package.bytes.count }, Limits.archiveRawPackageBytes)
        let decoded = try CatalogCodec.decode(CatalogCodec.encode(catalog))
        let document = ActivationDocument(activation: .empty, selectionGeneration: UUID(), selections: selections)
        XCTAssertEqual(try document.projected(over: decoded).selections, selections)
        // Beyond these byte limits requires a 33rd selection/34th archive entry or an oversized
        // package; those independent count/package bounds reject first, not an artificial raw-byte fixture.
    }

    func testMetadataRefreshPreserves33EntryArchive() async throws {
        let f = tempFile()
        var catalog = Catalog()
        catalog.revisions = try (0..<33).map { try revision($0) }
        try CatalogFile(url: f).replace(with: CatalogCodec.encode(catalog))
        let store = AutomationStore(fileURL: f)
        let first = try snap(indexJSON())
        _ = try await store.accept(first, acknowledgeUnverified: true, now: now)
        let next = try snap(indexJSON(sequence: 2))
        _ = try await store.accept(next, acknowledgeUnverified: true, now: now)
        let reloaded = try CatalogCodec.decode(Data(contentsOf: f))
        XCTAssertEqual(reloaded.revisions, catalog.revisions, "metadata has no activation lock and must not prune")
        XCTAssertEqual(reloaded.record(for: url())?.sequence, 2)
        do {
            _ = try await store.importLocal(packageBytes(source: "// legacy direct install"))
            XCTFail("Legacy direct install retains its 32-entry bound")
        } catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        XCTAssertEqual(try CatalogCodec.decode(Data(contentsOf: f)), reloaded)
    }

    func testLegacyActivePreferredBytesAndProvenanceSurvivePruning() async throws {
        let f = tempFile(), shared = f.appendingPathExtension("activation")
        let old = try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(pluginID.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"a.js"}}}],
        "read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"a.js":"// old"}}
        """.utf8))
        let later = try PluginPackage.validate(Data(String(decoding: old.bytes, as: UTF8.self).replacingOccurrences(of: "// old", with: "// later").utf8))
        let store = AutomationStore(fileURL: f)
        let snapshot = try snap(indexJSON(pkg: old.bytes))
        let record = try await store.accept(snapshot, acknowledgeUnverified: true, now: now)
        let retained = try await store.install(old, from: snapshot, expectedGeneration: record.generation, now: now)
        let subsequent = try snap(indexJSON(sequence: 2, pkg: later.bytes))
        let refreshed = try await store.accept(subsequent, acknowledgeUnverified: true, now: now)
        let unreferenced = try await store.install(later, from: subsequent, expectedGeneration: refreshed.generation, now: now)
        let grants = PluginActivationStore(fileURL: shared)
        let empty = try await grants.snapshot()
        let admitted = try await grants.activate(old, revisionID: retained.id, expectedGeneration: empty.generation)
        let coordinator = InstallationCoordinator(catalogURL: f, activationURL: shared)
        let before = try coordinator.state()
        XCTAssertEqual(before.installed, [retained], "active revision wins over later legacy history")
        let next = try coordinator.importLocal(packageBytes(), expectedSelectionGeneration: before.selectionGeneration)
        XCTAssertTrue(next.installed.contains(retained))
        XCTAssertTrue(next.catalog.revisions.contains(retained), "retain the original repository provenance")
        XCTAssertFalse(next.catalog.revisions.contains(unreferenced))
        XCTAssertEqual(next.activation, admitted)
        XCTAssertEqual(try coordinator.state(), next)
    }
}
