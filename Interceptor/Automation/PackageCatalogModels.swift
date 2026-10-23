import AutomationCore
import Foundation
import SwiftData

// Persistent package catalog projection. Core (AutomationStore) stays the authority; these rows are display/content only.

enum PackageCatalogSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CatalogSnapshotModel.self, CatalogEntryModel.self, CatalogDetailModel.self, CatalogContentModel.self, CatalogLeaseModel.self]
    }
}

enum PackageCatalogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PackageCatalogSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// One accepted source snapshot, addressed by canonical URL + repository UUID + payload digest.
@Model
final class CatalogSnapshotModel {
    @Attribute(.unique) var key: String
    var sourceURL: String
    var repositoryID: UUID
    var digest: String
    var entryCount: Int
    var createdAt: Date

    init(key: String, sourceURL: String, repositoryID: UUID, digest: String, entryCount: Int, createdAt: Date) {
        self.key = key; self.sourceURL = sourceURL; self.repositoryID = repositoryID; self.digest = digest
        self.entryCount = entryCount; self.createdAt = createdAt
    }
}

/// List/search row for one index entry of one snapshot (or one installed orphan). Never holds raw bytes.
@Model
final class CatalogEntryModel {
    @Attribute(.unique) var key: String
    /// `PackageCatalogKeys.orphan` (empty) for installed repository packages whose source or entry is gone.
    var snapshotKey: String
    var sourceURL: String
    var repositoryID: UUID
    var digest: String
    var entryID: UUID
    /// Typed detail and raw bytes for `sha256` are stored.
    var complete: Bool
    var indexName: String
    var indexVersion: String
    var indexAuthor: String?
    var indexSummary: String?
    var category: String?
    /// `category ?? ""`, so category filters are plain string predicates.
    var categoryKey: String
    var packagePath: String
    var sha256: String
    var size: Int
    /// Materialized effective fields: the selected installed manifest when installed (nil stays nil), else the index.
    var displayName: String
    var displayVersion: String
    var displayAuthor: String?
    var displaySummary: String?
    /// `InstalledRevision.id` this projection was computed for; nil when nothing is installed.
    var installedKey: String?
    var searchKey: String

    init(snapshotKey: String, snapshot: VerifiedSnapshot, entry: IndexEntry, complete: Bool) {
        key = PackageCatalogKeys.entry(snapshotKey: snapshotKey, id: entry.id)
        self.snapshotKey = snapshotKey; sourceURL = snapshot.url.canonical; repositoryID = snapshot.index.id
        digest = snapshot.payloadDigest; entryID = entry.id; self.complete = complete
        indexName = entry.name; indexVersion = entry.version; indexAuthor = entry.author; indexSummary = entry.summary
        category = entry.category; categoryKey = entry.category ?? ""
        packagePath = entry.packagePath; sha256 = entry.sha256; size = entry.size
        displayName = entry.name; displayVersion = entry.version; displayAuthor = entry.author; displaySummary = entry.summary
        installedKey = nil
        searchKey = PackageCatalogText.searchKey(name: entry.name, author: entry.author, summary: entry.summary)
    }

    /// Installed repository package without a current visible entry; appears in global listings only.
    init(orphan revision: InstalledRevision, source: String) {
        let m = revision.package.manifest
        key = PackageCatalogKeys.orphanEntry(source: source, id: m.id)
        snapshotKey = PackageCatalogKeys.orphan; sourceURL = source; repositoryID = PackageCatalogKeys.nilUUID
        digest = ""; entryID = m.id; complete = true
        indexName = m.name; indexVersion = m.version; indexAuthor = m.author; indexSummary = m.summary
        category = m.category; categoryKey = m.category ?? ""
        packagePath = ""; sha256 = revision.package.revision; size = revision.package.bytes.count
        displayName = m.name; displayVersion = m.version; displayAuthor = m.author; displaySummary = m.summary
        installedKey = revision.id
        searchKey = PackageCatalogText.searchKey(name: m.name, author: m.author, summary: m.summary)
    }

