import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AutomationCore

/// Real-filesystem tests for the plugin file destination contract
/// (docs/superpowers/specs/2026-10-24-plugin-file-destinations-design.md).
/// Written before implementation: `PluginFileStorage`, `PluginFileDestination`, `PluginFileStore`
/// and `PluginFileRecord` do not exist yet, so this target fails to build until they land.
final class PluginFileStoreTests: XCTestCase {
    private var directory: URL!
    private var outside: URL!
    private var rootURL: URL { directory.appendingPathComponent("PluginFileRecords") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("PluginFileStore-" + UUID().uuidString)
        outside = directory.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path) }
        }
        try fm.removeItem(at: directory)
    }

    // MARK: helpers

    private func store() -> PluginFileStore { PluginFileStore(directoryURL: rootURL) }

    private func package(id: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, files: Bool = true,
                         source: String = "// s") throws -> PluginPackage {
        let json = """
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"Test","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"response":{"onLeave":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method","host","path","status"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},
        "write":{"requestBody":true,"responseBody":true,"files":\(files)},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """
        return try PluginPackage.validate(Data(json.utf8))
    }
    private func revisionID(_ p: PluginPackage, origin: String = "local") -> String { "\(origin)|\(p.manifest.id.uuidString)|\(p.revision)" }
    private func dest(_ path: String, _ storage: PluginFileStorage = .icloud) throws -> PluginFileDestination {
        try PluginFileDestination(storage: storage, atPath: path)
    }
    private func prepare(_ s: PluginFileStore, _ p: PluginPackage, _ path: String, _ data: Data,
                         storage: PluginFileStorage = .icloud, origin: String = "local") throws -> PluginFileStore.PreparedWrite {
        try s.prepare(revisionID: revisionID(p, origin: origin), package: p, destination: dest(path, storage), contents: data)
    }
    @discardableResult
    private func write(_ s: PluginFileStore, _ p: PluginPackage, _ path: String, _ data: Data,
                       storage: PluginFileStorage = .icloud, origin: String = "local",
                       check: @escaping @Sendable () throws -> Void = {}) throws -> PluginFileStore.PreparedWrite {
        let w = try prepare(s, p, path, data, storage: storage, origin: origin)
        try w.commit(checkAuthorization: check)
        return w
    }
    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func files(under u: URL) -> [URL] {
        guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private func onlyRecord(_ s: PluginFileStore) throws -> (id: String, url: URL) {
        let ids = try s.recordIdentifiers()
        XCTAssertEqual(ids.count, 1)
        let id = try XCTUnwrap(ids.first)
        let url = rootURL.appendingPathComponent(id)
        XCTAssertTrue(fm.fileExists(atPath: url.path), "cannot locate the file of record \(id)")
        return (id, url)
    }
    private func assertOutsideEmpty(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [], "write escaped through a link", file: file, line: line)
    }
    private func assertNoEmptyDirectories(file: StaticString = #filePath, line: UInt = #line) throws {
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let u as URL in e where (try u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            XCTAssertFalse(try fm.contentsOfDirectory(atPath: u.path).isEmpty, "empty directory \(u.lastPathComponent)", file: file, line: line)
        }
    }

    // MARK: contents

    func testStoresNonJSONTextNULInvalidUTF8AndEmptyBytesExactly() throws {
        let p = try package(), s = store()
        let cases: [(String, Data)] = [
            ("a/text.txt", Data("plain\r\ntext é 😀\n".utf8)),
            ("a/binary.bin", Data([0x00, 0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x80])),
            ("a/empty", Data()),
        ]
        for (path, bytes) in cases { try write(s, p, path, bytes) }
        let records = try s.recordIdentifiers().map { try s.readRecord($0) }
        XCTAssertEqual(records.count, 3)
        for (path, bytes) in cases {
            let r = try XCTUnwrap(records.first { $0.destination.atPath == path })
            XCTAssertEqual(r.contents, bytes)
            XCTAssertEqual(r.digest, sha(bytes))
            XCTAssertEqual(r.destination.storage, .icloud)
        }
    }

    func testRejectsContentsOverOneMiBButAcceptsExactlyOneMiB() throws {
        let p = try package(), s = store()
        XCTAssertNoThrow(try write(s, p, "limit", Data(count: 1 << 20)))
        XCTAssertThrowsError(try prepare(s, p, "over", Data(count: (1 << 20) + 1)))
        XCTAssertEqual(try s.recordIdentifiers().count, 1)
    }

    // MARK: private storage

    func testMissingFilesPermissionAndWrongPackageBindingAreRejectedBeforeIO() throws {
        let s = store(), denied = try package(files: false), allowed = try package(), other = try package(id: UUID())
        XCTAssertThrowsError(try prepare(s, denied, "a.txt", Data()))
        XCTAssertThrowsError(try s.prepare(revisionID: revisionID(other), package: allowed,
                                         destination: dest("a.txt"), contents: Data()))
        XCTAssertFalse(fm.fileExists(atPath: rootURL.path))
    }

    func testRecordIsOwnerOnlyAndExcludedFromBackup() throws {
        let p = try package(), s = store()
        try write(s, p, "a/b.txt", Data("x".utf8))
        let rec = try onlyRecord(s)
        let mode = try fm.attributesOfItem(atPath: rec.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(try XCTUnwrap(mode) & 0o777, 0o600)
        XCTAssertEqual(try rec.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testPreparedWriteIsInvisibleUntilCommitAndDiscardCleansUp() throws {
        let p = try package(), s = store()
        let w = try prepare(s, p, "a.txt", Data("new".utf8))
        XCTAssertEqual(try s.recordIdentifiers(), [])
        try w.commit()
        XCTAssertEqual(try s.recordIdentifiers().count, 1)

        let before = files(under: rootURL).map(\.path).sorted()
        let d = try prepare(s, p, "b.txt", Data("other".utf8))
        d.discard()
        XCTAssertEqual(files(under: rootURL).map(\.path).sorted(), before)
        XCTAssertEqual(try s.recordIdentifiers().count, 1)
        try assertNoEmptyDirectories()
    }

    func testCancellationBeforeCommitLeavesPreviousRecordUntouched() throws {
        let p = try package(), s = store()
        try write(s, p, "a.txt", Data("old".utf8))
        let id = try XCTUnwrap(try s.recordIdentifiers().first)
        let w = try prepare(s, p, "a.txt", Data("new".utf8))
        XCTAssertThrowsError(try w.commit(checkAuthorization: { throw CancellationError() }))
        XCTAssertEqual(try s.recordIdentifiers(), [id])
        XCTAssertEqual(try s.readRecord(id).contents, Data("old".utf8))
    }

    func testCommittedWriteCannotBeCommittedAgain() throws {
        let p = try package(), s = store()
        let w = try write(s, p, "a.txt", Data("one".utf8))
        let id = try XCTUnwrap(try s.recordIdentifiers().first)
        XCTAssertThrowsError(try w.commit())
        XCTAssertEqual(try s.readRecord(id).contents, Data("one".utf8))
    }

    func testDeniedFirstCommitLeavesNoEmptyFamily() throws {
        let s = store()
        XCTAssertThrowsError(try write(s, try package(), "a.txt", Data("x".utf8), check: { throw CancellationError() }))
        XCTAssertEqual(try s.recordIdentifiers(), [])
        try assertNoEmptyDirectories()
        XCTAssertTrue(files(under: rootURL).isEmpty)
    }

    func testPrepareSweepsOnlyOldUnlockedOwnedTemporaries() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.txt", Data())
        let abandoned = rootURL.appendingPathComponent(".tmp-" + UUID().uuidString)
        let active = rootURL.appendingPathComponent(".tmp-" + UUID().uuidString)
        let recent = rootURL.appendingPathComponent(".tmp-" + UUID().uuidString)
        for url in [abandoned, active, recent] { try Data("temporary".utf8).write(to: url) }
        for url in [abandoned, active] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: url.path)
        }
        let activeFD = open(active.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(activeFD, 0)
        guard activeFD >= 0 else { return }
        defer { close(activeFD) }
        XCTAssertEqual(flock(activeFD, LOCK_EX | LOCK_NB), 0)
        let pending = try prepare(s, p, "next.txt", Data())
        defer { pending.discard() }
        XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
        XCTAssertTrue(fm.fileExists(atPath: active.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertEqual(try s.recordIdentifiers().count, 1)
    }

    // MARK: replacement and families

    func testSamePathReplacesAtomicallyWithStableIdentifier() throws {
        let p = try package(), s = store()
        try write(s, p, "Salmon Run/history.json", Data("v1".utf8))
        let rec = try onlyRecord(s)
        try write(s, p, "Salmon Run/history.json", Data("version-two".utf8))
        let again = try onlyRecord(s)
        XCTAssertEqual(again.id, rec.id)
        XCTAssertEqual(again.url, rec.url)
        XCTAssertEqual(try s.readRecord(rec.id).contents, Data("version-two".utf8))
        XCTAssertEqual(files(under: rootURL).count, 1, "replacement must leave no temporary or stale file")
    }

    func testNormalPackageUpdateKeepsFamilyAndReplacesRecord() throws {
        let id = UUID()
        let v1 = try package(id: id, source: "// one"), v2 = try package(id: id, source: "// two")
        XCTAssertNotEqual(v1.revision, v2.revision)
        let s = store()
        try write(s, v1, "a.json", Data("old".utf8))
        let first = try XCTUnwrap(try s.recordIdentifiers().first)
        let family = try s.readRecord(first).family
        try write(s, v2, "a.json", Data("new".utf8))
        XCTAssertEqual(try s.recordIdentifiers(), [first])
        let r = try s.readRecord(first)
        XCTAssertEqual(r.family, family)
        XCTAssertEqual(r.contents, Data("new".utf8))
    }

    func testDifferentFamiliesCannotClaimTheSameCanonicalPath() throws {
        let a = try package(), b = try package(id: UUID())
        let s = store()
        try write(s, a, "Shared/file.txt", Data("a".utf8))
        XCTAssertThrowsError(try write(s, b, "shared/FILE.txt", Data("b".utf8)))
        XCTAssertThrowsError(try write(s, b, "Shared/file.txt", Data("b".utf8)))
        XCTAssertEqual(try s.recordIdentifiers().count, 1)
        XCTAssertEqual(try s.readRecord(try XCTUnwrap(try s.recordIdentifiers().first)).contents, Data("a".utf8))
    }

    func testSourceQualifiedFamiliesOfSamePackageCollide() throws {
        let p = try package(), s = store()
        try write(s, p, "x.txt", Data("local".utf8), origin: "local")
        XCTAssertThrowsError(try write(s, p, "x.txt", Data("remote".utf8), origin: "https://example.com/plugin"))
        XCTAssertEqual(try s.readRecord(try XCTUnwrap(try s.recordIdentifiers().first)).contents, Data("local".utf8))
    }

    func testLocalAndICloudStoragesAreIndependent() throws {
        let p = try package(), s = store()
        try write(s, p, "same.txt", Data("local".utf8), storage: .local)
        try write(s, p, "same.txt", Data("cloud".utf8), storage: .icloud)
        let records = try s.recordIdentifiers().map { try s.readRecord($0) }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(try XCTUnwrap(records.first { $0.destination.storage == .local }).contents, Data("local".utf8))
        XCTAssertEqual(try XCTUnwrap(records.first { $0.destination.storage == .icloud }).contents, Data("cloud".utf8))
    }

    func testCaseAliasInSameFamilyIsRejectedWithoutRenaming() throws {
        let p = try package(), s = store()
        try write(s, p, "Salmon Run/History.json", Data("a".utf8))
        XCTAssertThrowsError(try write(s, p, "salmon run/history.json", Data("b".utf8)))
        let records = try s.recordIdentifiers().map { try s.readRecord($0) }
        XCTAssertEqual(records.map(\.destination.atPath), ["Salmon Run/History.json"])
        XCTAssertEqual(records.first?.contents, Data("a".utf8))
    }

    // MARK: path validation

    func testDotFollowedByCombiningMarkStillStartsAHiddenComponent() throws {
        for path in [".\u{301}hidden", "a/.\u{301}hidden"] {
            XCTAssertThrowsError(try dest(path), "POSIX leading dot must remain hidden: \(path)")
        }
    }

    func testSlashFollowedByCombiningMarkStillCountsAsAPathSeparator() throws {
        let nineComponents = "a" + String(repeating: "/\u{301}b", count: 8)
        XCTAssertThrowsError(try dest(nineComponents), "combining marks must not bypass the eight-component limit")
    }

    func testSlashFollowedByCombiningMarkDoesNotMergeValidComponentByteLimits() throws {
        let parent = String(repeating: "a", count: 255)
        XCTAssertNoThrow(try dest(parent + "/\u{301}b.txt"), "POSIX has two individually valid components")
    }

    func testPublicPathComponentsUsePOSIXScalarBoundaries() throws {
        XCTAssertEqual(try dest("a/\u{301}b.txt").pathComponents, ["a", "\u{301}b.txt"])
        XCTAssertEqual(try dest("Salmon Run/details/result.json").pathComponents, ["Salmon Run", "details", "result.json"])
    }

    func testNonNFCPathIsRejectedNotRenamed() throws {
        let decomposed = "cafe\u{301}.txt"
        XCTAssertNotEqual(Data(decomposed.utf8), Data(decomposed.precomposedStringWithCanonicalMapping.utf8))
        XCTAssertThrowsError(try dest(decomposed))
        XCTAssertEqual(try dest("caf\u{e9}.txt").atPath, "caf\u{e9}.txt")
    }

    func testInvalidPathsAreRejected() throws {
        let c255 = String(repeating: "a", count: 255)
        let invalid = [
            "", "/abs.txt", "a//b", "a/", ".", "./a", "a/./b", "..", "a/../b", "../a",
            ".hidden", "a/.hidden", "a\\b", "a:b", "a/b:c", "a\tb", "a\nb", "a\u{0}b", "a\u{7f}b",
            String(repeating: "a/", count: 8) + "f",            // depth 9
            String(repeating: "a", count: 256),                // component 256 bytes
            String(repeating: "é", count: 128),                // component 256 bytes (multibyte)
            (0..<5).map { _ in c255 }.joined(separator: "/"),   // 1279 bytes, over 1024
        ]
        for path in invalid {
            XCTAssertThrowsError(try dest(path), "accepted \(path.debugDescription)")
        }
        let valid = [
            "a", "Salmon Run/history.json", String(repeating: "a/", count: 7) + "f",
            c255, "ひらがな/😀.txt",
            ([String](repeating: String(repeating: "a", count: 255), count: 3) + [String(repeating: "b", count: 250)]).joined(separator: "/"),
        ]
        for path in valid {
            XCTAssertNoThrow(try dest(path), "rejected \(path.debugDescription)")
        }
        // Path-length boundary: four 255-byte components + 3 separators = 1023 bytes passes; adding "/x" (1025) fails.
        let four = [String](repeating: String(repeating: "a", count: 255), count: 4).joined(separator: "/")
        XCTAssertEqual(four.utf8.count, 1023)
        XCTAssertNoThrow(try dest(four))
        let exact = ([String](repeating: String(repeating: "a", count: 255), count: 3)
            + [String(repeating: "b", count: 200), String(repeating: "c", count: 55)]).joined(separator: "/")
        XCTAssertEqual(exact.utf8.count, 1024)
        XCTAssertNoThrow(try dest(exact), "exactly 1024 bytes is allowed")
        XCTAssertThrowsError(try dest(four + "/x"), "over 1024 bytes")
    }

    func testDecodedDestinationRevalidatesPath() throws {
        let good = Data(#"{"storage":"icloud","atPath":"a/b.txt"}"#.utf8)
        let decoded = try JSONDecoder().decode(PluginFileDestination.self, from: good)
        XCTAssertEqual(decoded.storage, .icloud)
        XCTAssertEqual(decoded.atPath, "a/b.txt")
        for bad in ["../x", "/x", ".h", "a\\\\b", "a:b"] {
            let json = Data(#"{"storage":"local","atPath":"\#(bad)"}"#.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(PluginFileDestination.self, from: json), bad)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PluginFileDestination.self, from: Data(#"{"storage":"dropbox","atPath":"x"}"#.utf8)))
        XCTAssertEqual(PluginFileStorage.local.rawValue, "local")
        XCTAssertEqual(PluginFileStorage.icloud.rawValue, "icloud")
    }

    // MARK: corruption and identifiers

    func testRecordVersionsTracksReplacementAndReportsDeclaredDigestWithoutPayloadValidation() throws {
        let p = try package(), s = store()
        XCTAssertEqual(try s.recordVersions(), [:])
        XCTAssertFalse(fm.fileExists(atPath: rootURL.path), "metadata reads must not create a missing store")
        let old = Data("old payload".utf8), new = Data("new payload".utf8)
        try write(s, p, "existing.bin", old)
        let record = try onlyRecord(s)
        XCTAssertEqual(try s.recordVersions(), [record.id: sha(old)])
        try write(s, p, "existing.bin", new)
        XCTAssertEqual(try s.recordVersions(), [record.id: sha(new)])

        var bytes = try Data(contentsOf: record.url)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: record.url)
        // Metadata is only the bounded header's declared version, not a claim that payload bytes were verified.
        XCTAssertEqual(try s.recordVersions(), [record.id: sha(new)])
        XCTAssertThrowsError(try s.readRecord(record.id), "full reads must still validate the payload digest")
    }

    func testRecordVersionsRejectsCorruptHeaderAndForeignBinding() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.bin", Data())
        let record = try onlyRecord(s)
        let original = try Data(contentsOf: record.url)
        var corruptMagic = original
        corruptMagic[0] ^= 0xFF
        try corruptMagic.write(to: record.url)
        XCTAssertThrowsError(try s.recordVersions())

        var foreign = original
        let oldID = Data("33333333-3333-3333-3333-333333333333".utf8)
        let range = try XCTUnwrap(foreign.range(of: oldID))
        foreign.replaceSubrange(range, with: Data("44444444-4444-4444-4444-444444444444".utf8))
        try foreign.write(to: record.url)
        XCTAssertThrowsError(try s.recordVersions(), "metadata must validate namespace/header ownership")

        try original.dropLast().write(to: record.url)
        XCTAssertThrowsError(try s.recordVersions(), "metadata must validate the declared file length")
    }

    func testRecordVersionsBoundsRootEnumerationWithoutChangingFiles() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.bin", Data())
        for _ in 0..<273 {
            try Data().write(to: rootURL.appendingPathComponent(".tmp-" + UUID().uuidString))
        }
        let before = files(under: rootURL).map(\.path).sorted()
        XCTAssertThrowsError(try s.recordVersions(), "metadata enumeration must be bounded")
        XCTAssertEqual(files(under: rootURL).map(\.path).sorted(), before, "metadata must be read-only")
    }

    func testCorruptTruncatedAndMismatchedRecordsFailToRead() throws {
        let p = try package(), s = store()
        try write(s, p, "a.bin", Data((0..<200).map { UInt8($0) }))
        let rec = try onlyRecord(s)
        let original = try Data(contentsOf: rec.url)

        var flipped = original
        flipped[flipped.count - 1] ^= 0xFF
        try flipped.write(to: rec.url)
        XCTAssertThrowsError(try s.readRecord(rec.id), "payload mismatch")

        try original.dropLast(7).write(to: rec.url)
        XCTAssertThrowsError(try s.readRecord(rec.id), "truncated")

        try (original + Data([0x01])).write(to: rec.url)
        XCTAssertThrowsError(try s.readRecord(rec.id), "trailing bytes")

        try Data().write(to: rec.url)
        XCTAssertThrowsError(try s.readRecord(rec.id), "empty file")

        try Data(repeating: 0xAA, count: original.count).write(to: rec.url)
        XCTAssertThrowsError(try s.readRecord(rec.id), "garbage header")

        try original.write(to: rec.url)
        XCTAssertEqual(try s.readRecord(rec.id).contents, Data((0..<200).map { UInt8($0) }))
    }

    func testOversizedExistingRecordFailsClosedBeforeQuotaArithmetic() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.bin", Data())
        let record = try onlyRecord(s)
        let file = try FileHandle(forWritingTo: record.url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64((1 << 20) + 4096 + 13))
        XCTAssertThrowsError(try write(s, p, "new.bin", Data()), "oversized corrupt record must reject publication")
        XCTAssertEqual(try s.recordIdentifiers().count, 1)
    }

    func testForeignHeaderBindingCannotBeOverwrittenAsAnOwnedRecord() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.bin", Data())
        let record = try onlyRecord(s)
        var bytes = try Data(contentsOf: record.url)
        let originalFamilyID = Data("33333333-3333-3333-3333-333333333333".utf8)
        let otherFamilyID = Data("44444444-4444-4444-4444-444444444444".utf8)
        let range = try XCTUnwrap(bytes.range(of: originalFamilyID))
        bytes.replaceSubrange(range, with: otherFamilyID)
        try bytes.write(to: record.url)
        XCTAssertThrowsError(try s.readRecord(record.id), "header namespace binding is corrupt")
        XCTAssertThrowsError(try write(s, p, "existing.bin", Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: record.url), bytes, "untrusted ownership record must remain untouched")
    }

    func testTooManyPendingTemporariesRejectsBeforeCreatingMore() throws {
        let p = try package(), s = store()
        try write(s, p, "existing.bin", Data())
        for _ in 0..<257 {
            try Data().write(to: rootURL.appendingPathComponent(".tmp-" + UUID().uuidString))
        }
        let before = files(under: rootURL).count
        XCTAssertThrowsError(try prepare(s, p, "new.bin", Data()), "pending temporary count is bounded to 256")
        XCTAssertEqual(files(under: rootURL).count, before)
    }

    func testTraversalIdentifiersAreRejectedAndNothingOutsideIsRead() throws {
        let p = try package(), s = store()
        try write(s, p, "a.txt", Data("x".utf8))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("leak"))
        for id in ["../outside/leak", "/etc/passwd", "..", ".", "", "a/b", "a\\b", String(repeating: "a", count: 4096),
                   "\(try XCTUnwrap(try s.recordIdentifiers().first))/../../outside/leak"] {
            XCTAssertThrowsError(try s.readRecord(id), id)
        }
    }

    // MARK: links fail closed

    func testSymlinkedStoreRootFailsClosed() throws {
        try fm.createSymbolicLink(at: rootURL, withDestinationURL: outside)
        let s = store()
        XCTAssertThrowsError(try write(s, try package(), "a.txt", Data("x".utf8)))
        XCTAssertThrowsError(try s.recordIdentifiers())
        try assertOutsideEmpty()
    }

    func testSymlinkedNamespaceFailsClosed() throws {
        let p = try package(), s = store()
        try write(s, p, "a.txt", Data("x".utf8))
        let rec = try onlyRecord(s)
        let namespace = rec.url.deletingLastPathComponent()
        XCTAssertNotEqual(namespace.standardizedFileURL, rootURL.standardizedFileURL, "records must live in a family namespace")
        try fm.removeItem(at: namespace)
        try fm.createSymbolicLink(at: namespace, withDestinationURL: outside)
        XCTAssertThrowsError(try write(s, p, "a.txt", Data("y".utf8)))
        XCTAssertThrowsError(try write(s, p, "b.txt", Data("y".utf8)))
        try assertOutsideEmpty()
    }

    func testSymlinkedRecordFailsClosedAndIsNeverWrittenThrough() throws {
        let p = try package(), s = store()
        try write(s, p, "a.txt", Data("x".utf8))
        let rec = try onlyRecord(s)
        let target = outside.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try fm.removeItem(at: rec.url)
        try fm.createSymbolicLink(at: rec.url, withDestinationURL: target)
        XCTAssertThrowsError(try s.readRecord(rec.id))
        _ = try? write(s, p, "a.txt", Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["target"])
    }

    // MARK: quotas

    func testSeventeenthFamilyIsRejectedWhileExistingFamiliesStillUpdate() throws {
        let s = store()
        var packages: [PluginPackage] = []
        for index in 0..<16 {
            let p = try package(id: UUID())
            packages.append(p)
            try write(s, p, "\(index)/f.txt", Data())
        }
        XCTAssertEqual(try s.recordIdentifiers().count, 16)
        XCTAssertThrowsError(try write(s, try package(id: UUID()), "sixteenth/f.txt", Data()))
        XCTAssertEqual(try s.recordIdentifiers().count, 16)
        XCTAssertNoThrow(try write(s, packages[0], "0/f.txt", Data("update".utf8)))
        XCTAssertNoThrow(try write(s, packages[0], "second.txt", Data()))
        try assertNoEmptyDirectories()
    }
}
