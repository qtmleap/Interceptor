import Foundation

/// App-only persistent folder authority; never available to the JS VM or tunnel extension.
public struct PluginFolderGrant: Equatable, Sendable {
    public let bookmark: Data
    public let rootIdentity: String
    public let pathPrefix: String
    public init(bookmark: Data, rootIdentity: String, pathPrefix: String = "") {
        self.bookmark = bookmark
        self.rootIdentity = rootIdentity
        self.pathPrefix = pathPrefix
    }
}

public struct PluginFolderGrantStore: Sendable {
    public enum StoreError: Error, Sendable { case invalidGrant }
    private struct Entry { let family: String; let grant: PluginFolderGrant }
    private let file: CatalogFile
    private static let maxBytes = 2 * 1024 * 1024
    public init(url: URL) { file = CatalogFile(url: url) }

    public func grant(for family: String, prefix: String = "") throws -> PluginFolderGrant? {
        try Self.decode(file.read(maximumBytes: Self.maxBytes))[Self.key(family, prefix)]?.grant
    }

    public func set(_ grant: PluginFolderGrant, for family: String) throws {
        guard Self.valid(family: family, grant: grant) else { throw StoreError.invalidGrant }
        try file.locked {
            var grants = try Self.decode(file.read(maximumBytes: Self.maxBytes))
            let entry = Entry(family: family, grant: grant)
            guard !grants.values.contains(where: { Self.overlaps($0, entry) }) else { throw StoreError.invalidGrant }
            grants[Self.key(family, grant.pathPrefix)] = entry
            guard grants.count <= 32 else { throw AutomationError.limitExceeded }
            let values = grants.mapValues { entry in
                JSONValue.object(["family": .string(entry.family), "pathPrefix": .string(entry.grant.pathPrefix),
                                  "bookmark": .string(entry.grant.bookmark.base64EncodedString()),
                                  "rootIdentity": .string(entry.grant.rootIdentity)])
            }
            let bytes = try JSONValue.object(["version": .integer(1), "grants": .object(values)]).data()
            guard bytes.count <= Self.maxBytes else { throw AutomationError.limitExceeded }
            try file.replace(with: bytes)
            try file.synchronizeParentDirectory()
        }
    }

    private static func key(_ family: String, _ prefix: String) -> String {
        Digest.sha256Hex(Data((family + "\n" + prefix).utf8))
    }

    private static func valid(family: String, grant: PluginFolderGrant) -> Bool {
        let prefix = grant.pathPrefix
        let validPrefix = prefix.isEmpty || (!prefix.unicodeScalars.contains("/") &&
            (try? PluginFileDestination(storage: .icloud, atPath: prefix)) != nil)
        return validPrefix && InstallationIdentity.valid(family + "|" + String(repeating: "0", count: 64))
            && !grant.bookmark.isEmpty && grant.bookmark.count <= 64 * 1024
            && Digest.isHex64(grant.rootIdentity)
    }

    private static func overlaps(_ lhs: Entry, _ rhs: Entry) -> Bool {
        guard lhs.family == rhs.family else { return false }
        let a = lhs.grant.pathPrefix, b = rhs.grant.pathPrefix
        guard Data(a.utf8) != Data(b.utf8) else { return false }
        return a.isEmpty || b.isEmpty || PluginFileDestination.foldedKey(a) == PluginFileDestination.foldedKey(b)
    }

    private static func decode(_ data: Data?) throws -> [String: Entry] {
        guard let data else { return [:] }
        let document = try JSONFields(JSONValue(parsing: data), required: ["version", "grants"], error: .corruptStore)
        guard try document.int("version") == 1,
              case let .object(entries) = try document.value("grants"), entries.count <= 32 else {
            throw AutomationError.corruptStore
        }
        var result: [String: Entry] = [:]
        for (key, value) in entries {
            let fields = try JSONFields(value, required: ["family", "pathPrefix", "bookmark", "rootIdentity"], error: .corruptStore)
            let family = try fields.string("family")
            guard let bookmark = try Data(base64Encoded: fields.string("bookmark")) else { throw AutomationError.corruptStore }
            let grant = try PluginFolderGrant(bookmark: bookmark, rootIdentity: fields.string("rootIdentity"),
                                            pathPrefix: fields.string("pathPrefix"))
            let entry = Entry(family: family, grant: grant)
            guard valid(family: family, grant: grant), key == Self.key(family, grant.pathPrefix),
                  !result.values.contains(where: { overlaps($0, entry) }) else { throw AutomationError.corruptStore }
            result[key] = entry
        }
        return result
    }
}
