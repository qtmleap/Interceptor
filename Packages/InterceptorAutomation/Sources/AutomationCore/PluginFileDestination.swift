import Foundation

public enum PluginFileStorage: String, Codable, Sendable {
    case local
    case icloud
}

/// A validated, storage-relative destination chosen by plugin JavaScript.
///
/// Paths must already be NFC (compared by UTF-8 bytes; Swift `String` equality is canonical equivalence and
/// would accept other spellings). Aliases are detected through `canonicalIdentity`, never by renaming.
public struct PluginFileDestination: Sendable, Equatable, Codable {
    public enum ValidationError: Error, Equatable, Sendable { case invalidPath }

    public static let maxPathBytes = 1024
    public static let maxComponentBytes = 255
    public static let maxDepth = 8

    public let storage: PluginFileStorage
    public let atPath: String

    public init(storage: PluginFileStorage, atPath: String) throws {
        try Self.validate(atPath)
        self.storage = storage
        self.atPath = atPath
    }

    private enum CodingKeys: String, CodingKey { case storage, atPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storage = try c.decode(PluginFileStorage.self, forKey: .storage)
        let path = try c.decode(String.self, forKey: .atPath)
        do { try self.init(storage: storage, atPath: path) }
        catch { throw DecodingError.dataCorruptedError(forKey: .atPath, in: c, debugDescription: "invalid atPath") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(storage, forKey: .storage)
        try c.encode(atPath, forKey: .atPath)
    }

    /// Conservative case/compatibility-folded identity: two destinations with the same identity are aliases.
    public var canonicalIdentity: String { storage.rawValue + "\n" + Self.foldedKey(atPath) }

    /// POSIX treats every slash scalar as a separator, even when a following combining mark
    /// makes it part of a larger Swift `Character`.
    public var pathComponents: [String] { Self.components(in: atPath) }

    private static func components(in path: String) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
    }

    static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCompatibilityMapping.uppercased().lowercased().precomposedStringWithCompatibilityMapping
    }

    private static func validate(_ path: String) throws {
        let bytes = path.utf8.count
        guard (1...maxPathBytes).contains(bytes) else { throw AutomationError.limitExceeded }
        guard Data(path.utf8) == Data(path.precomposedStringWithCanonicalMapping.utf8) else { throw ValidationError.invalidPath }
        let components = Self.components(in: path)
        guard components.count <= maxDepth else { throw AutomationError.limitExceeded }
        for component in components {
            guard (1...maxComponentBytes).contains(component.utf8.count), component.unicodeScalars.first != "." else {
                throw ValidationError.invalidPath
            }
            for scalar in component.unicodeScalars {
                if scalar == "\\" || scalar == ":" { throw ValidationError.invalidPath }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: throw ValidationError.invalidPath
                default: break
                }
            }
        }
    }
}
