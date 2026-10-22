import AutomationCore
import AutomationRepository
import Foundation
import Observation

struct PluginBrowserFamilyID: Hashable, Sendable {
    let source: String
    let manifestID: UUID

    init(source: String, manifestID: UUID) {
        self.source = source
        self.manifestID = manifestID
    }

    init(repository: RepositoryURL, manifestID: UUID) {
        source = repository.canonical
        self.manifestID = manifestID
    }

    init(_ revision: InstalledRevision) {
        if case .repository(let url, _) = revision.provenance.origin { source = url.canonical }
        else { source = "local" }
        manifestID = revision.package.manifest.id
    }
}

struct PluginQueuedPackage: Identifiable, Equatable, Sendable {
    enum Operation: Equatable, Sendable { case get, reinstall(selectedRevisionID: String) }
    let id: PluginBrowserFamilyID
    let package: PluginPackage
    let operation: Operation
    let snapshot: VerifiedSnapshot?
    let sourceGeneration: UUID?
    var name: String { package.manifest.name }
    var version: String { package.manifest.version }
}

/// One Packages row: a visible repository entry, or an installed repository package whose source or entry is gone.
/// Identity is source + manifest UUID, so the same UUID published by two sources stays two rows.
struct PluginBrowserCatalogPackage: Identifiable, Equatable, Sendable {
    let id: PluginBrowserFamilyID
    /// Current catalog entry; nil for an installed orphan.
    let entry: IndexEntry?
    /// Visible source record; nil when the installed package's source was removed.
    let record: RepositoryRecord?
    /// The selected installed revision of this family, if any.
    let installed: InstalledRevision?
    /// Displayed metadata: the selected local manifest when installed, otherwise the catalog entry.
    let name: String
    let version: String
    let author: String?
    let summary: String?
}

struct PluginBrowserCategory: Identifiable, Equatable, Sendable {
    let name: String?
    let count: Int
    var id: String { name.map { "category:" + $0 } ?? "uncategorized" }
}

typealias PluginBrowserRule = PackageCatalogRule

struct PluginBrowserUpdate: Equatable, Sendable {
    let package: PluginPackage
    let baseRevision: InstalledRevision
    let expectedSelectionGeneration: UUID
    let expectedGrantGeneration: UUID
    let requiresApproval: Bool
    fileprivate let request: InstallationRequest
}

enum PluginBrowserError: Error, Equatable, Sendable {
    case busy, emptyQueue, queueLimit, staleQueue, updateUnavailable, catalogUnavailable
}

/// UI state only. Selection and execution always come from the controller's durable coordinator.
@MainActor @Observable
final class PluginBrowserModel {
    let controller: AutomationController
    private(set) var queue: [PluginQueuedPackage] = []
    private(set) var isProcessing = false
    private(set) var queueError: Error?
    private(set) var queueCompletionCount: Int?
    private(set) var isQueuePresented = false
    private(set) var updateError: Error?
    private(set) var isRefreshing = false
    private(set) var refreshErrors: [String: Error] = [:]
    private struct CatalogPresentationKey: Hashable {
        let family: PluginBrowserFamilyID
        let generation: UUID
    }
    @ObservationIgnored private var presentationRevision: UInt64?
    @ObservationIgnored private var catalogPresentations: [CatalogPresentationKey: PluginPackagePresentation] = [:]
    @ObservationIgnored private var presentationOrder: [CatalogPresentationKey] = []
    @ObservationIgnored private var installedPresentations: [String: PluginPackagePresentation] = [:]
    @ObservationIgnored private(set) var catalogReadError: Error?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(controller: AutomationController) { self.controller = controller }

    var canDismissQueue: Bool { !isProcessing }

    var hasSourceRefreshFailures: Bool {
        !refreshErrors.isEmpty || controller.repositories.contains { controller.packageCatalogBackfillErrors[$0.url.canonical] != nil }
    }

