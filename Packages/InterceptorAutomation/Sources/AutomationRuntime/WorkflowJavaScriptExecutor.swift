import CQuickJS
import AutomationCore
import Foundation

public enum WorkflowStage: Int32, Sendable, CaseIterable {
    case requestPlanning = 1, responsePlanning = 2, httpResult = 3
}

/// Each token belongs to one admitted operation, including while its invocation waits on the worker.
private final class WorkflowJob: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OpaquePointer?
    init?() { guard let t = qjs_cancel_token_new() else { return nil }; token = t }
    var native: OpaquePointer? { lock.lock(); defer { lock.unlock() }; return token }
    func cancel() { lock.lock(); if let token { qjs_cancel_token_cancel(token) }; lock.unlock() }
    func finish() { lock.lock(); if let token { qjs_cancel_token_free(token) }; token = nil; lock.unlock() }
}

/// Separate v2 executor. At most two admitted jobs, no unbounded queue, fresh VM per stage.
/// Cancellation targets an operation; the legacy global cancellation API is never used.
public final class WorkflowJavaScriptExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.interceptor.automation.workflow", qos: .userInitiated)
    private let lock = NSLock()
    private var jobs: [UUID: WorkflowJob] = [:]
    public init() {}

    public func run(source: String, stage: WorkflowStage, inputJSON: Data, configJSON: Data, operationID: UUID) async throws -> Data {
        guard !source.isEmpty, source.utf8.count <= JavaScriptLimits.maxSourceBytes, inputJSON.count <= WorkflowLimits.inputBytes, configJSON.count <= 16384 else { throw JavaScriptExecutionError.invalidInput }
        if Task.isCancelled { throw JavaScriptExecutionError.cancelled }
        let endpointID: UUID?
        do {
            endpointID = try WorkflowInput.validateConfig(configJSON)
            try WorkflowInput.validate(inputJSON, httpResult: stage == .httpResult, responsePlanning: stage == .responsePlanning)
        } catch { throw JavaScriptExecutionError.invalidInput }
        guard let job = WorkflowJob() else { throw JavaScriptExecutionError.internalFailure }
        guard admit(job, operationID: operationID) else { job.finish(); throw JavaScriptExecutionError.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    let result = Result { try Self.execute(job: job, source: Array(source.utf8), stage: stage, input: inputJSON, config: configJSON, endpointID: endpointID) }
                    self.release(job, operationID: operationID)
                    continuation.resume(with: result)
                }
            }
        } onCancel: { job.cancel() }
    }
    public func cancel(operationID: UUID) { lock.lock(); let job = jobs[operationID]; lock.unlock(); job?.cancel() }
    private func admit(_ job: WorkflowJob, operationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard jobs.count < 2, jobs[operationID] == nil else { return false }; jobs[operationID] = job; return true
    }
    private func release(_ job: WorkflowJob, operationID: UUID) {
        job.finish(); lock.lock(); if jobs[operationID] === job { jobs[operationID] = nil }; lock.unlock()
    }
    private static func execute(job: WorkflowJob, source: [UInt8], stage: WorkflowStage, input: Data, config: Data, endpointID: UUID?) throws -> Data {
        let cap = stage == .httpResult ? WorkflowLimits.resultBytes : WorkflowLimits.planningBytes
        var limits = QJSLimits(deadline_ms: 50, heap_bytes: 8 * 1024 * 1024, stack_bytes: 256 * 1024,
                               max_source_bytes: JavaScriptLimits.maxSourceBytes, max_event_bytes: WorkflowLimits.inputBytes,
                               max_config_bytes: 16384, max_result_bytes: cap, max_result_depth: 32, max_actions: 1)
        var result = source.withUnsafeBufferPointer { src in input.withUnsafeBytes { event in config.withUnsafeBytes { cfg in
            qjs_run_workflow(job.native, &limits, stage.rawValue, src.baseAddress, src.count,
                             event.baseAddress?.assumingMemoryBound(to: UInt8.self), event.count,
                             cfg.baseAddress?.assumingMemoryBound(to: UInt8.self), cfg.count)
        } } }
        defer { qjs_result_free(&result) }
        switch result.status {
        case Int32(QJS_OK):
            guard let p = result.data, result.length <= cap else { throw JavaScriptExecutionError.invalidResult }
            let data = Data(bytes: p, count: result.length)
            do {
                if stage == .httpResult { _ = try WorkflowResult(parsing: data, endpointID: endpointID) }
                else { _ = try WorkflowPlanningResult(parsing: data) }
            } catch { throw JavaScriptExecutionError.invalidResult }
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
