import Foundation

/// Actor-serialized, bounded catalog store. Every mutation takes a per-path flock, reloads and re-validates
/// the file, applies the change to a copy, and atomically replaces the file; in-memory state only changes
/// after a successful save. A corrupt file is never overwritten or reset: it blocks all mutation.
public actor AutomationStore {
    typealias Writer = @Sendable (CatalogFile, Data) throws -> Void

    private let file: CatalogFile
    private let writer: Writer
    private var current = Catalog()

    public init(fileURL: URL) {
        file = CatalogFile(url: fileURL)
        writer = { try $0.replace(with: $1) }
    }

    /// Test seam for save-failure injection.
    init(fileURL: URL, writer: @escaping Writer) {
        file = CatalogFile(url: fileURL)
        self.writer = writer
    }

    // MARK: Reading

    /// Loads and strictly validates the persisted catalog (empty when no file exists yet).
    public func load() throws -> Catalog {
        try file.locked { try reload() }
    }

    public func catalog() -> Catalog { current }

    private func reload() throws -> Catalog {
        do {
            guard let data = try file.read() else { current = Catalog(); return current }
            current = try CatalogCodec.decode(data)
            return current
        } catch {
            current = Catalog() // Invalidate memory only. The corrupt file remains untouched and load still fails.
            throw error
        }
    }

    private func transact<T>(_ body: (inout Catalog) throws -> T) throws -> T {
        try file.locked {
            var cat = try reload()
            let result = try body(&cat)
            let data = try CatalogCodec.encode(cat)
            _ = try CatalogCodec.decode(data)   // never write what we could not read back
            do { try writer(file, data) } catch {
                if let d = try? file.read(), let c = try? CatalogCodec.decode(d) { current = c }
                throw (error as? AutomationError) ?? AutomationError.saveFailed
            }
            current = cat
            return result
        }
    }

    // MARK: Repositories

    /// Registers bundled publisher identity against freshly verified metadata, once per URL.
    /// Existing records (including removal tombstones) retain all user choices and high-water state.
    public func seedIfAbsent(_ snapshot: VerifiedSnapshot, expectedURL: RepositoryURL, expectedRepositoryID: UUID,
                             expectedFingerprint: String, now: Date) throws -> RepositoryRecord {
        try transact { cat in
            try Task.checkCancellation()
            if let existing = cat.record(for: expectedURL) { return existing }
            guard snapshot.url == expectedURL else { throw AutomationError.invalidURL }
            guard snapshot.index.id == expectedRepositoryID else { throw AutomationError.repositoryIdentityChanged }
            try RepositoryEnvelope.checkTime(snapshot.index, now: now)
            guard case .signed(let key) = snapshot.signature, Digest.isHex64(expectedFingerprint),
                  key.hex == expectedFingerprint else { throw AutomationError.fingerprintMismatch }
            guard cat.repositories.count < Limits.repositories else { throw AutomationError.limitExceeded }
            let record = RepositoryRecord(url: snapshot.url, repositoryID: snapshot.index.id, trust: .pinned(key),
                                          sequence: snapshot.index.sequence, payloadDigest: snapshot.payloadDigest,
                                          visible: true, generation: UUID(), snapshot: snapshot)
            replace(record, in: &cat)
            return record
        }
    }

    /// What Add/Refresh would do for this snapshot (reloads; mutates nothing).
    public func preview(_ snapshot: VerifiedSnapshot, now: Date) throws -> AcceptancePreview {
        let cat = try file.locked { try reload() }
        let existing = cat.record(for: snapshot.url)
        let plan = try TrustPlanner.plan(existing: existing, snapshot: snapshot, now: now)
        return AcceptancePreview(resultingTrust: plan.trust, requiresAcknowledgment: plan.requiresAck, isNewRepository: existing == nil)
    }

    /// Add or refresh with no automatic publisher trust.
    public func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date) throws -> RepositoryRecord {
        try accept(snapshot, acknowledgeUnverified: acknowledgeUnverified, fingerprint: nil, now: now)
    }

    /// The reviewed metadata, high-water mark and independently verified pin commit together.
    public func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date) throws -> RepositoryRecord {
        try accept(snapshot, acknowledgeUnverified: true, fingerprint: fingerprint, now: now)
    }

    private func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, fingerprint: String?, now: Date) throws -> RepositoryRecord {
        try transact { cat in
            let existing = cat.record(for: snapshot.url)
            let plan = try TrustPlanner.plan(existing: existing, snapshot: snapshot, now: now)
            if plan.requiresAck && !acknowledgeUnverified { throw AutomationError.acknowledgmentRequired }
            var trust = plan.trust
            if let fingerprint {
                let typed = fingerprint.lowercased()
                guard case .signed(let key) = snapshot.signature, Digest.isHex64(typed), typed == key.hex else {
                    throw AutomationError.fingerprintMismatch
                }
                trust = .pinned(key)
            }
            if existing == nil, cat.repositories.count >= Limits.repositories { throw AutomationError.limitExceeded }
            let record = RepositoryRecord(url: snapshot.url, repositoryID: snapshot.index.id, trust: trust,
                                          sequence: snapshot.index.sequence, payloadDigest: snapshot.payloadDigest,
                                          visible: true, generation: UUID(), snapshot: snapshot)
            replace(record, in: &cat)
            return record
        }
    }

    /// Pin requires the independently obtained full 64-hex fingerprint to match the offered key.
    public func pin(_ url: RepositoryURL, fingerprint: String) throws -> RepositoryRecord {
        try transact { cat in
            guard let r = cat.record(for: url), r.visible else { throw AutomationError.unknownRepository }
            let typed = fingerprint.lowercased()
            let key: PublicKeyFingerprint
            switch r.trust {
            case .signedUnverified(let k), .pinned(let k): key = k
            case .unsignedAcknowledged: throw AutomationError.fingerprintMismatch
            }
            guard Digest.isHex64(typed), typed == key.hex else { throw AutomationError.fingerprintMismatch }
            let updated = RepositoryRecord(url: r.url, repositoryID: r.repositoryID, trust: .pinned(key), sequence: r.sequence,
                                           payloadDigest: r.payloadDigest, visible: true, generation: UUID(), snapshot: r.snapshot)
            replace(updated, in: &cat)
            return updated
        }
    }

    /// Hides the source; keeps trust/high-water tombstone. Installed revisions are untouched.
    public func remove(_ url: RepositoryURL) throws {
        try transact { cat in
            guard let r = cat.record(for: url), r.visible else { throw AutomationError.unknownRepository }
            replace(RepositoryRecord(url: r.url, repositoryID: r.repositoryID, trust: r.trust, sequence: r.sequence,
                                     payloadDigest: r.payloadDigest, visible: false, generation: UUID(), snapshot: nil), in: &cat)
        }
    }

    private func replace(_ r: RepositoryRecord, in cat: inout Catalog) {
        if let i = cat.repositories.firstIndex(where: { $0.url == r.url }) { cat.repositories[i] = r } else { cat.repositories.append(r) }
    }

    // MARK: Revisions

    /// Commits a disabled revision with provenance from the accepted snapshot. Rejects stale generation/snapshot,
    /// expired metadata, and packages that do not match the snapshot's index entry. Idempotent per source+plugin+revision.
    public func install(_ package: PluginPackage, from snapshot: VerifiedSnapshot, expectedGeneration: UUID, now: Date) throws -> InstalledRevision {
        try transact { cat in
            guard let r = cat.record(for: snapshot.url), r.visible, let accepted = r.snapshot else { throw AutomationError.unknownRepository }
            guard r.generation == expectedGeneration else { throw AutomationError.staleGeneration }
            guard accepted == snapshot, r.sequence == snapshot.index.sequence, r.payloadDigest == snapshot.payloadDigest else {
                throw AutomationError.staleSnapshot
            }
            try RepositoryEnvelope.checkTime(snapshot.index, now: now)
            guard let entry = snapshot.index.plugins.first(where: { $0.id == package.manifest.id }) else { throw AutomationError.metadataMismatch }
            let checked = try PluginPackage.validate(package.bytes, against: entry)
            guard checked == package else { throw AutomationError.metadataMismatch }
            let rev = InstalledRevision(package: checked, provenance: Provenance(origin: .repository(url: r.url, sequence: r.sequence), trustAtImport: r.trust), enabled: false)
            return try add(rev, to: &cat)
        }
    }

    /// Imports a complete local package file (strict validation; never executed, never enabled).
    public func importLocal(_ bytes: Data) throws -> InstalledRevision {
        let package = try PluginPackage.validate(bytes)
        return try transact { cat in
            try add(InstalledRevision(package: package, provenance: Provenance(origin: .localImport, trustAtImport: nil), enabled: false), to: &cat)
        }
    }

    /// Creates a new revision with edited source and the parent's manifest preserved. Provenance is localEdit(parent),
    /// never publisher trust. The parent revision stays installed.
    public func editSource(of revisionID: String, to source: String) throws -> InstalledRevision {
        try transact { cat in
            guard let parent = cat.revision(id: revisionID) else { throw AutomationError.unknownRevision }
            guard parent.package.source != source else { throw AutomationError.noChange }
            let edited = try parent.package.replacingSource(source)
            return try add(InstalledRevision(package: edited, provenance: Provenance(origin: .localEdit(parent: parent.package.revision), trustAtImport: nil), enabled: false), to: &cat)
        }
    }

    public func deleteRevision(_ revisionID: String) throws {
        try transact { cat in
            guard let i = cat.revisions.firstIndex(where: { $0.id == revisionID }) else { throw AutomationError.unknownRevision }
            cat.revisions.remove(at: i)
        }
    }

    private func add(_ rev: InstalledRevision, to cat: inout Catalog) throws -> InstalledRevision {
        if let existing = cat.revision(id: rev.id) { return existing }
        let bytes = cat.revisions.reduce(rev.package.bytes.count) { $0 + $1.package.bytes.count }
        guard cat.revisions.count < Limits.revisions, bytes <= Limits.rawPackageBytes else { throw AutomationError.limitExceeded }
        cat.revisions.append(rev)
        return rev
    }
}
