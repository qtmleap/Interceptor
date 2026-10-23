import AutomationCore
import AutomationRuntime
import Foundation
import Mudmouth
import MudmouthHTTPHooks

/// Immutable connection-time grants. A generation change invalidates all work admitted by this instance.
final class HTTPPluginProcessor: HTTPPluginProcessing, Sendable {
    enum Failure: Error, Equatable { case revoked, invalidResult }
    private let store: PluginActivationStore
    private let snapshot: PluginActivationSnapshot
    private let executor = JavaScriptExecutor()
    // The single executor rejects overlapping runs, so whole phases are admitted one at a time.
    private let admission = HTTPPluginPhaseAdmission()
    private let hasCaptureConsent: @Sendable () -> Bool
    private let outbound: HTTPPluginOutboundDispatcher
    private static let bodyLimit = 24 * 1024

    private struct PhaseResult {
        var body: Data?
        var intents: [PluginOutboundIntent] = []
    }

    init(store: PluginActivationStore, snapshot: PluginActivationSnapshot,
         hasCaptureConsent: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
         outboundTransport: any HTTPPluginOutboundTransport = HTTPPluginDirectTransport(),
         outboundObserver: HTTPPluginOutboundDispatcher.Observer? = nil)
    {
        self.store = store
        self.snapshot = snapshot
        self.hasCaptureConsent = hasCaptureConsent
        outbound = HTTPPluginOutboundDispatcher(transport: outboundTransport, observer: outboundObserver)
    }

    func matches(_ request: HTTPPluginRequest) -> Bool {
        snapshot.revisions.contains { revision in
            // Status is unknown until response enter. Preserve those candidates for the response.
            revision.package.manifest.matches.contains { match in
                guard match.hosts.contains(request.host), match.methods?.contains(request.method) != false else { return false }
                switch match.path {
                    case let .exact(path)?: return request.path == path
                    case let .prefix(path)?: return request.path.hasPrefix(path)
                    case nil: return true
                }
            }
        }
    }

    func isAuthorized() async -> Bool {
        guard outbound.isActive, hasCaptureConsent() else { return false }
        let current = await store.isCurrent(admitted: snapshot)
        return current && outbound.isActive
    }

    /// Synchronous so tunnel shutdown/revocation cannot leave a window for new outbound admission.
    func shutdown() {
        outbound.shutdown()
        executor.cancel()
    }

    func waitUntilStopped() async -> Bool {
        await outbound.waitUntilStopped()
    }

    func process(_ phase: HTTPPluginPhase, request: HTTPPluginRequest, response: HTTPPluginResponse?) async throws -> Data? {
        try await admission.acquire()
        // No await inside a defer: release explicitly on every path.
        let result: PhaseResult
        do {
            // A grant can race with cancellation; honor the cancellation, but never keep the permit.
            if Task.isCancelled {
                throw JavaScriptExecutionError.cancelled
            }
            result = try await processAdmitted(phase, request: request, response: response)
        } catch {
            await admission.release()
            throw error
        }
        await admission.release()
        // The complete phase, including every result and mutation, is validated before any send.
        // No networking is awaited while a phase or VM permit is held.
        guard !Task.isCancelled else { throw JavaScriptExecutionError.cancelled }
        guard await isAuthorized() else { throw Failure.revoked }
        outbound.submit(result.intents) { [self] in await isAuthorized() }
        return result.body
    }

