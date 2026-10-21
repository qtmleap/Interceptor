import Foundation

public struct PluginSubscription: Equatable, Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        case requestHeaders = "request.headers", requestCompleted = "request.completed"
        case responseHeaders = "response.headers", responseCompleted = "response.completed"
        public var isResponse: Bool { self == .responseHeaders || self == .responseCompleted }
        public var isHeadersPhase: Bool { self == .requestHeaders || self == .responseHeaders }
    }
    public enum PathMatch: Equatable, Sendable { case exact(String), prefix(String) }
    public let phase: Phase
    public let hosts: [String]
    public let methods: [String]?
    public let path: PathMatch?
    public let status: ClosedRange<Int>?
}

public struct PluginReadDeclaration: Equatable, Sendable {
    public enum Body: Equatable, Sendable { case none, jsonPointers([String]), raw, json }
    public let metadata: [String]
    public let headers: [String]
    public let queryKeys: [String]
    public let body: Body
}

/// Fully validated schema 1 or 2 manifest. Declarations grant no data access or execution; `json` preserves the
/// complete validated manifest so source edits keep every declaration.
public struct PluginManifest: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let version: String
    public let subscriptions: [PluginSubscription]
    public let read: PluginReadDeclaration
    public let endpointBindings: [String]
    public let settings: JSONValue
    /// Optional publisher-supplied display text. Unauthenticated and unverified; never an identity claim.
    public let author: String?
    public let summary: String?
    /// Optional display-only grouping label (1...80 Unicode scalars, <=256 UTF-8 bytes), preserved verbatim. Not a trust claim.
    public let category: String?
    /// Optional publisher-declared static release date (`yyyy-MM-ddTHH:mm:ssZ`, UTC whole seconds). Display only; not a
    /// trust, ordering or freshness claim. Covered by the package bytes/revision hash.
    public let publishedAt: Date?
    public let json: JSONValue

    public let schemaVersion: Int64
    public let matches: [PluginMatch]
    public let writeRequestBody: Bool
    public let writeResponseBody: Bool

    static let metadataNames: Set<String> = ["method", "host", "status", "path"]

    init(validating v: JSONValue) throws {
        let bad = AutomationError.invalidManifest
        guard case .object(let raw) = v, case .integer(let version2)? = raw["schemaVersion"], version2 == 1 || version2 == 2 else { throw bad }
        let isV2 = version2 == 2
        let f = try JSONFields(v, required: isV2
                               ? ["schemaVersion", "id", "name", "version", "matches", "read", "write", "endpointBindings", "settings"]
                               : ["schemaVersion", "id", "name", "version", "subscriptions", "read", "endpointBindings", "settings"],
                               optional: ["author", "summary", "category", "publishedAt"], error: bad)
        let name = try f.string("name"), version = try f.string("version")
        guard Text.isDisplayName(name) else { throw bad }
        _ = try SemVer(parsing: version)

        var subs: [PluginSubscription] = []
        var matches: [PluginMatch] = []
        var writeRequest = false, writeResponse = false
        let read: PluginReadDeclaration
        if isV2 {
            let rawMatches = try f.array("matches")
            guard (1...16).contains(rawMatches.count) else { throw bad }
            matches = try rawMatches.map { try PluginMatch(validating: $0) }
            read = try PluginManifest.readDeclaration(try f.value("read"), allowJSON: true)
            let w = try JSONFields(try f.value("write"), required: ["requestBody", "responseBody"], error: bad)
            writeRequest = try w.bool("requestBody")
            writeResponse = try w.bool("responseBody")
        } else {
            let subsRaw = try f.array("subscriptions")
            guard (1...8).contains(subsRaw.count) else { throw bad }
            subs = try subsRaw.map(PluginManifest.subscription)
            read = try PluginManifest.readDeclaration(try f.value("read"), allowJSON: false)
            if subs.contains(where: \.phase.isHeadersPhase), read.body != .none { throw bad }
        }

        let bindings = try f.strings("endpointBindings")
        guard bindings.count <= 4, Set(bindings).count == bindings.count, bindings.allSatisfy(PluginManifest.isBindingName) else { throw bad }

        let settings = try f.value("settings")
        guard case .object = settings, settings.nesting <= Limits.settingsDepth,
              let encoded = try? settings.data(), encoded.count <= Limits.settingsBytes else { throw bad }

        var author: String?, summary: String?, category: String?
        if f.has("author") {
            let a = try f.string("author")
            guard Text.isOptionalText(a, maxCharacters: 80, maxBytes: 256) else { throw bad }
            author = a
        }
        if f.has("summary") {
            let t = try f.string("summary")
            guard Text.isOptionalText(t, maxCharacters: 280, maxBytes: 1024) else { throw bad }
            summary = t
        }
        if f.has("category") {
            let c = try f.string("category")
            guard Text.isScalarBoundedText(c, maxScalars: 80, maxBytes: 256) else { throw bad }
            category = c
        }

        var publishedAt: Date?
        if f.has("publishedAt") {
            guard let d = DateCodec.parse(try f.string("publishedAt")) else { throw bad }
            publishedAt = d
        }

        id = try f.uuid("id")
        self.publishedAt = publishedAt
        self.author = author
        self.summary = summary
        self.category = category
        self.name = name
        self.version = version
        subscriptions = subs
        schemaVersion = version2
        self.matches = matches
        writeRequestBody = writeRequest
        writeResponseBody = writeResponse
        self.read = read
        endpointBindings = bindings
        self.settings = settings
        json = v
    }

    private static func isBindingName(_ s: String) -> Bool {
        guard let first = s.utf8.first, s.utf8.count <= 32, (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }

    private static func subscription(_ v: JSONValue) throws -> PluginSubscription {
        let bad = AutomationError.invalidManifest
        let f = try JSONFields(v, required: ["phase", "match"], error: bad)
        guard let phase = PluginSubscription.Phase(rawValue: try f.string("phase")) else { throw bad }
        let m = try JSONFields(try f.value("match"), required: ["hosts"], optional: ["methods", "path", "status"], error: bad)
        let hosts = try m.strings("hosts")
        guard (1...32).contains(hosts.count), Set(hosts).count == hosts.count, hosts.allSatisfy(isMatchHost) else { throw bad }
        var methods: [String]?
        if m.has("methods") {
            let ms = try m.strings("methods")
            guard (1...16).contains(ms.count), Set(ms).count == ms.count,
                  ms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 && $0.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A } }) else { throw bad }
            methods = ms
        }
        var path: PluginSubscription.PathMatch?
        if m.has("path") {
            let p = try JSONFields(try m.value("path"), required: ["kind", "value"], error: bad)
            let value = try p.string("value")
            guard isEncodedPath(value) else { throw bad }
            switch try p.string("kind") {
            case "exact": path = .exact(value)
            case "prefix": path = .prefix(value)
            default: throw bad
            }
        }
        var status: ClosedRange<Int>?
        if m.has("status") {
            guard phase.isResponse else { throw bad }
            let s = try JSONFields(try m.value("status"), required: ["min", "max"], error: bad)
            let lo = try s.int("min"), hi = try s.int("max")
            guard (100...599).contains(lo), (100...599).contains(hi), lo <= hi else { throw bad }
            status = Int(lo)...Int(hi)
        }
        return PluginSubscription(phase: phase, hosts: hosts, methods: methods, path: path, status: status)
    }

    private static func readDeclaration(_ v: JSONValue, allowJSON: Bool) throws -> PluginReadDeclaration {
        let bad = AutomationError.invalidManifest
        let f = try JSONFields(v, required: ["metadata", "headers", "queryKeys", "body"], error: bad)
        let metadata = try f.strings("metadata")
        guard Set(metadata).count == metadata.count, Set(metadata).isSubset(of: metadataNames) else { throw bad }
        let headers = try f.strings("headers")
        guard headers.count <= 32, Set(headers.map { $0.lowercased() }).count == headers.count, headers.allSatisfy(isHeaderName) else { throw bad }
        let keys = try f.strings("queryKeys")
        guard keys.count <= 32, Set(keys).count == keys.count,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) else { throw bad }

        let b = try JSONFields(try f.value("body"), required: ["mode"], optional: ["pointers"], error: bad)
        let body: PluginReadDeclaration.Body
        switch try b.string("mode") {
        case "none": guard !b.has("pointers") else { throw bad }; body = .none
        case "raw": guard !allowJSON, !b.has("pointers") else { throw bad }; body = .raw
        case "json": guard allowJSON, !b.has("pointers") else { throw bad }; body = .json
        case "jsonPointers":
            guard !allowJSON else { throw bad }
            let ps = try b.strings("pointers")
            guard (1...32).contains(ps.count), Set(ps).count == ps.count, ps.allSatisfy(isJSONPointer) else { throw bad }
            body = .jsonPointers(ps)
        default: throw bad
        }
        return PluginReadDeclaration(metadata: metadata, headers: headers, queryKeys: keys, body: body)
    }

    static func isMatchHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.utf8.count <= 253 else { return false }
        return h.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { l in
            !l.isEmpty && l.utf8.count <= 63 && l.first != "-" && l.last != "-"
                && l.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
        }
    }

    static func isEncodedPath(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.first == 0x2F, u.count <= 1024 else { return false }
        func isHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        var i = 0
        let extra = Array("-._~!$&'()*+,;=:@/".utf8)
        while i < u.count {
            let c = u[i]
            if c == 0x25 {
                guard i + 2 < u.count, isHex(u[i + 1]), isHex(u[i + 2]) else { return false }
                i += 3
                continue
            }
            guard (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || extra.contains(c) else { return false }
            i += 1
        }
        return true
    }

    private static func isHeaderName(_ s: String) -> Bool {
        let extra = Array("!#$%&'*+-.^_`|~".utf8)
        return !s.isEmpty && s.utf8.count <= 128 && s.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || extra.contains($0)
        }
    }

    private static func isJSONPointer(_ s: String) -> Bool {
        guard s.count <= 256 else { return false }
        if s.isEmpty { return true }
        guard s.first == "/" else { return false }
        let u = Array(s.utf8)
        for (i, c) in u.enumerated() where c == UInt8(ascii: "~") {
            guard i + 1 < u.count, u[i + 1] == UInt8(ascii: "0") || u[i + 1] == UInt8(ascii: "1") else { return false }
        }
        return true
    }
}