    /// Recomputes index fields and effective display fields. Untouched values are not reassigned.
    func project(_ entry: IndexEntry, installed: InstalledRevision?) {
        let fields = PackageCatalogText.effective(entry, installed: installed)
        if indexName != entry.name { indexName = entry.name }
        if indexVersion != entry.version { indexVersion = entry.version }
        if indexAuthor != entry.author { indexAuthor = entry.author }
        if indexSummary != entry.summary { indexSummary = entry.summary }
        if category != entry.category { category = entry.category; categoryKey = entry.category ?? "" }
        if packagePath != entry.packagePath { packagePath = entry.packagePath }
        if sha256 != entry.sha256 { sha256 = entry.sha256 }
        if size != entry.size { size = entry.size }
        if displayName != fields.name { displayName = fields.name }
        if displayVersion != fields.version { displayVersion = fields.version }
        if displayAuthor != fields.author { displayAuthor = fields.author }
        if displaySummary != fields.summary { displaySummary = fields.summary }
        let search = PackageCatalogText.searchKey(name: fields.name, author: fields.author, summary: fields.summary)
        if searchKey != search { searchKey = search }
        if installedKey != installed?.id { installedKey = installed?.id }
    }

    var row: PackageCatalogRow {
        PackageCatalogRow(source: sourceURL, repositoryID: repositoryID, payloadDigest: digest, manifestID: entryID,
                          name: displayName, version: displayVersion, author: displayAuthor, summary: displaySummary,
                          category: category, complete: complete)
    }
}

/// Typed presentation for one package payload, shared by every entry with the same SHA-256.
@Model
final class CatalogDetailModel {
    @Attribute(.unique) var sha256: String
    var manifestID: UUID
    var schemaVersion: Int64
    var name: String
    var version: String
    var author: String?
    var summary: String?
    var category: String?
    var publishedAt: Date?
    var targetHosts: [String]
    var source: String?
    var manifestJSON: String
    var sourceFileNames: [String]
    var filesData: Data
    var rulesData: Data

    init(sha256: String, presentation p: PluginPackagePresentation) throws {
        self.sha256 = sha256
        manifestID = p.manifest.id; schemaVersion = p.manifest.schemaVersion; name = p.manifest.name
        version = p.manifest.version; author = p.manifest.author; summary = p.manifest.summary
        category = p.manifest.category; publishedAt = p.manifest.publishedAt; targetHosts = p.manifest.targetHosts
        source = p.source; manifestJSON = p.manifestJSON; sourceFileNames = p.sourceFileNames
        let encoder = JSONEncoder()
        filesData = try encoder.encode(p.sourceFiles)
        rulesData = try encoder.encode(p.rulesByFile.mapValues { $0.map(PackageCatalogStoredRule.init) })
    }

    /// Repair only from a newly validated package; reads never rewrite cached presentation data.
    func project(_ p: PluginPackagePresentation) throws {
        manifestID = p.manifest.id; schemaVersion = p.manifest.schemaVersion; name = p.manifest.name
        version = p.manifest.version; author = p.manifest.author; summary = p.manifest.summary
        category = p.manifest.category; publishedAt = p.manifest.publishedAt; targetHosts = p.manifest.targetHosts
        source = p.source; manifestJSON = p.manifestJSON; sourceFileNames = p.sourceFileNames
        let encoder = JSONEncoder()
        filesData = try encoder.encode(p.sourceFiles)
        rulesData = try encoder.encode(p.rulesByFile.mapValues { $0.map(PackageCatalogStoredRule.init) })
    }

    func presentation() throws -> PluginPackagePresentation {
        let decoder = JSONDecoder()
        let files = try decoder.decode([String: String].self, from: filesData)
        let rules = try decoder.decode([String: [PackageCatalogStoredRule]].self, from: rulesData).mapValues { $0.map(\.rule) }
        return PluginPackagePresentation(
            manifest: .init(id: manifestID, schemaVersion: schemaVersion, name: name, version: version, author: author,
                            summary: summary, category: category, publishedAt: publishedAt, targetHosts: targetHosts),
            source: source, sourceFiles: files, manifestJSON: manifestJSON, rulesByFile: rules,
            sourceFileNames: sourceFileNames, isComplete: true)
    }
}

