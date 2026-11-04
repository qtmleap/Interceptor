import Foundation

/// Strict input/config validation shared with native service preparation. Validation precedes VM admission.
public enum WorkflowInput {
    public static func validateConfig(_ data: Data) throws -> UUID? {
        guard data.count <= 16 * 1024 else { throw AutomationError.limitExceeded }
        let f = try JSONFields(StrictJSON.parse(data), required: ["settings", "endpoints"])
        let settings = try f.value("settings")
        guard case .object = settings, settings.nesting <= 16, try settings.data().count <= 8192 else { throw AutomationError.invalidJSON }
        guard case .object(let endpoints) = try f.value("endpoints"), endpoints.count <= 1 else { throw AutomationError.invalidJSON }
        guard let (binding, value) = endpoints.first else { return nil }
        guard !binding.isEmpty, binding.utf8.count <= 32, let first = binding.utf8.first,
              (65...90).contains(first) || (97...122).contains(first),
              binding.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              case .string(let id) = value, let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw AutomationError.invalidJSON }
        return uuid
    }

    public static func validate(_ data: Data, httpResult: Bool, responsePlanning: Bool = false) throws {
        guard !data.isEmpty, data.count <= WorkflowLimits.inputBytes else { throw AutomationError.limitExceeded }
        let f = try JSONFields(StrictJSON.parse(data), required: httpResult ? ["operationID", "eventID", "exchangeID", "phase", "time", "request", "response"] : ["id", "exchangeID", "phase", "time", "request"], optional: httpResult ? ["continuation"] : responsePlanning ? ["response"] : [])
        _ = try f.uuid(httpResult ? "eventID" : "id"); _ = try f.uuid("exchangeID")
        guard DateCodec.parse(try f.string("time")) != nil else { throw AutomationError.invalidJSON }
        if httpResult {
            _ = try f.uuid("operationID")
            guard try f.string("phase") == "http.result" else { throw AutomationError.invalidJSON }
            if f.has("continuation") {
                let c = try f.value("continuation")
                guard case .object = c, c.nesting <= 16, try c.data().count <= WorkflowLimits.continuationBytes else { throw AutomationError.limitExceeded }
            }
        } else {
            guard let phase = PluginSubscription.Phase(rawValue: try f.string("phase")), phase.isResponse == responsePlanning else { throw AutomationError.invalidJSON }
        }
        try validateProjection(f.value("request"), response: false)
        if f.has("response") { try validateProjection(f.value("response"), response: true) }
        else if responsePlanning { throw AutomationError.invalidJSON }
    }

    public static func validateProjection(_ value: JSONValue, response: Bool) throws {
        let f = try JSONFields(value, required: [], optional: response ? ["status", "headers", "body"] : ["method", "host", "path", "headers", "query", "body"])
        if f.has("status") { guard (100...599).contains(try f.int("status")) else { throw AutomationError.invalidJSON } }
        if f.has("method") { _ = try WorkflowPath.validateMethod(f.string("method")) }
        if f.has("host") { _ = try WorkflowAuthority(host: f.string("host")) }
        if f.has("path") { _ = try WorkflowPath.canonicalize(f.string("path")) }
        if f.has("headers") {
            let headers = try f.array("headers")
            guard try JSONValue.array(headers).data().count <= WorkflowLimits.headerBytes else { throw AutomationError.limitExceeded }
            for value in headers {
                let h = try JSONFields(value, required: ["name", "value"]), name = try h.string("name")
                guard name == name.lowercased() else { throw AutomationError.invalidJSON }
                try WorkflowHeaderPolicy.validate(.init(name: name, value: h.string("value")))
            }
        }
        if f.has("query") {
            let pairs = try f.array("query").map { value -> WorkflowQueryField in
                let q = try JSONFields(value, required: ["name", "value"])
                return try .init(name: q.string("name"), value: q.value("value") == .null ? nil : q.string("value"))
            }
            _ = try WorkflowQueryField.encode(pairs)
        }
        if f.has("body") { try validateBody(f.value("body")) }
    }
    private static func validateBody(_ value: JSONValue) throws {
        let f = try JSONFields(value, required: ["state"], optional: ["mode", "base64", "values", "reason"])
        switch try f.string("state") {
        case "absent", "truncated": guard f.d.count == 1 else { throw AutomationError.invalidJSON }
        case "unavailable": guard f.d.count == 2, WorkflowBodyUnavailableReason(rawValue: try f.string("reason")) != nil else { throw AutomationError.invalidJSON }
        case "complete":
            guard f.d.count == 3 else { throw AutomationError.invalidJSON }
            switch try f.string("mode") {
            case "raw": guard try StrictBase64.decode(f.string("base64")).count <= WorkflowLimits.bodyBytes else { throw AutomationError.limitExceeded }
            case "jsonPointers":
                let values = try f.array("values")
                guard values.count <= 32 else { throw AutomationError.limitExceeded }
                for value in values {
                    let p = try JSONFields(value, required: ["pointer", "found"], optional: ["value"])
                    guard PluginManifest.isJSONPointer(try p.string("pointer")), try p.bool("found") == p.has("value") else { throw AutomationError.invalidJSON }
                }
            default: throw AutomationError.invalidJSON
            }
        default: throw AutomationError.invalidJSON
        }
    }
}
