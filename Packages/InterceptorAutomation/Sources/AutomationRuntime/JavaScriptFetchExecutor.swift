import AutomationCore
import CQuickJS
import Foundation

public struct JavaScriptFetchRequest: Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeoutMilliseconds: Int
    public let maxResponseBytes: Int
}

public struct JavaScriptFetchResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// One fetch-enabled invocation: native cancel token plus the in-flight transport task.
/// Both are guarded by one lock so a late `cancel()` can neither touch a freed token nor miss a
/// task installed after cancellation was requested.
private final class FetchJob: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OpaquePointer?
    private var task: Task<Void, Never>?
    private var cancelled = false

    init?() {
        guard let token = qjs_cancel_token_new() else { return nil }
        self.token = token
    }

    var nativeToken: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let token {
            qjs_cancel_token_cancel(token)
        }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    /// Installs the task; if cancellation already happened the task is cancelled immediately.
    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let already = cancelled
        lock.unlock()
        if already {
            task.cancel()
        }
    }

    func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    /// Call only after `qjs_run_v2_fetch` has returned.
    func finish() {
        lock.lock()
        if let token {
            qjs_cancel_token_free(token)
        }
        token = nil
        lock.unlock()
    }
}

private final class FetchContext: @unchecked Sendable {
    let job: FetchJob
    let transport: JavaScriptFetchExecutor.Transport
    init(job: FetchJob, transport: @escaping JavaScriptFetchExecutor.Transport) {
        self.job = job
        self.transport = transport
    }
}

private let fetchMaxResponseBytes = 1024 * 1024

