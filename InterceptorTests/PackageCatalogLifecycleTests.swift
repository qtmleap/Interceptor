import AutomationCore
import AutomationRepository
import CryptoKit
import Foundation
import Observation
@testable import Interceptor
import XCTest

@MainActor
final class PackageCatalogLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PackageLifecycle-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(packages: [PluginPackage], database: (any PackageCatalogStoring)? = nil, automaticPackageBackfill: Bool = true)
        throws -> (AutomationController, AutomationStore, FakeRepositoryClient, any PackageCatalogStoring)
    {
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: packages), packages: packages)
        let database = try database ?? PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(),
                                              clock: { AutomationFixtures.now }, packageCatalog: database, automaticPackageBackfill: automaticPackageBackfill)
        return (controller, store, client, database)
    }

    func testAcceptPersistsExactContentWithoutInstallingAndRestartReadsOffline() async throws {
        let package = try AutomationFixtures.multiFilePackage(name: "Durable")
        let (controller, store, client, database) = try fixture(packages: [package])
        await controller.load()
        let accepted = try await controller.acceptRepository(client.snapshot, expecting: .absent,
                                                               pinning: nil, acknowledgeUnverified: true)
        XCTAssertEqual(client.packageCount, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
        let persisted = try await store.load()
        XCTAssertTrue(persisted.revisions.isEmpty)
        XCTAssertEqual(try database.packageBytes(in: accepted, entry: client.snapshot.index.plugins[0]), package.bytes)
        XCTAssertEqual(try database.detail(in: accepted, entryID: package.manifest.id)?.sourceFiles, package.sourceFiles)
        let offline = FakeRepositoryClient(snapshot: client.snapshot, packages: [package])
        offline.previewError = URLError(.notConnectedToInternet)
        offline.packageError = URLError(.notConnectedToInternet)
        let reopened = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let restart = AutomationController(store: store, client: offline, executor: FakeScriptRunner(),
                                          clock: { AutomationFixtures.now }, packageCatalog: reopened)
        await restart.load()
        let rows = try reopened.rows(visible: restart.repositories, installed: restart.scripts, query: "Durable",
                                     source: nil, category: .all)
        XCTAssertEqual(rows.map(\.manifestID), [package.manifest.id])
        XCTAssertEqual(offline.previewCount, 0)
        XCTAssertEqual(offline.packageCount, 0)
    }

    func testAddSheetPersistsContentOnlyAfterExplicitAdd() async throws {
        let package = try AutomationFixtures.package(name: "Added")
        let (controller, _, client, database) = try fixture(packages: [package])
        await controller.load()
        let model = AddRepositoryModel(controller: controller)
        model.urlText = AutomationFixtures.url.canonical
        model.preview()
        let previewed = await waitUntil { model.phase == .previewed }
        XCTAssertTrue(previewed)
        XCTAssertEqual(client.packageCount, 0)
        XCTAssertTrue(controller.repositories.isEmpty)
        model.addUnverified()
        let added = await waitUntil { model.phase == .added }
        XCTAssertTrue(added)
        let record = try XCTUnwrap(controller.repositories.first)
        XCTAssertTrue(try XCTUnwrap(database.detail(in: record, entryID: package.manifest.id)).isComplete)
        XCTAssertEqual(client.packageCount, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testDefaultSourceStagesPackageContentBeforeRegistration() async throws {
        let package = try AutomationFixtures.package(name: "Official")
        let key = Curve25519.Signing.PrivateKey()
        let snapshot = try AutomationFixtures.snapshot(packages: [package], key: key)
        let client = FakeRepositoryClient(snapshot: snapshot, packages: [package])
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        let descriptor = DefaultRepository(url: snapshot.url, repositoryID: snapshot.index.id, fingerprint: fingerprint)
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(),
                                              clock: { AutomationFixtures.now }, defaultRepository: descriptor,
                                              packageCatalog: database)
        await controller.load()
        let record = try XCTUnwrap(controller.repositories.first)
        guard case .pinned(let pinned) = record.trust else { return XCTFail("default source must retain the bundled pin") }
        XCTAssertEqual(pinned.hex, fingerprint)
        XCTAssertTrue(try database.isComplete(snapshot))
        XCTAssertEqual(client.packageCount, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testPreparationUsesAtMostThreeFetchesAndRefreshReusesExactDatabaseBytes() async throws {
        let packages = try (0..<7).map { try AutomationFixtures.package(name: "Package \($0)") }
        let snapshot = try AutomationFixtures.snapshot(packages: packages)
        let client = BoundedLifecycleClient(snapshot: snapshot, packages: packages)
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(),
                                              clock: { AutomationFixtures.now }, packageCatalog: database)
        let accepted = try await controller.acceptRepository(snapshot, expecting: .absent,
                                                               pinning: nil, acknowledgeUnverified: true)
        let refreshed = try AutomationFixtures.snapshot(packages: packages, sequence: 2)
        _ = try await controller.refreshRepository(refreshed, expectedGeneration: accepted.generation)
        let counts = await client.counts()
        XCTAssertEqual(counts.total, packages.count)
        XCTAssertEqual(counts.maximum, 3)
        XCTAssertTrue(try database.isComplete(refreshed))
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testStageFailureDoesNotPublishSourceOrLoseEarlierSnapshot() async throws {
        let old = try AutomationFixtures.package(name: "Earlier")
        let backing = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let faulting = FailingLifecycleCatalog(base: backing)
        let (controller, store, client, _) = try fixture(packages: [old], database: faulting)
        let accepted = try await controller.acceptRepository(client.snapshot, expecting: .absent,
                                                               pinning: nil, acknowledgeUnverified: true)
        let replacement = try AutomationFixtures.snapshot(packages: [old], sequence: 2)
        faulting.failStage = true
        do {
            _ = try await controller.refreshRepository(replacement, expectedGeneration: accepted.generation)
            XCTFail("failed database staging must not publish authority")
        } catch { XCTAssertEqual(error as? LifecycleFailure, .stage) }
        let persisted = try await store.load()
        XCTAssertEqual(persisted.record(for: accepted.url), accepted)
        XCTAssertNotNil(controller.packageCatalogError)
        XCTAssertEqual(try backing.detail(in: accepted, entryID: old.manifest.id)?.manifest.name, "Earlier")
    }

    func testRemovalDuringAddPreparationCannotResurrectSource() async throws {
        let package = try AutomationFixtures.package(name: "Removed")
        let (controller, store, client, _) = try fixture(packages: [package])
        let first = try await store.accept(client.snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now)
        // Force a missing-content preparation after capturing the reviewed source generation.
        client.delayNanoseconds = 100_000_000
        let add = Task {
            try await controller.acceptRepository(client.snapshot, expecting: .generation(first.generation),
                                                  pinning: nil, acknowledgeUnverified: true)
        }
        let started = await waitUntil { client.packageCount > 0 }
        XCTAssertTrue(started)
        try await store.remove(first.url)
        do { _ = try await add.value; XCTFail("a stale add must fail") }
        catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        let persisted = try await store.load()
        XCTAssertFalse(try XCTUnwrap(persisted.record(for: first.url)).visible)
        XCTAssertTrue(controller.repositories.isEmpty)
    }

    func testCancellationBeforeCommitPreservesAbsentAuthority() async throws {
        let package = try AutomationFixtures.package(name: "Cancelled")
        let (controller, store, client, _) = try fixture(packages: [package])
        client.delayNanoseconds = 200_000_000
        let add = Task {
            try await controller.acceptRepository(client.snapshot, expecting: .absent,
                                                  pinning: nil, acknowledgeUnverified: true)
        }
        let started = await waitUntil { client.packageCount > 0 }
        XCTAssertTrue(started)
        add.cancel()
        do { _ = try await add.value; XCTFail("cancelled add must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let persisted = try await store.load()
        XCTAssertTrue(persisted.repositories.isEmpty)
        XCTAssertNil(controller.actionError, "cancelling an Add is not a global browser failure")
    }

    func testMissingAcknowledgmentFailsBeforeDownloadingPackages() async throws {
        let package = try AutomationFixtures.package(name: "Unacknowledged")
        let (controller, _, client, _) = try fixture(packages: [package])
        do {
            _ = try await controller.acceptRepository(client.snapshot, expecting: .absent,
                                                       pinning: nil, acknowledgeUnverified: false)
            XCTFail("acknowledgment is required")
        } catch { XCTAssertEqual(error as? AutomationError, .acknowledgmentRequired) }
        XCTAssertEqual(client.packageCount, 0)
    }

    func testUpgradeSeedsKnownIndexAndAttemptsBackfillOnlyOncePerDigest() async throws {
        let package = try AutomationFixtures.package(name: "Known offline")
        let (controller, store, client, database) = try fixture(packages: [package])
        _ = try await store.accept(client.snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now)
        client.packageError = URLError(.notConnectedToInternet)
        await controller.load()
        let finished = await waitUntil { !controller.isBackfillingPackages }
        XCTAssertTrue(finished)
        let rows = try database.rows(visible: controller.repositories, installed: [], query: "Known", source: nil, category: .all)
        XCTAssertEqual(rows.map(\.name), ["Known offline"])
        XCTAssertEqual(rows.map(\.complete), [false])
        XCTAssertNotNil(controller.packageCatalogBackfillErrors[AutomationFixtures.url.canonical])
        await controller.refreshCatalog()
        await controller.load()
        XCTAssertEqual(client.packageCount, 1)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertTrue(controller.scripts.isEmpty)
    }
    func testRemovingSourcePrunesItsUnreferencedStoredContent() async throws {
        let package = try AutomationFixtures.package(name: "Disposable metadata")
        let (controller, _, client, database) = try fixture(packages: [package])
        let record = try await controller.acceptRepository(client.snapshot, expecting: .absent, pinning: nil, acknowledgeUnverified: true)
        await controller.deleteRepository(record.url)
        XCTAssertTrue(controller.repositories.isEmpty)
        XCTAssertNil(try database.reusableBytes(sha256: package.revision))
        XCTAssertNil(try database.detail(in: record, entryID: package.manifest.id))
    }

    func testDeletingLastSelectedOrphanPrunesItsStoredContent() async throws {
        let package = try AutomationFixtures.package(name: "Selected orphan")
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let coordinator = InstallationCoordinator(catalogURL: catalogURL, activationURL: directory.appendingPathComponent("activation.json"))
        let store = AutomationStore(fileURL: catalogURL)
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                              packageCatalog: database, installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
        let record = try await controller.acceptRepository(client.snapshot, expecting: .absent, pinning: nil, acknowledgeUnverified: true)
        let state = try await controller.readInstallation()
        let request = InstallationRequest(package: package, snapshot: client.snapshot, expectedSourceGeneration: record.generation, operation: .add)
        let installed = try await controller.commitInstallationBatch([request], expectedSelectionGeneration: state.selectionGeneration)
        let revision = try XCTUnwrap(installed.installed.first)
        await controller.deleteRepository(record.url)
        XCTAssertEqual(try database.reusableBytes(sha256: package.revision), package.bytes)
        XCTAssertEqual(try database.rows(visible: [], installed: controller.scripts, query: "", source: nil, category: .all).count, 1)
        await controller.deleteScript(id: revision.id)
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertNil(try database.reusableBytes(sha256: package.revision))
        XCTAssertTrue(try database.rows(visible: [], installed: [], query: "", source: nil, category: .all).isEmpty)
    }

    func testDatabaseOnlyCompletionNotifiesAnObservedPresentation() async throws {
        let package = try AutomationFixtures.package(name: "Initially partial")
        let (controller, store, client, database) = try fixture(packages: [package], automaticPackageBackfill: false)
        let record = try await store.accept(client.snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.load()
        let model = PluginBrowserModel(controller: controller)
        let family = PluginBrowserFamilyID(repository: record.url, manifestID: package.manifest.id)
        let before = try XCTUnwrap(model.packagePresentation(for: family, record: record))
        XCTAssertFalse(before.isComplete)
        let changed = LifecycleCounter()
        withObservationTracking {
            _ = try? model.packagePresentation(for: family, record: record)
        } onChange: { changed.increment() }
        let revision = controller.packageCatalogRevision
        let lease = UUID()
        try await database.stage(client.snapshot, packages: [package], leaseID: lease)
        await controller.refreshCatalog()
        XCTAssertEqual(controller.catalog.record(for: record.url), record)
        XCTAssertEqual(controller.packageCatalogRevision, revision + 1)
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(try XCTUnwrap(model.packagePresentation(for: family, record: record)).isComplete)
        XCTAssertEqual(client.packageCount, 0)
        try await database.finish(leaseID: lease, visible: controller.repositories)
    }

    func testFailedProjectionKeepsStagedLeaseUntilSuccessfulReload() async throws {
        let package = try AutomationFixtures.package(name: "Retained staging")
        let base = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let database = FailingLifecycleCatalog(base: base)
        database.failSynchronize = true
        let (controller, store, client, _) = try fixture(packages: [package], database: database)
        let record = try await controller.acceptRepository(client.snapshot, expecting: .absent, pinning: nil, acknowledgeUnverified: true)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.record(for: record.url), record)
        XCTAssertEqual(controller.packageCatalogRevision, 0)
        XCTAssertEqual(database.finishCalls.count, 0, "unproven projections cannot release a committed staging lease")
        try await base.finish(leaseID: UUID(), visible: [])
        XCTAssertTrue(try base.isComplete(client.snapshot))
        database.failSynchronize = false
        await controller.refreshCatalog()
        XCTAssertEqual(controller.packageCatalogRevision, 1)
        XCTAssertEqual(database.finishCalls.count, 1, "successful recovery drains the pending lease")
        await controller.deleteRepository(record.url)
        XCTAssertNil(try base.reusableBytes(sha256: package.revision))
    }

    func testInstallationReadFailureClearsUnknownSourceProjection() async throws {
        let package = try AutomationFixtures.package(name: "Unknown selection")
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let store = AutomationStore(fileURL: catalogURL)
        let coordinator = FailingLifecycleCoordinator(base: InstallationCoordinator(catalogURL: catalogURL, activationURL: directory.appendingPathComponent("activation.json")))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                              packageCatalog: database, installationCoordinator: coordinator)
        let record = try await controller.acceptRepository(client.snapshot, expecting: .absent, pinning: nil, acknowledgeUnverified: true)
        let revision = controller.packageCatalogRevision
        try await store.remove(record.url)
        coordinator.failState = true
        await controller.refreshCatalog()
        XCTAssertTrue(controller.repositories.isEmpty)
        XCTAssertTrue(controller.catalog.visibleRepositories.isEmpty)
        XCTAssertNil(controller.installationState)
        XCTAssertNotNil(controller.installationError)
        XCTAssertEqual(controller.packageCatalogRevision, revision)
        XCTAssertEqual(try database.reusableBytes(sha256: package.revision), package.bytes, "unknown selection is not permission to prune")
    }

    func testCancelledQueuedPreparationFinishesBeforeOwnerAndPreservesNextWaiter() async throws {
        let a = try AutomationFixtures.package(name: "Owner")
        let b = try AutomationFixtures.package(name: "Cancelled waiter")
        let c = try AutomationFixtures.package(name: "Next waiter")
        let first = try AutomationFixtures.snapshot(packages: [a])
        let second = try AutomationFixtures.snapshot(packages: [b], sequence: 2)
        let third = try AutomationFixtures.snapshot(packages: [c], sequence: 3)
        let gate = LifecycleGate()
        let client = GatedLifecycleClient(snapshot: first, packages: [a, b, c], gate: gate, held: [a.manifest.id])
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let synchronization = PackageCatalogSynchronization(database: database, client: client)
        let firstLease = UUID(), secondLease = UUID(), thirdLease = UUID()
        let owner = Task { try await synchronization.stage(first, installed: [], leaseID: firstLease) }
        let ownerStarted = await waitUntil { client.started.contains(a.manifest.id) }
        XCTAssertTrue(ownerStarted)
        var entered = false, finished = false
        let cancelled = Task { () -> Bool in
            entered = true
            defer { finished = true }
            do { try await synchronization.stage(second, installed: [], leaseID: secondLease); return false }
            catch { return error is CancellationError }
        }
        let waiterEntered = await waitUntil { entered }
        XCTAssertTrue(waiterEntered)
        await Task.yield()
        let next = Task { try await synchronization.stage(third, installed: [], leaseID: thirdLease) }
        cancelled.cancel()
        let finishedBeforeOwner = await waitUntil { finished }
        XCTAssertTrue(finishedBeforeOwner, "cancellation must not wait for the owner to finish fetching")
        XCTAssertFalse(client.started.contains(b.manifest.id))
        XCTAssertFalse(client.started.contains(c.manifest.id))
        gate.open()
        try await owner.value
        let wasCancelled = await cancelled.value
        XCTAssertTrue(wasCancelled)
        try await next.value
        XCTAssertEqual(try database.reusableBytes(sha256: c.revision), c.bytes)
        for lease in [firstLease, secondLease, thirdLease] { try await database.finish(leaseID: lease, visible: []) }
    }

    func testExplicitRetryBootstrapsAfterOfflineStartupAndHonorsRemoval() async throws {
        let package = try AutomationFixtures.package(name: "Retry official")
        let key = Curve25519.Signing.PrivateKey()
        let snapshot = try AutomationFixtures.snapshot(packages: [package], key: key)
        let client = FakeRepositoryClient(snapshot: snapshot, packages: [package])
        client.previewError = URLError(.notConnectedToInternet)
        let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        let descriptor = DefaultRepository(url: snapshot.url, repositoryID: snapshot.index.id, fingerprint: fingerprint)
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                              defaultRepository: descriptor, packageCatalog: database)
        await controller.start()
        XCTAssertTrue(controller.repositories.isEmpty)
        XCTAssertEqual(client.previewCount, 1)
        client.previewError = nil
        try await controller.retryDefaultRepository()
        XCTAssertEqual(controller.repositories.count, 1)
        XCTAssertTrue(try database.isComplete(snapshot))
        XCTAssertEqual(client.previewCount, 2)
        await controller.deleteRepository(snapshot.url)
        try await controller.retryDefaultRepository()
        XCTAssertTrue(controller.repositories.isEmpty)
        XCTAssertEqual(client.previewCount, 2, "a removal tombstone must suppress bootstrap retries")
    }

    func testObsoleteBackfillFailureDoesNotOverwriteSuccessfulNewDigest() async throws {
        let old = try AutomationFixtures.package(name: "Old offline digest")
        let new = try AutomationFixtures.package(name: "New complete digest")
        let first = try AutomationFixtures.snapshot(packages: [old])
        let second = try AutomationFixtures.snapshot(packages: [new], sequence: 2)
        let fetchGate = LifecycleGate(), syncGate = LifecycleGate()
        let client = GatedLifecycleClient(snapshot: second, packages: [old, new], gate: fetchGate,
                                          held: [old.manifest.id], failing: [old.manifest.id])
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let record = try await store.accept(first, acknowledgeUnverified: true, now: AutomationFixtures.now)
        let base = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let database = FailingLifecycleCatalog(base: base)
        database.synchronizeGate = syncGate
        database.gatedSynchronizeCall = 2
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now }, packageCatalog: database)
        await controller.load()
        let started = await waitUntil { client.started.contains(old.manifest.id) }
        XCTAssertTrue(started)
        fetchGate.open()
        let cleanupHeld = await waitUntil { database.synchronizeCalls == 2 }
        XCTAssertTrue(cleanupHeld)
        _ = try await controller.refreshRepository(second, expectedGeneration: record.generation)
        let currentRevision = controller.packageCatalogRevision
        syncGate.open()
        let finished = await waitUntil { !controller.isBackfillingPackages }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.repositories.first?.payloadDigest, second.payloadDigest)
        XCTAssertEqual(controller.packageCatalogRevision, currentRevision, "the superseded projection cannot invalidate current reads")
        XCTAssertTrue(try database.isComplete(second))
        XCTAssertNil(controller.packageCatalogBackfillErrors[second.url.canonical])
        XCTAssertNil(controller.packageCatalogError)
    }

    func testAbsentDatabaseNeverAdvancesPresentationRevision() async throws {
        let package = try AutomationFixtures.package(name: "No database seam")
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now })
        await controller.load()
        _ = await controller.createExample(name: "Local authority only")
        await controller.refreshCatalog()
        XCTAssertEqual(controller.packageCatalogRevision, 0)
    }

    func testSourceSkippedBeforeBackfillAdmissionRetainsItsFirstRealAttempt() async throws {
        let a = try AutomationFixtures.package(name: "First source")
        let b = try AutomationFixtures.package(name: "Skipped source")
        let first = try AutomationFixtures.snapshot(packages: [a])
        let secondURL = try RepositoryURL(parsing: "https://zzz.example.com/repository.json")
        let second = try snapshot(packages: [b], url: secondURL)
        let gate = LifecycleGate()
        let client = GatedLifecycleClient(snapshot: first, packages: [a, b], gate: gate, held: [a.manifest.id])
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        _ = try await store.accept(first, acknowledgeUnverified: true, now: AutomationFixtures.now)
        _ = try await store.accept(second, acknowledgeUnverified: true, now: AutomationFixtures.now)
        let database = try PackageCatalogDatabase(url: directory.appendingPathComponent("PackageCatalog"))
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), clock: { AutomationFixtures.now }, packageCatalog: database)
        await controller.load()
        let started = await waitUntil { client.started.contains(a.manifest.id) }
        XCTAssertTrue(started)
        try await store.remove(second.url)
        await controller.refreshCatalog()
        gate.open()
        let firstFinished = await waitUntil { !controller.isBackfillingPackages }
        XCTAssertTrue(firstFinished)
        XCTAssertFalse(client.started.contains(b.manifest.id))
        _ = try await store.accept(second, acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let secondFinished = await waitUntil { !controller.isBackfillingPackages }
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(client.started.filter { $0 == b.manifest.id }.count, 1)
        XCTAssertTrue(try database.isComplete(second))
    }

    private func snapshot(packages: [PluginPackage], url: RepositoryURL) throws -> VerifiedSnapshot {
        let index: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string("11111111-1111-4111-8111-111111111111"), "name": .string("Example Repo"), "sequence": .integer(1),
            "issuedAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(-60))),
            "expiresAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(86_400))),
            "plugins": .array(packages.map(AutomationFixtures.entry)),
        ])
        let envelope: JSONValue = .object(["schemaVersion": .integer(1), "payload": .string(try index.data().base64EncodedString())])
        return try RepositoryEnvelope.verify(envelope: envelope.data(), url: url, now: AutomationFixtures.now)
    }

}

