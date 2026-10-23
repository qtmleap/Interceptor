import AutomationCore
import Foundation
import SwiftData

enum PackageCatalogCategoryFilter: Equatable, Sendable {
    case all
    /// `nil` selects uncategorized packages.
    case category(String?)
}

/// One Packages row from the database. `complete` is false for index-only (seeded) rows without stored content.
struct PackageCatalogRow: Equatable, Sendable {
    let source: String
    let repositoryID: UUID
    let payloadDigest: String
    let manifestID: UUID
    let name: String
    let version: String
    let author: String?
    let summary: String?
    let category: String?
    let complete: Bool
}

struct PackageCatalogCategory: Equatable, Sendable {
    let name: String?
    let count: Int
}

/// Persistent display/content projection of accepted repository snapshots. Never fetches, validates packages or installs.
/// Reads are synchronous and use a fresh context on the main actor. Writes run on a serialized background writer.
@MainActor
protocol PackageCatalogStoring: AnyObject {
    /// Stages one snapshot's validated packages under a lease, before the authoritative accept/refresh commit.
    func stage(_ snapshot: VerifiedSnapshot, packages: [PluginPackage], leaseID: UUID) async throws
    /// Seeds index-only rows for visible sources offline, materializes effective display fields and installed orphans.
    /// A `receipt` older than one already applied by this instance is ignored.
    func synchronize(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) async throws
    /// Releases the lease and prunes content unreferenced by `visible` and other unexpired leases.
    func finish(leaseID: UUID, visible: [RepositoryRecord]) async throws

    func rows(visible: [RepositoryRecord], installed: [InstalledRevision], query: String, source: String?,
              category: PackageCatalogCategoryFilter) throws -> [PackageCatalogRow]
    func categories(in record: RepositoryRecord) throws -> [PackageCatalogCategory]
    func detail(in record: RepositoryRecord, entryID: UUID) throws -> PluginPackagePresentation?
    func packageBytes(in record: RepositoryRecord, entry: IndexEntry) throws -> Data?
    func reusableBytes(sha256: String) throws -> Data?
    func isComplete(_ snapshot: VerifiedSnapshot) throws -> Bool
}

/// SwiftData-backed `PackageCatalogStoring`, separate from the traffic database.
/// `url` is the directory holding `packages.store`; it is created protected and excluded from backup.
@MainActor
final class PackageCatalogDatabase: PackageCatalogStoring {
    nonisolated static let storeName = "packages.store"

    nonisolated let url: URL
    nonisolated var storeURL: URL { url.appendingPathComponent(Self.storeName) }
    private let container: ModelContainer
    private let writer: PackageCatalogWriter
    private let inMemory: Bool