    /// Explicit Get/Update reads exact local bytes and revalidates against current authority.
    /// Presentation never calls this path.
    func fetchPackage(entry: IndexEntry, record: RepositoryRecord) async throws -> PluginPackage {
        guard let current = currentRecord(record), current.generation == record.generation,
              let snapshot = current.snapshot, snapshot.index.plugins.contains(entry) else { throw AutomationError.staleSnapshot }
        guard let database = controller.packageCatalog else { throw PluginBrowserError.catalogUnavailable }
        guard let bytes = try database.packageBytes(in: current, entry: entry) else { throw PluginBrowserError.catalogUnavailable }
        try Task.checkCancellation()
        let validation = Task.detached(priority: .userInitiated) { try PluginPackage.validate(bytes, against: entry) }
        let checked = try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        guard currentRecord(record)?.generation == current.generation else { throw AutomationError.staleSnapshot }
        return checked
    }

    /// Synchronous database read, suitable for the first NavigationLink render.
    func packagePresentation(for family: PluginBrowserFamilyID, record: RepositoryRecord?) throws -> PluginPackagePresentation? {
        if let selected = selectedRevision(for: family) { return presentation(of: selected) }
        guard let record, let current = currentRecord(record), current.repositoryID == record.repositoryID else { return nil }
        let revision = controller.packageCatalogRevision
        if presentationRevision != revision {
            catalogPresentations.removeAll(keepingCapacity: true)
            presentationOrder.removeAll(keepingCapacity: true)
            presentationRevision = revision
        }
        let key = CatalogPresentationKey(family: family, generation: current.generation)
        if let cached = catalogPresentations[key] { return cached }
        guard let database = controller.packageCatalog else { throw PluginBrowserError.catalogUnavailable }
        let detail = try database.detail(in: current, entryID: family.manifestID)
        if let detail {
            catalogPresentations[key] = detail
            presentationOrder.append(key)
            if presentationOrder.count > 16 {
                catalogPresentations.removeValue(forKey: presentationOrder.removeFirst())
            }
        }
        return detail
    }

    func presentation(of revision: InstalledRevision) -> PluginPackagePresentation {
        if let cached = installedPresentations[revision.id] { return cached }
        let value = PluginPackagePresentation(revision.package)
        installedPresentations = installedPresentations.filter { id, _ in controller.scripts.contains { $0.id == id } }
        installedPresentations[revision.id] = value
        return value
    }

    @discardableResult
    func enqueueGet(entry: IndexEntry, record: RepositoryRecord) async -> Bool {
        do {
            let package = try await fetchPackage(entry: entry, record: record)
            return enqueueGet(package: package, record: record)
        } catch {
            queueError = error
            return false
        }
    }

    func recoverPackageSource(after failure: Error, record: RepositoryRecord) async throws -> Bool {
        let packageFailure = failure as? AutomationError
        guard (failure as? RepositoryClientError) == .responseTooLarge || packageFailure == .sizeMismatch || packageFailure == .hashMismatch else {
            return false
        }
        guard !isProcessing else { throw PluginBrowserError.busy }
        isProcessing = true
        defer { isProcessing = false }
        try Task.checkCancellation()
        let snapshot = try await controller.client.preview(url: record.url, now: controller.now)
        try Task.checkCancellation()
        do {
            _ = try await controller.refreshRepository(snapshot, expectedGeneration: record.generation)
        } catch {
            guard (error as? AutomationError) == .staleSnapshot else { throw error }
            await controller.refreshCatalog()
            let current = try recoveryRecord(for: record)
            guard current.generation != record.generation else { throw error }
            // A concurrent accepted record is only a reload signal, not acceptance of our preview.
            return true
        }
        // A committed refresh must reach the UI even when its new identity cancels this task.
        await controller.refreshCatalog()
        return try recoveryRecord(for: record).generation != record.generation
    }

    private func recoveryRecord(for record: RepositoryRecord) throws -> RepositoryRecord {
        if let error = controller.storeError { throw error }
        guard let current = currentRecord(record) else { throw AutomationError.staleSnapshot }
        guard current.repositoryID == record.repositoryID else { throw AutomationError.repositoryIdentityChanged }
        return current
    }

