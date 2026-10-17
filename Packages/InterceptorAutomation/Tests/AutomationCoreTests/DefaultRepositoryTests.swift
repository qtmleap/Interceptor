import CryptoKit
import XCTest
@testable import AutomationCore

final class DefaultRepositoryTests: AutomationTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var fingerprint: String { Digest.sha256Hex(key.publicKey.rawRepresentation) }

    private func seed(_ st: AutomationStore, _ s: VerifiedSnapshot, id: UUID = repoID, fp: String? = nil,
                      expected: RepositoryURL = url(), at: Date = now) async throws -> RepositoryRecord {
        try await st.seedIfAbsent(s, expectedURL: expected, expectedRepositoryID: id, expectedFingerprint: fp ?? fingerprint, now: at)
    }

    func testSeedPinsAndPersistsMetadataOnlyWithNoRevisions() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let s = try snap(indexJSON(), key: key)
        let record = try await seed(st, s)
        XCTAssertTrue(record.visible)
        XCTAssertEqual(record.url, s.url)
        XCTAssertEqual(record.repositoryID, repoID)
        XCTAssertEqual(record.sequence, s.index.sequence)
        XCTAssertEqual(record.payloadDigest, s.payloadDigest)
        XCTAssertEqual(record.snapshot, s)
        guard case .pinned(let pinned) = record.trust else { return XCTFail("seed must pin") }
        XCTAssertEqual(pinned.hex, fingerprint)
        let reloaded = try await AutomationStore(fileURL: f).load()
        XCTAssertEqual(reloaded.record(for: s.url), record)
        XCTAssertTrue(reloaded.revisions.isEmpty)
        XCTAssertEqual(reloaded.repositories.count, 1)
    }

    func testSeedIsIdempotentAndPreservesExistingGeneration() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let first = try await seed(st, snap(indexJSON(sequence: 1), key: key))
        let second = try await seed(st, snap(indexJSON(sequence: 2), key: key))
        XCTAssertEqual(second, first)
        let reloaded = try await AutomationStore(fileURL: f).load()
        XCTAssertEqual(reloaded.record(for: url()), first)
        XCTAssertEqual(reloaded.repositories.count, 1)
    }

    func testSeedPreservesUserAcceptedExistingRecord() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let existing = try await st.accept(snap(indexJSON(sequence: 5)), acknowledgeUnverified: true, now: now)
        let result = try await seed(st, snap(indexJSON(sequence: 1), key: key))
        XCTAssertEqual(result, existing)
        let cat = try await st.load()
        XCTAssertEqual(cat.record(for: url()), existing)
    }

    func testRemovalTombstoneSurvivesRelaunchAndLateSeed() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let s = try snap(indexJSON(), key: key)
        _ = try await seed(st, s)
        try await st.remove(s.url)
        let loaded = try await st.load()
        let tombstone = try XCTUnwrap(loaded.record(for: s.url))
        XCTAssertFalse(tombstone.visible)
        // A seed that was already in flight when the user removed the source must not resurrect it.
        let late = try await seed(st, s)
        XCTAssertEqual(late, tombstone)
        // Nor may a relaunch (fresh actor over the same file).
        let relaunched = AutomationStore(fileURL: f)
        let again = try await seed(relaunched, s)
        XCTAssertEqual(again, tombstone)
        let cat = try await relaunched.load()
        XCTAssertEqual(cat.record(for: s.url), tombstone)
        XCTAssertTrue(cat.visibleRepositories.isEmpty)
    }

    func testConcurrentSeedsCommitOneRecord() async throws {
        let file = tempFile(), st = AutomationStore(fileURL: file)
        let s = try snap(indexJSON(), key: key)
        let fp = fingerprint
        let records = try await withThrowingTaskGroup(of: RepositoryRecord.self) { group in
            for _ in 0..<4 {
                group.addTask { try await AutomationStore(fileURL: file).seedIfAbsent(s, expectedURL: url(), expectedRepositoryID: repoID, expectedFingerprint: fp, now: now) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(records.map(\.generation)).count, 1)
        let cat = try await st.load()
        XCTAssertEqual(cat.repositories.count, 1)
    }

    func testSeedRejectsMismatchesWithoutMutation() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let other = Curve25519.Signing.PrivateKey()
        let otherURL = try RepositoryURL(parsing: "https://example.com/other/repository.json")
        let wrongRepo = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let signed = try snap(indexJSON(), key: key)

        // Unsigned snapshot.
        await assertSeedFails(st, try snap(indexJSON()), expecting: .fingerprintMismatch)
        // Signed by a different key than the expected fingerprint.
        await assertSeedFails(st, try snap(indexJSON(), key: other), expecting: .fingerprintMismatch)
        // Malformed expected fingerprint.
        await assertSeedFails(st, signed, fp: "abc", expecting: .fingerprintMismatch)
        // Wrong URL.
        await assertSeedFails(st, signed, expected: otherURL, expecting: nil)
        // Wrong repository UUID.
        await assertSeedFails(st, signed, id: wrongRepo, expecting: nil)
        // Expired at the moment of seeding.
        await assertSeedFails(st, signed, at: now.addingTimeInterval(86_401), expecting: .expired)

        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        let cat = await st.catalog()
        XCTAssertTrue(cat.repositories.isEmpty)
    }

    private func assertSeedFails(_ st: AutomationStore, _ s: VerifiedSnapshot, id: UUID = repoID, fp: String? = nil,
                                 expected: RepositoryURL = url(), at: Date = now, expecting: AutomationError?,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await seed(st, s, id: id, fp: fp, expected: expected, at: at)
            XCTFail("seed must be rejected", file: file, line: line)
        } catch {
            if let expecting { XCTAssertEqual(error as? AutomationError, expecting, file: file, line: line) }
            else { XCTAssertTrue(error is AutomationError, "\(error)", file: file, line: line) }
        }
    }

    func testSeedRespectsRepositoryCap() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        for i in 0..<Limits.repositories {
            let u = try RepositoryURL(parsing: "https://example.com/r\(i)/repository.json")
            let s = try RepositoryEnvelope.verify(envelope: envelope(indexJSON(id: UUID())), url: u, now: now)
            _ = try await st.accept(s, acknowledgeUnverified: true, now: now)
        }
        let before = try Data(contentsOf: f)
        do { _ = try await seed(st, snap(indexJSON(), key: key)); XCTFail("cap must reject") }
        catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        XCTAssertEqual(try Data(contentsOf: f), before)
    }

    func testSeedSaveFailureAndCorruptStoreLeaveStateUntouched() async throws {
        let failFile = tempFile()
        let failing = AutomationStore(fileURL: failFile, writer: { _, _ in throw AutomationError.saveFailed })
        do { _ = try await seed(failing, snap(indexJSON(), key: key)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .saveFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failFile.path))
        let failedCatalog = await failing.catalog()
        XCTAssertTrue(failedCatalog.repositories.isEmpty)

        let corruptFile = tempFile()
        let garbage = Data("not a catalog".utf8)
        try garbage.write(to: corruptFile)
        let st = AutomationStore(fileURL: corruptFile)
        do { _ = try await seed(st, snap(indexJSON(), key: key)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: corruptFile), garbage)
    }
}
