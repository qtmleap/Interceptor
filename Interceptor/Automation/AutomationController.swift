import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation
import Mudmouth
import Observation

/// Shared app-owned automation state. Startup registers the default publisher when absent.
/// Imports remain explicit disabled revisions; nothing executes except `ScriptSession.run`.
@MainActor @Observable
final class AutomationController {
    private(set) var catalog = Catalog()
    private(set) var isLoaded = false
    /// Persistent: set when the store cannot be read or reports corruption. Blocks every mutation until the
    /// user resolves it; the data is never reset automatically.
    private(set) var storeError: Error?
    /// Transient result of the last user action.
    var actionError: Error?

    let packageCatalog: (any PackageCatalogStoring)?
    /// The display database is independent of authority, trust, and installation storage.
    private(set) var packageCatalogError: Error?
    /// Invalidates database presentation reads even when authority remains Equatable-equal.
    private(set) var packageCatalogRevision: UInt64 = 0
    @ObservationIgnored private var successfulPackageProjectionReceipt: UInt64?
    @ObservationIgnored private var pendingPackageLeaseIDs = Set<UUID>()
    @ObservationIgnored private var isDrainingPackageLeases = false
    private(set) var packageCatalogBackfillErrors: [String: Error] = [:]
    private(set) var isBackfillingPackages = false
    @ObservationIgnored private let packageSynchronization: PackageCatalogSynchronization?
    private let automaticPackageBackfill: Bool
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var packageBackfillTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedPackageBackfills = Set<String>()

    let store: any AutomationStoring
    let client: any RepositoryFetching
    let executor: any ScriptRunning
    let activationStore: PluginActivationStore?
    let installationCoordinator: (any InstallationCoordinating)?
    private let installationAvailable: Bool
    private(set) var installationState: InstallationState?
    private(set) var installationError: Error?
    private(set) var activationSnapshot: PluginActivationSnapshot?
    private(set) var activationError: Error?
    private(set) var pendingRevocations = Set<String>()
    private var activationErrorPreservesStore = false
    private let hasCaptureConsent: @Sendable () -> Bool
    private let stopCapture: @MainActor () -> Void
    private let clock: @Sendable () -> Date
    private let defaultRepository: DefaultRepository?
    /// Main-actor presentation order. Durable UUIDs are CAS tokens, never ordering tokens.
    @ObservationIgnored private var projectionReceipt: UInt64 = 0
    @ObservationIgnored private var projectionFailureReceipt: UInt64?
    @ObservationIgnored private var revocationAttempts: [String: UInt64] = [:]
    @ObservationIgnored private var deletionAttempts: [String: UInt64] = [:]
    @ObservationIgnored private var revocationIntentReceipt: UInt64 = 0
    /// Retained for the pending entry's lifetime, after its in-flight attempt has finished.
    @ObservationIgnored private var pendingRevocationReceipts: [String: UInt64] = [:]

    init(store: any AutomationStoring, client: any RepositoryFetching, executor: any ScriptRunning,
         clock: @escaping @Sendable () -> Date = { Date() }, defaultRepository: DefaultRepository? = nil,
         packageCatalog: (any PackageCatalogStoring)? = nil, packageCatalogError: Error? = nil,
         automaticPackageBackfill: Bool = true,
         activationStore: PluginActivationStore? = nil,
         installationCoordinator: (any InstallationCoordinating)? = nil, installationAvailable: Bool = true,
         hasCaptureConsent: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
         stopCapture: @escaping @MainActor () -> Void = { Mudmouth.default.stopVPNTunnel() })
    {
        self.packageCatalog = packageCatalog
        self.packageCatalogError = packageCatalogError
        self.automaticPackageBackfill = automaticPackageBackfill
        packageSynchronization = packageCatalog.map { PackageCatalogSynchronization(database: $0, client: client) }
        self.store = installationCoordinator == nil ? store : CoordinatorCatalogStore(base: store)
        self.client = client; self.executor = executor; self.clock = clock
        self.defaultRepository = defaultRepository
        self.activationStore = activationStore
        self.installationCoordinator = installationCoordinator
        self.installationAvailable = installationAvailable
        self.hasCaptureConsent = hasCaptureConsent
        self.stopCapture = stopCapture
    }

    var now: Date {
        clock()
    }

