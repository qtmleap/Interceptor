import Foundation

/// V2 budgets are deliberately independent of the v1 preview envelopes.
public enum WorkflowLimits {
    public static let inputBytes = 192 * 1024
    public static let planningBytes = 96 * 1024
    public static let resultBytes = 32 * 1024
    public static let bodyBytes = 32 * 1024
    public static let headerBytes = 8 * 1024
    public static let queryBytes = 8 * 1024
    public static let continuationBytes = 8 * 1024
}

public enum WorkflowPath {
    private static func unreserved(_ b: UInt8) -> Bool {
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45,46,95,126].contains(b)
    }
    public static func canonicalize(_ path: String) throws -> String {
        let b = Array(path.utf8)
        guard b.count <= 1024, b.first == 47, b.count == 1 || b[1] != 47 else { throw AutomationError.invalidManifest }
        var decoded: [UInt8] = [], out = "", i = 0
        let allowed = Array("!$&'()*+,;=:@/".utf8)
        while i < b.count {
            let c = b[i]
            if c == 37 {
                guard i + 2 < b.count, let v = UInt8(String(decoding: b[(i+1)...(i+2)], as: UTF8.self), radix: 16), v >= 32, v != 127, v != 47, v != 92, v != 37 else { throw AutomationError.invalidManifest }
                decoded.append(v)
                out += unreserved(v) ? String(UnicodeScalar(v)) : String(format: "%%%02X", v)
                i += 3
            } else {
                guard unreserved(c) || allowed.contains(c) else { throw AutomationError.invalidManifest }
                decoded.append(c); out.append(Character(UnicodeScalar(c))); i += 1
            }
        }
        guard let semantic = String(bytes: decoded, encoding: .utf8), !semantic.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw AutomationError.invalidManifest }
        let parts = out.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() where index > 0 {
            guard part != ".", part != "..", !part.isEmpty || index == parts.count - 1 else { throw AutomationError.invalidManifest }
        }
        return out
    }

    public static func validateMethod(_ method: String) throws -> String {
        guard !method.isEmpty, method.utf8.count <= 16, method == method.uppercased(), PluginManifest.isHeaderName(method), !["CONNECT", "TRACE"].contains(method) else { throw AutomationError.invalidManifest }
        return method
    }
}

public struct WorkflowPathScope: Equatable, Sendable {
    public enum Kind: String, Sendable { case exact, prefix }
    public let kind: Kind
    public let value: String
    public init(kind: Kind, value: String) throws { self.kind = kind; self.value = try WorkflowPath.canonicalize(value) }
    public func matches(_ path: String) -> Bool {
        guard let p = try? WorkflowPath.canonicalize(path) else { return false }
        if kind == .exact { return p == value }
        return value == "/" || p == value || p.hasPrefix(value.hasSuffix("/") ? value : value + "/")
    }
}

public enum WorkflowHeaderInheritance: Equatable, Sendable {
    case allEndToEnd
    case names([String])
    public init(validating value: JSONValue) throws {
        let f = try JSONFields(value, required: ["mode"], optional: ["names"], error: .invalidManifest)
        switch try f.string("mode") {
        case "allEndToEnd": guard !f.has("names") else { throw AutomationError.invalidManifest }; self = .allEndToEnd
        case "names":
            let names = try f.strings("names")
            guard names.count <= 32, names.allSatisfy(PluginManifest.isHeaderName), Set(names.map { $0.lowercased() }).count == names.count else { throw AutomationError.invalidManifest }
            self = .names(names.map { $0.lowercased() })
        default: throw AutomationError.invalidManifest
        }
    }
}

public struct WorkflowScope: Equatable, Sendable {
    public let methods: [String]
    public let paths: [WorkflowPathScope]
    public init(methods: [String], paths: [WorkflowPathScope]) throws {
        guard (1...8).contains(methods.count), (1...8).contains(paths.count), Set(methods).count == methods.count,
              Set(paths.map { $0.kind.rawValue + ":" + $0.value }).count == paths.count else { throw AutomationError.invalidManifest }
        self.methods = try methods.map(WorkflowPath.validateMethod); self.paths = paths
    }
    public func permits(method: String, path: String) -> Bool { methods.contains(method) && paths.contains { $0.matches(path) } }
}

