import CryptoKit
import Foundation
import XCTest
@testable import AutomationCore

/// Real-filesystem tests for the Task 2 contract (docs/superpowers/plans/2026-10-23-plugin-json-storage.md).
/// Written before implementation: `PluginJSONFileStore` and `withCurrentActivation` do not exist yet, and
/// schema-2 `write.files` is added by Task 1, so these fail to build/run until those land.
final class PluginJSONFileStoreTests: XCTestCase {
    private var directory: URL!
    private var outside: URL!
    private var rootURL: URL { directory.appendingPathComponent("PluginFiles") }
    private var activeURL: URL { directory.appendingPathComponent("active.json") }
    private var catalogURL: URL { directory.appendingPathComponent("catalog.json") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("PluginJSONStore-" + UUID().uuidString)
        outside = directory.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        // Restore permissions a test may have removed so cleanup of this test's own directory succeeds.
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path) }
        }
        try fm.removeItem(at: directory)
    }

    func testBlockedExportFileDoesNotPreventOtherResponsesFromExporting() throws {
        let package = try package(), store = store()
        try save(store, package, key: "blocked", "{}")
        try save(store, package, key: "healthy", "{\"ok\":true}")
        let destination = directory.appendingPathComponent("Documents")
        let namespace = try onlyNamespace().lastPathComponent
        let sourceFiles = try fm.contentsOfDirectory(atPath: onlyNamespace().path)
        let blocked = try XCTUnwrap(sourceFiles.first)
        let healthy = try XCTUnwrap(sourceFiles.last)
        let exported = destination.appendingPathComponent(namespace)
        try fm.createDirectory(at: exported.appendingPathComponent(blocked), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.export(to: destination))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent(healthy)), try Data(contentsOf: onlyNamespace().appendingPathComponent(healthy)))
    }

    func testIdenticalSaveAndExportRestoreBackupExclusion() throws {
        let package = try package(), store = store()
        try save(store, package, key: "key", "{}")
        var saved = try fileURL("key")
        var included = URLResourceValues()
        included.isExcludedFromBackup = false
        try saved.setResourceValues(included)
        try save(store, package, key: "key", "{}")
        XCTAssertEqual(try saved.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let destination = directory.appendingPathComponent("Documents")
        try store.export(to: destination)
        var exported = destination.appendingPathComponent(try onlyNamespace().lastPathComponent).appendingPathComponent(sha("key") + ".json")
        try exported.setResourceValues(included)
        try store.export(to: destination)
        XCTAssertEqual(try exported.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRejectedFirstPublicationDoesNotConsumeNamespace() throws {
        let store = store()
        XCTAssertThrowsError(try save(store, try package(), key: "key", "{}", check: { throw CancellationError() }))
        XCTAssertTrue(try namespaces().isEmpty)
    }

    func testNumbersThatOverflowFiniteDoubleAreRejectedLikeTheBridge() throws {
        XCTAssertThrowsError(try save(store(), try package(), key: "key", "1e999"))
    }

    func testProtectionTargetsTheOpenInodeAfterItsPathIsReplaced() throws {
        let original = directory.appendingPathComponent("original.json")
        let moved = directory.appendingPathComponent("moved.json")
        try Data("{}".utf8).write(to: original)
        let fd = open(original.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        try fm.moveItem(at: original, to: moved)
        try Data("{}".utf8).write(to: original)
        try Posix.protect(fd, url: original)
        XCTAssertEqual(try moved.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNotEqual(try original.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    // MARK: helpers

    private func store() -> PluginJSONFileStore { PluginJSONFileStore(directoryURL: rootURL) }

    private func package(id: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                         files: Bool = true, source: String = "// s") throws -> PluginPackage {
        let w = files ? #"{"requestBody":true,"responseBody":true,"files":true}"# : #"{"requestBody":true,"responseBody":true}"#
        let json = """
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"Test","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"response":{"onLeave":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method","host","path","status"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},
        "write":\(w),"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """
        return try PluginPackage.validate(Data(json.utf8))
    }
    private func revisionID(_ p: PluginPackage, origin: String = "local") -> String { "\(origin)|\(p.manifest.id.uuidString)|\(p.revision)" }

    private func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func save(_ s: PluginJSONFileStore, _ p: PluginPackage, key: String, _ text: String,
                      origin: String = "local", check: @escaping @Sendable () throws -> Void = {}) throws {
        try s.save(revisionID: revisionID(p, origin: origin), package: p, key: key, jsonText: text, checkAuthorization: check)
    }

    private func namespaces() throws -> [URL] {
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        return try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }
    private func onlyNamespace() throws -> URL {
        let n = try namespaces()
        XCTAssertEqual(n.count, 1)
        return try XCTUnwrap(n.first)
    }
    private func fileURL(_ key: String) throws -> URL { try onlyNamespace().appendingPathComponent(sha(key) + ".json") }
    private func entries(_ dir: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: dir.path).sorted() }
    private func inode(_ u: URL) throws -> (Int, Date) {
        let a = try fm.attributesOfItem(atPath: u.path)
        return ((a[.systemFileNumber] as? Int) ?? -1, (a[.modificationDate] as? Date) ?? .distantPast)
    }
    private func quoted(bytes n: Int) -> String { "\"" + String(repeating: "a", count: n - 2) + "\"" }
    private func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
    private func assertOutsideEmpty(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try entries(outside), [], "write escaped through a link", file: file, line: line)
    }
    private func skipIfRoot() throws { try XCTSkipIf(geteuid() == 0, "permission-denied behaviour is not observable as root") }

    // MARK: bytes, replacement, no-op

    func testSavePreservesOriginalBytesExactly() throws {
        let p = try package(), s = store()
        let text = "{\n  \"z\" : 1,\r\n \"a\":\"caf\\u00e9 é 日本 😀 \\n\" ,\"z2\":[ 1.50 , 1e2 ]\n}\n"
        try save(s, p, key: "history", text)
        XCTAssertEqual(try Data(contentsOf: fileURL("history")), Data(text.utf8))
        XCTAssertEqual(try entries(onlyNamespace()), [sha("history") + ".json"])
    }

    func testFilesAreOwnerOnly() throws {
        let p = try package(), s = store()
        try save(s, p, key: "k", "{}")
        let mode = try fm.attributesOfItem(atPath: fileURL("k").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
    }

    func testSameKeyReplacesAndLeavesNoTemporaries() throws {
        let p = try package(), s = store()
        try save(s, p, key: "k", #"{"v":1}"#)
        try save(s, p, key: "k", #"{"v":2}"#)
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), #"{"v":2}"#)
        XCTAssertEqual(try entries(onlyNamespace()), [sha("k") + ".json"])
    }

    func testIdenticalBytesAreANoOp() throws {
        let p = try package(), s = store()
        try save(s, p, key: "k", #"{"v":1}"#)
        let before = try inode(fileURL("k"))
        Thread.sleep(forTimeInterval: 1.1)
        try save(s, p, key: "k", #"{"v":1}"#)
        let after = try inode(fileURL("k"))
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
    }

    func testDifferentKeysAreIndependentFiles() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        try save(s, p, key: "b", "2")
        XCTAssertEqual(try entries(onlyNamespace()).sorted(), [sha("a") + ".json", sha("b") + ".json"].sorted())
    }

    // MARK: prepare / commit

    func testPreparedWriteIsInvisibleUntilCommitAndCleansUp() throws {
        let p = try package(), s = store()
        let prepared = try s.prepare(revisionID: revisionID(p), package: p, key: "k", jsonText: "{}")
        XCTAssertTrue(try namespaces().allSatisfy { $0.lastPathComponent.hasPrefix(".tmp-") })
        try prepared.commit()
        XCTAssertEqual(try entries(onlyNamespace()), [sha("k") + ".json"])
        XCTAssertThrowsError(try prepared.commit())
        let dropped = try s.prepare(revisionID: revisionID(p), package: p, key: "j", jsonText: "{}")
        dropped.discard()
        XCTAssertEqual(try namespaces().count, 1)
    }

    func testDuplicateObjectKeysAreRejectedButNumberSpellingIsPreserved() throws {
        let p = try package(), s = store()
        XCTAssertThrowsError(try save(s, p, key: "d", #"{"a":1,"a":2}"#))
        XCTAssertThrowsError(try save(s, p, key: "d", #"{"a":1,"a":2}"#))
        try save(s, p, key: "n", "[1.0, 1E+2, -0]")
        XCTAssertEqual(try String(contentsOf: fileURL("n"), encoding: .utf8), "[1.0, 1E+2, -0]")
    }

    // MARK: validation

    func testKeyLengthBoundaries() throws {
        let p = try package(), s = store()
        try save(s, p, key: String(repeating: "k", count: 1024), "{}")
        try save(s, p, key: String(repeating: "é", count: 512), "{}")   // 1024 UTF-8 bytes
        try save(s, p, key: "x", "{}")
        XCTAssertThrowsError(try save(s, p, key: String(repeating: "k", count: 1025), "{}"))
        XCTAssertThrowsError(try save(s, p, key: String(repeating: "é", count: 513), "{}"))
        XCTAssertThrowsError(try save(s, p, key: "", "{}"))
        XCTAssertThrowsError(try save(s, p, key: "a\u{0}b", "{}"))
        XCTAssertEqual(try entries(onlyNamespace()).count, 3)
    }

    func testJSONSizeBoundary() throws {
        let p = try package(), s = store()
        let max = quoted(bytes: 1024 * 1024)
        try save(s, p, key: "max", max)
        XCTAssertEqual(try Data(contentsOf: fileURL("max")).count, 1024 * 1024)
        XCTAssertThrowsError(try save(s, p, key: "over", quoted(bytes: 1024 * 1024 + 1)))
        XCTAssertEqual(try entries(onlyNamespace()), [sha("max") + ".json"])
    }

    func testJSONDepthBoundary() throws {
        let p = try package(), s = store()
        try save(s, p, key: "d64", nested(64))
        XCTAssertThrowsError(try save(s, p, key: "d65", nested(65)))
        XCTAssertThrowsError(try save(s, p, key: "obj65", String(repeating: #"{"a":"#, count: 65) + "1" + String(repeating: "}", count: 65)))
        XCTAssertEqual(try entries(onlyNamespace()), [sha("d64") + ".json"])
    }

    func testInvalidJSONIsRejectedWithoutWriting() throws {
        let p = try package(), s = store()
        for bad in ["", "   ", "{", "{} x", "[1,]", "{'a':1}", "nope", "01"] {
            XCTAssertThrowsError(try save(s, p, key: "bad", bad), "accepted \(bad)")
        }
        XCTAssertTrue(try namespaces().isEmpty)
    }

    func testRevisionMustMatchPackage() throws {
        let p = try package(), other = try package(id: UUID())
        let s = store()
        XCTAssertThrowsError(try s.save(revisionID: revisionID(other), package: p, key: "k", jsonText: "{}"))
        XCTAssertThrowsError(try s.save(revisionID: "garbage", package: p, key: "k", jsonText: "{}"))
        XCTAssertThrowsError(try s.save(revisionID: "local|\(p.manifest.id.uuidString)|" + String(repeating: "0", count: 64), package: p, key: "k", jsonText: "{}"))
        XCTAssertTrue(try namespaces().allSatisfy { try entries($0).isEmpty })
    }

    // MARK: permission

    func testPackageWithoutFilesPermissionCannotSave() throws {
        let p = try package(files: false), s = store()
        XCTAssertThrowsError(try save(s, p, key: "k", "{}"))
        XCTAssertTrue(try namespaces().allSatisfy { try entries($0).isEmpty })
    }

    // MARK: namespaces

    func testNamespacesAreIsolatedPerInstallationFamily() throws {
        let a = try package(id: UUID()), b = try package(id: UUID()), s = store()
        try save(s, a, key: "k", "\"a\"")
        try save(s, b, key: "k", "\"b\"")
        // Same manifest id from a different trusted origin is a different family.
        try save(s, a, key: "k", "\"remote\"", origin: "https://example.com/r/repository.json")
        let ns = try namespaces()
        XCTAssertEqual(ns.count, 3)
        let contents = try ns.map { try String(contentsOf: $0.appendingPathComponent(sha("k") + ".json"), encoding: .utf8) }
        XCTAssertEqual(Set(contents), ["\"a\"", "\"b\"", "\"remote\""])
    }

    func testNamespaceIsStableAcrossRevisionsOfOneFamily() throws {
        let v1 = try package(source: "// one"), v2 = try package(source: "// two")
        XCTAssertNotEqual(v1.revision, v2.revision)
        let s = store()
        try save(s, v1, key: "k", "1")
        try save(s, v2, key: "k", "2")
        XCTAssertEqual(try namespaces().count, 1)
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), "2")
    }

    func testNamespaceNameDoesNotLeakKeysOrPaths() throws {
        let p = try package(), s = store()
        try save(s, p, key: "../../escape/\(UUID().uuidString)", "{}")
        let ns = try onlyNamespace()
        XCTAssertEqual(ns.deletingLastPathComponent().standardizedFileURL.path, rootURL.standardizedFileURL.path)
        XCTAssertFalse(ns.lastPathComponent.contains("/") || ns.lastPathComponent.contains(".."))
        XCTAssertEqual(try entries(ns).count, 1)
        XCTAssertEqual(try entries(directory).sorted(), ["PluginFiles", "outside"])
    }

    // MARK: quotas

    func testFileCountQuota() throws {
        let p = try package(), s = store()
        for i in 0..<2048 { try save(s, p, key: "k\(i)", "\(i)") }
        XCTAssertThrowsError(try save(s, p, key: "one-too-many", "1"))
        XCTAssertEqual(try entries(onlyNamespace()).count, 2048)
        // Replacing an existing key does not grow the namespace.
        try save(s, p, key: "k0", "999")
        XCTAssertEqual(try String(contentsOf: fileURL("k0"), encoding: .utf8), "999")
        // Another namespace has its own budget.
        try save(s, try package(id: UUID()), key: "k", "1")
    }

    func testByteQuota() throws {
        let p = try package(), s = store()
        func big(_ c: Character) -> String { "\"" + String(repeating: c, count: 1024 * 1024 - 2) + "\"" }
        for i in 0..<64 { try save(s, p, key: "b\(i)", big(Character(UnicodeScalar(UInt8(97 + i % 26))))) }
        XCTAssertThrowsError(try save(s, p, key: "b64", big("z")))
        XCTAssertEqual(try entries(onlyNamespace()).count, 64)
        let before = try Data(contentsOf: fileURL("b1"))
        // Same-size replacement fits; growing past the limit does not.
        try save(s, p, key: "b0", big("Z"))
        XCTAssertNotEqual(try Data(contentsOf: fileURL("b0")), Data(big("a").utf8))
        try save(s, p, key: "b1", "1")
        XCTAssertEqual(try entries(onlyNamespace()).count, 64)
        XCTAssertNotEqual(before, try Data(contentsOf: fileURL("b1")))
        try save(s, p, key: "b64", "1")
        XCTAssertEqual(try entries(onlyNamespace()).count, 65)
    }

    // MARK: links and special files

    func testSymlinkedRootIsRejected() throws {
        try fm.createSymbolicLink(at: rootURL, withDestinationURL: outside)
        XCTAssertThrowsError(try save(store(), try package(), key: "k", "{}"))
        try assertOutsideEmpty()
    }

    func testSymlinkedNamespaceIsRejected() throws {
        let p = try package(), s = store()
        try save(s, p, key: "first", "1")
        let ns = try onlyNamespace()
        let original = ns.deletingLastPathComponent().appendingPathComponent("moved")
        try fm.moveItem(at: ns, to: original)
        try fm.createSymbolicLink(at: ns, withDestinationURL: outside)
        XCTAssertThrowsError(try save(s, p, key: "second", "2"))
        try assertOutsideEmpty()
        XCTAssertEqual(try entries(original), [sha("first") + ".json"])
    }

    func testSymlinkedFileIsNotFollowedOrReplaced() throws {
        let p = try package(), s = store()
        try save(s, p, key: "k", "1")
        let target = outside.appendingPathComponent("secret.json")
        try Data("secret".utf8).write(to: target)
        let file = try fileURL("k")
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try save(s, p, key: "k", "2"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "secret")
        XCTAssertEqual(try entries(outside), ["secret.json"])
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: file.path))
    }

    func testSymlinkOrSpecialEntryInNamespaceFailsClosed() throws {
        let p = try package(), s = store()
        try save(s, p, key: "keep", "1")
        let ns = try onlyNamespace()
        try fm.createSymbolicLink(at: ns.appendingPathComponent("link.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try save(s, p, key: "next", "2"))
        try fm.removeItem(at: ns.appendingPathComponent("link.json"))
        XCTAssertEqual(mkfifo(ns.appendingPathComponent("pipe.json").path, 0o600), 0)
        XCTAssertThrowsError(try save(s, p, key: "next", "2"))
        XCTAssertEqual(try Data(contentsOf: fileURL("keep")), Data("1".utf8))
        XCTAssertFalse(fm.fileExists(atPath: ns.appendingPathComponent(sha("next") + ".json").path))
        try assertOutsideEmpty()
    }

    func testDirectoryAtFileLocationIsRejected() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        try fm.createDirectory(at: try onlyNamespace().appendingPathComponent(sha("b") + ".json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try save(s, p, key: "b", "2"))
    }

    // MARK: failure preservation

    func testAuthorizationFailurePreservesPriorFileAndLeavesNoTemporaries() throws {
        struct Revoked: Error {}
        let p = try package(), s = store()
        try save(s, p, key: "k", #""old""#)
        let calls = Counter()
        XCTAssertThrowsError(try save(s, p, key: "k", #""new""#, check: { calls.bump(); throw Revoked() })) { XCTAssertTrue($0 is Revoked) }
        XCTAssertThrowsError(try save(s, p, key: "fresh", #""new""#, check: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls.value, 1, "authorization must be re-checked during the save")
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), #""old""#)
        XCTAssertEqual(try entries(onlyNamespace()), [sha("k") + ".json"])
    }

    func testAuthorizationIsCheckedOnSuccessfulSave() throws {
        let calls = Counter()
        try save(store(), try package(), key: "k", "{}", check: { calls.bump() })
        XCTAssertGreaterThanOrEqual(calls.value, 1)
    }

    func testInvalidReplacementPreservesPriorFile() throws {
        let p = try package(), s = store()
        try save(s, p, key: "k", #""old""#)
        XCTAssertThrowsError(try save(s, p, key: "k", "{"))
        XCTAssertThrowsError(try save(s, p, key: "k", nested(65)))
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), #""old""#)
    }

    func testIOFailurePreservesPriorFile() throws {
        try skipIfRoot()
        let p = try package(), s = store()
        try save(s, p, key: "k", #""old""#)
        let ns = try onlyNamespace()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ns.path)
        XCTAssertThrowsError(try save(s, p, key: "k", #""new""#))
        XCTAssertThrowsError(try save(s, p, key: "other", #""new""#))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ns.path)
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), #""old""#)
        XCTAssertEqual(try entries(ns), [sha("k") + ".json"])
        try save(s, p, key: "k", #""new""#)
        XCTAssertEqual(try String(contentsOf: fileURL("k"), encoding: .utf8), #""new""#)
    }

    // MARK: activation fence

    private func activationFixture() async throws -> (PluginActivationStore, PluginPackage, String, PluginActivationSnapshot) {
        let p = try package(id: UUID())
        let file = CatalogFile(url: catalogURL)
        try file.locked {
            var catalog = try file.read().map(CatalogCodec.decode) ?? Catalog()
            catalog.revisions.append(InstalledRevision(package: p, provenance: .init(origin: .localImport, trustAtImport: nil), enabled: false))
            try file.replace(with: CatalogCodec.encode(catalog))
        }
        let store = PluginActivationStore(fileURL: activeURL, catalogURL: catalogURL)
        let initial = try await store.snapshot()
        let rid = revisionID(p)
        let admitted = try await store.activate(p, revisionID: rid, expectedGeneration: initial.generation)
        return (store, p, rid, admitted)
    }

    func testFenceRunsOperationWithExactGrantedRevision() async throws {
        let (activation, p, rid, admitted) = try await activationFixture()
        let seen = Box<ActivatedPlugin?>(nil)
        try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { seen.set($0) }
        XCTAssertEqual(seen.get()?.revisionID, rid)
        XCTAssertEqual(seen.get()?.package.bytes, p.bytes)
    }

    func testFenceRejectsRevokedAdmission() async throws {
        let (activation, _, rid, admitted) = try await activationFixture()
        _ = try await activation.revoke(revisionID: rid)
        let ran = Counter()
        do {
            try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { _ in ran.bump() }
            XCTFail("stale admission was accepted")
        } catch {}
        XCTAssertEqual(ran.value, 0)
    }

    func testFenceRejectsStaleGenerationAfterReactivation() async throws {
        let (activation, p, rid, admitted) = try await activationFixture()
        _ = try await activation.revoke(revisionID: rid)
        let now = try await activation.snapshot()
        _ = try await activation.activate(p, revisionID: rid, expectedGeneration: now.generation)
        let ran = Counter()
        do {
            try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { _ in ran.bump() }
            XCTFail("old generation was accepted")
        } catch {}
        XCTAssertEqual(ran.value, 0)
    }

    func testFenceRejectsRevisionNotGrantedInSnapshot() async throws {
        let (activation, p, _, admitted) = try await activationFixture()
        let other = "local|\(p.manifest.id.uuidString)|" + String(repeating: "1", count: 64)
        let ran = Counter()
        do {
            try await activation.withCurrentActivation(admitted: admitted, revisionID: other) { _ in ran.bump() }
            XCTFail("ungranted revision accepted")
        } catch {}
        XCTAssertEqual(ran.value, 0)
    }

    func testFencePropagatesOperationErrorAndStaysUsable() async throws {
        struct Boom: Error {}
        let (activation, _, rid, admitted) = try await activationFixture()
        do {
            try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { _ in throw Boom() }
            XCTFail("error swallowed")
        } catch { XCTAssertTrue(error is Boom) }
        let ran = Counter()
        try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { _ in ran.bump() }
        XCTAssertEqual(ran.value, 1)
    }

    func testFenceHoldsActivationLockWhileOperationRuns() async throws {
        let (activation, _, rid, admitted) = try await activationFixture()
        let other = PluginActivationStore(fileURL: activeURL, catalogURL: catalogURL)
        let revoked = Counter()
        let revokeTask = Box<Task<Void, Error>?>(nil)
        try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) { _ in
            revokeTask.set(Task { _ = try await other.revoke(revisionID: rid); revoked.bump() })
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(revoked.value, 0, "revocation completed while the fence was held")
        }
        try await revokeTask.get()?.value
        XCTAssertEqual(revoked.value, 1)
    }

    func testRevocationBlocksFurtherSavesButKeepsPublishedFiles() async throws {
        let (activation, p, rid, admitted) = try await activationFixture()
        let s = store()
        try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) {
            try s.save(revisionID: $0.revisionID, package: $0.package, key: "k", jsonText: "{}")
        }
        _ = try await activation.revoke(revisionID: rid)
        do {
            try await activation.withCurrentActivation(admitted: admitted, revisionID: rid) {
                try s.save(revisionID: $0.revisionID, package: $0.package, key: "late", jsonText: "{}")
            }
            XCTFail("write after revocation")
        } catch {}
        XCTAssertEqual(try entries(onlyNamespace()), [sha("k") + ".json"])
        _ = p
    }

    // MARK: export

    private func exportDestination() throws -> URL {
        let d = directory.appendingPathComponent("Documents/Plugins")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testExportMirrorsCommittedFilesAndPreservesUnrelatedContent() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", #"{"a": 1}"#)
        try save(s, p, key: "b", "[1, 2]\n")
        let dest = try exportDestination()
        try Data("keep".utf8).write(to: dest.appendingPathComponent("notes.txt"))
        let ns = try onlyNamespace().lastPathComponent
        try fm.createDirectory(at: dest.appendingPathComponent(ns), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dest.appendingPathComponent(ns).appendingPathComponent("user.txt"))
        try fm.createDirectory(at: dest.appendingPathComponent("other"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dest.appendingPathComponent("other/x.json"))

        try s.export(to: dest)
        for key in ["a", "b"] {
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(ns).appendingPathComponent(sha(key) + ".json")),
                           try Data(contentsOf: fileURL(key)))
        }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("notes.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent(ns).appendingPathComponent("user.txt"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("other/x.json"), encoding: .utf8), "{}")
    }

    func testExportNeverImportsEditedDocumentsFiles() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        let dest = try exportDestination()
        try s.export(to: dest)
        let ns = try onlyNamespace().lastPathComponent
        let exported = dest.appendingPathComponent(ns).appendingPathComponent(sha("a") + ".json")
        try Data("edited".utf8).write(to: exported)
        try s.export(to: dest)
        XCTAssertEqual(try String(contentsOf: fileURL("a"), encoding: .utf8), "1")
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "1")
        try s.export(to: dest)   // idempotent
    }

    func testExportRejectsSymlinkedSourceFile() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        let file = try fileURL("a")
        let target = outside.appendingPathComponent("secret.json")
        try Data("secret".utf8).write(to: target)
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        let dest = try exportDestination()
        XCTAssertThrowsError(try s.export(to: dest))
        XCTAssertFalse(try fm.subpathsOfDirectory(atPath: dest.path).contains { $0.hasSuffix(".json") })
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "secret")
    }

    func testExportRejectsSymlinkedSourceNamespaceAndRoot() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        let ns = try onlyNamespace()
        let moved = directory.appendingPathComponent("moved-ns")
        try fm.moveItem(at: ns, to: moved)
        try fm.createSymbolicLink(at: ns, withDestinationURL: moved)
        let dest = try exportDestination()
        XCTAssertThrowsError(try s.export(to: dest))
        try fm.removeItem(at: ns)
        try fm.moveItem(at: moved, to: ns)
        let realRoot = directory.appendingPathComponent("real-root")
        try fm.moveItem(at: rootURL, to: realRoot)
        try fm.createSymbolicLink(at: rootURL, withDestinationURL: realRoot)
        XCTAssertThrowsError(try s.export(to: dest))
        XCTAssertFalse(try fm.subpathsOfDirectory(atPath: dest.path).contains { $0.hasSuffix(".json") })
    }

    func testExportRejectsSymlinkedDestinationParts() throws {
        let p = try package(), s = store()
        try save(s, p, key: "a", "1")
        let ns = try onlyNamespace().lastPathComponent

        // Destination root is a symlink.
        let linkedDest = directory.appendingPathComponent("LinkedPlugins")
        try fm.createSymbolicLink(at: linkedDest, withDestinationURL: outside)
        XCTAssertThrowsError(try s.export(to: linkedDest))
        try assertOutsideEmpty()

        // Destination namespace is a symlink.
        let dest = try exportDestination()
        try fm.createSymbolicLink(at: dest.appendingPathComponent(ns), withDestinationURL: outside)
        XCTAssertThrowsError(try s.export(to: dest))
        try assertOutsideEmpty()
        try fm.removeItem(at: dest.appendingPathComponent(ns))

        // Destination file is a symlink.
        try fm.createDirectory(at: dest.appendingPathComponent(ns), withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("victim.json")
        try Data("victim".utf8).write(to: target)
        try fm.createSymbolicLink(at: dest.appendingPathComponent(ns).appendingPathComponent(sha("a") + ".json"), withDestinationURL: target)
        XCTAssertThrowsError(try s.export(to: dest))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "victim")
        XCTAssertEqual(try entries(outside), ["victim.json"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ new: T) { lock.lock(); v = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
}
