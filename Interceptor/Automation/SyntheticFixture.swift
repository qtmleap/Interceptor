import AutomationCore
import AutomationRuntime
import Foundation

/// Clearly synthetic request/response event and config for the dry run. Never derived from saved captures.
enum SyntheticFixture {
    /// Already laid out by `JSONPrettyPrinter`, so focusing and leaving an editor never changes it.
    static func eventJSON(for hook: JavaScriptHook) -> String {
        JSONPrettyPrinter.format(rawEventJSON(for: hook), maxBytes: JavaScriptLimits.maxEventBytes)
    }

    /// Package tests use declared routes, so an otherwise valid sample does not silently miss every hook.
    static func eventJSON(for hook: JavaScriptHook, manifest: PluginManifest) -> String {
        let fallback = eventJSON(for: hook)
        guard manifest.schemaVersion == 2,
              let match = manifest.matches.first(where: { $0.hooks[hook.rawValue] != nil }),
              var event = try? JSONValue(parsing: Data(fallback.utf8)).objectValue,
              var request = event["request"]?.objectValue,
              let host = match.hosts.sorted().first else { return fallback }
        let originalRequest = request
        request["host"] = .string(host)
        if let method = match.methods?.sorted().first { request["method"] = .string(method) }
        switch match.path {
            case let .exact(path)?, let .prefix(path)?: request["path"] = .string(path)
            case nil: break
        }
        guard request != originalRequest else { return fallback }
        event["request"] = .object(request)
        guard let encoded = try? JSONValue.object(event).jsonString() else { return fallback }
        return JSONPrettyPrinter.format(encoded, maxBytes: JavaScriptLimits.maxEventBytes)
    }

    static var configJSON: String {
        JSONPrettyPrinter.format(rawConfigJSON, maxBytes: JavaScriptLimits.maxConfigBytes)
    }

    private static func rawEventJSON(for hook: JavaScriptHook) -> String {
        switch hook {
            case .requestEnter, .requestLeave, .responseEnter, .responseLeave:
                let response = hook == .responseEnter || hook == .responseLeave
                return """
                {
                  "id": "00000000-0000-4000-8000-000000000002",
                  "phase": "\(hook.rawValue)",
                  "request": { "method": "POST", "host": "example.com", "path": "/synthetic", "headers": {}, "body": {"limit": 20} }\(response ? ",\n  \"response\": {\"status\": 200, \"headers\": {}, \"body\": {\"maintenance\": false}}" : "")
                }
                """
            case .request:
                return """
                {
                  "id": "00000000-0000-4000-8000-000000000001",
                  "exchangeID": "00000000-0000-4000-8000-000000000002",
                  "phase": "request.completed",
                  "time": "2026-01-01T00:00:00Z",
                  "request": { "method": "GET", "host": "example.com", "path": "/synthetic" }
                }
                """
            case .response:
                return """
                {
                  "id": "00000000-0000-4000-8000-000000000003",
                  "exchangeID": "00000000-0000-4000-8000-000000000002",
                  "phase": "response.completed",
                  "time": "2026-01-01T00:00:01Z",
                  "request": { "method": "GET", "host": "example.com", "path": "/synthetic" },
                  "response": { "status": 503 }
                }
                """
        }
    }

    private static var rawConfigJSON: String {
        "{\n  \"endpoints\": { \"preview\": \"\(AutomationTemplate.previewEndpointID.uuidString)\" }\n}"
    }
}

/// One validated, display-only intent. Dry runs never construct a dispatcher or transport.
struct ValidatedAction: Equatable, Identifiable {
    enum Kind: Equatable {
        case webhook(UUID)
        case http(binding: String, destination: String)
    }
    let id: Int
    let kind: Kind
    let json: String

    var endpointID: UUID? {
        if case let .webhook(id) = kind { return id }
        return nil
    }
    var outboundBinding: String? {
        if case let .http(binding, _) = kind { return binding }
        return nil
    }
    var destination: String? {
        if case let .http(_, destination) = kind { return destination }
        return nil
    }

    /// Re-validates the runtime's result bytes: `{actions:[{type:"webhook",endpointId:UUID,json:any}]}`, max 2.
    static func parse(_ data: Data) throws -> [ValidatedAction] {
        try parse(data, manifest: nil)
    }

    static func parse(_ data: Data, manifest: PluginManifest?) throws -> [ValidatedAction] {
        guard data.count <= JavaScriptLimits.maxResultBytes,
              let root = try? JSONValue(parsing: data), let object = root.objectValue, Set(object.keys) == ["actions"],
              let actions = object["actions"]?.arrayValue, actions.count <= JavaScriptLimits.maxActions
        else {
            throw JavaScriptExecutionError.invalidResult
        }
        return try actions.enumerated().map { index, action in
            if action.objectValue?["type"]?.stringValue == "http" {
                guard let manifest, manifest.schemaVersion == 2,
                      let intent = try? PluginOutboundIntent.validating(action, manifest: manifest)
                else { throw JavaScriptExecutionError.invalidResult }
                let payload = JSONValue.object(intent.headers.mapValues(JSONValue.string))
                return try ValidatedAction(id: index, kind: .http(binding: intent.binding, destination: intent.endpoint.url),
                                           json: payload.jsonString())
            }
            guard let a = action.objectValue, Set(a.keys) == ["type", "endpointId", "json"], a["type"]?.stringValue == "webhook",
                  let id = a["endpointId"]?.stringValue.flatMap(UUID.init(uuidString:)), let payload = a["json"],
                  let text = try? payload.jsonString() else { throw JavaScriptExecutionError.invalidResult }
            return ValidatedAction(id: index, kind: .webhook(id), json: text)
        }
    }
}