    var activationErrorKey: String? {
        guard let error = activationError else { return nil }
        if error is CaptureAuthorization.Failure || (error as? InstallationError) == .consentRequired {
            return "AUTO_ACTIVATION_CONSENT"
        }
        if (error as? AutomationError) == .limitExceeded {
            return "AUTO_ACTIVATION_LIMIT"
        }
        if (error as? AutomationError) == .staleSnapshot {
            return "AUTO_ACTIVATION_STALE"
        }
        if activationErrorPreservesStore, (error as? AutomationError) == .corruptStore {
            return "AUTO_ACTIVATION_STORE_PRESERVED"
        }
        if !pendingRevocations.isEmpty {
            return "AUTO_ACTIVATION_REVOCATION_PENDING"
        }
        return AutomationErrorText.key(for: error)
    }

    var scripts: [InstalledRevision] {
        let installed = installationCoordinator == nil ? catalog.revisions : installationState?.installed ?? []
        return installed.sorted {
            let order = $0.package.manifest.name.localizedStandardCompare($1.package.manifest.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var repositories: [RepositoryRecord] {
        catalog.visibleRepositories.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.url.canonical < $1.url.canonical : order == .orderedAscending
        }
    }

    /// Startup work belongs to the app lifetime, independently of Plugins presentation.
    func start() async {
        if startupTask == nil { startupTask = Task { await self.load() } }
        await startupTask?.value
    }

    func load() async {
        defer { isLoaded = true }
        if installationCoordinator != nil {
            guard await refreshCatalog() else { return }
        } else {
            let approvals = await readActivationBeforeCatalog()
            guard await refreshCatalog() else { return }
            await reconcileActivation(approvals, catalog: catalog)
        }
        do {
            try await bootstrapDefaultRepository()
        } catch is CancellationError {
            // Explicit initialization may be cancelled before the authoritative commit.
        } catch {
            actionError = error
            if installationCoordinator != nil {
                await refreshCatalog()
            } else if (error as? AutomationError) == .corruptStore {
                storeError = error
                catalog = Catalog()
            }
        }
    }

    /// Explicit Sources refresh may retry an unavailable first-run publisher; tombstones remain final.
    func retryDefaultRepository() async throws {
        guard await refreshCatalog() else {
            throw storeError ?? installationError ?? AutomationInputError.storeUnavailable
        }
        try await bootstrapDefaultRepository()
    }

    private func bootstrapDefaultRepository() async throws {
        guard let source = defaultRepository, catalog.record(for: source.url) == nil else { return }
        let snapshot = try await client.preview(url: source.url, now: now)
        _ = try await seedRepository(snapshot, descriptor: source)
        actionError = nil
    }

    /// Re-reads the store's authoritative state after a mutation.
    @discardableResult
    func refreshCatalog() async -> Bool {
        let receipt = nextProjectionReceipt()
        let loaded: Catalog
        do {
            loaded = try await store.load()
        } catch {
            guard receipt == projectionReceipt else { return false }
            projectionFailureReceipt = receipt
            catalog = Catalog(); storeError = error
            installationState = nil
            if installationCoordinator != nil { activationSnapshot = nil }
            return false
        }
        guard receipt == projectionReceipt else { return false }
        storeError = nil
        projectionFailureReceipt = nil
        if installationCoordinator != nil {
            do {
                let observation = try await readInstallationReceipt(honorCancellation: false)
                return observation.receipt == projectionReceipt
            } catch { return false } // The receipt-owning read publishes a current failure itself.
        }
        let synchronized = await synchronizePackageCatalog(visible: loaded.visibleRepositories, installed: loaded.revisions, receipt: receipt)
        guard receipt == projectionReceipt else { return false }
        publishPackageCatalogRevision(receipt: receipt, synchronized: synchronized)
        catalog = loaded
        schedulePackageBackfill()
        await drainPendingPackageLeases()
        return receipt == projectionReceipt
    }

    var selectionGeneration: UUID? { installationState?.selectionGeneration }

    /// Cancellation is checked before admission, never after a confirmed durable publication.
    private func withInstallation<T: Sendable>(honorCancellation: Bool = true,
                                        _ body: @escaping @Sendable (any InstallationCoordinating) throws -> T) async throws -> T {
        guard installationAvailable, let coordinator = installationCoordinator else { throw InstallationError.activationUnavailable }
        let worker = Task.detached(priority: .userInitiated) {
            if honorCancellation { try Task.checkCancellation() }
            return try body(coordinator)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            if honorCancellation { worker.cancel() }
        }
    }

    @discardableResult
    func readInstallation(honorCancellation: Bool = true) async throws -> InstallationState {
        try await readInstallationReceipt(honorCancellation: honorCancellation).state
    }

    private func nextProjectionReceipt() -> UInt64 {
        projectionReceipt += 1
        return projectionReceipt
    }

    private func nextRevocationIntentReceipt() -> UInt64 {
        revocationIntentReceipt += 1
        return revocationIntentReceipt
    }

    private func clearPendingRevocation(_ id: String) {
        pendingRevocations.remove(id)
        pendingRevocationReceipts.removeValue(forKey: id)
    }

    private func readInstallationReceipt(honorCancellation: Bool) async throws -> (state: InstallationState, receipt: UInt64) {
        let receipt = nextProjectionReceipt()
        do {
            let state = try await withInstallation(honorCancellation: honorCancellation) { try $0.state() }
            if receipt == projectionReceipt {
                let synchronized = await synchronizePackageCatalog(visible: state.catalog.visibleRepositories, installed: state.installed, receipt: receipt)
                if receipt == projectionReceipt {
                    publishPackageCatalogRevision(receipt: receipt, synchronized: synchronized)
                    applyInstallation(state)
                    schedulePackageBackfill()
                    await drainPendingPackageLeases()
                }
            }
            return (state, receipt)
        } catch is CancellationError {
            // Cancelling a request is not evidence that durable authority became unreadable.
            // Replace its invalidated observation once, without inheriting caller cancellation.
            if honorCancellation, receipt == projectionReceipt {
                _ = try? await readInstallationReceipt(honorCancellation: false)
            }
            throw CancellationError()
        } catch {
            if receipt == projectionReceipt {
                projectionFailureReceipt = receipt
                installationError = error
                installationState = nil
                catalog = Catalog() // Source visibility cannot be published with an unknown selection.
                activationSnapshot = nil
            }
            throw error
        }
    }

    private func applyInstallation(_ state: InstallationState) {
        installationState = state
        installationError = nil
        projectionFailureReceipt = nil
        catalog = state.catalog
        activationSnapshot = state.activation
    }

    /// A mutation result is its durable receipt, not a current read. Delivery can lag another writer.
    /// Always re-read authority on success and failure; a refresh never retries an uncertain write.
    private func performInstallationMutation(
        _ body: @escaping @Sendable (any InstallationCoordinating) throws -> InstallationState
    ) async throws -> InstallationState {
        _ = nextProjectionReceipt()
        do {
            let receipt = try await withInstallation(body)
            await refreshCatalog()
            return receipt // No cancellation check after confirmed publication.
        } catch {
            await refreshCatalog()
            throw error
        }
    }

    func commitInstallationBatch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID) async throws -> InstallationState {
        let clock = now
        return try await performInstallationMutation { try $0.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: clock) }
    }