    init(url: URL, inMemory: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
         leaseDuration: TimeInterval = 1800) throws
    {
        self.url = url
        self.inMemory = inMemory
        let schema = Schema(versionedSchema: PackageCatalogSchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("PackageCatalog-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        } else {
            try Self.prepareDirectory(url)
            configuration = ModelConfiguration("PackageCatalog", schema: schema, url: url.appendingPathComponent(Self.storeName),
                                               allowsSave: true, cloudKitDatabase: .none)
        }
        // Errors propagate untouched: a failing store is never deleted, reset or recreated here.
        let container = try ModelContainer(for: schema, migrationPlan: PackageCatalogMigrationPlan.self, configurations: configuration)
        self.container = container
        writer = PackageCatalogWriter(container: container, now: now, leaseDuration: leaseDuration)
        if !inMemory { try Self.protectContents(of: url) }
    }

    // MARK: Writes

    func stage(_ snapshot: VerifiedSnapshot, packages: [PluginPackage], leaseID: UUID) async throws {
        try await writer.stage(snapshot, packages: packages, leaseID: leaseID)
        if !inMemory { try Self.protectContents(of: url) }
    }

    func synchronize(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) async throws {
        try await writer.synchronize(visible: visible, installed: installed, receipt: receipt)
        if !inMemory { try Self.protectContents(of: url) }
    }

    func finish(leaseID: UUID, visible: [RepositoryRecord]) async throws {
        try await writer.finish(leaseID: leaseID, visible: visible)
    }

    // MARK: Reads

    private func readContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func rows(visible: [RepositoryRecord], installed: [InstalledRevision], query: String, source: String?,
              category: PackageCatalogCategoryFilter) throws -> [PackageCatalogRow]
    {
        let keys = visible.compactMap(PackageCatalogKeys.snapshot)
        let selected = PackageCatalogKeys.selectedInstalled(installed)
        let visibleFamilies = Set(visible.flatMap { record in
            (record.snapshot?.index.plugins ?? []).map { PackageCatalogKeys.family(source: record.url.canonical, id: $0.id) }
        })
        let normalized = PackageCatalogText.normalizedQuery(query).replacingOccurrences(of: PackageCatalogText.separator, with: "")
        let hasQuery = !normalized.isEmpty
        let filterSource = source != nil, sourceValue = source ?? ""
        var filterCategory = false, categoryValue = ""
        if case .category(let name) = category { filterCategory = true; categoryValue = name ?? "" }
        let includeOrphans = source == nil
        let orphanKey = PackageCatalogKeys.orphan

        let predicate = #Predicate<CatalogEntryModel> { entry in
            (keys.contains(entry.snapshotKey) || (includeOrphans && entry.snapshotKey == orphanKey))
                && (!filterSource || entry.sourceURL == sourceValue)
                && (!filterCategory || entry.categoryKey == categoryValue)
                && (!hasQuery || entry.searchKey.contains(normalized))
        }
        let descriptor = FetchDescriptor<CatalogEntryModel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.displayName, comparator: .localizedStandard), SortDescriptor(\.sourceURL), SortDescriptor(\.key)])
        let models = try readContext().fetch(descriptor)

        return models.compactMap { model in
            let family = PackageCatalogKeys.family(source: model.sourceURL, id: model.entryID)
            let expected = selected[family]
            // Queries never repair or search a stale installed projection in memory.
            // The controller synchronizes it before publishing a new selected state.
            guard model.installedKey == expected?.id else { return nil }
            if model.snapshotKey == PackageCatalogKeys.orphan {
                guard expected != nil, !visibleFamilies.contains(family) else { return nil }
            }
            return model.row
        }
    }

    func categories(in record: RepositoryRecord) throws -> [PackageCatalogCategory] {
        guard let key = PackageCatalogKeys.snapshot(record) else { return [] }
        let models = try readContext().fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.snapshotKey == key }))
        var counts: [String?: Int] = [:]
        for model in models { counts[model.category, default: 0] += 1 }
        return counts.map { PackageCatalogCategory(name: $0.key, count: $0.value) }.sorted {
            guard let left = $0.name else { return false }
            guard let right = $1.name else { return true }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    func detail(in record: RepositoryRecord, entryID: UUID) throws -> PluginPackagePresentation? {
        guard let snapshotKey = PackageCatalogKeys.snapshot(record) else { return nil }
        let context = readContext()
        guard let entry = try entryModel(PackageCatalogKeys.entry(snapshotKey: snapshotKey, id: entryID), in: context) else { return nil }
        if entry.complete {
            let sha = entry.sha256
            if let detail = try context.fetch(FetchDescriptor<CatalogDetailModel>(predicate: #Predicate { $0.sha256 == sha })).first {
                return try detail.presentation()
            }
        }
        // Index-only: finite partial metadata from the stored index fields. No network, no validation.
        return PluginPackagePresentation(
            manifest: .init(id: entry.entryID, schemaVersion: 0, name: entry.indexName, version: entry.indexVersion,
                            author: entry.indexAuthor, summary: entry.indexSummary, category: entry.category,
                            publishedAt: nil, targetHosts: []),
            source: nil, sourceFiles: [:], manifestJSON: "", rulesByFile: [:], sourceFileNames: [], isComplete: false)
    }

    func packageBytes(in record: RepositoryRecord, entry: IndexEntry) throws -> Data? {
        guard let snapshotKey = PackageCatalogKeys.snapshot(record),
              record.snapshot?.index.plugins.contains(entry) == true else { return nil }
        let context = readContext()
        guard let model = try entryModel(PackageCatalogKeys.entry(snapshotKey: snapshotKey, id: entry.id), in: context),
              model.sha256 == entry.sha256 else { return nil }
        return try content(sha256: entry.sha256, size: entry.size, in: context)
    }

    func reusableBytes(sha256: String) throws -> Data? {
        try content(sha256: sha256, size: nil, in: readContext())
    }

    func isComplete(_ snapshot: VerifiedSnapshot) throws -> Bool {
        let context = readContext()
        let snapshotKey = PackageCatalogKeys.snapshot(snapshot)
        let entries = try context.fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.snapshotKey == snapshotKey }))
        let byID = Dictionary(entries.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        guard entries.count == snapshot.index.plugins.count else { return false }
        for plugin in snapshot.index.plugins {
            guard let model = byID[plugin.id], model.complete, model.sha256 == plugin.sha256, model.size == plugin.size else { return false }
            let sha = plugin.sha256
            guard try context.fetchCount(FetchDescriptor<CatalogContentModel>(predicate: #Predicate { $0.sha256 == sha })) == 1,
                  try context.fetchCount(FetchDescriptor<CatalogDetailModel>(predicate: #Predicate { $0.sha256 == sha })) == 1
            else { return false }
        }
        return true
    }

    private func entryModel(_ key: String, in context: ModelContext) throws -> CatalogEntryModel? {
        try context.fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.key == key })).first
    }

    /// Bytes are only returned when they still hash to their address; callers revalidate against the trusted index anyway.
    private func content(sha256: String, size: Int?, in context: ModelContext) throws -> Data? {
        guard let model = try context.fetch(FetchDescriptor<CatalogContentModel>(predicate: #Predicate { $0.sha256 == sha256 })).first,
              size == nil || model.bytes.count == size, Digest.sha256Hex(model.bytes) == sha256 else { return nil }
        return model.bytes
    }

    // MARK: File protection

    nonisolated private static func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        // Protection is requested at creation so the store and its sidecars never exist unprotected.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protectionAttributes)
        try protect(directory)
    }

    /// Re-applies protection and backup exclusion to the store, WAL/SHM sidecars and external storage.
    nonisolated private static func protectContents(of directory: URL) throws {
        try protect(directory)
        let manager = FileManager.default
        guard let items = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            do { try protect(item) } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
        }
    }

    nonisolated private static func protect(_ item: URL) throws {
        var target = item
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        if let attributes = protectionAttributes {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: item.path)
        }
    }

    nonisolated private static var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }
}

