import Foundation
import XCTest
@testable import AutomationCore

/// Real-filesystem tests for the generic File Provider publisher
/// (docs/superpowers/specs/2026-10-24-plugin-file-destinations-design.md). Written before
/// implementation: `PluginFilePublisher`, `PluginFileStore` and `PluginFileDestination` may not exist yet.
/// Records are produced through the Core store; root, state and record directories are separate paths.
final class PluginFilePublisherTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var outside: URL!
    private var stateURL: URL { directory.appendingPathComponent("state/publisher.json") }
    private let fm = FileManager.default
    private let rootIdentity = "test-root-identity"
    private let familyA = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let familyB = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("PluginFilePublisher-" + UUID().uuidString)
        root = directory.appendingPathComponent("root")
        outside = directory.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path) }
        }
        try fm.removeItem(at: directory)
    }

    // MARK: tests

    func testPublishesExactBinaryBytesAtNestedPath() async throws {
        let bytes = Data([0x00, 0xff, 0x7b, 0x00, 0x0a, 0xfe, 0x80, 0x00])
        let record = try makeRecord(family: familyA, path: "Salmon Run/details/abc.json", contents: bytes)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Salmon Run/details/abc.json")), bytes)
    }

    func testPublishesEmptyFile() async throws {
        let record = try makeRecord(family: familyA, path: "a/empty.bin", contents: Data())
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        let url = root.appendingPathComponent("a/empty.bin")
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testCombiningMarkAfterSlashUsesSeparatePathComponents() async throws {
        let bytes = Data("response".utf8)
        let record = try makeRecord(family: familyA, path: "a/\u{0301}b", contents: bytes)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a").appendingPathComponent("\u{0301}b")), bytes)
    }

    func testCombiningMarkAfterSlashDoesNotFollowSymlinkAncestor() async throws {
        try fm.createSymbolicLink(at: root.appendingPathComponent("a"), withDestinationURL: outside)
        let record = try makeRecord(family: familyA, path: "a/\u{0301}b", contents: Data("response".utf8))
        await assertRejects(record)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }

    func testCombiningMarkAfterDotIsRejectedBeforePublication() throws {
        XCTAssertThrowsError(try makeRecord(family: familyA, path: "a/.\u{0301}hidden", contents: Data("response".utf8)))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
        XCTAssertFalse(fm.fileExists(atPath: stateURL.path))
    }

    func testGrantedFolderPrefixPublishesWithoutNestingTheFolderAgain() async throws {
        let bytes = Data("original response".utf8)
        let record = try makeRecord(family: familyA, path: "Salmon Run/details/result.json", contents: bytes, storage: .icloud)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity,
                                                                 pathPrefix: "Salmon Run")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("details/result.json")), bytes)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Salmon Run").path))
        XCTAssertEqual(record.destination.atPath, "Salmon Run/details/result.json")
    }

    func testInvalidOrMismatchedFolderPrefixIsRejectedBeforeSideEffects() async throws {
        for (index, pair) in [
            ("Salmon Run/history.json", "salmon run"),
            ("Salmon Run/history.json", "Salmon"),
            ("Salmon Run/history.json", "Other"),
            ("Salmon Run/history.json", "../Salmon Run"),
            ("Salmon Run/history.json", "Salmon Run/details"),
            ("Salmon Run", "Salmon Run"),
        ].enumerated() {
            let record = try makeRecord(family: familyA, path: pair.0, contents: Data("raw".utf8),
                                        store: "prefix-\(index)", storage: .icloud)
            do {
                try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity,
                                                                         pathPrefix: pair.1)
                XCTFail("invalid/mismatched prefix accepted: \(pair)")
            } catch {}
            XCTAssertFalse(fm.fileExists(atPath: stateURL.path))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testPrefixedOwnedReplacementUsesPhysicalRelativePathInPersistedLedger() async throws {
        let first = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("one".utf8),
                                   store: "p1", storage: .icloud)
        try await PluginFilePublisher(stateURL: stateURL).publish(first, to: root, rootIdentity: rootIdentity,
                                                                 pathPrefix: "Salmon Run")
        let second = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("two".utf8),
                                    store: "p2", storage: .icloud)
        try await PluginFilePublisher(stateURL: stateURL).publish(second, to: root, rootIdentity: rootIdentity,
                                                                 pathPrefix: "Salmon Run")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), Data("two".utf8))
        let ledger = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"path\":\"history.json\""))
        XCTAssertFalse(ledger.contains("Salmon Run"))
    }

    func testAbandonedOwnedLedgerTempIsRemovedWithoutTouchingOtherFiles() async throws {
        let parent = stateURL.deletingLastPathComponent()
        let orphan = parent.appendingPathComponent(".ledger-tmp-" + UUID().uuidString)
        let unrelated = parent.appendingPathComponent(".ledger-tmp-not-owned")
        try Data("interrupted ledger".utf8).write(to: orphan)
        try Data("keep".utf8).write(to: unrelated)
        let record = try makeRecord(family: familyA, path: "history.json", contents: Data("raw".utf8))
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path), "crashed ledger temporaries must not accumulate")
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), Data("raw".utf8))
    }

    func testSameFamilySamePathReplacementSurvivesFreshPublisherInstance() async throws {
        let first = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("one".utf8), store: "s1")
        try await PluginFilePublisher(stateURL: stateURL).publish(first, to: root, rootIdentity: rootIdentity)
        let second = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("two, longer".utf8), store: "s2")
        // A new instance only knows what the persisted ledger recorded.
        try await PluginFilePublisher(stateURL: stateURL).publish(second, to: root, rootIdentity: rootIdentity)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Salmon Run/history.json")), Data("two, longer".utf8))
    }

    func testTargetFileIsCoordinatedWhenReplacingOwnedContents() async throws {
        let first = try makeRecord(family: familyA, path: "history.json", contents: Data("one".utf8), store: "s1")
        try await PluginFilePublisher(stateURL: stateURL).publish(first, to: root, rootIdentity: rootIdentity)
        let presenter = LeafPresenter(url: root.appendingPathComponent("history.json"))
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let second = try makeRecord(family: familyA, path: "history.json", contents: Data("two".utf8), store: "s2")
        try await PluginFilePublisher(stateURL: stateURL).publish(second, to: root, rootIdentity: rootIdentity)
        XCTAssertGreaterThan(presenter.writerCount, 0, "coordinating the containing directory does not coordinate this file")
    }

    func testProviderRematerializationWithIdenticalBytesRetainsOwnership() async throws {
        let first = try makeRecord(family: familyA, path: "history.json", contents: Data("one".utf8), store: "s1")
        try await PluginFilePublisher(stateURL: stateURL).publish(first, to: root, rootIdentity: rootIdentity)
        let target = root.appendingPathComponent("history.json")
        let oldInode = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
        // File Providers may materialize the same document on a new inode. Its contents still match
        // the persisted published digest; only per-operation race checks may rely on the inode.
        try Data("one".utf8).write(to: target, options: .atomic)
        let newInode = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(oldInode, newInode)
        let second = try makeRecord(family: familyA, path: "history.json", contents: Data("two".utf8), store: "s2")
        try await PluginFilePublisher(stateURL: stateURL).publish(second, to: root, rootIdentity: rootIdentity)
        XCTAssertEqual(try Data(contentsOf: target), Data("two".utf8))
    }

    func testPreexistingUnknownFileIsRejectedWithoutChange() async throws {
        let target = root.appendingPathComponent("Salmon Run/history.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: target)
        let record = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("plugin".utf8))
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: target), Data("user data".utf8))
    }

    func testExternallyEditedOwnedFileIsRejected() async throws {
        let first = try makeRecord(family: familyA, path: "history.json", contents: Data("one".utf8), store: "s1")
        try await PluginFilePublisher(stateURL: stateURL).publish(first, to: root, rootIdentity: rootIdentity)
        let target = root.appendingPathComponent("history.json")
        try Data("edited by user".utf8).write(to: target)
        let second = try makeRecord(family: familyA, path: "history.json", contents: Data("two".utf8), store: "s2")
        await assertRejects(second)
        XCTAssertEqual(try Data(contentsOf: target), Data("edited by user".utf8))
    }

    func testCrossFamilyCollisionIsRejected() async throws {
        let owner = try makeRecord(family: familyA, path: "shared/history.json", contents: Data("a".utf8), store: "sA")
        try await PluginFilePublisher(stateURL: stateURL).publish(owner, to: root, rootIdentity: rootIdentity)
        let other = try makeRecord(family: familyB, path: "shared/history.json", contents: Data("b".utf8), store: "sB")
        await assertRejects(other)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("shared/history.json")), Data("a".utf8))
    }

    func testCaseAliasOfAnotherFamilysFileIsRejected() async throws {
        let owner = try makeRecord(family: familyA, path: "Shared/History.json", contents: Data("a".utf8), store: "sA")
        try await PluginFilePublisher(stateURL: stateURL).publish(owner, to: root, rootIdentity: rootIdentity)
        let other = try makeRecord(family: familyB, path: "shared/history.json", contents: Data("b".utf8), store: "sB")
        await assertRejects(other)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Shared/History.json")), Data("a".utf8))
    }

    func testCompatibilityAliasUsesTheCoreOwnershipIdentity() async throws {
        let owner = try makeRecord(family: familyA, path: "Shared/history.json", contents: Data("a".utf8), store: "sA")
        try await PluginFilePublisher(stateURL: stateURL).publish(owner, to: root, rootIdentity: rootIdentity)
        let other = try makeRecord(family: familyB, path: "Ｓｈａｒｅｄ/history.json", contents: Data("b".utf8), store: "sB")
        await assertRejects(other)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Shared/history.json")), Data("a".utf8))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Ｓｈａｒｅｄ/history.json").path))
    }

    func testSymlinkAncestorIsRejectedWithoutOutsideChange() async throws {
        try fm.createSymbolicLink(at: root.appendingPathComponent("Salmon Run"), withDestinationURL: outside)
        let record = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("x".utf8))
        await assertRejects(record)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkFinalTargetIsRejectedWithoutOutsideChange() async throws {
        let victim = outside.appendingPathComponent("victim.json")
        try Data("victim".utf8).write(to: victim)
        try fm.createSymbolicLink(at: root.appendingPathComponent("history.json"), withDestinationURL: victim)
        let record = try makeRecord(family: familyA, path: "history.json", contents: Data("x".utf8))
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["victim.json"])
    }

    func testCancellationBeforePublishLeavesNoFileOrLedger() async throws {
        let record = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: Data("x".utf8))
        let publisher = PluginFilePublisher(stateURL: stateURL)
        let root = self.root!, identity = rootIdentity
        let task = Task {
            // Enter publish only once cancellation is already visible; no timing involved.
            while !Task.isCancelled { await Task.yield() }
            try await publisher.publish(record, to: root, rootIdentity: identity)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled publish must not succeed")
        } catch {}
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
        XCTAssertFalse(fm.fileExists(atPath: stateURL.path), "ledger mutated by a cancelled publish")
    }

    private func writeLedger(_ record: PluginFileRecord, path: String, pending: String?, published: String?,
                             temporary: URL? = nil, includeTempIdentity: Bool = true) throws {
        let key = PluginFilePublisher.ledgerKey(rootIdentity: rootIdentity, path: path)
        func j(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "null" }
        let family = Digest.sha256Hex(Data(record.family.utf8))
        var extra = ""
        if let temporary {
            extra = ",\"tempName\":\"\(temporary.lastPathComponent)\""
            if includeTempIdentity {
                var info = stat()
                guard lstat(temporary.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                extra += ",\"tempDevice\":\(Int64(info.st_dev)),\"tempInode\":\(Int64(truncatingIfNeeded: info.st_ino))"
            }
        }
        let json = "{\"entries\":[{\"family\":\"\(family)\",\"key\":\"\(key)\",\"path\":\"\(path)\",\"pending\":\(j(pending)),\"published\":\(j(published))\(extra)}],\"version\":1}"
        try Data(json.utf8).write(to: stateURL)
    }

    private func crashTemporary(_ bytes: Data, stale: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(".interceptor-" + UUID().uuidString + ".tmp")
        try bytes.write(to: url)
        if stale { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path) }
        return url
    }

    func testAbandonedIntentTempIsRemovedWithoutTouchingUntrackedLookalike() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(bytes)
        let unrelated = try crashTemporary(bytes)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), bytes)
        XCTAssertFalse(try String(contentsOf: stateURL, encoding: .utf8).contains("tempName"))
    }

    func testOwnedScratchInodeIsReclaimedAfterInterruptedWrite() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(Data("incomplete native scratch bytes".utf8))
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), bytes)
    }

    func testPartialScratchFromOlderResponseIsReclaimedForNewerResponse() async throws {
        let old = try makeRecord(family: familyA, path: "history.json", contents: Data("old response".utf8), store: "old")
        let orphan = try crashTemporary(Data("old".utf8))
        try writeLedger(old, path: "history.json", pending: old.digest, published: nil, temporary: orphan)
        let new = try makeRecord(family: familyA, path: "history.json", contents: Data("new response".utf8), store: "new")
        try await PluginFilePublisher(stateURL: stateURL).publish(new, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), Data("new response".utf8))
    }

    func testEmptyScratchBeforeInodeJournalIsReclaimed() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(Data())
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil,
                        temporary: orphan, includeTempIdentity: false)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), bytes)
    }

    func testReplacedScratchWithEditedBytesIsPreserved() async throws {
        let record = try makeRecord(family: familyA, path: "history.json", contents: Data("complete response".utf8))
        let orphan = try crashTemporary(Data("partial".utf8))
        let oldInode = try fm.attributesOfItem(atPath: orphan.path)[.systemFileNumber] as? NSNumber
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        try Data("user replacement".utf8).write(to: orphan, options: .atomic)
        XCTAssertNotEqual(oldInode, try fm.attributesOfItem(atPath: orphan.path)[.systemFileNumber] as? NSNumber)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: orphan.path)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: orphan), Data("user replacement".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [orphan.lastPathComponent])
    }

    func testRematerializedScratchWithCompletePendingResponseIsReclaimed() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(Data("partial".utf8))
        let oldInode = try fm.attributesOfItem(atPath: orphan.path)[.systemFileNumber] as? NSNumber
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        try bytes.write(to: orphan, options: .atomic)
        XCTAssertNotEqual(oldInode, try fm.attributesOfItem(atPath: orphan.path)[.systemFileNumber] as? NSNumber)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: orphan.path)
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), bytes)
    }

    func testJournaledSymlinkScratchIsPreserved() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let target = outside.appendingPathComponent("response")
        try bytes.write(to: target)
        let orphan = root.appendingPathComponent(".interceptor-" + UUID().uuidString + ".tmp")
        try fm.createSymbolicLink(at: orphan, withDestinationURL: target)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        await assertRejects(record)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: orphan.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testJournaledHardLinkedScratchIsPreserved() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let target = outside.appendingPathComponent("response")
        try bytes.write(to: target)
        let orphan = root.appendingPathComponent(".interceptor-" + UUID().uuidString + ".tmp")
        try fm.linkItem(at: target, to: orphan)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: orphan.path)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: orphan), bytes)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testIntentTempWithoutRecordedInodeIsPreserved() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(bytes)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil,
                        temporary: orphan, includeTempIdentity: false)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: orphan), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [orphan.lastPathComponent])
    }

    func testLockedIntentTempIsPreservedWithoutCreatingAnotherTemp() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(bytes)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        let fd = open(orphan.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: orphan), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [orphan.lastPathComponent])
    }

    func testRecentIntentTempIsPreservedWithoutCreatingAnotherTemp() async throws {
        let bytes = Data("complete response".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: bytes)
        let orphan = try crashTemporary(bytes, stale: false)
        try writeLedger(record, path: "history.json", pending: record.digest, published: nil, temporary: orphan)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: orphan), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [orphan.lastPathComponent])
    }

    func testRecoversInterruptedPublicationFromIntentLedger() async throws {
        // Crash after the external rename but before the ledger was finalized: ledger holds old+pending.
        let new = Data("new bytes".utf8)
        let record = try makeRecord(family: familyA, path: "Salmon Run/history.json", contents: new)
        let target = root.appendingPathComponent("Salmon Run/history.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: target)
        try writeLedger(record, path: "Salmon Run/history.json", pending: Digest.sha256Hex(new),
                        published: Digest.sha256Hex(Data("old".utf8)))
        try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
        XCTAssertEqual(try Data(contentsOf: target), new)
        let ledger = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"pending\":null"))
        XCTAssertTrue(ledger.contains("\"published\":\"\(Digest.sha256Hex(new))\""))
    }

    func testIntentLedgerDoesNotClaimUnknownFileWithDifferentBytes() async throws {
        let new = Data("new".utf8)
        let record = try makeRecord(family: familyA, path: "history.json", contents: new)
        let target = root.appendingPathComponent("history.json")
        try Data("user".utf8).write(to: target)
        try writeLedger(record, path: "history.json", pending: Digest.sha256Hex(new), published: nil)
        await assertRejects(record)
        XCTAssertEqual(try Data(contentsOf: target), Data("user".utf8))
    }

    func testCorruptLedgerFailsClosedWithoutPublishing() async throws {
        try Data("{\"entries\":[],\"version\":1,\"extra\":true}".utf8).write(to: stateURL)
        let record = try makeRecord(family: familyA, path: "history.json", contents: Data("x".utf8))
        await assertRejects(record)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
    }

    func testSymlinkRootIsRejected() async throws {
        let link = directory.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let record = try makeRecord(family: familyA, path: "history.json", contents: Data("x".utf8))
        do {
            try await PluginFilePublisher(stateURL: stateURL).publish(record, to: link, rootIdentity: rootIdentity)
            XCTFail("symlink root must be rejected")
        } catch {}
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }

    // MARK: helpers

    private final class LeafPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var writers = 0
        let presentedItemOperationQueue = OperationQueue()
        var presentedItemURL: URL? { url }
        var writerCount: Int { lock.withLock { writers } }

        init(url: URL) {
            self.url = url
            super.init()
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }

        func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
            lock.withLock { writers += 1 }
            writer(nil)
        }
    }

    private func assertRejects(_ record: PluginFileRecord, file: StaticString = #filePath, line: UInt = #line) async {
        let stateBefore = try? Data(contentsOf: stateURL)
        do {
            try await PluginFilePublisher(stateURL: stateURL).publish(record, to: root, rootIdentity: rootIdentity)
            XCTFail("publish should have been rejected", file: file, line: line)
        } catch {}
        XCTAssertEqual(try? Data(contentsOf: stateURL), stateBefore, "ledger changed by a rejected publish", file: file, line: line)
    }

    /// Builds a record through the Core store. Each `store` name is its own record directory, so records of
    /// different families or revisions never trip the source store's own ownership checks.
    private func makeRecord(family: UUID, path: String, contents: Data, store name: String = "records",
                            storage: PluginFileStorage = .local) throws -> PluginFileRecord {
        let store = PluginFileStore(directoryURL: directory.appendingPathComponent("records-" + name + "-" + family.uuidString))
        let package = try package(id: family)
        let destination = try PluginFileDestination(storage: storage, atPath: path)
        let revision = "local|\(package.manifest.id.uuidString)|\(package.revision)"
        let prepared = try store.prepare(revisionID: revision, package: package, destination: destination, contents: contents)
        try prepared.commit(checkAuthorization: {})
        let identifiers = try store.recordIdentifiers()
        XCTAssertEqual(identifiers.count, 1)
        return try store.readRecord(try XCTUnwrap(identifiers.first))
    }

    private func package(id: UUID, source: String = "// s") throws -> PluginPackage {
        let json = """
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"Test","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"response":{"onLeave":"hooks/example.com/GET.js"}}}],
        "read":{"metadata":["method","host","path","status"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},
        "write":{"requestBody":true,"responseBody":true,"files":true},"endpointBindings":[],"settings":{}},"sourceFiles":{"hooks/example.com/GET.js":"\(source)"}}
        """
        return try PluginPackage.validate(Data(json.utf8))
    }
}