private enum LifecycleFailure: Error, Equatable { case stage }

@MainActor
private final class FailingLifecycleCatalog: PackageCatalogStoring {
    let base: any PackageCatalogStoring
    var failStage = false
    var failSynchronize = false
    var finishCalls: [UUID] = []
    var synchronizeCalls = 0
    var gatedSynchronizeCall: Int?
    var synchronizeGate: LifecycleGate?
    init(base: any PackageCatalogStoring) { self.base = base }
    func stage(_ snapshot: VerifiedSnapshot, packages: [PluginPackage], leaseID: UUID) async throws {
        if failStage { throw LifecycleFailure.stage }
        try await base.stage(snapshot, packages: packages, leaseID: leaseID)
    }
    func synchronize(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) async throws {
        synchronizeCalls += 1
        if synchronizeCalls == gatedSynchronizeCall { await synchronizeGate?.wait() }
        if failSynchronize { throw LifecycleFailure.stage }
        try await base.synchronize(visible: visible, installed: installed, receipt: receipt)
    }
    func finish(leaseID: UUID, visible: [RepositoryRecord]) async throws {
        finishCalls.append(leaseID)
        try await base.finish(leaseID: leaseID, visible: visible)
    }
    func rows(visible: [RepositoryRecord], installed: [InstalledRevision], query: String, source: String?, category: PackageCatalogCategoryFilter) throws -> [PackageCatalogRow] {
        try base.rows(visible: visible, installed: installed, query: query, source: source, category: category)
    }
    func categories(in record: RepositoryRecord) throws -> [PackageCatalogCategory] { try base.categories(in: record) }
    func detail(in record: RepositoryRecord, entryID: UUID) throws -> PluginPackagePresentation? { try base.detail(in: record, entryID: entryID) }
    func packageBytes(in record: RepositoryRecord, entry: IndexEntry) throws -> Data? { try base.packageBytes(in: record, entry: entry) }
    func reusableBytes(sha256: String) throws -> Data? { try base.reusableBytes(sha256: sha256) }
    func icon(sha256: String) async throws -> PluginIcon? { try await base.icon(sha256: sha256) }
    func isComplete(_ snapshot: VerifiedSnapshot) throws -> Bool { try base.isComplete(snapshot) }
}

