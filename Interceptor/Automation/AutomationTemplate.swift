import AutomationCore
import Foundation

/// A disabled v2 example. Body edits are shown by the synthetic run and need separate live approval.
enum AutomationTemplate {
    static let previewEndpointID = UUID(uuidString: "5E1D0C4A-0000-4000-8000-00000000A001")!
    static let sourceFile = "hooks/example.com/synthetic/POST.js"
    static let source = """
    // Each callback uses a fresh VM. Leave callbacks see read-only traffic.
    Interceptor.attach({
      request: {
        onEnter(request, config) { request.body.limit = 5; },
        onLeave(request, config) {},
      },
      response: {
        onEnter(response, config) { response.body.maintenance = true; },
        onLeave(response, config) {},
      },
    });

    """

    static func packageBytes(name: String, id: UUID = UUID()) throws -> Data {
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(2), "id": .string(id.uuidString), "name": .string(name), "version": .string("1.0.0"),
            "matches": .array([.object([
                "hosts": .array([.string("example.com")]), "methods": .array([.string("POST")]),
                "path": .object(["kind": .string("exact"), "value": .string("/synthetic")]),
                "hooks": .object([
                    "request": .object(["onEnter": .string(sourceFile), "onLeave": .string(sourceFile)]),
                    "response": .object(["onEnter": .string(sourceFile), "onLeave": .string(sourceFile)]),
                ]),
            ])]),
            "read": .object(["metadata": .array([.string("method"), .string("host"), .string("status"), .string("path")]),
                             "headers": .array([]), "queryKeys": .array([]), "body": .object(["mode": .string("json")])]),
            "write": .object(["requestBody": .bool(true), "responseBody": .bool(true)]),
            "endpointBindings": .array([]), "settings": .object([:]),
        ])
        return try JSONValue.object(["manifest": manifest, "sourceFiles": .object([sourceFile: .string(source)])]).data()
    }
}
