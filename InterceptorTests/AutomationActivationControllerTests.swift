@testable import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation
@testable import Interceptor
import XCTest

@MainActor
final class AutomationActivationControllerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivationController-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private struct Fixture {
        let controller: AutomationController
        let store: ObservedAutomationStore
        let activation: PluginActivationStore
        let baseActivation: PluginActivationStore
        let revision: InstalledRevision
        let activationURL: URL
        let catalogURL: URL
        let coordinator: InstallationCoordinator
        let stops: StopRecorder
    }

    private func fixture(legacy: Bool = false, multiFile: Bool = false, active: Bool = false, consent: Bool = true,
                         writer: PluginActivationStore.Writer? = nil, coordinated: Bool = false,
                         coordinatorWrapper: ((InstallationCoordinator) -> any InstallationCoordinating)? = nil) async throws -> Fixture
    {
        let base = directory.appendingPathComponent(UUID().uuidString)
        let catalogURL = base.appendingPathComponent("catalog.json"), activationURL = base.appendingPathComponent("active.json")
        let package: PluginPackage = if legacy {
            try PluginPackage.template()
        } else if multiFile {
            try AutomationFixtures.multiFilePackage(name: "Approval")
        } else {
            try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Approval"))
        }
        let backing = AutomationStore(fileURL: catalogURL)
        let setupCoordinator = InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL)
        let revision: InstalledRevision
        if coordinated {
            let empty = try setupCoordinator.state()
            let imported = try setupCoordinator.importLocal(package.bytes, expectedSelectionGeneration: empty.selectionGeneration)
            revision = try XCTUnwrap(imported.installed.first)
            if active {
                _ = try setupCoordinator.activate(revisionID: revision.id, expectedSelectionGeneration: imported.selectionGeneration,
                                                  approval: InstallationApproval(packageBytes: package.bytes, expectedGrantGeneration: imported.activation.generation),
                                                  captureConsent: { true })
            }
        } else {
            revision = try await backing.importLocal(package.bytes)
        }
        let store = ObservedAutomationStore(backing)
        let original = PluginActivationStore(fileURL: activationURL, catalogURL: catalogURL)
        if active && !coordinated {
            let snapshot = try await original.snapshot()
            _ = try await original.activate(package, revisionID: revision.id, expectedGeneration: snapshot.generation)
        }
        let activation = writer.map { PluginActivationStore(fileURL: activationURL, catalogURL: catalogURL, writer: $0) } ?? original
        let coordinator = InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL,
                                                  catalogWriter: { try $0.replace(with: $1) },
                                                  activationWriter: writer ?? { try $0.replace(with: $1) })
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let stops = StopRecorder()
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), activationStore: activation,
                                              installationCoordinator: coordinated ? (coordinatorWrapper?(coordinator) ?? coordinator) : nil,
                                              hasCaptureConsent: { consent }, stopCapture: { stops.count += 1 })
        await controller.load()
        return Fixture(controller: controller, store: store, activation: activation, baseActivation: original,
                       revision: revision, activationURL: activationURL, catalogURL: catalogURL, coordinator: coordinator, stops: stops)
    }

    func testConsentIsRequiredAndFailedApprovalLeavesFileUnchanged() async throws {
        let f = try await fixture(consent: false)
        let before = try await f.activation.snapshot()
        await f.controller.activate(f.revision, expectedGeneration: before.generation)
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_CONSENT")
        let after = try await f.activation.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.activationURL.path))
    }

    func testStaleApprovalGenerationCannotRestoreEarlierState() async throws {
        let f = try await fixture()
        let reviewed = try await f.activation.snapshot()
        let revoked = try await f.activation.revokeAll()
        await f.controller.activate(f.revision, expectedGeneration: reviewed.generation)
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_STALE")
        XCTAssertEqual(f.controller.activationSnapshot, revoked)
    }

    func testApprovalRechecksExactInstalledBytes() async throws {
        let f = try await fixture()
        let reviewed = try await f.activation.snapshot()
        try await f.store.backing.deleteRevision(f.revision.id)
        _ = try await f.store.backing.importLocal(AutomationTemplate.packageBytes(name: "Replacement", id: f.revision.package.manifest.id))
        await f.controller.activate(f.revision, expectedGeneration: reviewed.generation)
        XCTAssertEqual(f.controller.activationError as? AutomationError, .staleSnapshot)
        let after = try await f.activation.snapshot()
        XCTAssertEqual(after, reviewed)
    }

    func testFailedActivationWriteKeepsPreviousSnapshotAndError() async throws {
        let f = try await fixture(writer: { _, _ in throw AutomationError.saveFailed })
        _ = try await f.baseActivation.revokeAll()
        await f.controller.refreshActivation()
        let before = try await f.activation.snapshot(), bytes = try Data(contentsOf: f.activationURL)
        await f.controller.activate(f.revision, expectedGeneration: before.generation)
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ERR_SAVE")
        XCTAssertEqual(f.controller.activationSnapshot, before)
        XCTAssertEqual(try Data(contentsOf: f.activationURL), bytes)
    }

    func testLegacyCannotActivate() async throws {
        let f = try await fixture(legacy: true)
        let before = try await f.activation.snapshot()
        await f.controller.activate(f.revision, expectedGeneration: before.generation)
        XCTAssertEqual(f.controller.activationError as? AutomationError, .invalidManifest)
        let after = try await f.activation.snapshot()
        XCTAssertEqual(after, before)
    }

    func testCoordinatorDeleteRemovesSelectionAndExactGrantWhileRetainingHistory() async throws {
        let f = try await fixture(active: true, coordinated: true)
        let before = try f.coordinator.state()
        await f.controller.deleteScript(id: f.revision.id)
        let after = try f.coordinator.state()
        XCTAssertTrue(after.installed.isEmpty)
        XCTAssertTrue(after.activation.revisions.isEmpty)
        XCTAssertNotEqual(after.activation.generation, before.activation.generation)
        XCTAssertNotEqual(after.selectionGeneration, before.selectionGeneration)
        XCTAssertEqual(after.catalog.revision(id: f.revision.id)?.package.bytes, f.revision.package.bytes)
        XCTAssertTrue(f.controller.scripts.isEmpty)
        XCTAssertNil(f.controller.actionError)
        XCTAssertTrue(f.controller.pendingRevocations.isEmpty)
        XCTAssertEqual(f.stops.count, 0, "atomic revocation needs no emergency capture-stop request")
        let counts = await f.store.counts
        XCTAssertEqual(counts.edits, 0)
        XCTAssertEqual(counts.deletes, 0, "the coordinator must not physically delete catalog history")
    }

    func testAnyFileDraftBlocksApprovalAndBulkSaveRevokesExactParentOnce() async throws {
        let f = try await fixture(multiFile: true, active: true)
        let reviewed = try await f.activation.snapshot()
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        let files = session.sourceFileNames
        session.selectedSourceFile = files[1]
        session.source += "\n// second file edit"
        session.selectedSourceFile = files[0]
        await session.activate(expectedGeneration: reviewed.generation)
        let afterDirtyApproval = try await f.activation.snapshot()
        XCTAssertEqual(afterDirtyApproval, reviewed)
        await f.store.beforeEdit { [activation = f.activation, revisionID = f.revision.id] in
            let snapshot = try await activation.snapshot()
            XCTAssertFalse(snapshot.contains(revisionID: revisionID))
        }
        await session.saveAsLocalEdit()
        XCTAssertNil(session.saveError)
        XCTAssertEqual(session.revision.package.manifest, f.revision.package.manifest)
        XCTAssertEqual(session.revision.package.sourceFiles[files[0]], f.revision.package.sourceFiles[files[0]])
        XCTAssertNotEqual(session.revision.package.sourceFiles[files[1]], f.revision.package.sourceFiles[files[1]])
        let afterSave = try await f.activation.snapshot()
        XCTAssertTrue(afterSave.revisions.isEmpty)
        let counts = await f.store.counts
        XCTAssertEqual(counts.edits, 1)
        XCTAssertEqual(f.controller.scripts.count, 2)
    }

    func testTypingInEveryFileWhileBulkSaveAwaitsKeepsNewerDrafts() async throws {
        let f = try await fixture(multiFile: true)
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        for file in session.sourceFileNames {
            session.selectedSourceFile = file
            session.source += "\n// captured edit"
        }
        let captured = session.sourceFiles
        await f.store.beforeEdit {
            await MainActor.run {
                for file in session.sourceFileNames {
                    session.selectedSourceFile = file
                    session.source += "\n// newer typing"
                }
            }
        }
        await session.saveAsLocalEdit()
        XCTAssertNil(session.saveError)
        XCTAssertEqual(session.revision.package.sourceFiles, captured)
        for file in session.sourceFileNames {
            session.selectedSourceFile = file
            XCTAssertEqual(session.source, try XCTUnwrap(captured[file]) + "\n// newer typing")
        }
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.canRun)
    }

    func testCorruptApprovalPreservedAndBlocksV2SaveDeleteWithUsefulErrors() async throws {
        let f = try await fixture(active: true)
        let corrupt = Data("{invalid approvals".utf8)
        try corrupt.write(to: f.activationURL)
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        session.source += "\n// change"
        await session.saveAsLocalEdit()
        await f.controller.deleteScript(id: f.revision.id)
        XCTAssertEqual(session.saveErrorKey, "AUTO_ACTIVATION_STORE_PRESERVED")
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_STORE_PRESERVED")
        XCTAssertEqual(try Data(contentsOf: f.activationURL), corrupt)
        let counts = await f.store.counts
        XCTAssertEqual(counts.edits, 0)
        XCTAssertEqual(counts.deletes, 0)
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        XCTAssertEqual(f.stops.count, 1, "one shutdown request per pending revision, including repeated user actions")
    }

    func testKnownLegacySaveDeleteSkipCorruptApprovalFile() async throws {
        let f = try await fixture(legacy: true)
        let corrupt = Data("{invalid approvals".utf8)
        try corrupt.write(to: f.activationURL)
        await f.controller.refreshActivation()
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        session.source += "\n// legacy edit"
        await session.saveAsLocalEdit()
        await f.controller.deleteScript(id: f.revision.id)
        XCTAssertNil(session.saveError)
        XCTAssertNotEqual(session.revision.id, f.revision.id)
        XCTAssertEqual(try Data(contentsOf: f.activationURL), corrupt)
        let counts = await f.store.counts
        XCTAssertEqual(counts.edits, 1)
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(f.stops.count, 0)
    }

    func testUnknownDeleteStillAttemptsFailClosedRevocation() async throws {
        let f = try await fixture()
        let corrupt = Data("{invalid approvals".utf8)
        try corrupt.write(to: f.activationURL)
        await f.controller.deleteScript(id: "unknown|revision")
        let counts = await f.store.counts
        XCTAssertEqual(counts.deletes, 0)
        XCTAssertEqual(f.controller.pendingRevocations, ["unknown|revision"])
        XCTAssertEqual(f.stops.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.activationURL), corrupt)
    }

    func testConcurrentApprovalBeforeCoordinatorDeleteIsRevokedAndCannotBeRestored() async throws {
        let concurrentApproval = LockedValue<PluginActivationSnapshot?>(nil)
        let f = try await fixture(coordinated: true, coordinatorWrapper: { coordinator in
            DeleteObservingCoordinator(base: coordinator) { revisionID in
                let before = try coordinator.state()
                let revision = try XCTUnwrap(before.installed.first { $0.id == revisionID })
                let approved = try coordinator.activate(revisionID: revisionID, expectedSelectionGeneration: before.selectionGeneration,
                                                        approval: InstallationApproval(packageBytes: revision.package.bytes, expectedGrantGeneration: before.activation.generation),
                                                        captureConsent: { true })
                concurrentApproval.value = approved.activation
            }
        })
        let reviewedSelection = try f.coordinator.state().selectionGeneration
        await f.controller.deleteScript(id: f.revision.id)
        let approved = try XCTUnwrap(concurrentApproval.value)
        XCTAssertTrue(approved.contains(revisionID: f.revision.id), "the other window must really publish a grant before deletion")
        let after = try f.coordinator.state()
        XCTAssertTrue(after.activation.revisions.isEmpty)
        XCTAssertTrue(after.installed.isEmpty)
        XCTAssertNotNil(after.catalog.revision(id: f.revision.id))
        XCTAssertTrue(f.controller.pendingRevocations.isEmpty)
        XCTAssertFalse(f.controller.scripts.contains { $0.id == f.revision.id })
        await f.controller.activate(f.revision, expectedGeneration: approved.generation)
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_STALE")
        XCTAssertThrowsError(try f.coordinator.activate(revisionID: f.revision.id, expectedSelectionGeneration: after.selectionGeneration,
                                                        approval: InstallationApproval(packageBytes: f.revision.package.bytes, expectedGrantGeneration: after.activation.generation),
                                                        captureConsent: { true }))
        { error in
            XCTAssertEqual(error as? AutomationError, .staleSnapshot)
        }
        XCTAssertThrowsError(try f.coordinator.delete(revisionID: f.revision.id, expectedSelectionGeneration: reviewedSelection)) { error in
            XCTAssertEqual(error as? AutomationError, .staleGeneration)
        }
        XCTAssertEqual(try f.coordinator.state(), after, "review of removed selection cannot restore execution authority")
    }

    func testFailedCoordinatorRevokeStopsCaptureRecordsPendingAndReconciles() async throws {
        let writer = FailingWriter(failAt: 1)
        let f = try await fixture(active: true, writer: { try writer.write($0, $1) }, coordinated: true)
        let before = try f.coordinator.state(), bytes = try Data(contentsOf: f.activationURL)
        let revoked = await f.controller.revokeActivation(id: f.revision.id)
        XCTAssertFalse(revoked)
        XCTAssertEqual(try f.coordinator.state(), before)
        XCTAssertEqual(try Data(contentsOf: f.activationURL), bytes)
        XCTAssertTrue(f.controller.isActive(f.revision.id), "failed persisted revocation must never be claimed as success")
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_REVOCATION_PENDING")
        XCTAssertEqual(f.stops.count, 1)
        writer.enabled = false
        await f.controller.refreshActivation()
        let reconciled = try await f.activation.snapshot()
        XCTAssertTrue(reconciled.revisions.isEmpty)
        XCTAssertTrue(f.controller.pendingRevocations.isEmpty)
        XCTAssertNil(f.controller.activationError)
        XCTAssertTrue(f.controller.scripts.contains { $0.id == f.revision.id }, "deactivation preserves installation")
        XCTAssertEqual(f.stops.count, 1)
    }

    func testFailedCoordinatorDeletePreservesSelectionApprovalAndReportsError() async throws {
        let writer = FailingWriter(failAt: 1, stage: .uninstallation)
        let f = try await fixture(active: true, writer: { try writer.write($0, $1) }, coordinated: true)
        let before = try f.coordinator.state(), bytes = try Data(contentsOf: f.activationURL)
        await f.controller.deleteScript(id: f.revision.id)
        XCTAssertEqual(f.controller.actionError as? AutomationError, .saveFailed)
        XCTAssertEqual(try f.coordinator.state(), before)
        XCTAssertEqual(try Data(contentsOf: f.activationURL), bytes)
        XCTAssertTrue(f.controller.isActive(f.revision.id))
        XCTAssertTrue(f.controller.scripts.contains { $0.id == f.revision.id })
        XCTAssertTrue(f.controller.pendingRevocations.isEmpty)
        XCTAssertEqual(f.stops.count, 0, "a failed atomic uninstall preserves the admitted grant")
        writer.enabled = false
        await f.controller.deleteScript(id: f.revision.id)
        let after = try f.coordinator.state()
        XCTAssertTrue(after.installed.isEmpty)
        XCTAssertTrue(after.activation.revisions.isEmpty)
        XCTAssertNotNil(after.catalog.revision(id: f.revision.id))
        XCTAssertNil(f.controller.actionError)
    }

    func testPendingReconcileDoesNotTreatCorruptCatalogAsEmpty() async throws {
        let writer = FailingWriter(failAt: 1)
        let f = try await fixture(active: true, writer: { try writer.write($0, $1) })
        let before = try await f.activation.snapshot()
        let revoked = await f.controller.revokeActivation(id: f.revision.id)
        XCTAssertFalse(revoked)
        writer.enabled = false
        try Data("{corrupt catalog".utf8).write(to: f.catalogURL)
        await f.controller.load()
        await f.controller.refreshActivation()
        XCTAssertNotNil(f.controller.storeError)
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        let after = try await f.activation.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(writer.count, 1)
    }

    func testConcurrentImportAndApprovalAfterCatalogReadSurviveEveryReconcileEntry() async throws {
        for entry in ["load", "refresh", "activate"] {
            let f = try await fixture(active: true)
            let reviewed = try await f.activation.snapshot()
            let newlyApproved = LockedValue<(revision: InstalledRevision, generation: UUID)?>(nil)
            let nextPackage = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Another window"))
            await f.store.afterLoad { [backing = f.store.backing, activation = f.baseActivation] in
                // The first controller already captured its catalog return value. Another window
                // installs and approves R before that load returns to the first controller.
                let revision = try await backing.importLocal(nextPackage.bytes)
                let before = try await activation.snapshot()
                let approved = try await activation.activate(nextPackage, revisionID: revision.id, expectedGeneration: before.generation)
                newlyApproved.value = (revision, approved.generation)
            }
            switch entry {
                case "load": await f.controller.load()
                case "refresh": await f.controller.refreshActivation()
                default: await f.controller.activate(f.revision, expectedGeneration: reviewed.generation)
            }
            let introduced = try XCTUnwrap(newlyApproved.value)
            let after = try await f.activation.snapshot()
            XCTAssertTrue(after.contains(revisionID: introduced.revision.id), "\(entry) must not classify a later grant as an orphan")
            XCTAssertEqual(after.generation, introduced.generation, "reconcile must not write or rotate after the other window's approval")
            XCTAssertEqual(f.stops.count, 0)
            if entry == "activate" {
                XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_STALE")
            }
        }
    }

    func testPassiveCorruptRefreshAndRepeatedMutationDoNotRepeatShutdownRequest() async throws {
        let f = try await fixture(active: true)
        let corrupt = Data("{invalid approvals".utf8)
        try corrupt.write(to: f.activationURL)
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        session.source += "\n// attempted save"
        await session.saveAsLocalEdit()
        XCTAssertEqual(f.stops.count, 1)
        await f.controller.refreshActivation()
        await f.controller.refreshActivation()
        await f.controller.load()
        await f.controller.deleteScript(id: f.revision.id)
        XCTAssertEqual(f.stops.count, 1, "passive reads and retries cannot stop a newly reconnected tunnel again")
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_STORE_PRESERVED")
        XCTAssertEqual(try Data(contentsOf: f.activationURL), corrupt)
    }

    func testRepeatedSaveFailedRetriesRemainPendingButRequestShutdownOnce() async throws {
        let writer = FailingWriter(failAt: 1, repeated: true)
        let f = try await fixture(active: true, writer: { try writer.write($0, $1) }, coordinated: true)
        let before = try Data(contentsOf: f.activationURL)
        let revoked = await f.controller.revokeActivation(id: f.revision.id)
        XCTAssertFalse(revoked)
        await f.controller.refreshActivation()
        await f.controller.refreshActivation()
        XCTAssertEqual(f.stops.count, 1)
        XCTAssertEqual(writer.count, 3)
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        XCTAssertEqual(f.controller.activationErrorKey, "AUTO_ACTIVATION_REVOCATION_PENDING")
        XCTAssertEqual(try Data(contentsOf: f.activationURL), before)
    }

    func testFailedSaveLaterReconcileStillPerformsIntendedRevocation() async throws {
        let writer = FailingWriter(failAt: 1)
        let f = try await fixture(active: true, writer: { try writer.write($0, $1) })
        let session = ScriptSession(controller: f.controller, revision: f.revision)
        session.source += "\n// attempted save"
        await session.saveAsLocalEdit()
        XCTAssertEqual(session.revision, f.revision, "failed save keeps the immutable parent installed")
        let pending = try await f.activation.snapshot()
        XCTAssertTrue(pending.contains(revisionID: f.revision.id))
        XCTAssertEqual(f.controller.pendingRevocations, [f.revision.id])
        writer.enabled = false
        await f.controller.refreshActivation()
        let after = try await f.activation.snapshot()
        XCTAssertTrue(after.revisions.isEmpty, "retry honors the earlier explicit revocation intent even though save was aborted")
        XCTAssertTrue(f.controller.pendingRevocations.isEmpty)
        XCTAssertTrue(f.controller.scripts.contains { $0.id == f.revision.id })
        let counts = await f.store.counts
        XCTAssertEqual(counts.edits, 0)
        XCTAssertEqual(f.stops.count, 1)
    }
}

