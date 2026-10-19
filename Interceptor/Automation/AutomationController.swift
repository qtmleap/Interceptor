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
    private(set) var activationSnapshot: PluginActivationSnapshot?
    private(set) var activationError: Error?
    private(set) var pendingRevocations = Set<String>()
    private var activationErrorPreservesStore = false
    private let hasCaptureConsent: @Sendable () -> Bool
    private let stopCapture: @MainActor () -> Void
    private let clock: @Sendable () -> Date
    private let defaultRepository: DefaultRepository?

    init(store: any AutomationStoring, client: any RepositoryFetching, executor: any ScriptRunning,
         clock: @escaping @Sendable () -> Date = { Date() }, defaultRepository: DefaultRepository? = nil,
         activationStore: PluginActivationStore? = nil,
         hasCaptureConsent: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
         stopCapture: @escaping @MainActor () -> Void = { Mudmouth.default.stopVPNTunnel() })
    {
        self.store = store; self.client = client; self.executor = executor; self.clock = clock
        self.defaultRepository = defaultRepository
        self.activationStore = activationStore
        self.hasCaptureConsent = hasCaptureConsent
        self.stopCapture = stopCapture
    }

    var now: Date {
        clock()
    }

    var activationErrorKey: String? {
        guard let error = activationError else { return nil }
        if error is CaptureAuthorization.Failure {
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
        catalog.revisions.sorted {
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
        let approvals = await readActivationBeforeCatalog()
        do { catalog = try await store.load(); storeError = nil } catch {
            catalog = Catalog(); storeError = error
            return
        }
        await reconcileActivation(approvals, catalog: catalog)
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
            if (error as? AutomationError) == .corruptStore {
                storeError = error
                catalog = Catalog()
            }
        }
    }

    /// Re-reads the store's authoritative state after a mutation.
    func refreshCatalog() async {
        catalog = await store.catalog()
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
            if (error as? AutomationError) == .corruptStore {
                storeError = error
                catalog = Catalog()
            }
            return nil
        }
    }

    // MARK: Scripts (never executed here)

    @discardableResult
    func createExample(name: String) async -> InstalledRevision? {
        await mutate { try await store.importLocal(AutomationTemplate.packageBytes(name: name)) }
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
        return await mutate { try await store.importLocal(data) }
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
        guard activationStore != nil else { return }
        let approvals = await readActivationBeforeCatalog()
        // The later catalog read cannot falsely orphan a grant imported and approved by another window
        // between reads. Reconcile only the earlier snapshot, never expand it from a newer read.
        do { catalog = try await store.load(); storeError = nil }
        catch { storeError = error; return }
        await reconcileActivation(approvals, catalog: catalog)
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
        guard let activationStore else { return true }
        do {
            activationSnapshot = try await activationStore.revoke(revisionID: id)
            pendingRevocations.remove(id)
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
        AutomationController(store: AutomationStore(fileURL: defaultStoreURL()), client: RepositoryClient(), executor: JavaScriptExecutor(),
                             defaultRepository: testStoreName == nil ? .official : nil,
                             activationStore: AutomationSharedConfiguration.activationURL().map { PluginActivationStore(fileURL: $0) })
    }
}
