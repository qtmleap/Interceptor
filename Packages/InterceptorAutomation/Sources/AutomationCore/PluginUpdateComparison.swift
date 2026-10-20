import Foundation

/// Pure comparison of an installed revision with the entry a repository currently lists for it.
/// The caller must already have fetched and validated the repository (trust, time, current generation);
/// this performs no persistence, fetching, acceptance, installation or approval.
public enum PluginUpdateComparison: Equatable, Sendable {
    case current
    case available(version: String)
    /// Same or equal-precedence version with different package bytes (republish, or build-metadata-only change).
    /// Never an automatic update.
    case changedContent(version: String)
    case older(version: String)
    case notListed
    /// The repository lists the manifest but no revision of it has been imported from this repository.
    case notInstalled
    case unrelated
    case invalidMetadata

    public static func compare(installed: InstalledRevision, published: IndexEntry?, repository: RepositoryURL) -> PluginUpdateComparison {
        guard case .repository(let url, _) = installed.provenance.origin, url == repository else { return .unrelated }
        let manifest = installed.package.manifest
        guard let published else { return .notListed }
        guard published.id == manifest.id else { return .unrelated }
        guard let installedVersion = try? SemVer(parsing: manifest.version),
              let publishedVersion = try? SemVer(parsing: published.version) else { return .invalidMetadata }
        let sameDigest = installed.package.revision == published.sha256
        if sameDigest {
            // The listed digest pins these bytes, so the listed metadata must agree with them.
            guard published.version == manifest.version, published.name == manifest.name,
                  published.size == installed.package.bytes.count else { return .invalidMetadata }
            return .current
        }
        switch publishedVersion.comparePrecedence(to: installedVersion) {
        case .orderedDescending: return .available(version: published.version)
        case .orderedAscending: return .older(version: published.version)
        case .orderedSame: return .changedContent(version: published.version)
        }
    }

    /// Aggregates every imported revision of one manifest family (same repository and manifest ID), so a newer
    /// revision that is already imported does not keep reporting an update. Imported is not the same as active.
    public static func compare(installed: [InstalledRevision], manifestID: UUID, published: IndexEntry?, repository: RepositoryURL) -> PluginUpdateComparison {
        if let published, published.id != manifestID { return .unrelated }
        guard let published else { return .notListed }
        let related = installed.filter {
            guard case .repository(let url, _) = $0.provenance.origin else { return false }
            return url == repository && $0.package.manifest.id == manifestID
        }
        guard !related.isEmpty else { return .notInstalled }
        let results = related.map { compare(installed: $0, published: published, repository: repository) }
        if results.contains(.current) { return .current }
        // A listed digest we already hold whose metadata disagrees with the bytes is never an update.
        if results.contains(.invalidMetadata), related.contains(where: { $0.package.revision == published.sha256 }) { return .invalidMetadata }
        var highest: InstalledRevision?
        var highestVersion: SemVer?
        for revision in related {
            guard let version = try? SemVer(parsing: revision.package.manifest.version) else { return .invalidMetadata }
            if let current = highestVersion, version.comparePrecedence(to: current) != .orderedDescending { continue }
            highest = revision
            highestVersion = version
        }
        guard let highest else { return .invalidMetadata }
        return compare(installed: highest, published: published, repository: repository)
    }
}