public struct WorkflowDeclaration: Equatable, Sendable {
    public let endpointBinding: String?
    public let sameOrigin: WorkflowScope
    public let inheritHeaders: WorkflowHeaderInheritance
    public let responseRead: PluginReadDeclaration
    init(validating value: JSONValue) throws {
        let f = try JSONFields(value, required: ["sameOrigin", "responseRead"], optional: ["endpointBinding"], error: .invalidManifest)
        endpointBinding = f.has("endpointBinding") ? try f.string("endpointBinding") : nil
        let s = try JSONFields(f.value("sameOrigin"), required: ["methods", "paths", "inheritHeaders"], error: .invalidManifest)
        let paths = try s.array("paths").map { v in
            let p = try JSONFields(v, required: ["kind", "value"], error: .invalidManifest)
            guard let kind = WorkflowPathScope.Kind(rawValue: try p.string("kind")) else { throw AutomationError.invalidManifest }
            return try WorkflowPathScope(kind: kind, value: p.string("value"))
        }
        sameOrigin = try WorkflowScope(methods: s.strings("methods"), paths: paths)
        inheritHeaders = try WorkflowHeaderInheritance(validating: s.value("inheritHeaders"))
        responseRead = try PluginManifest.readDeclaration(f.value("responseRead"))
        guard Set(responseRead.metadata).isSubset(of: ["status"]), responseRead.queryKeys.isEmpty else { throw AutomationError.invalidManifest }
    }
}

public struct WorkflowQueryField: Equatable, Sendable {
    public let name: String
    public let value: String?
    public init(name: String, value: String?) { self.name = name; self.value = value }
    public var json: JSONValue { .object(["name": .string(name), "value": value.map(JSONValue.string) ?? .null]) }
    public static func encode(_ fields: [Self]) throws -> String {
        guard fields.count <= 32, try JSONValue.array(fields.map(\.json)).data().count <= WorkflowLimits.queryBytes else { throw AutomationError.limitExceeded }
        func component(_ s: String) -> String {
            s.utf8.map { b in
                (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45,46,95,126].contains(b) ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
            }.joined()
        }
        let encoded = fields.map { component($0.name) + ($0.value.map { "=" + component($0) } ?? "") }.joined(separator: "&")
        guard encoded.utf8.count <= WorkflowLimits.queryBytes else { throw AutomationError.limitExceeded }
        return encoded
    }
}

public enum WorkflowRequestBody: Equatable, Sendable {
    case json(JSONValue)
    case raw(Data, contentType: String)
}

