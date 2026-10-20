import CryptoKit
import XCTest
@testable import AutomationCore

private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var failing: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

final class RepositoryRefreshTests: AutomationTestCase {
    private func counted(_ f: URL) -> (AutomationStore, WriteCounter) {
        let c = WriteCounter()
        return (AutomationStore(fileURL: f, writer: { file, data in c.bump(); try file.replace(with: data) }), c)
    }

    private func expect<T>(_ e: AutomationError, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected \(e)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationError, e, file: file, line: line) }
    }

    func testHigherSequenceChangesGenerationWithoutImport() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let r1 = try await st.accept(snap(indexJSON(sequence: 1)), acknowledgeUnverified: true, now: now)
        let r2 = try await st.refresh(snap(indexJSON(sequence: 2)), expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        XCTAssertNotEqual(r1.generation, r2.generation)
        XCTAssertEqual(r2.sequence, 2)
        let c = try await st.load()
        XCTAssertEqual(c.record(for: url()), r2)
        XCTAssertTrue(c.revisions.isEmpty)
    }

    func testIdenticalNoOpWritesNothing() async throws {
        let f = tempFile(), (st, writes) = counted(f)
        let s = try snap(indexJSON())
        let r1 = try await st.accept(s, acknowledgeUnverified: true, now: now)
        let before = try Data(contentsOf: f), w = writes.count
        let r2 = try await st.refresh(s, expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        XCTAssertEqual(r2, r1)
        XCTAssertEqual(try Data(contentsOf: f), before)
        XCTAssertEqual(writes.count, w)
    }

    func testWhitespaceEnvelopeVariantReturnsStoredSnapshot() async throws {
        let f = tempFile(), (st, writes) = counted(f)
        let payload = indexJSON()
        let s = try snap(payload)
        let r1 = try await st.accept(s, acknowledgeUnverified: true, now: now)
        var raw = try envelope(payload)
        raw.insert(contentsOf: Data(" \n".utf8), at: 1)
        let variant = try RepositoryEnvelope.verify(envelope: raw, url: url(), now: now)
        XCTAssertEqual(variant.payloadDigest, s.payloadDigest)
        XCTAssertNotEqual(variant, s)
        let before = try Data(contentsOf: f), w = writes.count
        let r2 = try await st.refresh(variant, expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        XCTAssertEqual(r2.generation, r1.generation)
        XCTAssertEqual(r2.snapshot, s)
        XCTAssertNotEqual(r2.snapshot, variant)
        XCTAssertEqual(try Data(contentsOf: f), before)
        XCTAssertEqual(writes.count, w)
    }

    func testTrustUpgradeSamePayloadNeedsAckAndNewGeneration() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = AutomationStore(fileURL: tempFile())
        let r1 = try await st.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now)
        let signed = try snap(indexJSON(), key: k)
        await expect(.acknowledgmentRequired) { try await st.refresh(signed, expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now) }
        let unchanged = try await st.load()
        XCTAssertEqual(unchanged.record(for: url()), r1)
        let r2 = try await st.refresh(signed, expectedGeneration: r1.generation, acknowledgeUnverified: true, now: now)
        XCTAssertNotEqual(r2.generation, r1.generation)
        XCTAssertEqual(r2.trust, .signedUnverified(PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!))
    }

    func testRejectionsLeaveRecordUnchanged() async throws {
        let k1 = Curve25519.Signing.PrivateKey(), k2 = Curve25519.Signing.PrivateKey()
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let r = try await st.accept(snap(indexJSON(sequence: 5), key: k1), acknowledgeUnverified: true, now: now)
        let before = try Data(contentsOf: f)
        let g = r.generation
        await expect(.keyChanged) { try await st.refresh(snap(indexJSON(sequence: 6), key: k2), expectedGeneration: g, acknowledgeUnverified: true, now: now) }
        await expect(.signatureRemoved) { try await st.refresh(snap(indexJSON(sequence: 6)), expectedGeneration: g, acknowledgeUnverified: true, now: now) }
        await expect(.rollback) { try await st.refresh(snap(indexJSON(sequence: 4), key: k1), expectedGeneration: g, acknowledgeUnverified: true, now: now) }
        await expect(.sameSequenceDifferentPayload) { try await st.refresh(snap(indexJSON(sequence: 5, issued: now.addingTimeInterval(-1)), key: k1), expectedGeneration: g, acknowledgeUnverified: true, now: now) }
        let other = UUID()
        await expect(.repositoryIdentityChanged) { try await st.refresh(snap(indexJSON(id: other, sequence: 6), key: k1), expectedGeneration: g, acknowledgeUnverified: true, now: now) }
        let later = now.addingTimeInterval(3 * 86_400)
        await expect(.expired) { try await st.refresh(snap(indexJSON(sequence: 6), key: k1), expectedGeneration: g, acknowledgeUnverified: true, now: later) }
        // identical content is still expiry-checked
        await expect(.expired) { try await st.refresh(snap(indexJSON(sequence: 5), key: k1), expectedGeneration: g, acknowledgeUnverified: true, now: later) }
        XCTAssertEqual(try Data(contentsOf: f), before)
    }

    func testWrongGenerationAndHiddenRepositoryRejected() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        let s = try snap(indexJSON())
        let r = try await st.accept(s, acknowledgeUnverified: true, now: now)
        await expect(.staleSnapshot) { try await st.refresh(s, expectedGeneration: UUID(), acknowledgeUnverified: true, now: now) }
        try await st.remove(url())
        let hidden = try await st.load().record(for: url())
        await expect(.staleSnapshot) { try await st.refresh(s, expectedGeneration: r.generation, acknowledgeUnverified: true, now: now) }
        await expect(.staleSnapshot) { try await st.refresh(s, expectedGeneration: hidden!.generation, acknowledgeUnverified: true, now: now) }
        let after = try await st.load().record(for: url())
        XCTAssertEqual(after, hidden)
        XCTAssertFalse(after!.visible)
        // re-adding after removal issues a new generation, so the pre-removal (hidden) generation stays stale
        let r2 = try await st.accept(s, acknowledgeUnverified: true, now: now)
        await expect(.staleSnapshot) { try await st.refresh(s, expectedGeneration: hidden!.generation, acknowledgeUnverified: true, now: now) }
        XCTAssertNotEqual(r2.generation, hidden!.generation)
    }

    func testSeparateActorSeesRefreshedRecord() async throws {
        let f = tempFile(), a = AutomationStore(fileURL: f), b = AutomationStore(fileURL: f)
        let r1 = try await a.accept(snap(indexJSON(sequence: 1)), acknowledgeUnverified: true, now: now)
        let r2 = try await a.refresh(snap(indexJSON(sequence: 2)), expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        let seen = try await b.load().record(for: url())
        XCTAssertEqual(seen, r2)
    }

    func testNoOpAfterOtherActorChangeRejectsCAS() async throws {
        let f = tempFile(), a = AutomationStore(fileURL: f), b = AutomationStore(fileURL: f)
        let s1 = try snap(indexJSON(sequence: 1))
        let r1 = try await a.accept(s1, acknowledgeUnverified: true, now: now)
        _ = try await b.load()
        _ = try await b.refresh(snap(indexJSON(sequence: 2)), expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        await expect(.staleSnapshot) { try await a.refresh(s1, expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now) }
    }

    func testRefreshPreservesImportedRevision() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let s1 = try snap(indexJSON(sequence: 1))
        let r1 = try await st.accept(s1, acknowledgeUnverified: true, now: now)
        let rev = try await st.install(PluginPackage.validate(packageBytes(), against: s1.index.plugins[0]), from: s1, expectedGeneration: r1.generation, now: now)
        let r2 = try await st.refresh(snap(indexJSON(sequence: 2)), expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now)
        XCTAssertNotEqual(r2.generation, r1.generation)
        let c = try await st.load()
        XCTAssertEqual(c.revisions, [rev])
        XCTAssertEqual(c.record(for: url()), r2)
    }

    func testFailedWriteLeavesImportedCatalogUnchangedAcrossReopen() async throws {
        let f = tempFile(), fail = FailSwitch()
        let st = AutomationStore(fileURL: f, writer: { file, data in
            if fail.failing { throw AutomationError.saveFailed }
            try file.replace(with: data)
        })
        let s1 = try snap(indexJSON(sequence: 1))
        let r1 = try await st.accept(s1, acknowledgeUnverified: true, now: now)
        let rev = try await st.install(PluginPackage.validate(packageBytes(), against: s1.index.plugins[0]), from: s1, expectedGeneration: r1.generation, now: now)
        let before = try Data(contentsOf: f)

        fail.failing = true
        await expect(.saveFailed) { try await st.refresh(snap(indexJSON(sequence: 2)), expectedGeneration: r1.generation, acknowledgeUnverified: false, now: now) }

        XCTAssertEqual(try Data(contentsOf: f), before)
        let inMemory = await st.catalog()
        let reopened = try await AutomationStore(fileURL: f).load()
        for catalog in [inMemory, reopened] {
            XCTAssertEqual(catalog.record(for: url()), r1)
            XCTAssertEqual(catalog.record(for: url())?.generation, r1.generation)
            XCTAssertEqual(catalog.record(for: url())?.snapshot, s1)
            XCTAssertEqual(catalog.revisions, [rev])
        }
    }

    func testStalePinFromOtherActorRejectsRefreshOfOldGeneration() async throws {
        let k = Curve25519.Signing.PrivateKey()
        let f = tempFile(), a = AutomationStore(fileURL: f), b = AutomationStore(fileURL: f)
        let r1 = try await a.accept(snap(indexJSON(sequence: 1), key: k), acknowledgeUnverified: true, now: now)
        let fingerprint = PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!.hex
        let pinned = try await b.pin(url(), fingerprint: fingerprint)
        XCTAssertNotEqual(pinned.generation, r1.generation)
        let before = try Data(contentsOf: f)
        await expect(.staleSnapshot) { try await a.refresh(snap(indexJSON(sequence: 2), key: k), expectedGeneration: r1.generation, acknowledgeUnverified: true, now: now) }
        XCTAssertEqual(try Data(contentsOf: f), before)
        let seen = try await a.load().record(for: url())
        XCTAssertEqual(seen, pinned)
    }

    func testCompetingRefreshesFromTwoActorsCommitExactlyOne() async throws {
        let f = tempFile(), a = AutomationStore(fileURL: f), b = AutomationStore(fileURL: f)
        let r1 = try await a.accept(snap(indexJSON(sequence: 1)), acknowledgeUnverified: true, now: now)
        let s2 = try snap(indexJSON(sequence: 2)), s3 = try snap(indexJSON(sequence: 3))
        let g = r1.generation

        async let ra: Result<RepositoryRecord, Error> = {
            do { return .success(try await a.refresh(s2, expectedGeneration: g, acknowledgeUnverified: false, now: now)) }
            catch { return .failure(error) }
        }()
        async let rb: Result<RepositoryRecord, Error> = {
            do { return .success(try await b.refresh(s3, expectedGeneration: g, acknowledgeUnverified: false, now: now)) }
            catch { return .failure(error) }
        }()
        let results = await [ra, rb]

        let winners = results.compactMap { try? $0.get() }
        let losers = results.compactMap { r -> Error? in if case .failure(let e) = r { return e } else { return nil } }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(losers.count, 1)
        XCTAssertEqual(losers.first as? AutomationError, .staleSnapshot)
        let winner = try XCTUnwrap(winners.first)
        XCTAssertNotEqual(winner.generation, g)
        XCTAssertTrue(winner.sequence == 2 || winner.sequence == 3)

        // The loser must not have overwritten the winner: strict readback through a fresh store.
        let disk = try await AutomationStore(fileURL: f).load().record(for: url())
        XCTAssertEqual(disk, winner)
    }
}
