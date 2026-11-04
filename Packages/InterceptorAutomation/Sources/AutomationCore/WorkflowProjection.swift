import Foundation

public struct WorkflowHeaderField: Equatable, Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
    public var json: JSONValue { .object(["name": .string(name), "value": .string(value)]) }
}

public struct WorkflowAuthority: Equatable, Sendable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int = 443) throws {
        guard host == host.lowercased(), !host.isEmpty, host.utf8.count <= 253, (1...65535).contains(port), host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
            !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw AutomationError.invalidJSON }
        self.host = host; self.port = port
    }
    public var hostHeader: String { port == 443 ? host : "\(host):\(port)" }
}

public enum WorkflowHeaderPolicy {
    static func validate(_ field: WorkflowHeaderField) throws {
        guard PluginManifest.isHeaderName(field.name), field.value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw AutomationError.invalidJSON }
    }
    public static func validateOriginal(_ fields: [WorkflowHeaderField], authority: WorkflowAuthority) throws -> Set<String> {
        guard try JSONValue.array(fields.map(\.json)).data().count <= WorkflowLimits.headerBytes else { throw AutomationError.limitExceeded }
        for field in fields { try validate(field) }
        let hosts = fields.filter { $0.name.lowercased() == "host" }
        guard hosts.count == 1 else { throw AutomationError.invalidJSON }
        let h = hosts[0].value.lowercased()
        guard h == authority.hostHeader || (authority.port == 443 && h == authority.host + ":443") else { throw AutomationError.invalidJSON }
        var nominated: Set<String> = []
        for field in fields where field.name.lowercased() == "connection" {
            for component in field.value.split(separator: ",", omittingEmptySubsequences: false) {
                let name = component.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard PluginManifest.isHeaderName(name) else { throw AutomationError.invalidJSON }
                nominated.insert(name.lowercased())
            }
        }
        return nominated
    }
    public static func inherit(original: [WorkflowHeaderField], authority: WorkflowAuthority, declaration: WorkflowHeaderInheritance, grant: WorkflowHeaderInheritance, body: WorkflowRequestBody?) throws -> [WorkflowHeaderField] {
        let nominated = try validateOriginal(original, authority: authority)
        func includes(_ name: String, _ scope: WorkflowHeaderInheritance) -> Bool {
            switch scope { case .allEndToEnd: return true; case .names(let names): return names.contains { $0.lowercased() == name } }
        }
        let excluded = Set(["connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host", "content-encoding", "content-length", "content-type", "content-md5", "digest", "content-digest", "repr-digest", "expect", "idempotency-key"])
        var output: [WorkflowHeaderField] = [], authorization: String?
        for field in original {
            let name = field.name.lowercased()
            guard includes(name, declaration), includes(name, grant) else { continue }
            if name == "authorization" {
                if let authorization { guard authorization == field.value else { throw AutomationError.invalidJSON }; continue }
                authorization = field.value
            }
            guard !excluded.contains(name), !nominated.contains(name) else { continue }
            output.append(field)
        }
        output.append(.init(name: "Host", value: authority.hostHeader))
        if let body {
            let type: String
            switch body {
            case .json(let value): guard try value.data().count <= WorkflowLimits.bodyBytes else { throw AutomationError.limitExceeded }; type = "application/json"
            case .raw(let bytes, let contentType):
                guard bytes.count <= WorkflowLimits.bodyBytes, WorkflowRequestIntent.isContentType(contentType) else { throw AutomationError.invalidJSON }; type = contentType
            }
            output.append(.init(name: "Content-Type", value: type))
        }
        guard try JSONValue.array(output.map(\.json)).data().count <= WorkflowLimits.headerBytes else { throw AutomationError.limitExceeded }
        return output
    }
}

public enum WorkflowBodyUnavailableReason: String, Equatable, Sendable {
    case notCaptured, unsupportedEncoding, invalidJSON, decodeLimit
}
public enum WorkflowBodySnapshot: Equatable, Sendable {
    case absent, complete(Data), truncated, unavailable(WorkflowBodyUnavailableReason)
}

public enum WorkflowProjection {
    /// The caller supplies a read declaration already intersected with the frozen grant.
    /// Header visibility is a separate native opt-in. Body projection and native forwarding are independent.
    public static func project(metadata: [String: JSONValue], headers: [WorkflowHeaderField], query: [WorkflowQueryField], body: WorkflowBodySnapshot, read: PluginReadDeclaration, headersEnabled: Bool = false) throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        for key in read.metadata { if let value = metadata[key] { result[key] = value } }
        if headersEnabled && !read.headers.isEmpty {
            let selected = try headers.filter { field in try WorkflowHeaderPolicy.validate(field); return read.headers.contains { $0.lowercased() == field.name.lowercased() } }.map { WorkflowHeaderField(name: $0.name.lowercased(), value: $0.value) }
            let value = JSONValue.array(selected.map(\.json))
            guard try value.data().count <= WorkflowLimits.headerBytes else { throw AutomationError.limitExceeded }
            result["headers"] = value
        }
        if !read.queryKeys.isEmpty {
            let selected = query.filter { read.queryKeys.contains($0.name) }
            _ = try WorkflowQueryField.encode(selected); result["query"] = .array(selected.map(\.json))
        }
        if read.body != .none { result["body"] = try bodyValue(body, mode: read.body) }
        return .object(result)
    }
    static func bodyValue(_ body: WorkflowBodySnapshot, mode: PluginReadDeclaration.Body) throws -> JSONValue {
        func state(_ s: String) -> JSONValue { .object(["state": .string(s)]) }
        func unavailable(_ r: WorkflowBodyUnavailableReason) -> JSONValue { .object(["state": .string("unavailable"), "reason": .string(r.rawValue)]) }
        switch body {
        case .absent: return state("absent")
        case .truncated: return state("truncated")
        case .unavailable(let reason): return unavailable(reason)
        case .complete(let bytes):
            guard bytes.count <= WorkflowLimits.bodyBytes else { return unavailable(.decodeLimit) }
            switch mode {
            case .none: throw AutomationError.invalidJSON
            case .raw: return .object(["state": .string("complete"), "mode": .string("raw"), "base64": .string(bytes.base64EncodedString())])
            case .jsonPointers(let pointers):
                guard let json = try? StrictJSON.parse(bytes) else { return unavailable(.invalidJSON) }
                let values = pointers.map { pointer -> JSONValue in
                    var entry: [String: JSONValue] = ["pointer": .string(pointer)]
                    if let value = resolve(pointer, in: json) { entry["found"] = .bool(true); entry["value"] = value }
                    else { entry["found"] = .bool(false) }
                    return .object(entry)
                }
                let output = JSONValue.object(["state": .string("complete"), "mode": .string("jsonPointers"), "values": .array(values)])
                // Repeated parent pointers may amplify data; bound before entering the VM.
                guard try output.data().count <= WorkflowLimits.inputBytes else { return unavailable(.decodeLimit) }
                return output
            }
        }
    }
    static func resolve(_ pointer: String, in json: JSONValue) -> JSONValue? {
        if pointer.isEmpty { return json }
        var value = json
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch value {
            case .object(let object): guard let found = object[key] else { return nil }; value = found
            case .array(let array):
                guard key == "0" || key.first != "0", !key.isEmpty, key.utf8.allSatisfy({ (48...57).contains($0) }), let index = Int(key), array.indices.contains(index) else { return nil }; value = array[index]
            default: return nil
            }
        }
        return value
    }
}