    @discardableResult
    func enqueueGet(package: PluginPackage, record: RepositoryRecord) -> Bool {
        guard !isProcessing else { return false }
        let family = PluginBrowserFamilyID(repository: record.url, manifestID: package.manifest.id)
        guard !queue.contains(where: { $0.id == family }) else { return false }
        guard queue.count < Limits.revisions else { queueError = PluginBrowserError.queueLimit; return false }
        guard selectedRevision(for: family) == nil else { queueError = InstallationError.familyAlreadyInstalled; return false }
        guard record.visible, let snapshot = record.snapshot,
              let entry = snapshot.index.plugins.first(where: { $0.id == package.manifest.id }),
              entry.version == package.manifest.version, entry.name == package.manifest.name,
              entry.sha256 == package.revision, entry.size == package.bytes.count else {
            queueError = AutomationError.metadataMismatch; return false
        }
        queue.append(.init(id: family, package: package, operation: .get,
                           snapshot: snapshot, sourceGeneration: record.generation))
        queueError = nil; queueCompletionCount = nil
        return true
    }

    @discardableResult
    func enqueueReinstall(_ revision: InstalledRevision) -> Bool {
        guard !isProcessing else { return false }
        let family = PluginBrowserFamilyID(revision)
        guard !queue.contains(where: { $0.id == family }) else { return false }
        guard queue.count < Limits.revisions else { queueError = PluginBrowserError.queueLimit; return false }
        guard selectedRevision(for: family)?.id == revision.id,
              selectedRevision(for: family)?.package.bytes == revision.package.bytes else {
            queueError = PluginBrowserError.staleQueue; return false
        }
        queue.append(.init(id: family, package: revision.package, operation: .reinstall(selectedRevisionID: revision.id),
                           snapshot: nil, sourceGeneration: nil))
        queueError = nil; queueCompletionCount = nil
        return true
    }

    func removeQueued(id: PluginBrowserFamilyID) {
        guard !isProcessing else { return }
        queue.removeAll { $0.id == id }
        queueError = nil; queueCompletionCount = nil
    }

    func clearQueue() {
        guard !isProcessing else { return }
        queue.removeAll(); queueError = nil; queueCompletionCount = nil
    }

    func openQueue() { isQueuePresented = true }

    @discardableResult
    func dismissQueue() -> Bool {
        guard canDismissQueue else { return false }
        isQueuePresented = false
        return true
    }

    @discardableResult
    func confirmQueue() async -> Bool {
        guard !isProcessing else { return false }
        guard !queue.isEmpty else { queueError = PluginBrowserError.emptyQueue; return false }
        let batch = queue
        isProcessing = true; queueError = nil; queueCompletionCount = nil
        defer { isProcessing = false }
        do {
            let validation = Task.detached(priority: .userInitiated) { try Self.validatedRequests(batch) }
            let requests = try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            // This is the final read for an all-reinstall queue and the CAS base for a mixed queue.
            try Task.checkCancellation()
            let current = try await controller.readInstallation()
            for item in batch {
                switch item.operation {
                case .get:
                    guard !current.installed.contains(where: { PluginBrowserFamilyID($0) == item.id }) else {
                        throw InstallationError.familyAlreadyInstalled
                    }
                case .reinstall(let selectedID):
                    guard current.installed.contains(where: { $0.id == selectedID && $0.package.bytes == item.package.bytes }) else {
                        throw PluginBrowserError.staleQueue
                    }
                }
            }
            if !requests.isEmpty {
                _ = try await controller.commitInstallationBatch(requests, expectedSelectionGeneration: current.selectionGeneration)
            }
            // No cancellation check after a confirmed publication, and no automatic retry of uncertain writes.
            queue.removeAll()
            queueCompletionCount = batch.count
            return true
        } catch {
            queueError = error
            return false
        }
    }

    nonisolated private static func validatedRequests(_ entries: [PluginQueuedPackage]) throws -> [InstallationRequest] {
        guard !entries.isEmpty, entries.count <= Limits.revisions,
              Set(entries.map(\.id)).count == entries.count else { throw InstallationError.duplicateFamily }
        return try entries.compactMap { item in
            try Task.checkCancellation()
            switch item.operation {
            case .get:
                guard let snapshot = item.snapshot, let generation = item.sourceGeneration,
                      let entry = snapshot.index.plugins.first(where: { $0.id == item.package.manifest.id }) else {
                    throw AutomationError.metadataMismatch
                }
                let checked = try PluginPackage.validate(item.package.bytes, against: entry)
                guard checked == item.package else { throw AutomationError.metadataMismatch }
                return InstallationRequest(package: checked, snapshot: snapshot, expectedSourceGeneration: generation, operation: .add)
            case .reinstall:
                guard try PluginPackage.validate(item.package.bytes) == item.package else { throw AutomationError.invalidManifest }
                return nil // Reinstall is validated against the exact selected bytes at the final state read.
            }
        }
    }

