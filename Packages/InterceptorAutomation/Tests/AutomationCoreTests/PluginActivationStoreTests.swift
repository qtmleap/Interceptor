import Foundation
import XCTest
@testable import AutomationCore

final class PluginActivationStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginActivation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("active.json") }

    private func package(_ id: UUID = UUID(), source: String = "// inactive until approved") throws -> PluginPackage {
        let json = """
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"Test","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method","host","path","status"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},
        "write":{"requestBody":true,"responseBody":true},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """
        return try PluginPackage.validate(Data(json.utf8))
    }
    private func key(_ p: PluginPackage) -> String { "local|\(p.manifest.id.uuidString)|\(p.revision)" }

    func testApprovalPersistsExactBytesAndRevocationInvalidatesAnotherReader() async throws {
        let store = PluginActivationStore(fileURL: url)
        let observer = PluginActivationStore(fileURL: url)
        let initial = try await store.snapshot()
        XCTAssertTrue(initial.revisions.isEmpty)
        let p = try package()
        let approved = try await store.activate(p, revisionID: key(p), expectedGeneration: initial.generation)
        let readBack = try await observer.snapshot()
        XCTAssertEqual(readBack, approved)
        XCTAssertEqual(readBack.revisions.first?.package.bytes, p.bytes)
        let before = await observer.isCurrent(admitted: approved)
        XCTAssertTrue(before)
        _ = try await store.revoke(revisionID: key(p))
        let after = await observer.isCurrent(admitted: approved)
        XCTAssertFalse(after)
        let empty = try await store.snapshot()
        XCTAssertTrue(empty.revisions.isEmpty)
    }

    func testStaleApprovalCannotResurrectRevokedRevision() async throws {
        let store = PluginActivationStore(fileURL: url)
        let before = try await store.snapshot()
        _ = try await store.revoke(revisionID: "deleted-before-enable")
        let p = try package()
        do {
            _ = try await store.activate(p, revisionID: key(p), expectedGeneration: before.generation)
            XCTFail("stale approval must fail")
        } catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        let empty = try await store.snapshot()
        XCTAssertTrue(empty.revisions.isEmpty)
    }

    func testLegacyPackageAndForgedRevisionIdentityCannotActivate() async throws {
        let store = PluginActivationStore(fileURL: url)
        let snapshot = try await store.snapshot()
        let legacy = try PluginPackage.template()
        do {
            _ = try await store.activate(legacy, revisionID: key(legacy), expectedGeneration: snapshot.generation)
            XCTFail("v1 may only dry-run")
        } catch { XCTAssertEqual(error as? AutomationError, .invalidManifest) }
        let p = try package()
        do {
            _ = try await store.activate(p, revisionID: "local|forged", expectedGeneration: snapshot.generation)
            XCTFail("revision must bind exact bytes and plugin identity")
        } catch { XCTAssertEqual(error as? AutomationError, .invalidManifest) }
    }

    func testNewRevisionNeedsApprovalAndReplacesOnlySameSourcePlugin() async throws {
        let store = PluginActivationStore(fileURL: url)
        let p = try package()
        let initial = try await store.snapshot()
        let old = try await store.activate(p, revisionID: key(p), expectedGeneration: initial.generation)
        let edited = try package(p.manifest.id, source: "// changed source")
        let stillOld = try await store.snapshot()
        XCTAssertEqual(stillOld.revisions.map(\.revisionID), [key(p)])
        let next = try await store.activate(edited, revisionID: key(edited), expectedGeneration: old.generation)
        XCTAssertEqual(next.revisions.map(\.revisionID), [key(edited)])
        XCTAssertNotEqual(next.generation, old.generation)
    }

    func testActivationLimitFailurePreservesExistingApprovedSet() async throws {
        let store = PluginActivationStore(fileURL: url)
        var snapshot = try await store.snapshot()
        for _ in 0..<4 {
            let p = try package()
            snapshot = try await store.activate(p, revisionID: key(p), expectedGeneration: snapshot.generation)
        }
        let extra = try package()
        do {
            _ = try await store.activate(extra, revisionID: key(extra), expectedGeneration: snapshot.generation)
            XCTFail("active revision cap")
        } catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        let after = try await store.snapshot()
        XCTAssertEqual(after, snapshot)
    }

    func testCorruptAndSymlinkedActivationFilesFailClosedAndRemainUntouched() async throws {
        let bytes = Data("{bad".utf8)
        try bytes.write(to: url)
        let store = PluginActivationStore(fileURL: url)
        let current = await store.isCurrent(admitted: .empty)
        XCTAssertFalse(current)
        do { _ = try await store.revokeAll(); XCTFail("preserve corrupt state") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let target = directory.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        do { _ = try await store.snapshot(); XCTFail("symlink") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testOversizeFileIsRejectedBeforeParsingAndPreserved() async throws {
        let bytes = Data(repeating: 0x20, count: PluginActivationStore.maxBytes + 1)
        try bytes.write(to: url)
        let store = PluginActivationStore(fileURL: url)
        do { _ = try await store.snapshot(); XCTFail("bounded read") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testDigestTamperingPreservesFileAndFailsClosed() async throws {
        let store = PluginActivationStore(fileURL: url)
        let package = try package()
        let initial = try await store.snapshot()
        _ = try await store.activate(package, revisionID: key(package), expectedGeneration: initial.generation)
        var root = try XCTUnwrap(JSONValue(parsing: Data(contentsOf: url)).objectValue)
        var entry = try XCTUnwrap(root["revisions"]?.arrayValue?.first?.objectValue)
        entry["digest"] = .string(String(repeating: "0", count: 64))
        root["revisions"] = .array([.object(entry)])
        let bytes = try JSONValue.object(root).data()
        try bytes.write(to: url)
        let current = await store.isCurrent(admitted: initial)
        XCTAssertFalse(current)
        do { _ = try await store.revokeAll(); XCTFail("tampered digest") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }


    func testCachedSnapshotIsReusedOnlyForIdenticalBytes() async throws {
        let writer = PluginActivationStore(fileURL: url)
        let p = try package()
        let initial = try await writer.snapshot()
        _ = try await writer.activate(p, revisionID: key(p), expectedGeneration: initial.generation)
        let reader = PluginActivationStore(fileURL: url)
        let first = try await reader.snapshot()
        _ = try await reader.snapshot()
        let count = await reader.validationCount
        XCTAssertEqual(count, 1)
        // Different valid JSON bytes must be validated even when the decoded state is unchanged.
        var bytes = try Data(contentsOf: url)
        bytes.append(0x20)
        try CatalogFile(url: url).replace(with: bytes)
        let second = try await reader.snapshot()
        XCTAssertEqual(second, first)
        let changedCount = await reader.validationCount
        XCTAssertEqual(changedCount, 2)
    }

    func testSameGenerationChangedRevisionIsRevalidatedAndNotCurrent() async throws {
        let store = PluginActivationStore(fileURL: url)
        let p = try package(), changed = try package()
        let initial = try await store.snapshot()
        let admitted = try await store.activate(p, revisionID: key(p), expectedGeneration: initial.generation)
        var root = try XCTUnwrap(JSONValue(parsing: Data(contentsOf: url)).objectValue)
        root["revisions"] = .array([.object(["revisionID": .string(key(changed)), "digest": .string(changed.revision),
                                               "package": .string(changed.bytes.base64EncodedString())])])
        try CatalogFile(url: url).replace(with: JSONValue.object(root).data())
        let current = try await store.snapshot()
        XCTAssertEqual(current.generation, admitted.generation)
        XCTAssertNotEqual(current, admitted)
        let authorized = await store.isCurrent(admitted: admitted)
        XCTAssertFalse(authorized)
        XCTAssertEqual(current.revisions.first?.package.bytes, changed.bytes)
    }

    func testFailedWritePreservesFileAndPreviouslyValidatedSnapshot() async throws {
        let setup = PluginActivationStore(fileURL: url)
        let p = try package()
        let initial = try await setup.snapshot()
        let admitted = try await setup.activate(p, revisionID: key(p), expectedGeneration: initial.generation)
        let bytes = try Data(contentsOf: url)
        let store = PluginActivationStore(fileURL: url, writer: { _, _ in throw AutomationError.saveFailed })
        _ = try await store.snapshot()
        do { _ = try await store.revokeAll(); XCTFail("write must fail") }
        catch { XCTAssertEqual(error as? AutomationError, .saveFailed) }
        let preserved = try await store.snapshot()
        let count = await store.validationCount
        XCTAssertEqual(preserved, admitted)
        XCTAssertEqual(count, 1, "failed replace must not publish a speculative cache entry")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSnapshotDoesNotCreateDirectoryOrLockFile() async throws {
        let missing = directory.appendingPathComponent("absent/active.json")
        let store = PluginActivationStore(fileURL: missing)
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let existing = PluginActivationStore(fileURL: url)
        _ = try await existing.snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("lock").path))
    }

    func testConcurrentAtomicWriterAndLockFreeReaderOnlySeeValidSnapshots() async throws {
        let writer = PluginActivationStore(fileURL: url), reader = PluginActivationStore(fileURL: url)
        let p = try package()
        let revisionID = key(p)
        let writing = Task {
            for _ in 0..<30 {
                let current = try await writer.snapshot()
                _ = try await writer.activate(p, revisionID: revisionID, expectedGeneration: current.generation)
                _ = try await writer.revokeAll()
            }
        }
        for _ in 0..<150 {
            let snapshot = try await reader.snapshot()
            XCTAssertLessThanOrEqual(snapshot.revisions.count, 1)
            if let revision = snapshot.revisions.first { XCTAssertEqual(revision.package.bytes, p.bytes) }
        }
        try await writing.value
    }

}