    private func processAdmitted(_ phase: HTTPPluginPhase, request: HTTPPluginRequest,
                                 response: HTTPPluginResponse?) async throws -> PhaseResult
    {
        guard await isAuthorized() else { throw Failure.revoked }
        guard let hook = JavaScriptHook(rawValue: phase.rawValue) else { throw Failure.invalidResult }
        let isResponse = phase == .responseEnter || phase == .responseLeave
        let isEnter = phase == .requestEnter || phase == .responseEnter
        let original = isResponse ? response?.body : request.body
        // Transport admits only complete eligible JSON messages. Retain the bounded/bodyless guard;
        // filtering below does not admit streaming or unsupported traffic to hooks.
        guard let original, !original.isEmpty, original.count <= Self.bodyLimit else { return PhaseResult() }
        var body = original
        var receivedMutation = false
        var intents: [PluginOutboundIntent] = []
        for approved in snapshot.revisions {
            guard await isAuthorized() else { throw Failure.revoked }
            let package = approved.package, manifest = package.manifest
            guard manifest.matches.contains(where: {
                $0.matches(method: request.method, host: request.host, path: request.path, status: isResponse ? response?.status : nil)
            }) else { continue }
            var req: [String: JSONValue] = try ["method": .string(request.method), "host": .string(request.host),
                                                "path": .string(request.path),
                                                "headers": Self.headers(request.headers, granted: manifest.read.headers)]
            // Bound the event to granted fields before VM admission. C independently enforces the
            // same grants; raw request identity remains available only for authoritative matching.
            req["query"] = Self.query(request.query, granted: manifest.read.queryKeys)
            if manifest.read.body == .json {
                if isResponse {
                    // Transport retains only complete eligible forwarded request JSON. A missing
                    // or unparseable associated body must not suppress an eligible response hook.
                    if !request.body.isEmpty, request.body.count <= Self.bodyLimit,
                       let forwarded = try? JSONValue(parsing: request.body)
                    {
                        req["body"] = forwarded
                    }
                } else {
                    req["body"] = try JSONValue(parsing: body)
                }
            }
            var event: [String: JSONValue] = ["id": .string(request.id.uuidString), "phase": .string(phase.rawValue),
                                              "request": .object(req)]
            if let response, isResponse {
                var leg: [String: JSONValue] = try ["status": .integer(Int64(response.status)),
                                                    "headers": Self.headers(response.headers, granted: manifest.read.headers)]
                if manifest.read.body == .json {
                    leg["body"] = try JSONValue(parsing: body)
                }
                event["response"] = .object(leg)
            }
            let eventBytes = try JSONValue.object(event).data()
            guard eventBytes.count <= JavaScriptLimits.maxEventBytes else { throw Failure.invalidResult }
            let config = try JSONValue.object(["settings": manifest.settings, "endpoints": .object([:])]).data()
            guard config.count <= JavaScriptLimits.maxConfigBytes else { throw JavaScriptExecutionError.invalidInput }
            let output = try await executor.runV2(packageJSON: package.bytes, hook: hook, eventJSON: eventBytes,
                                                  configJSON: config)
            guard await isAuthorized() else { throw Failure.revoked }
            guard output.count <= JavaScriptLimits.maxResultBytes,
                  let fields = try JSONValue(parsing: output).objectValue,
                  Set(fields.keys).isSubset(of: ["actions", "mutation"]), let actions = fields["actions"]?.arrayValue,
                  actions.count <= JavaScriptLimits.maxActions
            else {
                throw Failure.invalidResult
            }
            for action in actions {
                if action.objectValue?["type"]?.stringValue == "http" {
                    guard manifest.schemaVersion == 2,
                          let intent = try? PluginOutboundIntent.validating(action, manifest: manifest)
                    else { throw Failure.invalidResult }
                    intents.append(intent)
                    guard intents.count <= JavaScriptLimits.maxActions else { throw Failure.invalidResult }
                } else {
                    // Legacy webhook actions remain display-only, but must still cross a strict boundary.
                    guard let fields = action.objectValue, Set(fields.keys) == ["type", "endpointId", "json"],
                          fields["type"]?.stringValue == "webhook",
                          fields["endpointId"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil,
                          fields["json"] != nil else { throw Failure.invalidResult }
                }
            }
            if let mutation = fields["mutation"] {
                guard isEnter, manifest.read.body == .json,
                      isResponse ? manifest.writeResponseBody : manifest.writeRequestBody,
                      let fields = mutation.objectValue, Set(fields.keys) == ["body"], let value = fields["body"]
                else {
                    throw Failure.invalidResult
                }
                let bytes = try value.data()
                guard bytes.count <= Self.bodyLimit else { throw Failure.invalidResult }
                body = bytes
                receivedMutation = true
            }
        }
        guard await isAuthorized() else { throw Failure.revoked }
        guard isEnter, receivedMutation else { return PhaseResult(intents: intents) }
        guard try JSONValue(parsing: body) != JSONValue(parsing: original) else { return PhaseResult(intents: intents) }
        return PhaseResult(body: body, intents: intents)
    }

    private static func headers(_ values: [String: String], granted: [String]) throws -> JSONValue {
        var names = Set<String>()
        var result: [String: JSONValue] = [:]
        for declared in granted {
            // Manifest header names are ASCII tokens. Do not use Unicode case conversion here.
            let name = String(decoding: declared.utf8.map { (65 ... 90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
            guard names.insert(name).inserted else { throw JavaScriptExecutionError.invalidInput }
            // Transport canonicalizes header names to lowercase; never combine ambiguous spellings.
            if let value = values[name] {
                result[name] = .string(value)
            }
        }
        return .object(result)
    }

    private static func query(_ values: [String: String], granted: [String]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        // Query names are byte-exact. Swift String lookup treats canonically equivalent
        // Unicode spellings as equal and could otherwise expose an ungranted byte-key.
        for name in granted {
            if let entry = values.first(where: { name.utf8.elementsEqual($0.key.utf8) }) {
                result[name] = .string(entry.value)
            }
        }
        return .object(result)
    }
}

/// FIFO admission for whole hook phases: one active phase plus a bounded queue.
/// Overload fails fast with `.busy` instead of growing an unbounded backlog.
actor HTTPPluginPhaseAdmission {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumWaiting: Int
    private var isActive = false
    private var waiters: [Waiter] = []

    init(maximumWaiting: Int = 8) {
        self.maximumWaiting = maximumWaiting
    }

    func acquire() async throws {
        if Task.isCancelled {
            throw JavaScriptExecutionError.cancelled
        }
        if !isActive {
            isActive = true
            return
        }
        guard waiters.count < maximumWaiting else { throw JavaScriptExecutionError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs on the actor in the same turn as the append. Cancellation before registration
                // is seen here; later cancellation finds the waiter through cancelWaiter.
                if Task.isCancelled {
                    continuation.resume(throwing: JavaScriptExecutionError.cancelled)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the permit to the oldest waiter, or frees it when nobody waits.
    func release() {
        if waiters.isEmpty {
            isActive = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        // Already granted or never queued: nothing to do. Removal guarantees a single resume.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: JavaScriptExecutionError.cancelled)
    }
}
