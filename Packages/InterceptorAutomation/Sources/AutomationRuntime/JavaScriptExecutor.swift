import CQuickJS
import Foundation

/// Which declarative hook of a plugin source is invoked.
public enum JavaScriptHook: String, Sendable, CaseIterable {
    case request
    case response

    /// Global function name the script must define for this hook.
    public var functionName: String {
        switch self {
        case .request: return "onRequest"
        case .response: return "onResponse"
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
        guard source.utf8.count <= JavaScriptLimits.maxSourceBytes,
              eventJSON.count <= JavaScriptLimits.maxEventBytes,
              configJSON.count <= JavaScriptLimits.maxConfigBytes else {
            throw JavaScriptExecutionError.invalidInput
        }
        if Task.isCancelled { throw JavaScriptExecutionError.cancelled }
        guard let job = Job() else { throw JavaScriptExecutionError.internalFailure }
        guard admit(job) else {
            job.finish()
            throw JavaScriptExecutionError.busy
        }
        let sourceBytes = Array(source.utf8)
        let hookName = hook.functionName
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    let outcome = Result { try Self.execute(job: job, source: sourceBytes, hook: hookName,
                                                           event: eventJSON, config: configJSON) }
                    // Release admission before resuming so the caller can immediately run again.
                    self.release(job)
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            job.cancel()
        }
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

    private static func execute(job: Job, source: [UInt8], hook: String, event: Data, config: Data) throws -> Data {
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
                    qjs_run(token, &limits,
                            src.baseAddress, src.count,
                            hook,
                            ev.baseAddress?.assumingMemoryBound(to: UInt8.self), ev.count,
                            cfg.baseAddress?.assumingMemoryBound(to: UInt8.self), cfg.count)
                }
            }
        }
        defer { qjs_result_free(&result) }
        switch result.status {
        case Int32(QJS_OK):
            guard let bytes = result.data, result.length <= JavaScriptLimits.maxResultBytes else {
                throw JavaScriptExecutionError.invalidResult
            }
            return Data(bytes: bytes, count: result.length)
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