@MainActor private final class StopRecorder { var count = 0 }

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } } set { lock.withLock { stored = newValue } }
    }
}

private final class FailingWriter: @unchecked Sendable {
    enum Stage { case revocation, uninstallation }
    private let lock = NSLock()
    private let failAt: Int
    private let repeated: Bool
    private let stage: Stage
    private var writes = 0, failing = true
    init(failAt: Int, repeated: Bool = false, stage: Stage = .revocation) {
        self.failAt = failAt; self.repeated = repeated; self.stage = stage
    }

    var count: Int {
        lock.withLock { writes }
    }

    var enabled: Bool {
        get { lock.withLock { failing } } set { lock.withLock { failing = newValue } }
    }

    func write(_ file: CatalogFile, _ bytes: Data) throws {
        let root = try JSONValue(parsing: bytes).objectValue
        // Ignore unchanged migration/barrier publications. Fail the authoritative logical change.
        let matchesStage = switch stage {
            case .revocation: root?["revisions"]?.arrayValue?.isEmpty == true
            case .uninstallation: root?["selections"]?.arrayValue?.isEmpty == true
        }
        let fails = lock.withLock {
            guard matchesStage else { return false }
            writes += 1
            return failing && (writes == failAt || (repeated && writes >= failAt))
        }
        if fails {
            throw AutomationError.saveFailed
        }
        try file.replace(with: bytes)
    }
}

