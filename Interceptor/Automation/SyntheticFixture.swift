import AutomationCore
import AutomationRuntime
import Foundation

/// Clearly synthetic request/response event and config for the dry run. Never derived from saved captures.
enum SyntheticFixture {
    /// Already laid out by `JSONPrettyPrinter`, so focusing and leaving an editor never changes it.
    static func eventJSON(for hook: JavaScriptHook) -> String {
        JSONPrettyPrinter.format(rawEventJSON(for: hook), maxBytes: JavaScriptLimits.maxEventBytes)
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

/// One validated, display-only webhook intent. It is never queued or delivered.
struct ValidatedAction: Equatable, Identifiable {
    let id: Int
    let endpointID: UUID
    let json: String

    /// Re-validates the runtime's result bytes: `{actions:[{type:"webhook",endpointId:UUID,json:any}]}`, max 2.
    static func parse(_ data: Data) throws -> [ValidatedAction] {
        guard data.count <= JavaScriptLimits.maxResultBytes,
              let root = try? JSONValue(parsing: data), let object = root.objectValue, Set(object.keys) == ["actions"],
              let actions = object["actions"]?.arrayValue, actions.count <= JavaScriptLimits.maxActions
        else {
            throw JavaScriptExecutionError.invalidResult
        }
        return try actions.enumerated().map { index, action in
            guard let a = action.objectValue, Set(a.keys) == ["type", "endpointId", "json"], a["type"]?.stringValue == "webhook",
                  let id = a["endpointId"]?.stringValue.flatMap(UUID.init(uuidString:)), let payload = a["json"],
                  let text = try? payload.jsonString() else { throw JavaScriptExecutionError.invalidResult }
            return ValidatedAction(id: index, endpointID: id, json: text)
        }
    }
}