    func prepareUpdate(_ revision: InstalledRevision, record: RepositoryRecord) async -> PluginBrowserUpdate? {
        guard !isProcessing else { updateError = PluginBrowserError.busy; return nil }
        isProcessing = true; updateError = nil
        defer { isProcessing = false }
        do {
            let current = try await controller.readInstallation()
            guard current.installed.contains(where: { $0.id == revision.id && $0.package.bytes == revision.package.bytes }),
                  let snapshot = record.snapshot,
                  let entry = snapshot.index.plugins.first(where: { $0.id == revision.package.manifest.id }),
                  case .available = PluginUpdateComparison.compare(installed: revision, published: entry, repository: record.url) else {
                throw PluginBrowserError.updateUnavailable
            }
            let package = try await fetchPackage(entry: entry, record: record)
            return PluginBrowserUpdate(package: package, baseRevision: revision, expectedSelectionGeneration: current.selectionGeneration,
                                       expectedGrantGeneration: current.activation.generation,
                                       requiresApproval: current.activation.contains(revisionID: revision.id),
                                       request: InstallationRequest(package: package, snapshot: snapshot,
                                                                    expectedSourceGeneration: record.generation, operation: .add))
        } catch { updateError = error; return nil }
    }

    @discardableResult
    func commitUpdate(_ candidate: PluginBrowserUpdate, approval: InstallationApproval? = nil) async -> Bool {
        guard !isProcessing else { return false }
        isProcessing = true; updateError = nil
        defer { isProcessing = false }
        do {
            if candidate.requiresApproval {
                guard let approval, approval.packageBytes == candidate.package.bytes,
                      approval.expectedGrantGeneration == candidate.expectedGrantGeneration else { throw InstallationError.approvalRequired }
            }
            _ = try await controller.commitInstallationUpdate(candidate.request, baseRevisionID: candidate.baseRevision.id,
                                                               expectedSelectionGeneration: candidate.expectedSelectionGeneration, approval: approval)
            return true
        } catch { updateError = error; return false }
    }