    func commitInstallationUpdate(_ request: InstallationRequest, baseRevisionID: String,
                                  expectedSelectionGeneration: UUID, approval: InstallationApproval?) async throws -> InstallationState {
        let (clock, consent) = (now, hasCaptureConsent)
        return try await performInstallationMutation {
            try $0.update(request, baseRevisionID: baseRevisionID, expectedSelectionGeneration: expectedSelectionGeneration,
                          approval: approval, now: clock, captureConsent: consent)
        }
    }

    /// Runs a store mutation: refuses while the store is unreadable, records failures, reloads on success.
    @discardableResult
    func mutate<T>(_ body: () async throws -> T) async -> T? {
        guard storeError == nil else { actionError = AutomationInputError.storeUnavailable; return nil }
        do {
            let result = try await body()
            actionError = nil
            await refreshCatalog()
            return result
        } catch {
            actionError = error
            if installationCoordinator != nil {
                // A delayed action error cannot declare the current authority corrupt.
                await refreshCatalog()
            } else if (error as? AutomationError) == .corruptStore {
                storeError = error
                catalog = Catalog()
            }
            return nil
        }
    }

    // MARK: Scripts (never executed here)

    @discardableResult
    func createExample(name: String) async -> InstalledRevision? {
        if installationCoordinator != nil {
            do { return await importSelectedLocal(try AutomationTemplate.packageBytes(name: name)) }
            catch { actionError = error; return nil }
        }
        return await mutate { try await store.importLocal(AutomationTemplate.packageBytes(name: name)) }
    }