public struct WorkflowRequestIntent: Equatable, Sendable {
    public let method: String
    public let path: String
    public let query: [WorkflowQueryField]
    public let body: WorkflowRequestBody?
    public let continuation: JSONValue?
    public let encodedQuery: String
    /// Exactly the bytes to freeze and send; JSON must not be reserialized by transport.
    public let wireBody: Data?
    public let contentType: String?
    public let json: JSONValue
    init(validating value: JSONValue) throws {
        let f = try JSONFields(value, required: ["type", "method", "path"], optional: ["query", "body", "continuation"])
        guard try f.string("type") == "sameOrigin" else { throw AutomationError.invalidJSON }
        method = try WorkflowPath.validateMethod(f.string("method")); path = try WorkflowPath.canonicalize(f.string("path"))
        query = f.has("query") ? try f.array("query").map { v in
            let p = try JSONFields(v, required: ["name", "value"])
            let v = try p.value("value")
            if v == .null { return WorkflowQueryField(name: try p.string("name"), value: nil) }
            return try WorkflowQueryField(name: p.string("name"), value: p.string("value"))
        } : []
        encodedQuery = try WorkflowQueryField.encode(query)
        if f.has("continuation") {
            let c = try f.value("continuation")
            guard case .object = c, c.nesting <= 16, try c.data().count <= WorkflowLimits.continuationBytes else { throw AutomationError.limitExceeded }
            continuation = c
        } else { continuation = nil }
        if f.has("body") {
            guard method != "GET", method != "HEAD" else { throw AutomationError.invalidJSON }
            let b = try JSONFields(f.value("body"), required: ["mode"], optional: ["value", "base64", "contentType"])
            switch try b.string("mode") {
            case "json":
                guard !b.has("base64"), !b.has("contentType") else { throw AutomationError.invalidJSON }
                let v = try b.value("value"); wireBody = try v.data(); body = .json(v); contentType = "application/json"
            case "raw":
                guard !b.has("value") else { throw AutomationError.invalidJSON }
                let bytes = try StrictBase64.decode(b.string("base64")), type = try b.string("contentType")
                guard Self.isContentType(type) else { throw AutomationError.invalidJSON }
                body = .raw(bytes, contentType: type); wireBody = bytes; contentType = type
            default: throw AutomationError.invalidJSON
            }
            guard wireBody!.count <= WorkflowLimits.bodyBytes else { throw AutomationError.limitExceeded }
        } else { body = nil; wireBody = nil; contentType = nil }
        var canonical = f.d; canonical["path"] = .string(path); json = .object(canonical)
    }
    static func isContentType(_ type: String) -> Bool {
        guard type.utf8.count <= 256, type.utf8.allSatisfy({ (32...126).contains($0) }) else { return false }
        let bytes = Array(type.utf8)
        var i = 0
        func token(_ b: UInt8) -> Bool {
            (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || Array("!#$%&'*+-.^_`|~".utf8).contains(b)
        }
        func consumeToken() -> Bool {
            let start = i
            while i < bytes.count && token(bytes[i]) { i += 1 }
            return i > start
        }
        guard consumeToken(), i < bytes.count, bytes[i] == 47 else { return false }
        i += 1
        guard consumeToken() else { return false }
        while i < bytes.count {
            while i < bytes.count && bytes[i] == 32 { i += 1 }
            guard i < bytes.count, bytes[i] == 59 else { return false }
            i += 1
            while i < bytes.count && bytes[i] == 32 { i += 1 }
            guard consumeToken(), i < bytes.count, bytes[i] == 61 else { return false }
            i += 1
            if i < bytes.count && bytes[i] == 34 {
                i += 1
                var closed = false
                while i < bytes.count {
                    if bytes[i] == 34 { i += 1; closed = true; break }
                    if bytes[i] == 92 { i += 1; guard i < bytes.count else { return false } }
                    i += 1
                }
                guard closed else { return false }
            } else { guard consumeToken() else { return false } }
        }
        return true
    }
}

public struct WorkflowPlanningResult: Equatable, Sendable {
    public let intent: WorkflowRequestIntent?
    public init(parsing data: Data) throws {
        guard data.count <= WorkflowLimits.planningBytes else { throw AutomationError.limitExceeded }
        let value = try StrictJSON.parse(data)
        guard value.nesting <= 32 else { throw AutomationError.limitExceeded }
        let f = try JSONFields(value, required: ["actions"]), actions = try f.array("actions")
        guard actions.count <= 1 else { throw AutomationError.invalidJSON }
        intent = try actions.first.map(WorkflowRequestIntent.init(validating:))
    }
}

public struct WorkflowWebhookIntent: Equatable, Sendable {
    public let endpointID: UUID
    public let json: JSONValue
    public let payloadBytes: Data
}

public struct WorkflowResult: Equatable, Sendable {
    public let delivery: WorkflowWebhookIntent?
    public init(parsing data: Data, endpointID: UUID?) throws {
        guard data.count <= WorkflowLimits.resultBytes else { throw AutomationError.limitExceeded }
        let value = try StrictJSON.parse(data)
        guard value.nesting <= 32 else { throw AutomationError.limitExceeded }
        let f = try JSONFields(value, required: ["actions"]), actions = try f.array("actions")
        guard actions.count <= 1 else { throw AutomationError.invalidJSON }
        if let action = actions.first {
            let a = try JSONFields(action, required: ["type", "endpointId", "json"])
            guard try a.string("type") == "webhook", let endpointID, try a.uuid("endpointId") == endpointID else { throw AutomationError.invalidJSON }
            let json = try a.value("json")
            delivery = try WorkflowWebhookIntent(endpointID: endpointID, json: json, payloadBytes: json.data())
        } else { delivery = nil }
    }
}
