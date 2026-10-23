import Foundation

/// An explicit grant for one immutable installed package. It is separate from
/// the installation catalog, whose revisions always remain disabled.
public struct ActivatedPlugin: Equatable, Sendable {
    public let revisionID: String
    public let package: PluginPackage
}

/// Grant-only admission token. Selection-only writes do not change generation or equality.
public struct PluginActivationSnapshot: Equatable, Sendable {
    public let generation: UUID
    public let revisions: [ActivatedPlugin]

    private static let emptyGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static var empty: Self { .init(generation: emptyGeneration, revisions: []) }
    public func contains(revisionID: String) -> Bool { revisions.contains { $0.revisionID == revisionID } }
}

/// Readers use bounded, lock-free reads of atomically replaced files and never migrate on read.
/// Writers preserve initialized selections; corrupt data is never reset or overwritten.
public actor PluginActivationStore {
    public static let maxActiveRevisions = 4
    public static let maxBytes = 2 * 1024 * 1024
    typealias Writer = @Sendable (CatalogFile, Data) throws -> Void
    private let file: CatalogFile
    private let catalogURL: URL?
    private let writer: Writer
    private let reader: ActivationInitialization.Reader
    private var cached: (bytes: Data, document: ActivationDocument)?
    private(set) var validationCount = 0

    /// Supply catalogURL for legacy revocation. Extension readers need only fileURL and never migrate.
    public init(fileURL: URL, catalogURL: URL? = nil) {
        file = CatalogFile(url: fileURL)
        self.catalogURL = catalogURL
        writer = { try $0.replace(with: $1) }
        reader = { try $0.read(maximumBytes: PluginActivationStore.maxBytes) }
    }

    init(fileURL: URL, catalogURL: URL? = nil, writer: @escaping Writer,
         reader: @escaping ActivationInitialization.Reader = { try $0.read(maximumBytes: PluginActivationStore.maxBytes) }) {
        file = CatalogFile(url: fileURL)
        self.catalogURL = catalogURL
        self.writer = writer
        self.reader = reader
    }

    public func snapshot() throws -> PluginActivationSnapshot { try readUnlocked().activation }

    public func isCurrent(admitted: PluginActivationSnapshot) -> Bool {
        guard let current = try? snapshot() else { return false }
        return current == admitted
    }

    /// Runs `operation` while holding the activation lock, so a revocation cannot interleave. The admitted
    /// snapshot must still be current and the revision actually granted (and selected, once initialized).
    /// `operation` must be short, synchronous and must not await or block on other locks.
    public func withCurrentActivation(admitted: PluginActivationSnapshot, revisionID: String,
                                      _ operation: @Sendable (ActivatedPlugin) throws -> Void) throws {
        try file.locked {
            let document = try readUnlocked()
            guard document.activation == admitted,
                  let plugin = document.activation.revisions.first(where: { $0.revisionID == revisionID }),
                  document.selections.map({ $0[InstallationIdentity.family(revisionID)] == revisionID }) ?? true
            else { throw AutomationError.staleSnapshot }
            try operation(plugin)
        }
    }

    /// Legacy caller compatibility. Once v2 is initialized, this cannot switch the selected revision.
    /// New app callers must use InstallationCoordinator's exact-byte approval and live-consent gate.
    @discardableResult
    public func activate(_ package: PluginPackage, revisionID: String,
                         expectedGeneration: UUID) throws -> PluginActivationSnapshot {
        guard package.manifest.schemaVersion == 2, InstallationIdentity.valid(revisionID, package: package) else {
            throw AutomationError.invalidManifest
        }
        return try file.locked {
            var document = try readUnlocked()
            guard document.activation.generation == expectedGeneration else { throw AutomationError.staleSnapshot }
            let family = InstallationIdentity.family(revisionID)
            if let selections = document.selections {
                guard selections[family] == revisionID else { throw AutomationError.staleSnapshot }
            }
            var revisions = document.activation.revisions.filter { InstallationIdentity.family($0.revisionID) != family }
            revisions.append(.init(revisionID: revisionID, package: package))
            guard revisions.count <= Self.maxActiveRevisions else { throw AutomationError.limitExceeded }
            return try saveUnlocked(&document, revisions: revisions)
        }
    }

    /// Revocation changes grants only, never the installed selection.
    @discardableResult
    public func revoke(revisionID: String) throws -> PluginActivationSnapshot {
        if let catalogURL {
            return try InstallationCoordinator(catalogURL: catalogURL, activationURL: file.url,
                catalogWriter: { try $0.replace(with: $1) }, activationWriter: writer).revokeGrants(revisionID: revisionID).activation
        }
        return try file.locked {
            var document = try readUnlocked()
            let remaining = document.activation.revisions.filter { $0.revisionID != revisionID }
            guard document.selections != nil || remaining == document.activation.revisions else {
                // Without catalog context a v1 revoke could silently select the last historical revision.
                throw InstallationError.activationUnavailable
            }
            return try saveUnlocked(&document, revisions: remaining, invalidateApprovals: true)
        }
    }

    @discardableResult
    public func revokeAll() throws -> PluginActivationSnapshot {
        if let catalogURL {
            return try InstallationCoordinator(catalogURL: catalogURL, activationURL: file.url,
                catalogWriter: { try $0.replace(with: $1) }, activationWriter: writer).deactivateAll().activation
        }
        return try file.locked {
            var document = try readUnlocked()
            guard document.selections != nil || document.activation.revisions.isEmpty else {
                throw InstallationError.activationUnavailable
            }
            return try saveUnlocked(&document, revisions: [], invalidateApprovals: true)
        }
    }

    private func readUnlocked() throws -> ActivationDocument {
        let read = try ActivationInitialization.read(file, reader: reader)
        guard let data = read.bytes else {
            cached = nil
            try ActivationInitialization.validate(.empty, initialized: read.initialized)
            return .empty
        }
        if let cached, cached.bytes == data {
            try ActivationInitialization.validate(cached.document, initialized: read.initialized)
            return cached.document
        }
        validationCount += 1
        let document = try ActivationDocument.decode(data)
        try ActivationInitialization.validate(document, initialized: read.initialized)
        cached = (data, document)
        return document
    }

    private func saveUnlocked(_ document: inout ActivationDocument, revisions: [ActivatedPlugin],
                              invalidateApprovals: Bool = false) throws -> PluginActivationSnapshot {
        let sorted = revisions.sorted { $0.revisionID < $1.revisionID }
        guard invalidateApprovals || sorted != document.activation.revisions else { return document.activation }
        document.activation = .init(generation: UUID(), revisions: sorted)
        let data = try document.encoded()
        if document.selections != nil { try ActivationInitialization.prepare(file, writer: writer) }
        try writer(file, data)
        cached = (data, document)
        return document.activation
    }
}
