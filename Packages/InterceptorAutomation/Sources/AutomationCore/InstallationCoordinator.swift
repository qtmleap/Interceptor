import Foundation

public enum InstallationError: Error, Equatable, Sendable {
    case activationUnavailable, familyAlreadyInstalled, duplicateFamily
    case approvalRequired, consentRequired
}

public enum InstallationOperation: Equatable, Sendable {
    case add
    case reinstall(selectedRevisionID: String)
}

public struct InstallationRequest: Equatable, Sendable {
    public let package: PluginPackage
    public let snapshot: VerifiedSnapshot
    public let expectedSourceGeneration: UUID
    public let operation: InstallationOperation

    public init(package: PluginPackage, snapshot: VerifiedSnapshot, expectedSourceGeneration: UUID, operation: InstallationOperation) {
        self.package = package
        self.snapshot = snapshot
        self.expectedSourceGeneration = expectedSourceGeneration
        self.operation = operation
    }
}

public struct InstallationApproval: Equatable, Sendable {
    public let packageBytes: Data
    public let expectedGrantGeneration: UUID

    public init(packageBytes: Data, expectedGrantGeneration: UUID) {
        self.packageBytes = packageBytes
        self.expectedGrantGeneration = expectedGrantGeneration
    }
}

public struct InstallationState: Equatable, Sendable {
    public let catalog: Catalog
    public let installed: [InstalledRevision]
    public let selectionGeneration: UUID
    public let selectionsInitialized: Bool
    public let activation: PluginActivationSnapshot
}

/// Blocking synchronous transactions; call off the main actor. All transactions lock catalog, then
/// activation, and reload durable bytes. Never calls an already-locking actor API under these locks.
public struct InstallationCoordinator: Sendable {
    typealias Writer = @Sendable (CatalogFile, Data) throws -> Void
    private let catalogFile: CatalogFile
    private let activationFile: CatalogFile?
    private let catalogWriter: Writer
    private let activationWriter: Writer

    public init(catalogURL: URL, activationURL: URL?) {
        self.init(catalogURL: catalogURL, activationURL: activationURL,
                  catalogWriter: { try $0.replace(with: $1) }, activationWriter: { try $0.replace(with: $1) })
    }

    /// Independent pre-rename failure seams for staging and the authoritative shared publication.
    init(catalogURL: URL, activationURL: URL?, catalogWriter: @escaping Writer, activationWriter: @escaping Writer) {
        catalogFile = CatalogFile(url: catalogURL)
        activationFile = activationURL.map { CatalogFile(url: $0) }
        self.catalogWriter = catalogWriter
        self.activationWriter = activationWriter
    }

    public func state() throws -> InstallationState {
        try locked(requireActivation: false) { catalog, document in
            try makeState(catalog, document)
        }
    }

