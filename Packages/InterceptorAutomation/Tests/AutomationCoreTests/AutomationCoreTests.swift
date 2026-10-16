import CryptoKit
import XCTest
@testable import AutomationCore


final class AutomationCoreTests: AutomationTestCase {
    // MARK: known vectors
    func testSHA256KnownVectors() {
        XCTAssertEqual(Digest.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: canonical URLs
    func testCanonicalURL() throws {
        XCTAssertEqual(try RepositoryURL(parsing: "HTTPS://Example.COM:443/r/").envelopeURL.absoluteString,
                       "https://example.com/r/repository.json")
        XCTAssertEqual(try RepositoryURL(parsing: "https://example.com/a/x.json").envelopeURL.absoluteString,
                       "https://example.com/a/x.json")
    }
    func testRejectedURLs() {
        for s in ["http://a.com/x.json", "https://u@a.com/x.json", "https://a.com/x.json?q=1", "https://a.com/x.json#f",
                  "https://a.com/%2e/x.json", "https://a.com/a/../x.json", "https://a.com/a//x.json", "https://a.com\\x",
                  "https://ä.com/x.json"] {
            XCTAssertThrowsError(try RepositoryURL(parsing: s), s) { XCTAssertEqual($0 as? AutomationError, .invalidURL, s) }
        }
    }
    func testPackageURLConfinement() throws {
        XCTAssertEqual(try url().packageURL(path: "pkg/p.json").absoluteString, "https://example.com/r/pkg/p.json")
        for p in ["/p.json", "../p.json", "a/./p.json", "a//p.json", "a%2fp.json", "p.json?x", "p.json#x", "a\\p.json", "https://evil.com/p.json"] {
            XCTAssertThrowsError(try url().packageURL(path: p), p) { XCTAssertEqual($0 as? AutomationError, .invalidURL, p) }
        }
    }

    // MARK: strict JSON
    func testStrictJSONParsesValid() throws {
        XCTAssertEqual(try StrictJSON.parse(Data(#"{"a":[1,true,null,"x"]}"#.utf8)),
                       .object(["a": .array([.integer(1), .bool(true), .null, .string("x")])]))
    }
    func testDuplicateKeysRejected() {
        for s in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"o":{"k":1,"k":1}}"#] {
            XCTAssertThrowsError(try StrictJSON.parse(Data(s.utf8)), s) { XCTAssertEqual($0 as? AutomationError, .duplicateKey, s) }
        }
    }
    func testStrictJSONRejectsMalformed() {
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        for d in [Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8), Data("{} x".utf8), Data(#""\ud800""#.utf8), Data(deep.utf8)] {
            XCTAssertThrowsError(try StrictJSON.parse(d))
        }
    }

    // MARK: envelope
    func testUnsignedEnvelopeVerifies() throws {
        let s = try RepositoryEnvelope.verify(envelope: envelope(indexJSON()), url: url(), now: now)
        XCTAssertEqual(s.signature, .unsigned)
        XCTAssertEqual(s.index.sequence, 1)
        XCTAssertEqual(s.index.plugins.count, 1)
    }
    func testSignedEnvelopeCarriesFingerprint() throws {
        let k = Curve25519.Signing.PrivateKey()
        let payload = indexJSON()
        let s = try RepositoryEnvelope.verify(envelope: envelope(payload, key: k), url: url(), now: now)
        guard case .signed(let fp) = s.signature else { return XCTFail("expected signed") }
        XCTAssertEqual(fp.rawKey, k.publicKey.rawRepresentation)
        XCTAssertEqual(fp.hex, Digest.sha256Hex(k.publicKey.rawRepresentation))
        XCTAssertEqual(s.payloadDigest, Digest.sha256Hex(payload))
    }
    func testBadSignatureFatal() throws {
        var env = try envelope(indexJSON(), key: Curve25519.Signing.PrivateKey())
        env = Data(String(decoding: env, as: UTF8.self).replacingOccurrences(of: #""value":""#, with: #""value":"AAAA"#).utf8)
        XCTAssertThrowsError(try RepositoryEnvelope.verify(envelope: env, url: url(), now: now))
    }
    func testIndexRulesRejected() throws {
        let cases: [(Data, AutomationError)] = [
            (indexJSON(expires: now.addingTimeInterval(-1)), .expired),
            (indexJSON(expires: now.addingTimeInterval(91 * 86_400)), .lifetimeTooLong),
            (indexJSON(extra: #","bogus":1"#), .invalidJSON),
            (indexJSON(sequence: 0), .invalidJSON),
        ]
        for (p, err) in cases {
            XCTAssertThrowsError(try RepositoryEnvelope.verify(envelope: envelope(p), url: url(), now: now)) {
                XCTAssertEqual($0 as? AutomationError, err)
            }
        }
    }
    func testEnvelopeSizeLimit() {
        XCTAssertThrowsError(try RepositoryEnvelope.verify(envelope: Data(count: Limits.envelope + 1), url: url(), now: now)) {
            XCTAssertEqual($0 as? AutomationError, .limitExceeded)
        }
    }

    // MARK: package hash/size/crosscheck
    func testPackageValidatesAndRevisionIsHash() throws {
        let b = packageBytes()
        let p = try PluginPackage.validate(b, against: entry(for: b))
        XCTAssertEqual(p.bytes, b)
        XCTAssertEqual(p.revision, Digest.sha256Hex(b))
        XCTAssertEqual(p.manifest.id, pluginID)
    }
    func testPackageSizeAndHashMismatch() throws {
        let b = packageBytes()
        var e = entry(for: b)
        let wrongSize = IndexEntry(id: e.id, name: e.name, version: e.version, packagePath: e.packagePath, sha256: e.sha256, size: b.count + 1)
        XCTAssertThrowsError(try PluginPackage.validate(b, against: wrongSize)) { XCTAssertEqual($0 as? AutomationError, .sizeMismatch) }
        e = IndexEntry(id: e.id, name: e.name, version: e.version, packagePath: e.packagePath, sha256: String(repeating: "0", count: 64), size: b.count)
        XCTAssertThrowsError(try PluginPackage.validate(b, against: e)) { XCTAssertEqual($0 as? AutomationError, .hashMismatch) }
    }
    func testPackageMetadataCrosscheck() throws {
        let b = packageBytes(name: "Other")
        XCTAssertThrowsError(try PluginPackage.validate(b, against: entry(for: b, name: "P"))) {
            XCTAssertEqual($0 as? AutomationError, .metadataMismatch)
        }
        let v = packageBytes(version: "2.0.0")
        XCTAssertThrowsError(try PluginPackage.validate(v, against: entry(for: v, version: "1.0.0"))) {
            XCTAssertEqual($0 as? AutomationError, .metadataMismatch)
        }
    }

    // MARK: trust, rollback, provenance, store
    private func store() -> AutomationStore {
        AutomationStore(fileURL: tempFile())
    }

    func testSignedUnverifiedThenPinned() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = store()
        let s = try snap(indexJSON(), key: k)
        let r = try await st.accept(s, acknowledgeUnverified: true, now: now)
        guard case .signedUnverified(let fp) = r.trust else { return XCTFail("expected signedUnverified, got \(r.trust)") }
        let pinned = try await st.pin(url(), fingerprint: fp.hex)
        XCTAssertEqual(pinned.trust, .pinned(fp))
    }
    func testPinRequiresMatchingFingerprint() async throws {
        let st = store()
        _ = try? await st.accept(snap(indexJSON(), key: Curve25519.Signing.PrivateKey()), acknowledgeUnverified: true, now: now)
        do { _ = try await st.pin(url(), fingerprint: String(repeating: "a", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .fingerprintMismatch) }
    }
    func testPinnedRejectsUnsignedAndKeyChange() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = store()
        let r = try await st.accept(snap(indexJSON(sequence: 1), key: k), acknowledgeUnverified: true, now: now)
        guard case .signedUnverified(let fp) = r.trust else { return XCTFail("setup") }
        _ = try await st.pin(url(), fingerprint: fp.hex)
        do { _ = try await st.accept(snap(indexJSON(sequence: 2)), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .signatureRemoved) }
        do { _ = try await st.accept(snap(indexJSON(sequence: 2), key: Curve25519.Signing.PrivateKey()), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .keyChanged) }
    }
    func testRollbackAndSameSequenceDifferentPayload() async throws {
        let st = store()
        _ = try await st.accept(snap(indexJSON(sequence: 5)), acknowledgeUnverified: true, now: now)
        do { _ = try await st.accept(snap(indexJSON(sequence: 4)), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .rollback) }
        let other = indexJSON(sequence: 5, pkg: packageBytes(name: "Q"))
        do { _ = try await st.accept(snap(other), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .sameSequenceDifferentPayload) }
    }
    func testRepositoryUUIDChangeAtSameURLRejected() async throws {
        let st = store()
        _ = try await st.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now)
        let other = indexJSON(id: UUID())
        do { _ = try await st.accept(snap(other), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .repositoryIdentityChanged) }
    }
    func testRemoveKeepsTombstoneAndPin() async throws {
        let k = Curve25519.Signing.PrivateKey(), st = store()
        let r = try await st.accept(snap(indexJSON(sequence: 3), key: k), acknowledgeUnverified: true, now: now)
        guard case .signedUnverified(let fp) = r.trust else { return XCTFail("setup") }
        _ = try await st.pin(url(), fingerprint: fp.hex)
        try await st.remove(url())
        let cat = await st.catalog()
        XCTAssertEqual(cat.repositories.count, 1)
        XCTAssertEqual(cat.repositories[0].visible, false)
        XCTAssertEqual(cat.repositories[0].trust, .pinned(fp))
        do { _ = try await st.accept(snap(indexJSON(sequence: 2), key: k), acknowledgeUnverified: true, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .rollback) }
    }
    func testInstallCreatesDisabledRevisionWithProvenance() async throws {
        let st = store(), pkg = packageBytes()
        let s = try snap(indexJSON(pkg: pkg))
        _ = try await st.accept(s, acknowledgeUnverified: true, now: now)
        let gen = try await st.catalog().record(for: url())!.generation
        let rev = try await st.install(PluginPackage.validate(pkg, against: s.index.plugins[0]), from: s, expectedGeneration: gen, now: now)
        XCTAssertFalse(rev.enabled)
        XCTAssertEqual(rev.provenance.origin, .repository(url: url(), sequence: 1))
        XCTAssertEqual(rev.provenance.trustAtImport, .unsignedAcknowledged)
    }
    func testCatalogPersistsAcrossReload() async throws {
        let f = tempFile()
        let a = AutomationStore(fileURL: f)
        _ = try await a.accept(snap(indexJSON(sequence: 7)), acknowledgeUnverified: true, now: now)
        let b = AutomationStore(fileURL: f)
        let cat = try await b.load()
        XCTAssertEqual(cat.repositories.first?.sequence, 7)
    }
    func testCorruptStoreIsPreservedNotReset() async throws {
        let f = tempFile()
        let junk = Data("not json".utf8)
        try junk.write(to: f)
        let st = AutomationStore(fileURL: f)
        do { _ = try await st.load(); XCTFail() } catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: f), junk)
    }
}
