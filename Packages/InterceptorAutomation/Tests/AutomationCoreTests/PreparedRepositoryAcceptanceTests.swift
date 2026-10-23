import CryptoKit
import XCTest
@testable import AutomationCore

final class PreparedRepositoryAcceptanceTests: AutomationTestCase {
    func testPreparedAddDoesNotOverwriteAConcurrentAcceptance() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        let snapshot = try snap(indexJSON())
        let accepted = try await store.accept(snapshot, acknowledgeUnverified: true, now: now)
        let before = try Data(contentsOf: file)
        do {
            _ = try await store.accept(snapshot, acknowledgeUnverified: true, now: now, expecting: .absent)
            XCTFail("A prepared add must reject a source accepted while its packages downloaded")
        } catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let catalog = try await store.load()
        XCTAssertEqual(catalog.record(for: url()), accepted)
    }

    func testPreparedAddDoesNotResurrectASourceRemovedDuringDownload() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        let snapshot = try snap(indexJSON())
        let accepted = try await store.accept(snapshot, acknowledgeUnverified: true, now: now)
        try await store.remove(url())
        let before = try Data(contentsOf: file)
        do {
            _ = try await store.accept(snapshot, acknowledgeUnverified: true, now: now,
                                       expecting: .generation(accepted.generation))
            XCTFail("A prepared add must not resurrect a concurrently removed source")
        } catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let catalog = try await store.load()
        XCTAssertEqual(catalog.record(for: url())?.visible, false)
        XCTAssertTrue(catalog.revisions.isEmpty)
    }

    func testPreparedPinDoesNotReplaceAConcurrentGeneration() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        let key = Curve25519.Signing.PrivateKey()
        let snapshot = try snap(indexJSON(), key: key)
        let accepted = try await store.accept(snapshot, acknowledgeUnverified: true, now: now)
        let fingerprint = Digest.sha256Hex(key.publicKey.rawRepresentation)
        let pinned = try await store.pin(url(), fingerprint: fingerprint)
        let before = try Data(contentsOf: file)
        do {
            _ = try await store.acceptAndPin(snapshot, fingerprint: fingerprint, now: now,
                                             expecting: .generation(accepted.generation))
            XCTFail("A prepared pin must reject a concurrent source generation")
        } catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let catalog = try await store.load()
        XCTAssertEqual(catalog.record(for: url()), pinned)
    }

    func testMatchingPreparedAdmissionsDoNotInstallAnything() async throws {
        let store = AutomationStore(fileURL: tempFile())
        let initial = try await store.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now, expecting: .absent)
        let updated = try await store.accept(snap(indexJSON(sequence: 2)), acknowledgeUnverified: true, now: now,
                                              expecting: .generation(initial.generation))
        XCTAssertEqual(updated.sequence, 2)
        let catalog = try await store.load()
        XCTAssertTrue(catalog.revisions.isEmpty)
    }
    func testCancelledPreparedAddDoesNotPublishAuthority() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        let snapshot = try snap(indexJSON()), clock = now
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.accept(snapshot, acknowledgeUnverified: true, now: clock, expecting: .absent)
        }
        do { _ = try await operation.value; XCTFail("Cancelled admission must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let catalog = try await store.load()
        XCTAssertTrue(catalog.repositories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancelledRefreshKeepsPriorBytesAndGeneration() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        let original = try await store.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now)
        let next = try snap(indexJSON(sequence: 2)), clock = now
        let before = try Data(contentsOf: file)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.refresh(next, expectedGeneration: original.generation, acknowledgeUnverified: false, now: clock)
        }
        do { _ = try await operation.value; XCTFail("Cancelled refresh must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let catalog = try await store.load()
        XCTAssertEqual(catalog.record(for: url()), original)
    }

}
