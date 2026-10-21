import AutomationCore
import AutomationRepository
import Foundation
import Observation

struct PluginBrowserFamilyID: Hashable, Sendable {
    let source: String
    let manifestID: UUID

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

struct PluginBrowserRule: Equatable, Sendable {
    let hook: String
    let hosts: [String]
    let methods: [String]?
    let path: PluginSubscription.PathMatch?
    let status: ClosedRange<Int>?
}

struct PluginBrowserUpdate: Equatable, Sendable {
    let package: PluginPackage
    let baseRevision: InstalledRevision
    let expectedSelectionGeneration: UUID
    let expectedGrantGeneration: UUID
    let requiresApproval: Bool
    fileprivate let request: InstallationRequest
}

enum PluginBrowserError: Error, Equatable, Sendable {
    case busy, emptyQueue, queueLimit, staleQueue, updateUnavailable
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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(controller: AutomationController) { self.controller = controller }

    var canDismissQueue: Bool { !isProcessing }

    func fetchPackage(entry: IndexEntry, record: RepositoryRecord) async throws -> PluginPackage {
        guard let snapshot = record.snapshot, snapshot.index.plugins.contains(entry) else { throw AutomationError.staleSnapshot }
        let package = try await controller.client.fetchPackage(entry: entry, from: snapshot)
        try Task.checkCancellation()
        let checked = try await Task.detached(priority: .userInitiated) {
            try PluginPackage.validate(package.bytes, against: entry)
        }.value
        try Task.checkCancellation()
        return checked
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
            _ = try await controller.store.refresh(snapshot, expectedGeneration: record.generation,
                                                   acknowledgeUnverified: false, now: controller.now)
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
        for record in records {
            do {
                let snapshot = try await controller.client.preview(url: record.url, now: controller.now)
                try Task.checkCancellation()
                _ = try await controller.store.refresh(snapshot, expectedGeneration: record.generation,
                                                         acknowledgeUnverified: false, now: controller.now)
            } catch { refreshErrors[record.url.canonical] = error }
        }
        await controller.refreshCatalog()
    }

    func categories(in record: RepositoryRecord) -> [PluginBrowserCategory] {
        let entries = currentRecord(record)?.snapshot?.index.plugins ?? []
        let grouped = Dictionary(grouping: entries, by: \.category)
        return grouped.map { PluginBrowserCategory(name: $0.key, count: $0.value.count) }.sorted {
            guard let left = $0.name else { return false }
            guard let right = $1.name else { return true }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    func catalogEntries(in record: RepositoryRecord, category: PluginBrowserCategory? = nil, query: String = "") -> [IndexEntry] {
        let entries = currentRecord(record)?.snapshot?.index.plugins ?? []
        return entries.filter { entry in
            (category == nil || entry.category == category?.name) && Self.matches(query, name: entry.name, author: entry.author, summary: entry.summary)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Cached catalogs of all visible sources plus installed repository orphans. Never fetches.
    func catalogPackages(query: String = "") -> [PluginBrowserCatalogPackage] {
        let records = controller.repositories
        let installed = installedPackages().filter {
            if case .repository = $0.provenance.origin { return true }
            return false
        }
        let selectedByFamily = Dictionary(installed.map { (PluginBrowserFamilyID($0), $0) },
                                          uniquingKeysWith: { first, _ in first })
        var rows: [PluginBrowserCatalogPackage] = []
        var listed = Set<PluginBrowserFamilyID>()
        for record in records {
            for entry in record.snapshot?.index.plugins ?? [] {
                let family = PluginBrowserFamilyID(repository: record.url, manifestID: entry.id)
                guard listed.insert(family).inserted else { continue }
                let selected = selectedByFamily[family]
                let manifest = selected?.package.manifest
                rows.append(PluginBrowserCatalogPackage(
                    id: family, entry: entry, record: record, installed: selected,
                    name: manifest?.name ?? entry.name, version: manifest?.version ?? entry.version,
                    author: selected == nil ? entry.author : manifest?.author,
                    summary: selected == nil ? entry.summary : manifest?.summary,
                ))
            }
        }
        for revision in installed {
            let family = PluginBrowserFamilyID(revision)
            guard listed.insert(family).inserted else { continue }
            let manifest = revision.package.manifest
            rows.append(PluginBrowserCatalogPackage(
                id: family, entry: nil, record: records.first { $0.url.canonical == family.source }, installed: revision,
                name: manifest.name, version: manifest.version, author: manifest.author, summary: manifest.summary,
            ))
        }
        return rows.filter { Self.matches(query, name: $0.name, author: $0.author, summary: $0.summary) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.id.source != $1.id.source { return $0.id.source < $1.id.source }
            return $0.id.manifestID.uuidString < $1.id.manifestID.uuidString
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
        if manifest.schemaVersion == 2 {
            return manifest.matches.flatMap { match in
                match.hooks.keys.sorted().filter { match.hooks[$0] == file }.map {
                    PluginBrowserRule(hook: $0, hosts: match.hosts, methods: match.methods, path: match.path, status: match.status)
                }
            }
        }
        guard file == "script.js" else { return [] }
        return manifest.subscriptions.map { .init(hook: $0.phase.rawValue, hosts: $0.hosts, methods: $0.methods, path: $0.path, status: $0.status) }
    }
}