private actor BoundedLifecycleClient: RepositoryFetching {
    let snapshot: VerifiedSnapshot
    let packages: [UUID: PluginPackage]
    private var active = 0
    private var maximum = 0
    private var total = 0
    init(snapshot: VerifiedSnapshot, packages: [PluginPackage]) {
        self.snapshot = snapshot
        self.packages = Dictionary(uniqueKeysWithValues: packages.map { ($0.manifest.id, $0) })
    }
    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot { snapshot }
    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage {
        total += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        return try XCTUnwrap(packages[entry.id])
    }
    func counts() -> (total: Int, maximum: Int) { (total, maximum) }
}


@MainActor
private final class LifecycleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class LifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class GatedLifecycleClient: RepositoryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [UUID] = []
    let snapshot: VerifiedSnapshot
    let packages: [UUID: PluginPackage]
    let gate: LifecycleGate
    let held: Set<UUID>
    let failing: Set<UUID>
    var started: [UUID] { lock.withLock { fetched } }
    init(snapshot: VerifiedSnapshot, packages: [PluginPackage], gate: LifecycleGate, held: Set<UUID>, failing: Set<UUID> = []) {
        self.snapshot = snapshot; self.packages = Dictionary(uniqueKeysWithValues: packages.map { ($0.manifest.id, $0) })
        self.gate = gate; self.held = held; self.failing = failing
    }
    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot { snapshot }
    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage {
        lock.withLock { fetched.append(entry.id) }
        if held.contains(entry.id) { await gate.wait() }
        try Task.checkCancellation()
        if failing.contains(entry.id) { throw URLError(.notConnectedToInternet) }
        guard let package = packages[entry.id] else { throw AutomationError.metadataMismatch }
        return package
    }
}

private final class FailingLifecycleCoordinator: InstallationCoordinating, @unchecked Sendable {
    let base: InstallationCoordinator
    private let lock = NSLock()
    private var failed = false
    var failState: Bool { get { lock.withLock { failed } } set { lock.withLock { failed = newValue } } }
    init(base: InstallationCoordinator) { self.base = base }
    func state() throws -> InstallationState { if failState { throw LifecycleFailure.stage }; return try base.state() }
    func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState {
        try base.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: now)
    }
    func importLocal(_ bytes: Data, operation: InstallationOperation, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.importLocal(bytes, operation: operation, expectedSelectionGeneration: expectedSelectionGeneration)
    }
    func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.activate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, captureConsent: captureConsent)
    }
    func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState { try base.deactivate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration) }
    func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState { try base.delete(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration) }
    func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.update(request, baseRevisionID: baseRevisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, now: now, captureConsent: captureConsent)
    }
}