/// Serialized writer. Contexts are created on this actor's executor and never leave it; writes never await.
actor PackageCatalogWriter {
    private let container: ModelContainer
    private let now: @Sendable () -> Date
    private let leaseDuration: TimeInterval
    private var lastReceipt: UInt64?
    /// Protect the newest published projection if another cleanup delivers an older Core read.
    private var synchronizedSnapshots = Set<String>()
    /// A live publisher owns its staged bytes until it explicitly finishes, even across suspension.
    /// Persisted leases from an earlier process have no live owner and can expire normally.
    private var activeLeaseIDs = Set<UUID>()

    init(container: ModelContainer, now: @escaping @Sendable () -> Date, leaseDuration: TimeInterval) {
        self.container = container
        self.now = now
        self.leaseDuration = leaseDuration
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func stage(_ snapshot: VerifiedSnapshot, packages: [PluginPackage], leaseID: UUID) throws {
        let plugins = snapshot.index.plugins
        guard plugins.count <= Limits.plugins, packages.count == plugins.count else { throw PackageCatalogError.invalidSnapshot }
        let byID = Dictionary(packages.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byID.count == packages.count else { throw PackageCatalogError.invalidSnapshot }

        // Everything is checked and mapped before any row is written; nothing here can reach the network.
        var staged: [(entry: IndexEntry, presentation: PluginPackagePresentation, package: PluginPackage)] = []
        for entry in plugins {
            guard let package = byID[entry.id] else { throw PackageCatalogError.invalidSnapshot }
            let manifest = package.manifest
            guard package.bytes.count == entry.size, package.bytes.count <= Limits.package, package.revision == entry.sha256,
                  manifest.name == entry.name, manifest.version == entry.version,
                  entry.author == nil || entry.author == manifest.author,
                  entry.summary == nil || entry.summary == manifest.summary,
                  entry.category == nil || entry.category == manifest.category
            else { throw PackageCatalogError.contentMismatch }
            staged.append((entry, PluginPackagePresentation(package), package))
        }

        let context = makeContext()
        let snapshotKey = PackageCatalogKeys.snapshot(snapshot)
        try ensureSnapshot(snapshot, key: snapshotKey, in: context)
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.snapshotKey == snapshotKey })).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first })
        for item in staged {
            try storeContent(item.package, presentation: item.presentation, in: context)
            let key = PackageCatalogKeys.entry(snapshotKey: snapshotKey, id: item.entry.id)
            if let model = existing[key] {
                if !model.complete { model.complete = true }
            } else {
                context.insert(CatalogEntryModel(snapshotKey: snapshotKey, snapshot: snapshot, entry: item.entry, complete: true))
            }
        }
        let leaseKey = leaseID.uuidString + "|" + snapshotKey
        let expiry = now().addingTimeInterval(leaseDuration)
        if let lease = try context.fetch(FetchDescriptor<CatalogLeaseModel>(predicate: #Predicate { $0.key == leaseKey })).first {
            lease.expiresAt = expiry
        } else {
            context.insert(CatalogLeaseModel(leaseID: leaseID, snapshotKey: snapshotKey, expiresAt: expiry))
        }
        try context.save()
        activeLeaseIDs.insert(leaseID)
    }

    func synchronize(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) throws {
        if let lastReceipt, receipt < lastReceipt { return }
        let selected = PackageCatalogKeys.selectedInstalled(installed)
        let sources = visible.compactMap { record -> (RepositoryRecord, VerifiedSnapshot, String)? in
            guard let snapshot = record.snapshot, let key = PackageCatalogKeys.snapshot(record) else { return nil }
            return (record, snapshot, key)
        }

        let context = makeContext()
        var available = try availableContent(
            for: sources.flatMap { $0.1.index.plugins.map(\.sha256) } + selected.values.map(\.package.revision), in: context)
        var visibleFamilies = Set<String>()
        for (record, snapshot, snapshotKey) in sources {
            try ensureSnapshot(snapshot, key: snapshotKey, in: context)
            let existing = Dictionary(
                try context.fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.snapshotKey == snapshotKey })).map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first })
            for entry in snapshot.index.plugins {
                let family = PackageCatalogKeys.family(source: record.url.canonical, id: entry.id)
                visibleFamilies.insert(family)
                let installedRevision = selected[family]
                // Selected bytes can also repair present-but-corrupt content offline.
                if let installedRevision, installedRevision.package.revision == entry.sha256 {
                    try storeContent(installedRevision.package, presentation: PluginPackagePresentation(installedRevision.package), in: context)
                    available.insert(entry.sha256)
                }
                let key = PackageCatalogKeys.entry(snapshotKey: snapshotKey, id: entry.id)
                let model: CatalogEntryModel
                if let found = existing[key] {
                    model = found
                } else {
                    model = CatalogEntryModel(snapshotKey: snapshotKey, snapshot: snapshot, entry: entry, complete: false)
                    context.insert(model)
                }
                model.project(entry, installed: installedRevision)
                let complete = available.contains(entry.sha256)
                if model.complete != complete { model.complete = complete }
            }
        }

        // Installed repository packages without a visible source entry stay globally listed, identified by source + UUID.
        for orphan in try context.fetch(FetchDescriptor<CatalogEntryModel>(predicate: #Predicate { $0.snapshotKey == "" })) {
            context.delete(orphan)
        }
        for (family, revision) in selected where !visibleFamilies.contains(family) {
            guard case .repository(let url, _) = revision.provenance.origin else { continue }
            context.insert(CatalogEntryModel(orphan: revision, source: url.canonical))
        }
        try context.save()
        lastReceipt = receipt
        synchronizedSnapshots = Set(sources.map { $0.2 })
    }

    func finish(leaseID: UUID, visible: [RepositoryRecord]) throws {
        let context = makeContext()
        let current = now()
        var protected = Set(visible.compactMap(PackageCatalogKeys.snapshot)).union(synchronizedSnapshots)
        for lease in try context.fetch(FetchDescriptor<CatalogLeaseModel>()) {
            if lease.leaseID == leaseID || (!activeLeaseIDs.contains(lease.leaseID) && lease.expiresAt <= current) {
                context.delete(lease)
            } else {
                protected.insert(lease.snapshotKey)
            }
        }
        for snapshot in try context.fetch(FetchDescriptor<CatalogSnapshotModel>()) where !protected.contains(snapshot.key) {
            context.delete(snapshot)
        }
        var referenced = Set<String>()
        for entry in try context.fetch(FetchDescriptor<CatalogEntryModel>()) {
            if entry.snapshotKey == PackageCatalogKeys.orphan || protected.contains(entry.snapshotKey) {
                referenced.insert(entry.sha256)
            } else {
                context.delete(entry)
            }
        }
        for content in try context.fetch(FetchDescriptor<CatalogContentModel>()) where !referenced.contains(content.sha256) {
            context.delete(content)
        }
        for detail in try context.fetch(FetchDescriptor<CatalogDetailModel>()) where !referenced.contains(detail.sha256) {
            context.delete(detail)
        }
        try context.save()
        activeLeaseIDs.remove(leaseID)
    }

    // MARK: Helpers

    private func ensureSnapshot(_ snapshot: VerifiedSnapshot, key: String, in context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<CatalogSnapshotModel>(predicate: #Predicate { $0.key == key })) == 0 else { return }
        context.insert(CatalogSnapshotModel(key: key, sourceURL: snapshot.url.canonical, repositoryID: snapshot.index.id,
                                            digest: snapshot.payloadDigest, entryCount: snapshot.index.plugins.count, createdAt: now()))
    }

    /// Digests that already have both raw bytes and typed detail stored.
    private func availableContent(for digests: [String], in context: ModelContext) throws -> Set<String> {
        let wanted = Array(Set(digests))
        guard !wanted.isEmpty else { return [] }
        var contentDescriptor = FetchDescriptor<CatalogContentModel>(predicate: #Predicate { wanted.contains($0.sha256) })
        contentDescriptor.propertiesToFetch = [\.sha256]
        var detailDescriptor = FetchDescriptor<CatalogDetailModel>(predicate: #Predicate { wanted.contains($0.sha256) })
        detailDescriptor.propertiesToFetch = [\.sha256]
        let contents = Set(try context.fetch(contentDescriptor).map(\.sha256))
        let details = Set(try context.fetch(detailDescriptor).map(\.sha256))
        return contents.intersection(details)
    }

    private func storeContent(_ package: PluginPackage, presentation: PluginPackagePresentation, in context: ModelContext) throws {
        let sha = package.revision
        if let raw = try context.fetch(FetchDescriptor<CatalogContentModel>(predicate: #Predicate { $0.sha256 == sha })).first {
            if raw.bytes != package.bytes { raw.bytes = package.bytes }
            if raw.size != package.bytes.count { raw.size = package.bytes.count }
        } else {
            context.insert(CatalogContentModel(sha256: sha, bytes: package.bytes))
        }
        if let detail = try context.fetch(FetchDescriptor<CatalogDetailModel>(predicate: #Predicate { $0.sha256 == sha })).first {
            if (try? detail.presentation()) != presentation { try detail.project(presentation) }
        } else {
            context.insert(try CatalogDetailModel(sha256: sha, presentation: presentation))
        }
    }
}