    /// Imports a user-selected package file as a disabled local revision. The caller owns security-scoped access.
    @discardableResult
    func importFile(at url: URL) async -> InstalledRevision? {
        let reader = Task.detached(priority: .userInitiated) { try Self.readPackageBytes(at: url) }
        let data: Data
        do {
            data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            try Task.checkCancellation()
        } catch is CancellationError { return nil }
        catch let error as AutomationInputError { actionError = error; return nil }
        catch { actionError = AutomationInputError.fileUnreadable; return nil }
        if installationCoordinator != nil { return await importSelectedLocal(data) }
        return await mutate { try await store.importLocal(data) }
    }

    private func importSelectedLocal(_ bytes: Data) async -> InstalledRevision? {
        guard storeError == nil else { actionError = AutomationInputError.storeUnavailable; return nil }
        do {
            let current = try await readInstallation()
            let state = try await performInstallationMutation {
                try $0.importLocal(bytes, operation: .add, expectedSelectionGeneration: current.selectionGeneration)
            }
            actionError = nil
            return state.installed.first { revision in
                guard revision.package.bytes == bytes else { return false }
                if case .localImport = revision.provenance.origin { return true }
                return false
            }
        } catch { actionError = error; return nil }
    }

    private nonisolated static func readPackageBytes(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw AutomationInputError.fileUnreadable }
        if let size = values.fileSize, size > Limits.package {
            throw AutomationInputError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let bytes = try handle.read(upToCount: min(65_536, Limits.package + 1 - result.count)), !bytes.isEmpty {
            try Task.checkCancellation()
            result.append(bytes)
            guard result.count <= Limits.package else { throw AutomationInputError.fileTooLarge }
        }
        return result
    }

    func deleteScript(id: String) async {
        if installationCoordinator != nil {
            let attempt = nextRevocationIntentReceipt()
            deletionAttempts[id] = attempt
            let ownedPendingReceipt = pendingRevocationReceipts[id]
            defer { if deletionAttempts[id] == attempt { deletionAttempts.removeValue(forKey: id) } }
            do {
                let current = try await readInstallation()
                _ = try await performInstallationMutation { try $0.delete(revisionID: id, expectedSelectionGeneration: current.selectionGeneration) }
                await prunePackageCatalog()
                // The historical delete fulfilled only the pending intent it observed at admission.
                // Identical bytes can have been reinstalled and revoked again before receipt delivery.
                if pendingRevocationReceipts[id] == ownedPendingReceipt { clearPendingRevocation(id) }
                if deletionAttempts[id] == attempt { actionError = nil }
            } catch {
                if deletionAttempts[id] == attempt { actionError = error }
            }
            return
        }
        // Only a known immutable v1 revision can skip revocation. Unknown IDs remain fail-closed.
        let needsRevocation = catalog.revision(id: id)?.package.manifest.schemaVersion != 1
        if needsRevocation, await !revokeActivation(id: id) {
            return
        }
        guard let _: Void = await mutate({ try await store.deleteRevision(id) }) else { return }
        // Closes the cross-controller approve/delete race. An approval before this is removed;
        // one using an older generation afterwards fails CAS, and a new review sees no revision.
        if needsRevocation {
            await revokeActivation(id: id)
        }
        await prunePackageCatalog()
    }

    func refreshActivation() async {
        if installationCoordinator != nil {
            guard await refreshActivationProjection() else { return }
            for id in pendingRevocations.sorted() {
                // A superseded read is not evidence that a pending revocation became orphaned.
                guard await refreshActivationProjection() else { return }
                guard pendingRevocations.contains(id) else { continue }
                if installationState?.installed.contains(where: { $0.id == id }) == true {
                    guard await revokeActivation(id: id) else { return }
                } else { clearPendingRevocation(id) }
            }
            if pendingRevocations.isEmpty { activationError = nil; activationErrorPreservesStore = false }
            return
        }
        guard activationStore != nil else { return }
        let approvals = await readActivationBeforeCatalog()
        // The later catalog read cannot falsely orphan a grant imported and approved by another window
        // between reads. Reconcile only the earlier snapshot, never expand it from a newer read.
        guard await refreshCatalog() else { return }
        await reconcileActivation(approvals, catalog: catalog)
    }