/// Exact raw package bytes, content addressed. Kept apart from list/detail rows.
@Model
final class CatalogContentModel {
    @Attribute(.unique) var sha256: String
    var size: Int
    @Attribute(.externalStorage) var bytes: Data

    init(sha256: String, bytes: Data) { self.sha256 = sha256; size = bytes.count; self.bytes = bytes }
}

/// Protects a staged snapshot until its live owner finishes; abandoned leases expire after restart.
@Model
final class CatalogLeaseModel {
    @Attribute(.unique) var key: String
    var leaseID: UUID
    var snapshotKey: String
    var expiresAt: Date

    init(leaseID: UUID, snapshotKey: String, expiresAt: Date) {
        key = leaseID.uuidString + "|" + snapshotKey; self.leaseID = leaseID; self.snapshotKey = snapshotKey; self.expiresAt = expiresAt
    }
}

struct PackageCatalogStoredRule: Codable {
    var hook: String
    var hosts: [String]
    var methods: [String]?
    var pathKind: String?
    var pathValue: String?
    var statusLower: Int?
    var statusUpper: Int?

    init(_ rule: PackageCatalogRule) {
        hook = rule.hook; hosts = rule.hosts; methods = rule.methods
        switch rule.path {
        case .exact(let v)?: pathKind = "exact"; pathValue = v
        case .prefix(let v)?: pathKind = "prefix"; pathValue = v
        case nil: break
        }
        statusLower = rule.status?.lowerBound; statusUpper = rule.status?.upperBound
    }

    var rule: PackageCatalogRule {
        let path: PluginSubscription.PathMatch?
        switch (pathKind, pathValue) {
        case ("exact"?, let v?): path = .exact(v)
        case ("prefix"?, let v?): path = .prefix(v)
        default: path = nil
        }
        let status: ClosedRange<Int>?
        if let lo = statusLower, let hi = statusUpper, lo <= hi { status = lo ... hi } else { status = nil }
        return PackageCatalogRule(hook: hook, hosts: hosts, methods: methods, path: path, status: status)
    }
}

enum PackageCatalogError: Error, Equatable, Sendable {
    case invalidSnapshot, limitExceeded, contentMismatch
}

enum PackageCatalogKeys {
    static let orphan = ""
    static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func snapshot(_ s: VerifiedSnapshot) -> String {
        s.url.canonical + "|" + s.index.id.uuidString + "|" + s.payloadDigest
    }

    /// Only visible records that carry an accepted snapshot are addressable.
    static func snapshot(_ r: RepositoryRecord) -> String? {
        guard r.visible, let s = r.snapshot else { return nil }
        return snapshot(s)
    }

    static func entry(snapshotKey: String, id: UUID) -> String { snapshotKey + "|" + id.uuidString }

    static func orphanEntry(source: String, id: UUID) -> String { "orphan|" + source + "|" + id.uuidString }

    static func family(source: String, id: UUID) -> String { source + "|" + id.uuidString }

    /// Installed repository revisions by source-qualified family; the first revision per family is the selected one.
    static func selectedInstalled(_ installed: [InstalledRevision]) -> [String: InstalledRevision] {
        var result: [String: InstalledRevision] = [:]
        for revision in installed {
            guard case .repository(let url, _) = revision.provenance.origin else { continue }
            let family = family(source: url.canonical, id: revision.package.manifest.id)
            if result[family] == nil { result[family] = revision }
        }
        return result
    }
}

enum PackageCatalogText {
    static let separator = "\u{1F}"

    /// Case, diacritic and width insensitive, matching what `localizedStandardContains` ignores.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func searchKey(name: String, author: String?, summary: String?) -> String {
        [name, author ?? "", summary ?? ""].map(fold).joined(separator: separator)
    }

    static func normalizedQuery(_ query: String) -> String {
        fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Selected installed manifest wins; a nil installed author/summary stays nil.
    static func effective(_ entry: IndexEntry, installed: InstalledRevision?)
        -> (name: String, version: String, author: String?, summary: String?)
    {
        guard let manifest = installed?.package.manifest else { return (entry.name, entry.version, entry.author, entry.summary) }
        return (manifest.name, manifest.version, manifest.author, manifest.summary)
    }

}
