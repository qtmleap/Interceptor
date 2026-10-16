import CryptoKit
import XCTest
@testable import AutomationCore

final class StoreTests: AutomationTestCase {
    private func accepted(_ st: AutomationStore, _ s: VerifiedSnapshot) async throws -> UUID {
        try await st.accept(s, acknowledgeUnverified: true, now: now).generation
    }

    func testAcknowledgmentRequiredAndPersistsNothing() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        do { _ = try await st.accept(snap(indexJSON()), acknowledgeUnverified: false, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .acknowledgmentRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        let p = try await st.preview(snap(indexJSON()), now: now)
        XCTAssertTrue(p.requiresAcknowledgment && p.isNewRepository)
        XCTAssertEqual(p.resultingTrust, .unsignedAcknowledged)
        let c = await st.catalog()
        XCTAssertTrue(c.repositories.isEmpty)
    }

    func testTrustTable() async throws {
        let k1 = Curve25519.Signing.PrivateKey(), k2 = Curve25519.Signing.PrivateKey()
        // unsignedAcknowledged -> signed requires new ack and becomes signedUnverified
        var st = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st, snap(indexJSON(sequence: 1)))
        let p = try await st.preview(snap(indexJSON(sequence: 2), key: k1), now: now)
        XCTAssertTrue(p.requiresAcknowledgment)
        do { _ = try await st.accept(snap(indexJSON(sequence: 2), key: k1), acknowledgeUnverified: false, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .acknowledgmentRequired) }
        let r = try await st.accept(snap(indexJSON(sequence: 2), key: k1), acknowledgeUnverified: true, now: now)
        XCTAssertEqual(r.trust, .signedUnverified(PublicKeyFingerprint(rawKey: k1.publicKey.rawRepresentation)!))
        // unsigned refresh stays allowed without ack
        st = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st, snap(indexJSON(sequence: 1)))
        let again = try await st.accept(snap(indexJSON(sequence: 2)), acknowledgeUnverified: false, now: now)
        XCTAssertEqual(again.trust, .unsignedAcknowledged)
        // signedUnverified: unsigned and different key refused
        st = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st, snap(indexJSON(sequence: 1), key: k1))
        do { _ = try await st.accept(snap(indexJSON(sequence: 2)), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .signatureRemoved) }
        do { _ = try await st.accept(snap(indexJSON(sequence: 2), key: k2), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .keyChanged) }
        let same = try await st.accept(snap(indexJSON(sequence: 2), key: k1), acknowledgeUnverified: false, now: now)
        XCTAssertEqual(same.sequence, 2)
    }

    func testVerifiedAddPinsAtomicallyAndRejectsMismatchWithoutSaving() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let snapshot = try snap(indexJSON(), key: key)
        let fingerprint = Digest.sha256Hex(key.publicKey.rawRepresentation)
        let good = AutomationStore(fileURL: tempFile())
        let record = try await good.acceptAndPin(snapshot, fingerprint: fingerprint, now: now)
        guard case .pinned(let pinned) = record.trust else { return XCTFail("verified add must persist the pin") }
        XCTAssertEqual(pinned.hex, fingerprint)
        let loaded = try await good.load()
        XCTAssertEqual(loaded.record(for: snapshot.url)?.trust, record.trust)
        let file = tempFile(), bad = AutomationStore(fileURL: file)
        do {
            _ = try await bad.acceptAndPin(snapshot, fingerprint: String(repeating: "0", count: 64), now: now)
            XCTFail("mismatch must not add a source")
        } catch { XCTAssertEqual(error as? AutomationError, .fingerprintMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let unchanged = await bad.catalog()
        XCTAssertTrue(unchanged.repositories.isEmpty)
    }

    func testPinnedRefreshPreservesPin() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = AutomationStore(fileURL: tempFile())
        let fp = PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!
        _ = try await accepted(st, snap(indexJSON(sequence: 1), key: k))
        _ = try await st.pin(url(), fingerprint: fp.hex.uppercased())
        let r = try await st.accept(snap(indexJSON(sequence: 2), key: k), acknowledgeUnverified: false, now: now)
        XCTAssertEqual(r.trust, .pinned(fp))
    }

    func testPinRejectsUnsignedAndMalformedFingerprints() async throws {
        let st = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st, snap(indexJSON()))
        do { _ = try await st.pin(url(), fingerprint: String(repeating: "0", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .fingerprintMismatch) }
        let k = Curve25519.Signing.PrivateKey()
        let st2 = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st2, snap(indexJSON(), key: k))
        let hex = PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!.hex
        for bad in [String(hex.dropLast()), hex + "0", " " + hex, ""] {
            do { _ = try await st2.pin(url(), fingerprint: bad); XCTFail(bad) }
            catch { XCTAssertEqual(error as? AutomationError, .fingerprintMismatch) }
        }
    }

    func testSameSequenceSamePayloadIdempotentButRotatesGeneration() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let g1 = try await accepted(st, snap(indexJSON(sequence: 3)))
        let g2 = try await accepted(st, snap(indexJSON(sequence: 3)))
        XCTAssertNotEqual(g1, g2)
        let c = await st.catalog()
        XCTAssertEqual(c.repositories.count, 1)
    }

    func testRemoveThenReaddRequiresAckKeepsPinAndHighWater() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = AutomationStore(fileURL: tempFile())
        let fp = PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!
        _ = try await accepted(st, snap(indexJSON(sequence: 4), key: k))
        _ = try await st.pin(url(), fingerprint: fp.hex)
        try await st.remove(url())
        do { _ = try await st.accept(snap(indexJSON(sequence: 4)), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .signatureRemoved) }
        let r = try await st.accept(snap(indexJSON(sequence: 5), key: k), acknowledgeUnverified: false, now: now)
        XCTAssertEqual(r.trust, .pinned(fp))
        // unverified source requires ack again after removal
        let u = AutomationStore(fileURL: tempFile())
        _ = try await accepted(u, snap(indexJSON(sequence: 1)))
        try await u.remove(url())
        do { _ = try await u.accept(snap(indexJSON(sequence: 1)), acknowledgeUnverified: false, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .acknowledgmentRequired) }
        do { try await u.remove(url()); XCTFail() } catch { XCTAssertEqual(error as? AutomationError, .unknownRepository) }
    }

    func testSameURLDifferentUUIDRejectedEvenAfterRemove() async throws {
        let st = AutomationStore(fileURL: tempFile())
        _ = try await accepted(st, snap(indexJSON()))
        try await st.remove(url())
        do { _ = try await st.accept(snap(indexJSON(id: UUID())), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .repositoryIdentityChanged) }
    }

    func testSameUUIDAtDifferentURLIsSeparateIdentity() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let k = Curve25519.Signing.PrivateKey()
        _ = try await accepted(st, snap(indexJSON(), key: k))
        let other = try RepositoryURL(parsing: "https://mirror.example.org/repository.json")
        let s2 = try RepositoryEnvelope.verify(envelope: envelope(indexJSON(), key: k), url: other, now: now)
        let r = try await st.accept(s2, acknowledgeUnverified: true, now: now)
        guard case .signedUnverified = r.trust else { return XCTFail("pin inherited") }
        let c = await st.catalog()
        XCTAssertEqual(c.repositories.count, 2)
    }

    func testAcceptChecksExpiryAtCommit() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let s = try snap(indexJSON(expires: now.addingTimeInterval(60)))
        do { _ = try await st.accept(s, acknowledgeUnverified: true, now: now.addingTimeInterval(60)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .expired) }
    }

    func testRepositoryCountCap() async throws {
        let st = AutomationStore(fileURL: tempFile())
        for i in 0..<Limits.repositories {
            let u = try RepositoryURL(parsing: "https://h\(i).example.com/")
            _ = try await st.accept(RepositoryEnvelope.verify(envelope: envelope(indexJSON()), url: u, now: now), acknowledgeUnverified: true, now: now)
        }
        let u = try RepositoryURL(parsing: "https://extra.example.com/")
        do { _ = try await st.accept(RepositoryEnvelope.verify(envelope: envelope(indexJSON()), url: u, now: now), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        let c = await st.catalog()
        XCTAssertEqual(c.repositories.count, Limits.repositories)
    }

    // MARK: install

    private func setup(_ st: AutomationStore, pkg: Data = packageBytes(), sequence: Int = 1) async throws -> (VerifiedSnapshot, UUID) {
        let s = try snap(indexJSON(sequence: sequence, pkg: pkg))
        return (s, try await accepted(st, s))
    }

    func testInstallIdempotentAndDisabled() async throws {
        let st = AutomationStore(fileURL: tempFile()), pkg = packageBytes()
        let (s, g) = try await setup(st, pkg: pkg)
        let p = try PluginPackage.validate(pkg, against: s.index.plugins[0])
        let a = try await st.install(p, from: s, expectedGeneration: g, now: now)
        let b = try await st.install(p, from: s, expectedGeneration: g, now: now)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.enabled)
        let c = await st.catalog()
        XCTAssertEqual(c.revisions.count, 1)
    }

    func testStaleGenerationAfterPinRefreshRemove() async throws {
        let k = Curve25519.Signing.PrivateKey(), pkg = packageBytes()
        let st = AutomationStore(fileURL: tempFile())
        let s = try snap(indexJSON(pkg: pkg), key: k)
        let g = try await accepted(st, s)
        let p = try PluginPackage.validate(pkg, against: s.index.plugins[0])
        _ = try await st.pin(url(), fingerprint: PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!.hex)
        do { _ = try await st.install(p, from: s, expectedGeneration: g, now: now); XCTFail("after pin") }
        catch { XCTAssertEqual(error as? AutomationError, .staleGeneration) }
        let g2 = try await st.accept(s, acknowledgeUnverified: false, now: now).generation
        do { _ = try await st.install(p, from: s, expectedGeneration: g, now: now); XCTFail("after refresh") }
        catch { XCTAssertEqual(error as? AutomationError, .staleGeneration) }
        try await st.remove(url())
        do { _ = try await st.install(p, from: s, expectedGeneration: g2, now: now); XCTFail("after remove") }
        catch { XCTAssertEqual(error as? AutomationError, .unknownRepository) }
    }

    func testInstallRejectsSnapshotNotTheAcceptedOne() async throws {
        let pkg = packageBytes(), st = AutomationStore(fileURL: tempFile())
        let (s, g) = try await setup(st, pkg: pkg)
        let forged = try snap(indexJSON(pkg: pkg, extra: ""), at: now)   // identical content => same snapshot
        XCTAssertEqual(forged, s)
        let other = try snap(indexJSON(sequence: 2, pkg: pkg))
        let p = try PluginPackage.validate(pkg, against: s.index.plugins[0])
        do { _ = try await st.install(p, from: other, expectedGeneration: g, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
    }

    func testInstallRechecksExpiryAndPackageCrosscheck() async throws {
        let pkg = packageBytes(), st = AutomationStore(fileURL: tempFile())
        let (s, g) = try await setup(st, pkg: pkg)
        let p = try PluginPackage.validate(pkg, against: s.index.plugins[0])
        do { _ = try await st.install(p, from: s, expectedGeneration: g, now: s.index.expiresAt); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .expired) }
        // a valid, self-consistent package that is not the one the snapshot lists
        let other = packageBytes(source: "function onRequest(){return {actionz:[]}}")
        let op = try PluginPackage.validate(other)
        do { _ = try await st.install(op, from: s, expectedGeneration: g, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .hashMismatch) }
        // unlisted plugin id
        let unlisted = try PluginPackage.template()
        do { _ = try await st.install(unlisted, from: s, expectedGeneration: g, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .metadataMismatch) }
        let c = await st.catalog()
        XCTAssertTrue(c.revisions.isEmpty)
    }

    func testCollidingPluginIDsFromTwoSourcesDoNotOverwrite() async throws {
        let st = AutomationStore(fileURL: tempFile()), pkg = packageBytes()
        let (s, g) = try await setup(st, pkg: pkg)
        let p = try PluginPackage.validate(pkg, against: s.index.plugins[0])
        _ = try await st.install(p, from: s, expectedGeneration: g, now: now)
        let u2 = try RepositoryURL(parsing: "https://two.example.org/repository.json")
        let s2 = try RepositoryEnvelope.verify(envelope: envelope(indexJSON(id: UUID(), pkg: pkg)), url: u2, now: now)
        let g2 = try await accepted(st, s2)
        _ = try await st.install(p, from: s2, expectedGeneration: g2, now: now)
        _ = try await st.importLocal(pkg)
        let c = await st.catalog()
        XCTAssertEqual(c.revisions.count, 3)
        XCTAssertEqual(Set(c.revisions.map(\.id)).count, 3)
    }

    // MARK: local import / edit / delete

    func testImportLocalProvenanceAndValidation() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let r = try await st.importLocal(packageBytes())
        XCTAssertEqual(r.provenance, Provenance(origin: .localImport, trustAtImport: nil))
        XCTAssertFalse(r.enabled)
        do { _ = try await st.importLocal(Data("{}".utf8)); XCTFail() } catch { XCTAssertEqual(error as? AutomationError, .invalidManifest) }
        let dup = try await st.importLocal(packageBytes())
        XCTAssertEqual(dup, r)
    }

    func testEditCreatesNewRevisionPreservingManifest() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let parent = try await st.importLocal(packageBytes())
        let edited = try await st.editSource(of: parent.id, to: "function onRequest(e,c){return {actions:[]}} // é\n")
        XCTAssertNotEqual(edited.package.revision, parent.package.revision)
        XCTAssertEqual(edited.package.manifest, parent.package.manifest)
        XCTAssertEqual(edited.provenance.origin, .localEdit(parent: parent.package.revision))
        XCTAssertNil(edited.provenance.trustAtImport)
        XCTAssertEqual(edited.package.bytes, try JSONValue.object(["manifest": parent.package.manifest.json, "source": .string(edited.package.source)]).data())
        XCTAssertNoThrow(try PluginPackage.validate(edited.package.bytes))
        let c = await st.catalog()
        XCTAssertEqual(c.revisions.count, 2)
        do { _ = try await st.editSource(of: parent.id, to: parent.package.source); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .noChange) }
        do { _ = try await st.editSource(of: "nope", to: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .unknownRevision) }
    }

    func testEditOfRepositoryRevisionDoesNotInheritTrust() async throws {
        let k = Curve25519.Signing.PrivateKey(), pkg = packageBytes(), st = AutomationStore(fileURL: tempFile())
        let s = try snap(indexJSON(pkg: pkg), key: k)
        let g = try await accepted(st, s)
        _ = try await st.pin(url(), fingerprint: PublicKeyFingerprint(rawKey: k.publicKey.rawRepresentation)!.hex)
        let g2 = try await st.accept(s, acknowledgeUnverified: false, now: now).generation
        _ = g
        let rev = try await st.install(PluginPackage.validate(pkg, against: s.index.plugins[0]), from: s, expectedGeneration: g2, now: now)
        guard case .pinned = rev.provenance.trustAtImport else { return XCTFail("trust at import") }
        let edited = try await st.editSource(of: rev.id, to: "// changed")
        XCTAssertEqual(edited.provenance.origin, .localEdit(parent: rev.package.revision))
        XCTAssertNil(edited.provenance.trustAtImport)
    }

    func testEditSourceCapAndDelete() async throws {
        let st = AutomationStore(fileURL: tempFile())
        let parent = try await st.importLocal(packageBytes())
        do { _ = try await st.editSource(of: parent.id, to: String(repeating: "a", count: Limits.source + 1)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        try await st.deleteRevision(parent.id)
        let c = await st.catalog()
        XCTAssertTrue(c.revisions.isEmpty)
        do { try await st.deleteRevision(parent.id); XCTFail() } catch { XCTAssertEqual(error as? AutomationError, .unknownRevision) }
    }

    func testRevisionCountAndByteCaps() async throws {
        let st = AutomationStore(fileURL: tempFile())
        for i in 0..<Limits.revisions { _ = try await st.importLocal(packageBytes(source: "// \(i)")) }
        do { _ = try await st.importLocal(packageBytes(source: "// over")); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        let c = await st.catalog()
        XCTAssertEqual(c.revisions.count, Limits.revisions)
    }

    // MARK: persistence, corruption, failure, flags

    func testReloadRestoresSnapshotsRevisionsAndGenerations() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f), pkg = packageBytes()
        let (s, g) = try await setup(st, pkg: pkg)
        let rev = try await st.install(PluginPackage.validate(pkg, against: s.index.plugins[0]), from: s, expectedGeneration: g, now: now)
        let local = try await st.importLocal(packageBytes(source: "// l"))
        let again = try await AutomationStore(fileURL: f).load()
        XCTAssertEqual(again.record(for: url())?.snapshot, s)
        XCTAssertEqual(again.record(for: url())?.generation, g)
        XCTAssertEqual(again.revision(id: rev.id), rev)
        XCTAssertEqual(again.revision(id: local.id), local)
        let fresh = AutomationStore(fileURL: f)
        let r = try await fresh.install(PluginPackage.validate(pkg, against: s.index.plugins[0]), from: s, expectedGeneration: g, now: now)
        XCTAssertEqual(r, rev)
    }

    func testCorruptStoreBlocksMutationAndIsPreserved() async throws {
        let f = tempFile(), junk = Data("{\"version\":1,\"repositories\":[{}],\"revisions\":[]}".utf8)
        try junk.write(to: f)
        let st = AutomationStore(fileURL: f)
        do { _ = try await st.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        do { _ = try await st.importLocal(packageBytes()); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: f), junk)
    }

    func testTamperedStoreContentsRejected() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        _ = try await st.importLocal(packageBytes())
        let good = try String(contentsOf: f, encoding: .utf8)
        let mutations = [
            good.replacingOccurrences(of: #""enabled":false"#, with: #""enabled":true"#),
            good.replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
            good.replacingOccurrences(of: #""revisions":["#, with: #""bogus":1,"revisions":["#),
        ]
        for m in mutations {
            XCTAssertNotEqual(m, good)
            try Data(m.utf8).write(to: f)
            do { _ = try await AutomationStore(fileURL: f).load(); XCTFail(m) }
            catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        }
    }

    func testTamperedSnapshotInStoreRejected() async throws {
        let k = Curve25519.Signing.PrivateKey(), f = tempFile(), st = AutomationStore(fileURL: f)
        _ = try await accepted(st, snap(indexJSON(sequence: 1), key: k))
        let good = try String(contentsOf: f, encoding: .utf8)
        // swap the stored record's sequence so it disagrees with the verified envelope
        let bad = good.replacingOccurrences(of: #""sequence":1"#, with: #""sequence":9"#)
        XCTAssertNotEqual(bad, good)
        try Data(bad.utf8).write(to: f)
        do { _ = try await AutomationStore(fileURL: f).load(); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
    }

    func testSaveFailureLeavesStateAndDiskUnchanged() async throws {
        let f = tempFile()
        let good = AutomationStore(fileURL: f)
        _ = try await accepted(good, snap(indexJSON(sequence: 1)))
        let before = try Data(contentsOf: f)
        let failing = AutomationStore(fileURL: f, writer: { _, _ in throw AutomationError.saveFailed })
        _ = try await failing.load()
        do { _ = try await failing.accept(snap(indexJSON(sequence: 2)), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .saveFailed) }
        do { _ = try await failing.importLocal(packageBytes()); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .saveFailed) }
        let c = await failing.catalog()
        XCTAssertEqual(c.record(for: url())?.sequence, 1)
        XCTAssertTrue(c.revisions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f), before)
    }

    func testReloadBeforeMutationMergesConcurrentInstances() async throws {
        let f = tempFile(), a = AutomationStore(fileURL: f), b = AutomationStore(fileURL: f)
        _ = try await a.importLocal(packageBytes(source: "// a"))
        _ = try await b.importLocal(packageBytes(source: "// b"))
        let cat = try await AutomationStore(fileURL: f).load()
        XCTAssertEqual(cat.revisions.count, 2)
    }

    func testBackupExclusionAfterEachReplace() async throws {
        let f = tempFile(), st = AutomationStore(fileURL: f)
        for i in 0..<3 {
            _ = try await st.importLocal(packageBytes(source: "// \(i)"))
            let values = try f.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "after write \(i)")
        }
    }
}