    private func refreshActivationProjection() async -> Bool {
        let applied = await refreshCatalog()
        if !applied, projectionFailureReceipt == projectionReceipt,
           let error = storeError ?? installationError {
            recordActivationFailure(error, preservesStore: true)
        }
        return applied
    }

    private func readActivationBeforeCatalog() async -> Result<PluginActivationSnapshot, Error>? {
        guard let activationStore else { return nil }
        do { return try await .success(activationStore.snapshot()) }
        catch { return .failure(error) }
    }

    private func reconcileActivation(_ approvals: Result<PluginActivationSnapshot, Error>?, catalog validatedCatalog: Catalog) async {
        guard storeError == nil, let approvals else { return }
        do {
            let earlier = try approvals.get()
            activationSnapshot = earlier
            let installed = Set(validatedCatalog.revisions.map(\.id))
            let orphaned = Set(earlier.revisions.map(\.revisionID).filter { !installed.contains($0) })
            for id in pendingRevocations.union(orphaned).sorted() {
                guard storeError == nil else { return }
                guard await revokeActivation(id: id) else { return }
            }
            if pendingRevocations.isEmpty {
                activationError = nil
                activationErrorPreservesStore = false
            }
        } catch {
            activationSnapshot = nil
            recordActivationFailure(error, preservesStore: true)
        }
    }

    func isActive(_ id: String) -> Bool {
        activationSnapshot?.contains(revisionID: id) == true
    }

    func activate(_ revision: InstalledRevision, expectedGeneration: UUID) async {
        if installationCoordinator != nil {
            do {
                guard storeError == nil else { throw AutomationInputError.storeUnavailable }
                guard hasCaptureConsent() else { throw CaptureAuthorization.Failure.consentRequired }
                let current = try await readInstallation()
                guard current.installed.contains(where: { $0.id == revision.id && $0.package.bytes == revision.package.bytes }) else {
                    throw AutomationError.staleSnapshot
                }
                guard pendingRevocations.isEmpty else { return }
                let (consent, approval) = (hasCaptureConsent, InstallationApproval(packageBytes: revision.package.bytes, expectedGrantGeneration: expectedGeneration))
                _ = try await performInstallationMutation {
                    try $0.activate(revisionID: revision.id, expectedSelectionGeneration: current.selectionGeneration,
                                    approval: approval, captureConsent: consent)
                }
                if pendingRevocations.isEmpty { activationError = nil; activationErrorPreservesStore = false }
            } catch { recordActivationFailure(error, preservesStore: true) }
            return
        }
        guard storeError == nil, let activationStore else { return }
        do {
            guard hasCaptureConsent() else { throw CaptureAuthorization.Failure.consentRequired }
            guard revision.package.manifest.schemaVersion == 2 else { throw AutomationError.invalidManifest }
            // Both the reviewed generation and this approval snapshot precede the authoritative
            // catalog read; a newly imported/approved grant cannot become a false orphan.
            let approvals = await readActivationBeforeCatalog()
            let current: Catalog
            do {
                current = try await store.load()
                let receipt = nextProjectionReceipt()
                let synchronized = await synchronizePackageCatalog(visible: current.visibleRepositories, installed: current.revisions, receipt: receipt)
                guard receipt == projectionReceipt else { throw AutomationError.staleSnapshot }
                publishPackageCatalogRevision(receipt: receipt, synchronized: synchronized)
                catalog = current; storeError = nil
                schedulePackageBackfill()
                await drainPendingPackageLeases()
            }
            catch { storeError = error; throw error }
            guard current.revisions.contains(where: { $0.id == revision.id && $0.package.bytes == revision.package.bytes }) else {
                throw AutomationError.staleSnapshot
            }
            await reconcileActivation(approvals, catalog: current)
            guard storeError == nil, activationError == nil, pendingRevocations.isEmpty else { return }
            do {
                activationSnapshot = try await activationStore.activate(revision.package, revisionID: revision.id,
                                                                        expectedGeneration: expectedGeneration)
                activationError = nil
                activationErrorPreservesStore = false
            } catch { recordActivationFailure(error, preservesStore: true) }
        } catch { recordActivationFailure(error, preservesStore: false) }
        if activationError != nil {
            await refreshActivationPreservingError()
        }
    }

