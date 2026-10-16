import Foundation

public struct PluginPackage: Equatable, Sendable {
    public let manifest: PluginManifest
    public let source: String
    public let bytes: Data
    /// Revision = SHA-256 of exact package bytes.
    public var revision: String { Digest.sha256Hex(bytes) }

    /// Strict local validation of a complete package: size, JSON, {manifest, source} only, source <= 128 KiB, full manifest.
    public static func validate(_ bytes: Data) throws -> PluginPackage {
        guard !bytes.isEmpty, bytes.count <= Limits.package else { throw AutomationError.limitExceeded }
        let f: JSONFields
        do { f = try JSONFields(try StrictJSON.parse(bytes), required: ["manifest", "source"], error: .invalidManifest) }
        catch let e as AutomationError { throw e == .invalidJSON ? AutomationError.invalidManifest : e }
        let source = try f.string("source")
        guard source.utf8.count <= Limits.source else { throw AutomationError.limitExceeded }
        return PluginPackage(manifest: try PluginManifest(validating: try f.value("manifest")), source: source, bytes: bytes)
    }

    /// Checks exact size + SHA-256 first, then decodes and cross-checks id/name/version.
    public static func validate(_ bytes: Data, against entry: IndexEntry) throws -> PluginPackage {
        guard bytes.count == entry.size else { throw AutomationError.sizeMismatch }
        guard Digest.sha256Hex(bytes) == entry.sha256 else { throw AutomationError.hashMismatch }
        let p = try validate(bytes)
        guard p.manifest.id == entry.id, p.manifest.name == entry.name, p.manifest.version == entry.version else {
            throw AutomationError.metadataMismatch
        }
        return p
    }

    /// New immutable package with replaced source and the unchanged full manifest (new raw-byte revision).
    func replacingSource(_ source: String) throws -> PluginPackage {
        guard source.utf8.count <= Limits.source else { throw AutomationError.limitExceeded }
        let bytes = try JSONValue.object(["manifest": manifest.json, "source": .string(source)]).data()
        return try PluginPackage.validate(bytes)
    }

    /// Metadata-only starter template (no live capture, no endpoints, example.com).
    public static func template(id: UUID = UUID(), name: String = "New plugin") throws -> PluginPackage {
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string(id.uuidString), "name": .string(name), "version": .string("1.0.0"),
            "subscriptions": .array([.object(["phase": .string("request.completed"), "match": .object(["hosts": .array([.string("example.com")])])])]),
            "read": .object(["metadata": .array([.string("method"), .string("host")]), "headers": .array([]), "queryKeys": .array([]), "body": .object(["mode": .string("none")])]),
            "endpointBindings": .array([]), "settings": .object([:]),
        ])
        let source = "function onRequest(event, config) {\n  return { actions: [] };\n}\n"
        return try validate(try JSONValue.object(["manifest": manifest, "source": .string(source)]).data())
    }
}
