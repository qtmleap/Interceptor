import CQuickJS
import AutomationCore
import Foundation

/// Which declarative hook of a plugin source is invoked.
public enum JavaScriptHook: String, Sendable, CaseIterable {
    case request
    case response
    case requestEnter = "request.onEnter"
    case requestLeave = "request.onLeave"
    case responseEnter = "response.onEnter"
    case responseLeave = "response.onLeave"

    /// Global function name the script must define for this hook (legacy v1 hooks only).
    public var functionName: String {
        switch self {
        case .request: return "onRequest"
        case .response: return "onResponse"
        case .requestEnter, .requestLeave, .responseEnter, .responseLeave: return rawValue
        }
    }

    /// The four dotted lifecycle phases run through `JavaScriptExecutor.runV2` only.
    public var isLifecyclePhase: Bool {
        switch self {
        case .request, .response: return false
        case .requestEnter, .requestLeave, .responseEnter, .responseLeave: return true
        }
    }
}

public enum JavaScriptExecutionError: Error, Equatable, Sendable {
    case timeout
    case cancelled
    /// VM resource limit: heap, stack, or numeric operand size.
    case memoryOrStack
    case invalidInput
    case invalidResult
    case scriptError
    /// Another invocation is already admitted; rejected immediately, never queued.
    case busy
    /// Unexpected engine/bridge failure (allocation of the host objects, internal engine state).
    case internalFailure
}

public enum JavaScriptLimits {
    public static let deadlineMilliseconds = 50
    public static let heapBytes = 8 * 1024 * 1024
    public static let stackBytes = 256 * 1024
    public static let maxSourceBytes = 131_072
    public static let maxEventBytes = 65_536
    public static let maxConfigBytes = 8_192
    public static let maxResultBytes = 32 * 1024
    public static let maxResultDepth = 32
    public static let maxActions = 2
    public static let maxManifestBytes = 32 * 1024
    public static let maxPackageBytes = 256 * 1024
}

/// One admitted invocation. Owns the native cancel token for exactly its lifetime: the token is
/// freed under the same lock `cancel()` takes, so a late cancel can never touch freed memory.
private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OpaquePointer?

    init?() {
        guard let token = qjs_cancel_token_new() else { return nil }
        self.token = token
    }

    var nativeToken: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func cancel() {
        lock.lock()
        if let token { qjs_cancel_token_cancel(token) }
        lock.unlock()
    }

    /// Must be called after `qjs_run` has returned.
    func finish() {
        lock.lock()
        if let token { qjs_cancel_token_free(token) }
        token = nil
        lock.unlock()
    }
}

