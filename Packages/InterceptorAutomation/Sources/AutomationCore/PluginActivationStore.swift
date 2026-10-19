import Foundation

/// An explicit grant for one immutable installed package. It is separate from
/// the installation catalog, whose revisions always remain disabled.
public struct ActivatedPlugin: Equatable, Sendable {
    public let revisionID: String
    public let package: PluginPackage
}

public struct PluginActivationSnapshot: Equatable, Sendable {
    public let generation: UUID
    public let revisions: [ActivatedPlugin]

    private static let emptyGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static var empty: Self { .init(generation: emptyGeneration, revisions: []) }
    public func contains(revisionID: String) -> Bool { revisions.contains { $0.revisionID == revisionID } }
}

/// Readers use bounded, lock-free reads of atomically replaced files. Only fully validated exact
/// bytes are cached. Writers retain the per-path lock; corrupt data is never reset or overwritten.
public actor PluginActivationStore {
    public static let maxActiveRevisions = 4
    public static let maxBytes = 2 * 1024 * 1024
    typealias Writer = @Sendable (CatalogFile, Data) throws -> Void
    private let file: CatalogFile
    private let writer: Writer
    private var cached: (bytes: Data, snapshot: PluginActivationSnapshot)?
    /// Internal evidence for cache regression tests; never influences admission.
    private(set) var validationCount = 0

    public init(fileURL: URL) {
        file = CatalogFile(url: fileURL)
        writer = { try $0.replace(with: $1) }
    }

    /// Narrow save-failure seam, matching AutomationStore's internal writer injection.
    init(fileURL: URL, writer: @escaping Writer) {
        file = CatalogFile(url: fileURL)
        self.writer = writer
    }

    public func snapshot() throws -> PluginActivationSnapshot { try readUnlocked() }

    public func isCurrent(admitted: PluginActivationSnapshot) -> Bool {
        guard let current = try? snapshot() else { return false }
        return current == admitted
    }

    /// Approval is compare-and-swap against the state the user reviewed. Revoke
    /// rotates generation even when absent, invalidating an in-flight approval.
    @discardableResult
    public func activate(_ package: PluginPackage, revisionID: String,
                         expectedGeneration: UUID) throws -> PluginActivationSnapshot {
        guard case .integer(2)? = package.manifest.json.objectValue?["schemaVersion"],
              Self.validIdentity(revisionID, package: package) else { throw AutomationError.invalidManifest }
        return try file.locked {
            let current = try readUnlocked()
            guard current.generation == expectedGeneration else { throw AutomationError.staleSnapshot }
            let family = Self.family(revisionID)
            var revisions = current.revisions.filter { Self.family($0.revisionID) != family }
            revisions.append(.init(revisionID: revisionID, package: package))
            guard revisions.count <= Self.maxActiveRevisions else { throw AutomationError.limitExceeded }
            return try saveUnlocked(revisions)
        }
    }

    @discardableResult
    public func revoke(revisionID: String) throws -> PluginActivationSnapshot {
        try file.locked {
            let current = try readUnlocked()
            return try saveUnlocked(current.revisions.filter { $0.revisionID != revisionID })
        }
    }

    @discardableResult
    public func revokeAll() throws -> PluginActivationSnapshot {
        try file.locked {
            _ = try readUnlocked()
            return try saveUnlocked([])
        }
    }

    private static func family(_ id: String) -> Substring {
        id[..<(id.lastIndex(of: "|") ?? id.endIndex)]
    }

    private static func validIdentity(_ id: String, package: PluginPackage) -> Bool {
        let suffix = "|\(package.manifest.id.uuidString)|\(package.revision)"
        return id.utf8.count <= 4096 && id.hasSuffix(suffix) && id.count > suffix.count &&
            !id.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private func readUnlocked() throws -> PluginActivationSnapshot {
        guard let data = try file.read(maximumBytes: Self.maxBytes) else { return .empty }
        if let cached, cached.bytes == data { return cached.snapshot }
        validationCount += 1
        do {
            let root = try JSONFields(try JSONValue(parsing: data),
                                      required: ["version", "generation", "revisions"], error: .corruptStore)
            guard try root.int("version") == 1 else { throw AutomationError.corruptStore }
            let generation = try root.uuid("generation")
            let entries = try root.array("revisions")
            guard entries.count <= Self.maxActiveRevisions else { throw AutomationError.corruptStore }
            var identities = Set<String>()
            let revisions = try entries.map { value -> ActivatedPlugin in
                let fields = try JSONFields(value, required: ["revisionID", "digest", "package"], error: .corruptStore)
                let id = try fields.string("revisionID")
                let package = try PluginPackage.validate(try StrictBase64.decode(try fields.string("package")))
                guard case .integer(2)? = package.manifest.json.objectValue?["schemaVersion"],
                      try fields.string("digest") == package.revision,
                      Self.validIdentity(id, package: package),
                      identities.insert(String(Self.family(id))).inserted else { throw AutomationError.corruptStore }
                return ActivatedPlugin(revisionID: id, package: package)
            }
            guard generation != PluginActivationSnapshot.empty.generation else { throw AutomationError.corruptStore }
            let snapshot = PluginActivationSnapshot(generation: generation, revisions: revisions.sorted { $0.revisionID < $1.revisionID })
            cached = (data, snapshot)
            return snapshot
        } catch { throw AutomationError.corruptStore }
    }

    private func saveUnlocked(_ revisions: [ActivatedPlugin]) throws -> PluginActivationSnapshot {
        let snapshot = PluginActivationSnapshot(generation: UUID(), revisions: revisions.sorted { $0.revisionID < $1.revisionID })
        let entries: [JSONValue] = snapshot.revisions.map {
            .object(["revisionID": .string($0.revisionID), "digest": .string($0.package.revision),
                     "package": .string($0.package.bytes.base64EncodedString())])
        }
        let data = try JSONValue.object(["version": .integer(1), "generation": .string(snapshot.generation.uuidString),
                                         "revisions": .array(entries)]).data()
        guard data.count <= Self.maxBytes else { throw AutomationError.limitExceeded }
        try writer(file, data)
        cached = (data, snapshot)
        return snapshot
    }
}
