import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation
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
    private let clock: @Sendable () -> Date
    private let defaultRepository: DefaultRepository?

    init(store: any AutomationStoring, client: any RepositoryFetching, executor: any ScriptRunning,
         clock: @escaping @Sendable () -> Date = { Date() }, defaultRepository: DefaultRepository? = nil) {
        self.store = store; self.client = client; self.executor = executor; self.clock = clock
        self.defaultRepository = defaultRepository
    }

    var now: Date { clock() }

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
        do { catalog = try await store.load(); storeError = nil } catch {
            catalog = Catalog(); storeError = error
            return
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
            if (error as? AutomationError) == .corruptStore {
                storeError = error
                catalog = Catalog()
            }
        }
    }

    /// Re-reads the store's authoritative state after a mutation.
    func refreshCatalog() async { catalog = await store.catalog() }

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
        await mutate { try await store.importLocal(try AutomationTemplate.packageBytes(name: name)) }
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
        if let size = values.fileSize, size > Limits.package { throw AutomationInputError.fileTooLarge }
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

    func deleteScript(id: String) async { await mutate { try await store.deleteRevision(id) } }

    func deleteRepository(_ url: RepositoryURL) async { await mutate { try await store.remove(url) } }

    // MARK: Stable file location

    private static var testStoreName: String? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["INTERCEPTOR_TEST_AUTOMATION_STORE"], name.hasPrefix("Interceptor.UITests."),
           name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) { return name }
        #endif
        return nil
    }

    /// `Application Support/Interceptor/Automation/catalog.json`; the store applies backup exclusion and file protection.
    static func defaultStoreURL() -> URL {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let name = testStoreName { base.append(path: name, directoryHint: .isDirectory) }
        return base.appending(path: "Interceptor/Automation/catalog.json")
    }

    static func live() -> AutomationController {
        AutomationController(store: AutomationStore(fileURL: defaultStoreURL()), client: RepositoryClient(), executor: JavaScriptExecutor(),
                             defaultRepository: testStoreName == nil ? .official : nil)
    }
}