/// C callback: decodes the validated request, drives the async transport to completion on this
/// owned thread and always awaits/stops the transport task before returning.
private let fetchCallback: QJSFetchCallback = { opaque, json, length, timeoutMs, reply in
    guard let opaque, let json, let reply else { return 2 }
    let context = Unmanaged<FetchContext>.fromOpaque(opaque).takeUnretainedValue()
    let job = context.job
    if job.isCancelled {
        return 2
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(bytes: json, count: length)) as? [String: Any],
          let url = object["url"] as? String, let method = object["method"] as? String,
          let headers = object["headers"] as? [String: String] else { return 1 }
    let request = JavaScriptFetchRequest(
        url: url, method: method, headers: headers,
        body: (object["body"] as? String).map { Data($0.utf8) },
        timeoutMilliseconds: Int(timeoutMs), maxResponseBytes: fetchMaxResponseBytes,
    )

    let done = DispatchSemaphore(value: 0)
    let transport = context.transport
    let box = ResultBox()
    let task = Task<Void, Never> {
        do { box.value = try await .success(transport(request)) } catch { box.value = .failure(error) }
        done.signal()
    }
    job.install(task)
    var timedOut = false
    if done.wait(timeout: .now() + .milliseconds(Int(timeoutMs) + 250)) == .timedOut {
        timedOut = true
        task.cancel()
        done.wait()
    }
    let outcome = box.value ?? .failure(CancellationError())
    job.clearTask()
    if job.isCancelled {
        return 2
    }
    switch outcome {
        case let .success(response):
            guard (100 ... 599).contains(response.status), response.body.count <= fetchMaxResponseBytes else { return 1 }
            let ok = response.body.withUnsafeBytes { raw in
                qjs_fetch_reply_set(reply, Int32(response.status), raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
            }
            return ok == 0 ? 0 : 1
        case let .failure(error):
            return error is CancellationError && !timedOut ? 2 : 1
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<JavaScriptFetchResponse, Error>? // written before the semaphore signal
}

/// Runs `response.onLeave` with the standard global `fetch`, one VM per call on an owned thread.
/// At most two instances run at once process-wide; one per executor. Extras fail with `.busy`.
public final class JavaScriptFetchExecutor: @unchecked Sendable {
    /// Trusted host transport: honor the request deadline and Task cancellation, and finish owned
    /// I/O before returning. The callback waits for completion so no socket outlives the invocation.
    public typealias Transport = @Sendable (JavaScriptFetchRequest) async throws -> JavaScriptFetchResponse

    private static let globalLock = NSLock()
    private nonisolated(unsafe) static var globalActive = 0
    private static let globalSlots = 2
    private static let stackBytes = 2 * 1024 * 1024
    static let cpuDeadlineMilliseconds = 250

    private let lock = NSLock()
    private var current: FetchJob?

    public init() {}

    public func runV2(packageJSON: Data, hook: JavaScriptHook, eventJSON: Data, configJSON: Data,
                      transport: @escaping Transport) async throws -> Data
    {
        guard hook == .responseLeave, !packageJSON.isEmpty,
              packageJSON.count <= JavaScriptLimits.maxPackageBytes,
              eventJSON.count <= JavaScriptLimits.maxEventBytes,
              configJSON.count <= JavaScriptLimits.maxConfigBytes
        else {
            throw JavaScriptExecutionError.invalidInput
        }
        if Task.isCancelled {
            throw JavaScriptExecutionError.cancelled
        }
        guard let job = FetchJob() else { throw JavaScriptExecutionError.internalFailure }
        guard admit(job) else {
            job.finish()
            throw JavaScriptExecutionError.busy
        }
        let hookName = hook.functionName
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let thread = Thread {
                    let outcome = Result {
                        try Self.execute(job: job, package: packageJSON, hook: hookName, event: eventJSON,
                                         config: configJSON, transport: transport)
                    }
                    // Release admission (instance and global) before resuming the caller.
                    self.release(job)
                    continuation.resume(with: outcome)
                }
                thread.name = "app.interceptor.automation.fetch"
                thread.stackSize = Self.stackBytes
                thread.qualityOfService = .userInitiated
                thread.start()
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

    private func admit(_ job: FetchJob) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if current != nil {
            return false
        }
        Self.globalLock.lock()
        defer { Self.globalLock.unlock() }
        if Self.globalActive >= Self.globalSlots {
            return false
        }
        Self.globalActive += 1
        current = job
        return true
    }

    private func release(_ job: FetchJob) {
        job.finish()
        lock.lock()
        if current === job {
            current = nil
            Self.globalLock.lock()
            Self.globalActive -= 1
            Self.globalLock.unlock()
        }
        lock.unlock()
    }

    private static func execute(job: FetchJob, package: Data, hook: String, event: Data, config: Data,
                                transport: @escaping Transport) throws -> Data
    {
        do {
            guard case .object = try JSONValue(parsing: event),
                  case .object = try JSONValue(parsing: config) else { throw JavaScriptExecutionError.invalidInput }
        } catch { throw JavaScriptExecutionError.invalidInput }
        var limits = QJSLimits(
            deadline_ms: cpuDeadlineMilliseconds,
            heap_bytes: JavaScriptLimits.heapBytes,
            stack_bytes: JavaScriptLimits.stackBytes,
            max_source_bytes: JavaScriptLimits.maxSourceBytes,
            max_event_bytes: JavaScriptLimits.maxEventBytes,
            max_config_bytes: JavaScriptLimits.maxConfigBytes,
            max_result_bytes: JavaScriptLimits.maxResultBytes,
            max_result_depth: JavaScriptLimits.maxResultDepth,
            max_actions: JavaScriptLimits.maxActions,
        )
        let context = FetchContext(job: job, transport: transport)
        let token = job.nativeToken
        var result = withExtendedLifetime(context) {
            let opaque = Unmanaged.passUnretained(context).toOpaque()
            return package.withUnsafeBytes { pkg in
                event.withUnsafeBytes { ev in
                    config.withUnsafeBytes { cfg in
                        qjs_run_v2_fetch(token, &limits, fetchCallback, opaque,
                                         pkg.baseAddress?.assumingMemoryBound(to: UInt8.self), pkg.count, hook,
                                         ev.baseAddress?.assumingMemoryBound(to: UInt8.self), ev.count,
                                         cfg.baseAddress?.assumingMemoryBound(to: UInt8.self), cfg.count)
                    }
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
                do { _ = try JSONValue(parsing: data) } catch { throw JavaScriptExecutionError.invalidResult }
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