    @discardableResult
    func revokeActivation(id: String) async -> Bool {
        if installationCoordinator != nil {
            let attempt = nextRevocationIntentReceipt()
            revocationAttempts[id] = attempt
            defer { if revocationAttempts[id] == attempt { revocationAttempts.removeValue(forKey: id) } }
            do {
                let current = try await readInstallation()
                _ = try await performInstallationMutation { try $0.deactivate(revisionID: id, expectedSelectionGeneration: current.selectionGeneration) }
                if revocationAttempts[id] == attempt {
                    clearPendingRevocation(id)
                    if pendingRevocations.isEmpty { activationError = nil; activationErrorPreservesStore = false }
                }
                return true
            } catch {
                guard revocationAttempts[id] == attempt else { return false }
                let newlyPending = pendingRevocations.insert(id).inserted
                pendingRevocationReceipts[id] = attempt
                recordActivationFailure(error, preservesStore: true)
                if newlyPending { stopCapture() }
                return false
            }
        }
        guard let activationStore else { return true }
        do {
            activationSnapshot = try await activationStore.revoke(revisionID: id)
            clearPendingRevocation(id)
            if pendingRevocations.isEmpty {
                activationError = nil
                activationErrorPreservesStore = false
            }
            return true
        } catch {
            let newlyPending = pendingRevocations.insert(id).inserted
            recordActivationFailure(error, preservesStore: true)
            // One shutdown request for this pending operation. Passive retries must not repeatedly
            // stop a manually reconnected tunnel. Persisted revocation has not succeeded.
            if newlyPending {
                stopCapture()
            }
            return false
        }
    }

    private func recordActivationFailure(_ error: Error, preservesStore: Bool) {
        activationError = error
        activationErrorPreservesStore = preservesStore
    }

    private func refreshActivationPreservingError() async {
        if let activationStore {
            activationSnapshot = try? await activationStore.snapshot()
        }
    }

    func deleteRepository(_ url: RepositoryURL) async {
        guard let _: Void = await mutate({ try await store.remove(url) }) else { return }
        await prunePackageCatalog()
        if catalog.record(for: url)?.visible == false { packageCatalogBackfillErrors.removeValue(forKey: url.canonical) }
    }

    // MARK: Package metadata lifecycle

    /// All source publication paths stage package content before Core's authoritative transaction.
    func acceptRepository(_ snapshot: VerifiedSnapshot, expecting: RepositoryAcceptanceExpectation,
                          pinning fingerprint: String?, acknowledgeUnverified: Bool) async throws -> RepositoryRecord {
        try await ingestRepository(snapshot, acknowledgeUnverified: acknowledgeUnverified, preflight: {
            let current = try await self.store.load().record(for: snapshot.url)
            switch expecting {
            case .absent:
                guard current == nil else { throw AutomationError.staleSnapshot }
            case .generation(let generation):
                guard current?.generation == generation else { throw AutomationError.staleSnapshot }
            }
            if let fingerprint {
                guard case .signed(let key) = snapshot.signature, key.hex == fingerprint.lowercased() else {
                    throw AutomationError.fingerprintMismatch
                }
            }
        }) {
            if let fingerprint {
                return try await self.store.acceptAndPin(snapshot, fingerprint: fingerprint, now: self.now, expecting: expecting)
            }
            return try await self.store.accept(snapshot, acknowledgeUnverified: acknowledgeUnverified, now: self.now, expecting: expecting)
        }
    }

    func refreshRepository(_ snapshot: VerifiedSnapshot, expectedGeneration: UUID,
                           acknowledgeUnverified: Bool = false) async throws -> RepositoryRecord {
        try await ingestRepository(snapshot, acknowledgeUnverified: acknowledgeUnverified, preflight: {
            let current = try await self.store.load().record(for: snapshot.url)
            guard current?.visible == true, current?.generation == expectedGeneration else {
                throw AutomationError.staleSnapshot
            }
        }) {
            try await self.store.refresh(snapshot, expectedGeneration: expectedGeneration,
                                         acknowledgeUnverified: acknowledgeUnverified, now: self.now)
        }
    }

