import Foundation

public struct PluginPackage: Equatable, Sendable {
    public let manifest: PluginManifest
    public let source: String?
    public let sourceFiles: [String: String]
    public let bytes: Data
    /// Revision = SHA-256 of exact package bytes.
    public var revision: String { Digest.sha256Hex(bytes) }

    /// Strict complete-package validation: legacy {manifest,source} or routed {manifest,sourceFiles}.
    /// Checks all source paths/references and decoded-source, package and canonical-manifest budgets.
    public static func validate(_ bytes: Data) throws -> PluginPackage {
        guard !bytes.isEmpty, bytes.count <= Limits.package else { throw AutomationError.limitExceeded }
        let value: JSONValue
        do { value = try StrictJSON.parse(bytes) }
        catch let e as AutomationError { throw e == .invalidJSON ? AutomationError.invalidManifest : e }
        guard let object = value.objectValue, let manifestValue = object["manifest"] else { throw AutomationError.invalidManifest }
        let manifest = try PluginManifest(validating: manifestValue)
        if manifest.schemaVersion == 1 {
            let f = try JSONFields(value, required: ["manifest", "source"], error: .invalidManifest)
            let source = try f.string("source")
            guard source.utf8.count <= Limits.source else { throw AutomationError.limitExceeded }
            return PluginPackage(manifest: manifest, source: source, sourceFiles: [:], bytes: bytes)
        }
        let f = try JSONFields(value, required: ["manifest", "sourceFiles"], error: .invalidManifest)
        guard try manifest.json.data().count <= 32 * 1024 else { throw AutomationError.limitExceeded }
        guard case .object(let rawFiles) = try f.value("sourceFiles"), (1...64).contains(rawFiles.count) else { throw AutomationError.invalidManifest }
        var files: [String: String] = [:]
        var total = 0
        for (path, value) in rawFiles {
            guard isSourcePath(path), case .string(let code) = value, !code.utf8.contains(0) else { throw AutomationError.invalidManifest }
            total += code.utf8.count
            guard total <= Limits.source else { throw AutomationError.limitExceeded }
            files[path] = code
        }
        let referenced = Set(manifest.matches.flatMap { $0.hooks.values })
        guard referenced == Set(files.keys) else { throw AutomationError.invalidManifest }
        return PluginPackage(manifest: manifest, source: nil, sourceFiles: files, bytes: bytes)
    }

    static func isSourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 256 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || [0x2D, 0x2E, 0x5F, 0x7E].contains($0)
            }
        }
    }

    /// Checks exact size + SHA-256 first, then decodes and cross-checks id/name/version and any present display metadata.
    public static func validate(_ bytes: Data, against entry: IndexEntry) throws -> PluginPackage {
        guard bytes.count == entry.size else { throw AutomationError.sizeMismatch }
        guard Digest.sha256Hex(bytes) == entry.sha256 else { throw AutomationError.hashMismatch }
        let p = try validate(bytes)
        guard p.manifest.id == entry.id, p.manifest.name == entry.name, p.manifest.version == entry.version,
              entry.author == nil || entry.author == p.manifest.author,
              entry.summary == nil || entry.summary == p.manifest.summary,
              entry.category == nil || entry.category == p.manifest.category else {
            throw AutomationError.metadataMismatch
        }
        return p
    }

    /// New immutable package with replaced source and the unchanged full manifest (new raw-byte revision).
    public func replacingSource(_ source: String) throws -> PluginPackage {
        guard manifest.schemaVersion == 1 else { throw AutomationError.invalidManifest }
        guard source.utf8.count <= Limits.source else { throw AutomationError.limitExceeded }
        let bytes = try JSONValue.object(["manifest": manifest.json, "source": .string(source)]).data()
        return try PluginPackage.validate(bytes)
    }

    /// Replaces exactly one existing routed source, retaining the full manifest and all other files.
    public func replacingSource(_ source: String, file: String) throws -> PluginPackage {
        guard manifest.schemaVersion == 2, sourceFiles[file] != nil else { throw AutomationError.invalidManifest }
        var files = sourceFiles
        files[file] = source
        return try replacingSources(files)
    }

    /// Atomically replaces the exact set of routed source files without changing the manifest.
    public func replacingSources(_ files: [String: String]) throws -> PluginPackage {
        guard manifest.schemaVersion == 2, Set(files.keys) == Set(sourceFiles.keys) else { throw AutomationError.invalidManifest }
        let bytes = try JSONValue.object(["manifest": manifest.json, "sourceFiles": .object(files.mapValues(JSONValue.string))]).data()
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
