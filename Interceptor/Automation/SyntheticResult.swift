import AutomationCore
import AutomationRuntime
import Foundation

/// Display-only dry-run output. Revalidates mutation authority before showing a preview.
struct SyntheticResult {
    let actions: [ValidatedAction]
    let bodyPreview: String?

    static func parse(_ data: Data, hook: JavaScriptHook, manifest: PluginManifest) throws -> Self {
        guard data.count <= JavaScriptLimits.maxResultBytes,
              let object = try JSONValue(parsing: data).objectValue,
              Set(object.keys).isSubset(of: ["actions", "mutation"]), let actions = object["actions"]
        else {
            throw JavaScriptExecutionError.invalidResult
        }
        let validated = try ValidatedAction.parse(JSONValue.object(["actions": actions]).data(), manifest: manifest)
        var preview: String?
        if let mutation = object["mutation"] {
            guard manifest.schemaVersion == 2, manifest.read.body == .json,
                  (hook == .requestEnter && manifest.writeRequestBody) || (hook == .responseEnter && manifest.writeResponseBody),
                  let fields = mutation.objectValue, Set(fields.keys) == ["body"], let body = fields["body"]
            else {
                throw JavaScriptExecutionError.invalidResult
            }
            let bytes = try body.data()
            guard bytes.count <= 24 * 1024 else { throw JavaScriptExecutionError.invalidResult }
            preview = String(decoding: bytes, as: UTF8.self)
        }
        return Self(actions: validated, bodyPreview: preview)
    }
}