    func refreshSources() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isRefreshing = true; refreshErrors = [:]
        defer { isRefreshing = false }
        await controller.refreshCatalog()
        if let error = controller.storeError { refreshErrors["catalog"] = error; return }
        let records = controller.repositories
        do { try await controller.retryDefaultRepository() }
        catch is CancellationError { return }
        catch { refreshErrors["default"] = error }
        for record in records {
            do {
                let snapshot = try await controller.client.preview(url: record.url, now: controller.now)
                try Task.checkCancellation()
                _ = try await controller.refreshRepository(snapshot, expectedGeneration: record.generation)
            } catch is CancellationError { return }
            catch { refreshErrors[record.url.canonical] = error }
        }
        await controller.refreshCatalog()
    }

    func categories(in record: RepositoryRecord) -> [PluginBrowserCategory] {
        _ = controller.packageCatalogRevision
        guard let current = currentRecord(record) else { return [] }
        do {
            guard let database = controller.packageCatalog else { throw PluginBrowserError.catalogUnavailable }
            let values = try database.categories(in: current)
            catalogReadError = nil
            return values.map { PluginBrowserCategory(name: $0.name, count: $0.count) }
        } catch { catalogReadError = error; return [] }
    }

    func catalogEntries(in record: RepositoryRecord, category: PluginBrowserCategory? = nil, query: String = "") -> [IndexEntry] {
        guard let current = currentRecord(record) else { return [] }
        let filter: PackageCatalogCategoryFilter = category.map { .category($0.name) } ?? .all
        return databaseRows(query: query, source: current.url.canonical, category: filter).compactMap { row in
            current.snapshot?.index.plugins.first { $0.id == row.manifestID }
        }
    }

    /// Membership and search are database predicates over the current source projection.
    func catalogPackages(in record: RepositoryRecord, category: PluginBrowserCategory, query: String = "") -> [PluginBrowserCatalogPackage] {
        guard let current = currentRecord(record) else { return [] }
        return projectedPackages(databaseRows(query: query, source: current.url.canonical, category: .category(category.name)))
    }

    func catalogPackages(query: String = "") -> [PluginBrowserCatalogPackage] {
        let listed = projectedPackages(databaseRows(query: query, source: nil, category: .all))
        // A display-store failure must not hide management of an authoritative selection.
        // Search and source/category membership always remain database operations.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return listed }
        let returned = Set(listed.map(\.id))
        let recovery: [PluginBrowserCatalogPackage] = controller.scripts.compactMap { selected in
            guard case .repository(let url, _) = selected.provenance.origin else { return nil }
            let family = PluginBrowserFamilyID(selected)
            guard !returned.contains(family) else { return nil }
            let record = controller.repositories.first { $0.url == url }
            let manifest = selected.package.manifest
            return PluginBrowserCatalogPackage(id: family,
                entry: record?.snapshot?.index.plugins.first { $0.id == family.manifestID },
                record: record, installed: selected, name: manifest.name, version: manifest.version,
                author: manifest.author, summary: manifest.summary)
        }
        guard !recovery.isEmpty else { return listed }
        return (listed + recovery).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.id.source != $1.id.source { return $0.id.source < $1.id.source }
            return $0.id.manifestID.uuidString < $1.id.manifestID.uuidString
        }
    }

    private func databaseRows(query: String, source: String?, category: PackageCatalogCategoryFilter) -> [PackageCatalogRow] {
        _ = controller.packageCatalogRevision
        do {
            guard let database = controller.packageCatalog else { throw PluginBrowserError.catalogUnavailable }
            let rows = try database.rows(visible: controller.repositories, installed: controller.scripts,
                                         query: query, source: source, category: category)
            catalogReadError = nil
            return rows
        } catch { catalogReadError = error; return [] }
    }

    private func projectedPackages(_ rows: [PackageCatalogRow]) -> [PluginBrowserCatalogPackage] {
        let records = Dictionary(controller.repositories.map { ($0.url.canonical, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = Dictionary(controller.scripts.map { (PluginBrowserFamilyID($0), $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            let record = records[row.source]
            let family = PluginBrowserFamilyID(source: row.source, manifestID: row.manifestID)
            return PluginBrowserCatalogPackage(id: family,
                entry: record?.snapshot?.index.plugins.first { $0.id == row.manifestID },
                record: record, installed: selected[family],
                name: row.name, version: row.version, author: row.author, summary: row.summary)
        }
    }

    private func currentRecord(_ record: RepositoryRecord) -> RepositoryRecord? {
        controller.catalog.record(for: record.url).flatMap { $0.visible ? $0 : nil }
    }

    func installedPackages(query: String = "") -> [InstalledRevision] {
        controller.scripts.filter { Self.matches(query, name: $0.package.manifest.name,
                                                author: $0.package.manifest.author, summary: $0.package.manifest.summary) }
    }

    func selectedRevision(for family: PluginBrowserFamilyID) -> InstalledRevision? {
        controller.scripts.first { PluginBrowserFamilyID($0) == family }
    }

    func updateComparison(for revision: InstalledRevision, record: RepositoryRecord) -> PluginUpdateComparison {
        let family = PluginBrowserFamilyID(revision)
        guard let selected = selectedRevision(for: family) else { return .notInstalled }
        let entry = currentRecord(record)?.snapshot?.index.plugins.first { $0.id == selected.package.manifest.id }
        return PluginUpdateComparison.compare(installed: selected, published: entry, repository: record.url)
    }

    private static func matches(_ query: String, name: String, author: String?, summary: String?) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || [name, author ?? "", summary ?? ""].contains { $0.localizedStandardContains(trimmed) }
    }

    nonisolated static func targetHosts(_ manifest: PluginManifest) -> [String] {
        Array(Set(manifest.matches.flatMap(\.hosts) + manifest.subscriptions.flatMap(\.hosts))).sorted()
    }

    nonisolated static func sourceFiles(in package: PluginPackage) -> [String] {
        package.manifest.schemaVersion == 2 ? package.sourceFiles.keys.sorted() : ["script.js"]
    }

    nonisolated static func matchingRules(in manifest: PluginManifest, file: String) -> [PluginBrowserRule] {
        PluginPackagePresentation.matchingRules(in: manifest, file: file)
    }
}