/// Simulates another window immediately before a real atomic delete starts, outside its file locks.
private struct DeleteObservingCoordinator: InstallationCoordinating {
    let base: InstallationCoordinator
    let beforeDelete: @Sendable (String) throws -> Void

    func state() throws -> InstallationState {
        try base.state()
    }

    func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState {
        try base.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: now)
    }

    func importLocal(_ bytes: Data, operation: InstallationOperation, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.importLocal(bytes, operation: operation, expectedSelectionGeneration: expectedSelectionGeneration)
    }

    func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval,
                  captureConsent: @Sendable () -> Bool) throws -> InstallationState
    {
        try base.activate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration,
                          approval: approval, captureConsent: captureConsent)
    }

    func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.deactivate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
    }

    func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try beforeDelete(revisionID)
        return try base.delete(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
    }

    func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID,
                approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState
    {
        try base.update(request, baseRevisionID: baseRevisionID, expectedSelectionGeneration: expectedSelectionGeneration,
                        approval: approval, now: now, captureConsent: captureConsent)
    }
}

/// Pass-through to real catalog storage, with async barriers immediately before the two relevant
/// mutations. No fake catalog values or fake activation/runtime results are supplied.
private actor ObservedAutomationStore: AutomationStoring {
    let backing: AutomationStore
    private var editHook: (@Sendable () async throws -> Void)?, deleteHook: (@Sendable () async throws -> Void)?
    private var loadHook: (@Sendable () async throws -> Void)?
    private(set) var counts = (edits: 0, deletes: 0)
    init(_ backing: AutomationStore) {
        self.backing = backing
    }

    func beforeEdit(_ hook: @escaping @Sendable () async throws -> Void) {
        editHook = hook
    }

    func beforeDelete(_ hook: @escaping @Sendable () async throws -> Void) {
        deleteHook = hook
    }

    func afterLoad(_ hook: @escaping @Sendable () async throws -> Void) {
        loadHook = hook
    }

    func load() async throws -> Catalog {
        let loaded = try await backing.load()
        let hook = loadHook
        loadHook = nil
        try await hook?()
        return loaded
    }

    func catalog() async -> Catalog {
        await backing.catalog()
    }

    func seedIfAbsent(_ s: VerifiedSnapshot, expectedURL: RepositoryURL, expectedRepositoryID: UUID, expectedFingerprint: String, now: Date) async throws -> RepositoryRecord {
        try await backing.seedIfAbsent(s, expectedURL: expectedURL, expectedRepositoryID: expectedRepositoryID, expectedFingerprint: expectedFingerprint, now: now)
    }

    func preview(_ s: VerifiedSnapshot, now: Date) async throws -> AcceptancePreview {
        try await backing.preview(s, now: now)
    }

    func accept(_ s: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord {
        try await backing.accept(s, acknowledgeUnverified: acknowledgeUnverified, now: now)
    }

    func acceptAndPin(_ s: VerifiedSnapshot, fingerprint: String, now: Date) async throws -> RepositoryRecord {
        try await backing.acceptAndPin(s, fingerprint: fingerprint, now: now)
    }

    func pin(_ u: RepositoryURL, fingerprint: String) async throws -> RepositoryRecord {
        try await backing.pin(u, fingerprint: fingerprint)
    }

    func remove(_ u: RepositoryURL) async throws {
        try await backing.remove(u)
    }

    func install(_ p: PluginPackage, from s: VerifiedSnapshot, expectedGeneration: UUID, now: Date) async throws -> InstalledRevision {
        try await backing.install(p, from: s, expectedGeneration: expectedGeneration, now: now)
    }

    func importLocal(_ bytes: Data) async throws -> InstalledRevision {
        try await backing.importLocal(bytes)
    }

    func editSource(of id: String, to source: String) async throws -> InstalledRevision {
        counts.edits += 1
        try await editHook?()
        return try await backing.editSource(of: id, to: source)
    }

    func editSource(of id: String, file: String, to source: String) async throws -> InstalledRevision {
        counts.edits += 1
        try await editHook?()
        return try await backing.editSource(of: id, file: file, to: source)
    }

    func editSources(of id: String, to sources: [String: String]) async throws -> InstalledRevision {
        counts.edits += 1
        try await editHook?()
        return try await backing.editSources(of: id, to: sources)
    }

    func deleteRevision(_ id: String) async throws {
        counts.deletes += 1
        try await deleteHook?()
        try await backing.deleteRevision(id)
    }
}
