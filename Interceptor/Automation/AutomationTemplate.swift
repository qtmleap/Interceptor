import AutomationCore
import Foundation

/// The "create example" starter: metadata-only reads, example.com, no live capture. The sample source
/// returns at most one declarative webhook intent aimed at the fixed synthetic preview endpoint; nothing is sent.
enum AutomationTemplate {
    static let previewEndpointID = UUID(uuidString: "5E1D0C4A-0000-4000-8000-00000000A001")!
    static let source = """
    // Synthetic example. Returns at most one declarative webhook intent; nothing is ever sent.
    function onRequest(event, config) {
      if (event.request.method !== "GET") return { actions: [] };
      return { actions: [{ type: "webhook", endpointId: config.endpoints.preview,
                           json: { eventId: event.id, phase: event.phase, host: event.request.host } }] };
    }

    function onResponse(event, config) {
      if (event.response.status < 500) return { actions: [] };
      return { actions: [{ type: "webhook", endpointId: config.endpoints.preview,
                           json: { eventId: event.id, status: event.response.status } }] };
    }

    """

    static func packageBytes(name: String, id: UUID = UUID()) throws -> Data {
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string(id.uuidString), "name": .string(name), "version": .string("1.0.0"),
            "subscriptions": .array([
                .object(["phase": .string("request.completed"), "match": .object(["hosts": .array([.string("example.com")])])]),
                .object(["phase": .string("response.completed"), "match": .object(["hosts": .array([.string("example.com")])])]),
            ]),
            "read": .object(["metadata": .array([.string("method"), .string("host"), .string("status"), .string("path")]),
                             "headers": .array([]), "queryKeys": .array([]), "body": .object(["mode": .string("none")])]),
            "endpointBindings": .array([.string("preview")]),
            "settings": .object([:]),
        ])
        return try JSONValue.object(["manifest": manifest, "source": .string(source)]).data()
    }
}