    private func seedRepository(_ snapshot: VerifiedSnapshot, descriptor: DefaultRepository) async throws -> RepositoryRecord {
        guard snapshot.url == descriptor.url else { throw AutomationError.invalidURL }
        guard snapshot.index.id == descriptor.repositoryID else { throw AutomationError.repositoryIdentityChanged }
        guard case .signed(let key) = snapshot.signature, key.hex == descriptor.fingerprint else {
            throw AutomationError.fingerprintMismatch
        }
        return try await ingestRepository(snapshot, acknowledgeUnverified: true) {
            try await self.store.seedIfAbsent(snapshot, expectedURL: descriptor.url, expectedRepositoryID: descriptor.repositoryID,
                                              expectedFingerprint: descriptor.fingerprint, now: self.now)
        }
    }

    private func ingestRepository(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool,
                                  preflight: () async throws -> Void = {},
                                  publish: () async throws -> RepositoryRecord) async throws -> RepositoryRecord {
        guard storeError == nil else { throw AutomationInputError.storeUnavailable }
        let leaseID = UUID()
        do {
            try await preflight()
            // Trust/identity/time failures must precede content downloads; Core repeats checks at commit.
            let preview = try await store.preview(snapshot, now: now)
            guard acknowledgeUnverified || !preview.requiresAcknowledgment else { throw AutomationError.acknowledgmentRequired }
            if let packageSynchronization {
                try await packageSynchronization.stage(snapshot, installed: scripts, leaseID: leaseID)
            } else if let packageCatalogError {
                throw packageCatalogError // A production database-open failure is never an opt-out.
            }
            try Task.checkCancellation()
            let record = try await publish()
            // No cancellation check after confirmed authoritative publication.
            await refreshCatalog()
            await finishPackageLease(leaseID)
            if isCurrentPackageSnapshot(snapshot) { packageCatalogBackfillErrors.removeValue(forKey: snapshot.url.canonical) }
            actionError = nil
            return record
        } catch {
            await refreshCatalog()
            await finishPackageLease(leaseID)
            let failure = recordPackageFailure(error)
            if !(error is CancellationError) { actionError = failure }
            throw failure
        }
    }

    private func recordPackageFailure(_ error: Error) -> Error {
        if let failure = error as? PackageCatalogStorageFailure {
            packageCatalogError = failure.underlying
            return failure.underlying
        }
        return error
    }

    private func synchronizePackageCatalog(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) async -> Bool {
        guard let packageCatalog else { return false }
        do {
            try await packageCatalog.synchronize(visible: visible, installed: installed, receipt: receipt)
            guard receipt == projectionReceipt else { return false }
            packageCatalogError = nil
            return true
        } catch {
            if receipt == projectionReceipt { packageCatalogError = error }
            return false
        }
    }

    /// The caller publishes matching authority in this same actor turn, without an intervening await.
    private func publishPackageCatalogRevision(receipt: UInt64, synchronized: Bool) {
        guard synchronized, receipt == projectionReceipt else { return }
        successfulPackageProjectionReceipt = receipt
        packageCatalogRevision += 1
    }

    private func finishPackageLease(_ leaseID: UUID) async {
        guard packageCatalog != nil else { return }
        pendingPackageLeaseIDs.insert(leaseID)
        await drainPendingPackageLeases()
    }

    private func prunePackageCatalog() async {
        // This ID owns no lease. It schedules the same safe reference-based maintenance.
        await finishPackageLease(UUID())
    }

    private func drainPendingPackageLeases() async {
        guard let packageCatalog, !isDrainingPackageLeases else { return }
        isDrainingPackageLeases = true
        defer { isDrainingPackageLeases = false }
        while let leaseID = pendingPackageLeaseIDs.first {
            // Failed or superseded authority/selection projection cannot release staged content.
            guard successfulPackageProjectionReceipt == projectionReceipt else { return }
            let receipt = projectionReceipt
            let visible = catalog.visibleRepositories
            do {
                try await packageCatalog.finish(leaseID: leaseID, visible: visible)
                pendingPackageLeaseIDs.remove(leaseID)
            } catch {
                if receipt == projectionReceipt { packageCatalogError = error }
                return // A later successful projection retries the retained IDs.
            }
        }
    }