/// Runs one bounded plugin hook at a time on a dedicated serial queue with a fresh VM per call.
/// Input/output are bounded JSON `Data`; result is `{"actions":[{type,endpointId,json}]}`.
public final class JavaScriptExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.interceptor.automation.javascript", qos: .userInitiated)
    private let lock = NSLock()
    private var current: Job?

    public init() {}

    public func run(source: String, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data {
        // Cheap caps first; the bridge re-checks everything (including UTF-8, NUL and JSON shape).
        guard !hook.isLifecyclePhase,
              source.utf8.count <= JavaScriptLimits.maxSourceBytes,
              eventJSON.count <= JavaScriptLimits.maxEventBytes,
              configJSON.count <= JavaScriptLimits.maxConfigBytes else {
            throw JavaScriptExecutionError.invalidInput
        }
        return try await admitAndRun(input: Data(source.utf8), hookName: hook.functionName, event: eventJSON, config: configJSON, isV2: false)
    }

    private func admitAndRun(input: Data, hookName: String, event: Data, config: Data, isV2: Bool) async throws -> Data {
        if Task.isCancelled { throw JavaScriptExecutionError.cancelled }
        guard let job = Job() else { throw JavaScriptExecutionError.internalFailure }
        guard admit(job) else {
            job.finish()
            throw JavaScriptExecutionError.busy
        }
        let sourceBytes = Array(input)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    let outcome = Result { try Self.execute(job: job, source: sourceBytes, hook: hookName,
                                                           event: event, config: config, isV2: isV2) }
                    // Release admission before resuming so the caller can immediately run again.
                    self.release(job)
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            job.cancel()
        }
    }


    /// Evaluates only the source selected by the full strict schema 2 package and raw event.
    /// The native C boundary independently validates every file, route, reference and grant.
    public func runV2(packageJSON: Data, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data {
        guard hook.isLifecyclePhase, !packageJSON.isEmpty,
              packageJSON.count <= JavaScriptLimits.maxPackageBytes,
              eventJSON.count <= JavaScriptLimits.maxEventBytes,
              configJSON.count <= JavaScriptLimits.maxConfigBytes else {
            throw JavaScriptExecutionError.invalidInput
        }
        return try await admitAndRun(input: packageJSON, hookName: hook.functionName, event: eventJSON, config: configJSON, isV2: true)
    }

    /// Cancels the currently admitted invocation, if any. Idle calls must not affect later runs.
    public func cancel() {
        lock.lock()
        let job = current
        lock.unlock()
        job?.cancel()
    }

    private func admit(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if current != nil { return false }
        current = job
        return true
    }

    private func release(_ job: Job) {
        job.finish()
        lock.lock()
        if current === job { current = nil }
        lock.unlock()
    }

    private static func execute(job: Job, source: [UInt8], hook: String, event: Data, config: Data, isV2: Bool) throws -> Data {
        // Run strict parsing on the worker queue, before JS can discard duplicate keys.
        do {
            guard case .object = try JSONValue(parsing: event),
                  case .object = try JSONValue(parsing: config) else {
                throw JavaScriptExecutionError.invalidInput
            }
        } catch { throw JavaScriptExecutionError.invalidInput }
        var limits = QJSLimits(
            deadline_ms: JavaScriptLimits.deadlineMilliseconds,
            heap_bytes: JavaScriptLimits.heapBytes,
            stack_bytes: JavaScriptLimits.stackBytes,
            max_source_bytes: JavaScriptLimits.maxSourceBytes,
            max_event_bytes: JavaScriptLimits.maxEventBytes,
            max_config_bytes: JavaScriptLimits.maxConfigBytes,
            max_result_bytes: JavaScriptLimits.maxResultBytes,
            max_result_depth: JavaScriptLimits.maxResultDepth,
            max_actions: JavaScriptLimits.maxActions)
        let token = job.nativeToken
        var result = source.withUnsafeBufferPointer { src in
            event.withUnsafeBytes { ev in
                config.withUnsafeBytes { cfg in
                    let evp = ev.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    let cfgp = cfg.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    if isV2 {
                        return qjs_run_v2(token, &limits, src.baseAddress, src.count, hook, evp, ev.count, cfgp, cfg.count)
                    }
                    return qjs_run(token, &limits, src.baseAddress, src.count, hook, evp, ev.count, cfgp, cfg.count)
                }
            }
        }
        defer { qjs_result_free(&result) }
        switch result.status {
        case Int32(QJS_OK):
            guard let bytes = result.data, result.length <= JavaScriptLimits.maxResultBytes else {
                throw JavaScriptExecutionError.invalidResult
            }
            let data = Data(bytes: bytes, count: result.length)
            do { _ = try JSONValue(parsing: data) }
            catch { throw JavaScriptExecutionError.invalidResult }
            return data
        case Int32(QJS_TIMEOUT): throw JavaScriptExecutionError.timeout
        case Int32(QJS_CANCELLED): throw JavaScriptExecutionError.cancelled
        case Int32(QJS_MEMORY_OR_STACK): throw JavaScriptExecutionError.memoryOrStack
        case Int32(QJS_INVALID_INPUT): throw JavaScriptExecutionError.invalidInput
        case Int32(QJS_INVALID_RESULT): throw JavaScriptExecutionError.invalidResult
        case Int32(QJS_SCRIPT_ERROR): throw JavaScriptExecutionError.scriptError
        default: throw JavaScriptExecutionError.internalFailure
        }
    }
}
