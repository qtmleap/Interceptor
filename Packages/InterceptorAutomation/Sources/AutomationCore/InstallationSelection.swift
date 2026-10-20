import Foundation

/// Source-qualified family keys deliberately distinguish local imports from every canonical repository URL.
enum InstallationIdentity {
    static func family(_ id: String) -> String { String(id[..<(id.lastIndex(of: "|") ?? id.endIndex)]) }

    static func valid(_ id: String, package: PluginPackage? = nil) -> Bool {
        guard id.utf8.count <= 4096 else { return false }
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let uuid = UUID(uuidString: parts[1]), uuid.uuidString == parts[1],
              Digest.isHex64(parts[2]) else { return false }
        if parts[0] != "local" {
            guard let url = try? RepositoryURL(parsing: parts[0]), url.canonical == parts[0] else { return false }
        }
        return package.map { $0.manifest.id == uuid && $0.revision == parts[2] } ?? true
    }
}

/// The only durable selection authority. Nil selections mean legacy/uninitialized, NOT initialized-empty.
/// v2 is intentionally rejected by v1 readers; a downgrade after migration fails closed.
struct ActivationDocument {
    var activation: PluginActivationSnapshot
    var selectionGeneration: UUID?
    var selections: [String: String]?

    static var empty: Self { .init(activation: .empty, selectionGeneration: nil, selections: nil) }

    static func read(_ file: CatalogFile) throws -> Self {
        let read = try ActivationInitialization.read(file)
        let document = try read.bytes.map(decode) ?? .empty
        try ActivationInitialization.validate(document, initialized: read.initialized)
        return document
    }

    static func decode(_ bytes: Data) throws -> Self {
        do {
            guard bytes.count <= PluginActivationStore.maxBytes else { throw AutomationError.corruptStore }
            let value = try JSONValue(parsing: bytes)
            guard let version = value.objectValue?["version"], version == .integer(1) || version == .integer(2) else {
                throw AutomationError.corruptStore
            }
            let v2 = version == .integer(2)
            let root = try JSONFields(value, required: v2
                ? ["version", "generation", "revisions", "selectionGeneration", "selections"]
                : ["version", "generation", "revisions"], error: .corruptStore)
            let generation = try root.uuid("generation")
            let entries = try root.array("revisions")
            guard entries.count <= PluginActivationStore.maxActiveRevisions else { throw AutomationError.corruptStore }
            var families = Set<String>()
            let revisions = try entries.map { value -> ActivatedPlugin in
                let f = try JSONFields(value, required: ["revisionID", "digest", "package"], error: .corruptStore)
                let id = try f.string("revisionID")
                let package = try PluginPackage.validate(try StrictBase64.decode(try f.string("package")))
                guard package.manifest.schemaVersion == 2, InstallationIdentity.valid(id, package: package),
                      try f.string("digest") == package.revision,
                      families.insert(InstallationIdentity.family(id)).inserted else { throw AutomationError.corruptStore }
                return ActivatedPlugin(revisionID: id, package: package)
            }.sorted { $0.revisionID < $1.revisionID }
            // The zero token is reserved for grants that have never changed (e.g. a disabled first install).
            guard generation != PluginActivationSnapshot.empty.generation || (v2 && revisions.isEmpty) else {
                throw AutomationError.corruptStore
            }
            let snapshot = PluginActivationSnapshot(generation: generation, revisions: revisions)
            guard v2 else { return .init(activation: snapshot, selectionGeneration: nil, selections: nil) }
            let selectionGeneration = try root.uuid("selectionGeneration")
            let selected = try root.array("selections")
            guard selected.count <= Limits.revisions else { throw AutomationError.corruptStore }
            var selections: [String: String] = [:]
            for value in selected {
                let f = try JSONFields(value, required: ["family", "revisionID"], error: .corruptStore)
                let family = try f.string("family"), id = try f.string("revisionID")
                guard InstallationIdentity.valid(id), InstallationIdentity.family(id) == family,
                      selections.updateValue(id, forKey: family) == nil else { throw AutomationError.corruptStore }
            }
            guard revisions.allSatisfy({ selections[InstallationIdentity.family($0.revisionID)] == $0.revisionID }) else {
                throw AutomationError.corruptStore
            }
            return .init(activation: snapshot, selectionGeneration: selectionGeneration, selections: selections)
        } catch { throw AutomationError.corruptStore }
    }

    func encoded() throws -> Data {
        let entries: [JSONValue] = activation.revisions.map {
            .object(["revisionID": .string($0.revisionID), "digest": .string($0.package.revision),
                     "package": .string($0.package.bytes.base64EncodedString())])
        }
        var root: [String: JSONValue] = ["version": .integer(selections == nil ? 1 : 2),
            "generation": .string(activation.generation.uuidString), "revisions": .array(entries)]
        if let selections, let selectionGeneration {
            root["selectionGeneration"] = .string(selectionGeneration.uuidString)
            root["selections"] = .array(selections.keys.sorted().map {
                .object(["family": .string($0), "revisionID": .string(selections[$0]!)])
            })
        }
        let bytes = try JSONValue.object(root).data()
        guard bytes.count <= PluginActivationStore.maxBytes else { throw AutomationError.limitExceeded }
        _ = try Self.decode(bytes)
        return bytes
    }

    /// Pure projection, never a migration write. Catalog order is preserved by its codec.
    func projected(over catalog: Catalog) throws -> Self {
        var result = self
        if selections == nil {
            var selected: [String: String] = [:]
            for revision in catalog.revisions { selected[InstallationIdentity.family(revision.id)] = revision.id }
            for active in activation.revisions { selected[InstallationIdentity.family(active.revisionID)] = active.revisionID }
            result.selections = selected
            // Stable CAS token across read-only legacy loads; changes when the projected selection changes.
            let hex = Digest.sha256Hex(Data(selected.values.sorted().joined(separator: "\n").utf8))
            let chars = Array(hex.prefix(32))
            let text = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
            result.selectionGeneration = UUID(uuidString: text)!
        }
        guard result.selections!.count <= Limits.revisions else { throw AutomationError.limitExceeded }
        var selectedBytes = 0
        // v2 missing bytes are corruption, never an excuse to infer a different historical revision.
        for id in result.selections!.values {
            guard let revision = catalog.revision(id: id), InstallationIdentity.valid(id, package: revision.package) else {
                throw AutomationError.corruptStore
            }
            selectedBytes += revision.package.bytes.count
        }
        guard selectedBytes <= Limits.rawPackageBytes else { throw AutomationError.limitExceeded }
        for active in activation.revisions {
            guard catalog.revision(id: active.revisionID)?.package.bytes == active.package.bytes else { throw AutomationError.corruptStore }
        }
        return result
    }
}
