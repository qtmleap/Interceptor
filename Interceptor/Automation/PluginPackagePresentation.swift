import AutomationCore
import Foundation

/// One routing rule shown for a source file. Same fields as the former `PluginBrowserRule`.
struct PackageCatalogRule: Equatable, Sendable {
    let hook: String
    let hosts: [String]
    let methods: [String]?
    let path: PluginSubscription.PathMatch?
    let status: ClosedRange<Int>?
}

/// Typed, display-only projection of one already validated `PluginPackage`.
/// This is the single manifest-to-DTO mapping shared by database ingestion and installed-package UI.
/// It never validates, fetches or authorizes anything.
struct PluginPackagePresentation: Equatable, Sendable {
    struct Metadata: Equatable, Sendable {
        let id: UUID
        let schemaVersion: Int64
        let name: String
        let version: String
        let author: String?
        let summary: String?
        let category: String?
        let publishedAt: Date?
        let targetHosts: [String]
    }

    let manifest: Metadata
    let source: String?
    let sourceFiles: [String: String]
    /// Pretty-printed once at construction.
    let manifestJSON: String
    let rulesByFile: [String: [PackageCatalogRule]]
    let sourceFileNames: [String]
    /// False for index-only metadata: no stored files, rules or manifest JSON. A finite state, not an error.
    let isComplete: Bool

    init(manifest: Metadata, source: String?, sourceFiles: [String: String], manifestJSON: String,
         rulesByFile: [String: [PackageCatalogRule]], sourceFileNames: [String], isComplete: Bool)
    {
        self.manifest = manifest; self.source = source; self.sourceFiles = sourceFiles; self.manifestJSON = manifestJSON
        self.rulesByFile = rulesByFile; self.sourceFileNames = sourceFileNames; self.isComplete = isComplete
    }

    /// Known index metadata only; `schemaVersion` 0 and empty hosts/files mean "not stored yet".
    init(indexEntry entry: IndexEntry) {
        self.init(manifest: Metadata(id: entry.id, schemaVersion: 0, name: entry.name, version: entry.version, author: entry.author,
                                     summary: entry.summary, category: entry.category, publishedAt: nil, targetHosts: []),
                  source: nil, sourceFiles: [:], manifestJSON: "", rulesByFile: [:], sourceFileNames: [], isComplete: false)
    }

    init(_ package: PluginPackage) {
        isComplete = true
        let m = package.manifest
        manifest = Metadata(id: m.id, schemaVersion: m.schemaVersion, name: m.name, version: m.version,
                            author: m.author, summary: m.summary, category: m.category, publishedAt: m.publishedAt,
                            targetHosts: Array(Set(m.matches.flatMap(\.hosts) + m.subscriptions.flatMap(\.hosts))).sorted())
        source = package.source
        sourceFiles = package.sourceFiles
        manifestJSON = Self.prettyPrinted(m.json)
        let names = m.schemaVersion == 2 ? package.sourceFiles.keys.sorted() : ["script.js"]
        sourceFileNames = names
        rulesByFile = Dictionary(uniqueKeysWithValues: names.map { ($0, Self.matchingRules(in: m, file: $0)) })
    }

    static func matchingRules(in manifest: PluginManifest, file: String) -> [PackageCatalogRule] {
        if manifest.schemaVersion == 2 {
            return manifest.matches.flatMap { match in
                match.hooks.keys.sorted().filter { match.hooks[$0] == file }.map {
                    PackageCatalogRule(hook: $0, hosts: match.hosts, methods: match.methods, path: match.path, status: match.status)
                }
            }
        }
        guard file == "script.js" else { return [] }
        return manifest.subscriptions.map {
            PackageCatalogRule(hook: $0.phase.rawValue, hosts: $0.hosts, methods: $0.methods, path: $0.path, status: $0.status)
        }
    }

    private static func prettyPrinted(_ json: JSONValue) -> String {
        guard let compact = try? json.data() else { return "" }
        guard let object = try? JSONSerialization.jsonObject(with: compact),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: compact, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }
}