    @discardableResult
    public func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState {
        guard requests.count <= Limits.revisions else { throw AutomationError.limitExceeded }
        return try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            var next = projected, families = Set<String>()
            var candidates: [InstalledRevision] = []
            // Validate the entire immutable queue, including freshness of no-op reinstalls, before any write.
            for request in requests {
                let revision = try AutomationStore.repositoryRevision(request.package, from: request.snapshot,
                    expectedGeneration: request.expectedSourceGeneration, now: now, catalog: catalog)
                let family = InstallationIdentity.family(revision.id)
                guard families.insert(family).inserted else { throw InstallationError.duplicateFamily }
                try select(revision, operation: request.operation, current: projected, catalog: catalog, next: &next)
                candidates.append(revision)
            }
            var staged = stagingCatalog(catalog, current: projected, candidates: candidates)
            for revision in candidates { try stage(revision, in: &staged) }
            return try commit(catalog: catalog, staged: staged, original: document, projected: projected, next: next)
        }
    }

    /// Explicit disabled local import/select; legacy cache edits cannot silently switch a v2 selection.
    @discardableResult
    public func importLocal(_ bytes: Data, operation: InstallationOperation = .add,
                            expectedSelectionGeneration: UUID) throws -> InstallationState {
        let package = try PluginPackage.validate(bytes)
        return try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            let revision = InstalledRevision(package: package, provenance: .init(origin: .localImport, trustAtImport: nil), enabled: false)
            var next = projected
            var staged = stagingCatalog(catalog, current: projected, candidates: [revision])
            try select(revision, operation: operation, current: projected, catalog: catalog, next: &next)
            try stage(revision, in: &staged)
            return try commit(catalog: catalog, staged: staged, original: document, projected: projected, next: next)
        }
    }

    @discardableResult
    public func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval,
                         captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            let revision = try selected(revisionID, in: projected, catalog: catalog)
            try validateApproval(approval, package: revision.package, document: projected)
            guard captureConsent() else { throw InstallationError.consentRequired }
            var next = projected
            var grants = next.activation.revisions.filter { InstallationIdentity.family($0.revisionID) != InstallationIdentity.family(revisionID) }
            grants.append(.init(revisionID: revisionID, package: revision.package))
            try setGrants(grants, in: &next)
            return try commit(catalog: catalog, staged: catalog, original: document, projected: projected, next: next,
                              prepublication: { guard captureConsent() else { throw InstallationError.consentRequired } })
        }
    }

    @discardableResult
    public func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            _ = try selected(revisionID, in: projected, catalog: catalog)
            var next = projected
            try setGrants(next.activation.revisions.filter { $0.revisionID != revisionID }, in: &next, invalidateApprovals: true)
            return try commit(catalog: catalog, staged: catalog, original: document, projected: projected, next: next)
        }
    }

    /// Emergency revocation preserves even a legacy active-preferred selection, freezing its projection
    /// in the same document write. No selection CAS is needed to remove execution authority.
    @discardableResult
    public func deactivateAll() throws -> InstallationState {
        try revokeGrants(revisionID: nil)
    }

    func revokeGrants(revisionID: String?) throws -> InstallationState {
        try locked { catalog, document in
            let projected = try document.projected(over: catalog)
            var next = projected
            let remaining = projected.activation.revisions.filter { active in
                revisionID.map { active.revisionID != $0 } ?? false
            }
            try setGrants(remaining, in: &next, invalidateApprovals: true)
            return try commit(catalog: catalog, staged: catalog, original: document, projected: projected, next: next)
        }
    }

    /// Uninstallation is published first and atomically with revocation. Cache/history is deliberately
    /// retained: there is no fallible post-uninstall cleanup that could report an installation preserved.
    @discardableResult
    public func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            _ = try selected(revisionID, in: projected, catalog: catalog)
            var next = projected
            next.selections!.removeValue(forKey: InstallationIdentity.family(revisionID))
            try setGrants(next.activation.revisions.filter { $0.revisionID != revisionID }, in: &next, invalidateApprovals: true)
            return try commit(catalog: catalog, staged: catalog, original: document, projected: projected, next: next)
        }
    }

    /// Enabled replacement is a new exact-byte grant, not a pending switch. Disabled replacement never grants.
    @discardableResult
    public func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID,
                       approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try locked { catalog, document in
            let projected = try checked(document, catalog: catalog, generation: expectedSelectionGeneration)
            let base = try selected(baseRevisionID, in: projected, catalog: catalog)
            let revision = try AutomationStore.repositoryRevision(request.package, from: request.snapshot,
                expectedGeneration: request.expectedSourceGeneration, now: now, catalog: catalog)
            guard InstallationIdentity.family(base.id) == InstallationIdentity.family(revision.id) else { throw AutomationError.staleSnapshot }
            if let approval { try validateApproval(approval, package: revision.package, document: projected) }
            if base.id == revision.id {
                guard base.package.bytes == revision.package.bytes else { throw AutomationError.hashMismatch }
                return try makeState(catalog, document)
            }
            let enabled = projected.activation.contains(revisionID: baseRevisionID)
            if enabled {
                guard approval != nil else { throw InstallationError.approvalRequired }
                guard captureConsent() else { throw InstallationError.consentRequired }
            }
            var next = projected
            var staged = stagingCatalog(catalog, current: projected, candidates: [revision])
            next.selections![InstallationIdentity.family(revision.id)] = revision.id
            if enabled {
                var grants = next.activation.revisions.filter { $0.revisionID != baseRevisionID }
                grants.append(.init(revisionID: revision.id, package: revision.package))
                try setGrants(grants, in: &next)
            }
            try stage(revision, in: &staged)
            return try commit(catalog: catalog, staged: staged, original: document, projected: projected, next: next,
                prepublication: { if enabled && !captureConsent() { throw InstallationError.consentRequired } })
        }
    }

    private func locked<T>(requireActivation: Bool = true, _ body: (Catalog, ActivationDocument) throws -> T) throws -> T {
        if requireActivation && activationFile == nil { throw InstallationError.activationUnavailable }
        if let activationFile, activationFile.url.standardizedFileURL == catalogFile.url.standardizedFileURL {
            throw InstallationError.activationUnavailable
        }
        return try catalogFile.locked {
            let catalog = try catalogFile.read().map(CatalogCodec.decode) ?? Catalog()
            guard let activationFile else { return try body(catalog, .empty) }
            return try activationFile.locked { try body(catalog, ActivationDocument.read(activationFile)) }
        }
    }

    private func makeState(_ catalog: Catalog, _ document: ActivationDocument) throws -> InstallationState {
        let projected = try document.projected(over: catalog)
        let revisions = try projected.selections!.values.sorted().map { id -> InstalledRevision in
            guard let revision = catalog.revision(id: id) else { throw AutomationError.corruptStore }
            return revision
        }
        return .init(catalog: catalog, installed: revisions, selectionGeneration: projected.selectionGeneration!,
                     selectionsInitialized: document.selections != nil, activation: document.activation)
    }

    private func checked(_ document: ActivationDocument, catalog: Catalog, generation: UUID) throws -> ActivationDocument {
        let projected = try document.projected(over: catalog)
        guard projected.selectionGeneration == generation else { throw AutomationError.staleGeneration }
        return projected
    }

    private func selected(_ id: String, in document: ActivationDocument, catalog: Catalog) throws -> InstalledRevision {
        guard document.selections?[InstallationIdentity.family(id)] == id else { throw AutomationError.staleSnapshot }
        guard let revision = catalog.revision(id: id) else { throw AutomationError.corruptStore }
        return revision
    }

    private func select(_ revision: InstalledRevision, operation: InstallationOperation, current: ActivationDocument,
                        catalog: Catalog, next: inout ActivationDocument) throws {
        let family = InstallationIdentity.family(revision.id)
        switch operation {
        case .add:
            guard current.selections?[family] == nil else { throw InstallationError.familyAlreadyInstalled }
            next.selections![family] = revision.id
        case .reinstall(let id):
            let existing = try selected(id, in: current, catalog: catalog)
            guard id == revision.id, existing.package.bytes == revision.package.bytes else { throw AutomationError.staleSnapshot }
        }
    }

    /// Only staging reclaims history. Use the locked CURRENT projection, not the proposed selection:
    /// failed publication must leave every old selection/grant resolvable, with its original provenance.
    private func stagingCatalog(_ catalog: Catalog, current: ActivationDocument, candidates: [InstalledRevision]) -> Catalog {
        guard candidates.contains(where: { catalog.revision(id: $0.id) == nil }) else { return catalog }
        let retained = Set(current.selections!.values)
            .union(current.activation.revisions.map(\.revisionID))
            .union(candidates.map(\.id))
        var staged = catalog
        staged.revisions.removeAll { !retained.contains($0.id) }
        return staged
    }

    private func stage(_ revision: InstalledRevision, in catalog: inout Catalog) throws {
        if let existing = catalog.revision(id: revision.id) {
            guard existing.package.bytes == revision.package.bytes else { throw AutomationError.hashMismatch }
            return
        }
        let bytes = catalog.revisions.reduce(revision.package.bytes.count) { $0 + $1.package.bytes.count }
        guard catalog.revisions.count < Limits.archiveRevisions, bytes <= Limits.archiveRawPackageBytes else { throw AutomationError.limitExceeded }
        catalog.revisions.append(revision)
    }

    private func validateApproval(_ approval: InstallationApproval, package: PluginPackage, document: ActivationDocument) throws {
        guard package.manifest.schemaVersion == 2 else { throw AutomationError.invalidManifest }
        guard approval.expectedGrantGeneration == document.activation.generation else { throw AutomationError.staleSnapshot }
        guard approval.packageBytes == package.bytes else { throw InstallationError.approvalRequired }
    }

    private func setGrants(_ grants: [ActivatedPlugin], in document: inout ActivationDocument,
                           invalidateApprovals: Bool = false) throws {
        guard grants.count <= PluginActivationStore.maxActiveRevisions else { throw AutomationError.limitExceeded }
        let sorted = grants.sorted { $0.revisionID < $1.revisionID }
        if invalidateApprovals || sorted != document.activation.revisions {
            document.activation = .init(generation: UUID(), revisions: sorted)
        }
    }

    private func commit(catalog: Catalog, staged: Catalog, original: ActivationDocument, projected: ActivationDocument,
                        next proposed: ActivationDocument, prepublication: () throws -> Void = {}) throws -> InstallationState {
        var next = proposed
        let selectionChanged = next.selections != projected.selections
        let grantsChanged = next.activation != projected.activation
        // Exact reinstall (including a legacy reinstall) is a true no-op: no migration and no writes.
        guard selectionChanged || grantsChanged else { return try makeState(catalog, original) }
        if selectionChanged { next.selectionGeneration = UUID() }
        // Validate every bound and every byte before the first write, even for the last batch item.
        let catalogBytes = try CatalogCodec.encode(staged)
        let decodedCatalog = try CatalogCodec.decode(catalogBytes)
        _ = try projected.projected(over: decodedCatalog)
        _ = try next.projected(over: decodedCatalog)
        let sharedBytes = try next.encoded()
        let barrier: Data? = try (original.selections == nil ? projected.encoded() : nil)
        let result = try makeState(decodedCatalog, next)
        try Task.checkCancellation()
        try prepublication()
        guard let activationFile else { throw InstallationError.activationUnavailable }
        // Prepare even for grant-only/delete writes. The unchanged legacy barrier preserves both
        // generations and grants; its marker and parent entries are durable before catalog staging.
        try ActivationInitialization.prepare(activationFile, barrier: barrier, writer: activationWriter)
        if staged != catalog { try catalogWriter(catalogFile, catalogBytes) }
        try Task.checkCancellation()
        try prepublication()
        try activationWriter(activationFile, sharedBytes)
        return result
    }
}