    private func isCurrentPackageSnapshot(_ snapshot: VerifiedSnapshot) -> Bool {
        catalog.record(for: snapshot.url).map {
            $0.visible && $0.payloadDigest == snapshot.payloadDigest && $0.repositoryID == snapshot.index.id
        } == true
    }

    private func schedulePackageBackfill() {
        guard automaticPackageBackfill, let packageCatalog, let packageSynchronization, packageBackfillTask == nil else { return }
        let pending: [VerifiedSnapshot]
        do {
            pending = try repositories.compactMap { record in
                guard let snapshot = record.snapshot,
                      !attemptedPackageBackfills.contains(packageBackfillIdentity(snapshot)),
                      try !packageCatalog.isComplete(snapshot) else { return nil }
                return snapshot
            }
        } catch { packageCatalogError = error; return }
        guard !pending.isEmpty else { return }
        isBackfillingPackages = true
        packageBackfillTask = Task { [weak self] in
            guard let self else { return }
            for snapshot in pending {
                let leaseID = UUID()
                var failure: Error?
                var didStart = false
                do {
                    try await packageSynchronization.stage(snapshot, installed: scripts, leaseID: leaseID) {
                        let identity = self.packageBackfillIdentity(snapshot)
                        guard self.isCurrentPackageSnapshot(snapshot), !self.attemptedPackageBackfills.contains(identity) else { return false }
                        do { if try packageCatalog.isComplete(snapshot) { return false } }
                        catch { throw PackageCatalogStorageFailure(underlying: error) }
                        self.attemptedPackageBackfills.insert(identity)
                        didStart = true
                        return true
                    }
                } catch { failure = error }
                guard didStart || failure != nil else { continue }
                await refreshCatalog()
                await finishPackageLease(leaseID)
                guard isCurrentPackageSnapshot(snapshot) else { continue }
                if let failure {
                    do {
                        if try !packageCatalog.isComplete(snapshot) {
                            packageCatalogBackfillErrors[snapshot.url.canonical] = recordPackageFailure(failure)
                        }
                    } catch { packageCatalogError = error }
                } else {
                    packageCatalogBackfillErrors.removeValue(forKey: snapshot.url.canonical)
                }
            }
            packageBackfillTask = nil
            isBackfillingPackages = false
            if !Task.isCancelled { schedulePackageBackfill() }
        }
    }

    private func packageBackfillIdentity(_ snapshot: VerifiedSnapshot) -> String {
        snapshot.url.canonical + "|" + snapshot.index.id.uuidString + "|" + snapshot.payloadDigest
    }

    // MARK: Stable file location

    private static var testStoreName: String? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["INTERCEPTOR_TEST_AUTOMATION_STORE"], name.hasPrefix("Interceptor.UITests."),
           name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        {
            return name
        }
        #endif
        return nil
    }

    /// `Application Support/Interceptor/Automation/catalog.json`; the store applies backup exclusion and file protection.
    static func defaultStoreURL() -> URL {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let name = testStoreName {
            base.append(path: name, directoryHint: .isDirectory)
        }
        return base.appending(path: "Interceptor/Automation/catalog.json")
    }

    static func live() -> AutomationController {
        let catalogURL = defaultStoreURL(), activationURL = AutomationSharedConfiguration.activationURL()
        let database: PackageCatalogDatabase?
        let databaseError: Error?
        do {
            database = try PackageCatalogDatabase(url: catalogURL.deletingLastPathComponent().appendingPathComponent("PackageCatalog"))
            databaseError = nil
        } catch {
            database = nil
            databaseError = error
        }
        return AutomationController(store: AutomationStore(fileURL: catalogURL), client: RepositoryClient(), executor: JavaScriptExecutor(),
                             defaultRepository: testStoreName == nil ? .official : nil,
                             packageCatalog: database, packageCatalogError: databaseError,
                             activationStore: activationURL.map { PluginActivationStore(fileURL: $0, catalogURL: catalogURL) },
                             installationCoordinator: InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL),
                             installationAvailable: activationURL != nil)
    }
}
