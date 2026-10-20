import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation
import Mudmouth
import Observation

/// Owns Settings > Plugins. First entry registers the default publisher's metadata when absent.
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
         activationStore: PluginActivationStore? = nil,
         installationCoordinator: (any InstallationCoordinating)? = nil, installationAvailable: Bool = true,
         hasCaptureConsent: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
         stopCapture: @escaping @MainActor () -> Void = { Mudmouth.default.stopVPNTunnel() })
    {
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

    func load() async {
        defer { isLoaded = true }
        if installationCoordinator != nil {
            await refreshCatalog()
            guard storeError == nil else { return }
        } else {
            let approvals = await readActivationBeforeCatalog()
            do { catalog = try await store.load(); storeError = nil } catch {
                catalog = Catalog(); storeError = error
                return
            }
            await reconcileActivation(approvals, catalog: catalog)
        }
        guard let source = defaultRepository, catalog.record(for: source.url) == nil else { return }
        do {
            let snapshot = try await client.preview(url: source.url, now: now)
            try Task.checkCancellation()
            _ = try await store.seedIfAbsent(snapshot, expectedURL: source.url, expectedRepositoryID: source.repositoryID,
                                             expectedFingerprint: source.fingerprint, now: now)
            await refreshCatalog()
            actionError = nil
        } catch is CancellationError {
            // Leaving Plugins cancels this entry's fetch; the next entry may retry.
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
        catalog = loaded
        storeError = nil
        projectionFailureReceipt = nil
        if installationCoordinator != nil {
            do {
                let observation = try await readInstallationReceipt(honorCancellation: false)
                return observation.receipt == projectionReceipt
            } catch { return false } // The receipt-owning read publishes a current failure itself.
        }
        return true
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
            if receipt == projectionReceipt { applyInstallation(state) }
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
        do { catalog = try await store.load(); storeError = nil }
        catch { storeError = error; return }
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
            do { current = try await store.load(); catalog = current; storeError = nil }
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
        await mutate { try await store.remove(url) }
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
        return AutomationController(store: AutomationStore(fileURL: catalogURL), client: RepositoryClient(), executor: JavaScriptExecutor(),
                             defaultRepository: testStoreName == nil ? .official : nil,
                             activationStore: activationURL.map { PluginActivationStore(fileURL: $0, catalogURL: catalogURL) },
                             installationCoordinator: InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL),
                             installationAvailable: activationURL != nil)
    }
}
