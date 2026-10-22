import CQuickJS
import Foundation

/// Phases recorded inside the native v2 call. Raw values match `QJS_DIAG_PHASE_*`. A record means the
/// phase was ENTERED; the previous phase completed at the same instant.
enum JavaScriptDiagnosticPhase: Int32, Sendable, CaseIterable {
    case preflight = 1
    case inputCopy = 2
    case inputScan = 3
    case runtime = 4
    case context = 5
    case jsonParse = 6
    case package = 7
    case configEvent = 8
    case selection = 9
    case originalBody = 10
    case apiInstall = 11
    case eval = 12
    case callbacks = 13
    case result = 14
    case finalAcceptance = 15
    case teardown = 16
    case exit = 17
}

/// How the first (sticky) stop was detected, independent of the phase it happened in.
/// Raw values match `QJS_DIAG_ORIGIN_*`.
enum JavaScriptStopOrigin: Int32, Sendable, CaseIterable {
    case none = 0
    case interrupt = 1
    case inlinePoll = 2
    case finalCheck = 3
}

struct JavaScriptDiagnosticRecord: Equatable, Sendable {
    var phase: JavaScriptDiagnosticPhase
    /// Nanoseconds since the C deadline start (monotonic wall).
    var wallNanos: UInt64
    /// Worker-thread CPU nanoseconds since the first CPU reading; comparable only inside one C call.
    var threadCPUNanos: UInt64
}

/// Swift-side boundaries of one diagnosed call. Monotonic wall only: never mixed with thread CPU.
enum JavaScriptCallerPhase: Int, Sendable, CaseIterable {
    case called, admitted, workerStarted, preflightStarted, preflightFinished, nativeFinished, resultHandlingFinished, released, returned
}

struct JavaScriptCallerMark: Equatable, Sendable {
    var phase: JavaScriptCallerPhase
    var uptimeNanos: UInt64
}

/// Scalar-only trace of one diagnosed run: no payload, source, file name or exception text.
struct JavaScriptDiagnosticTrace: Equatable, Sendable {
    var capacity = 0
    /// Bounded decoder anomaly count (invalid count/capacity or unknown phase code).
    var nativeRecordAnomalies = 0
    var records: [JavaScriptDiagnosticRecord] = []
    var wallSupported = false
    var threadCPUSupported = false
    var nativeStatus: Int32?
    var stopStatus: Int32 = 0
    var stopOrigin = JavaScriptStopOrigin.none
    var stopPhase: JavaScriptDiagnosticPhase?
    /// Since the C deadline start / first CPU reading, at the first stop detection (0 when none).
    var stopWallNanos: UInt64 = 0
    var stopThreadCPUNanos: UInt64 = 0
    var interruptPolls: UInt32 = 0
    var inlinePolls: UInt32 = 0
    var deadlineRelativeNanos: UInt64 = 0
    var limitsValid = false
    var deadlineMilliseconds = 0
    var heapBytes = 0
    var stackBytes = 0
    var maxResultBytes = 0
    var packageLength: UInt64 = 0
    var eventLength: UInt64 = 0
    var configLength: UInt64 = 0
    var sourceLength: UInt64 = 0
    var resultLength: UInt64 = 0
    var routeCount = 0
    var fileCount = 0
    var registrationCount = 0
    var selectedRoute = -1
    var selectedSource = -1
    var callerMarks: [JavaScriptCallerMark] = []

    static let empty = JavaScriptDiagnosticTrace()

    init() {}

    init(native d: QJSDiagnostics) {
        records = withUnsafeBytes(of: d.records) { raw in
            let base = raw.bindMemory(to: QJSDiagnosticRecord.self)
            let storageCount = min(base.count, Int(QJS_DIAG_CAPACITY))
            capacity = storageCount
            if Int(d.capacity) != storageCount { nativeRecordAnomalies += 1 }
            if Int(d.count) > storageCount { nativeRecordAnomalies += 1 }
            if d.count > d.capacity { nativeRecordAnomalies += 1 }
            // Reported metadata is diagnostic input, never a pointer-indexing bound.
            let count = min(Int(d.count), storageCount)
            return (0..<count).compactMap { i in
                guard let phase = JavaScriptDiagnosticPhase(rawValue: base[i].phase) else {
                    nativeRecordAnomalies += 1
                    return nil
                }
                return JavaScriptDiagnosticRecord(phase: phase, wallNanos: base[i].wall_ns,
                                                  threadCPUNanos: base[i].thread_cpu_ns)
            }
        }
        wallSupported = d.supported_flags & UInt32(QJS_DIAG_WALL_SUPPORTED) != 0
        threadCPUSupported = d.supported_flags & UInt32(QJS_DIAG_THREAD_CPU_SUPPORTED) != 0
        nativeStatus = d.status
        stopStatus = d.stop_status
        stopOrigin = JavaScriptStopOrigin(rawValue: d.stop_origin) ?? .none
        stopPhase = JavaScriptDiagnosticPhase(rawValue: d.stop_phase)
        stopWallNanos = d.stop_wall_ns
        stopThreadCPUNanos = d.stop_thread_cpu_ns
        interruptPolls = d.interrupt_polls
        inlinePolls = d.inline_polls
        deadlineRelativeNanos = d.deadline_relative_ns
        limitsValid = d.limits_valid != 0
        deadlineMilliseconds = Int(d.limits.deadline_ms)
        heapBytes = Int(d.limits.heap_bytes)
        stackBytes = Int(d.limits.stack_bytes)
        maxResultBytes = Int(d.limits.max_result_bytes)
        packageLength = d.package_len
        eventLength = d.event_len
        configLength = d.config_len
        sourceLength = d.source_len
        resultLength = d.result_len
        routeCount = Int(d.route_count)
        fileCount = Int(d.file_count)
        registrationCount = Int(d.registration_count)
        selectedRoute = Int(d.selected_route)
        selectedSource = Int(d.selected_source)
    }

    /// Wall nanoseconds between two caller marks, if both exist.
    func callerNanos(from a: JavaScriptCallerPhase, to b: JavaScriptCallerPhase) -> UInt64? {
        guard let x = callerMarks.first(where: { $0.phase == a }), let y = callerMarks.first(where: { $0.phase == b }),
              y.uptimeNanos >= x.uptimeNanos else { return nil }
        return y.uptimeNanos - x.uptimeNanos
    }

    /// Nanoseconds between two native phase records (wall).
    func nativeWallNanos(from a: JavaScriptDiagnosticPhase, to b: JavaScriptDiagnosticPhase) -> UInt64? {
        guard let x = records.first(where: { $0.phase == a }), let y = records.first(where: { $0.phase == b }),
              y.wallNanos >= x.wallNanos else { return nil }
        return y.wallNanos - x.wallNanos
    }

    func nativeCPUNanos(from a: JavaScriptDiagnosticPhase, to b: JavaScriptDiagnosticPhase) -> UInt64? {
        guard let x = records.first(where: { $0.phase == a }), let y = records.first(where: { $0.phase == b }),
              y.threadCPUNanos >= x.threadCPUNanos else { return nil }
        return y.threadCPUNanos - x.threadCPUNanos
    }
}

/// Outcome identical to the ordinary `runV2` result or error, plus the trace (kept on failure too).
struct JavaScriptDiagnosedRun: Sendable {
    var outcome: Result<Data, JavaScriptExecutionError>
    var trace: JavaScriptDiagnosticTrace
}

/// Bounded, per-call collector shared between the caller task and the worker queue.
///
/// Safety: `@unchecked Sendable` because every mutable field is guarded by `lock`. The lock only
/// guards short appends/assignments of scalars; it is never held across the C call, a continuation
/// resume, or any callout. The fixed `JavaScriptCallerPhase` set bounds `marks` (each phase once).
final class JavaScriptDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [JavaScriptCallerMark] = []
    private var native: JavaScriptDiagnosticTrace?

    init() { marks.reserveCapacity(JavaScriptCallerPhase.allCases.count) }

    func mark(_ phase: JavaScriptCallerPhase) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if !marks.contains(where: { $0.phase == phase }) { marks.append(JavaScriptCallerMark(phase: phase, uptimeNanos: now)) }
        lock.unlock()
    }

    func setNative(_ trace: JavaScriptDiagnosticTrace) {
        lock.lock()
        native = trace
        lock.unlock()
    }

    func snapshot() -> JavaScriptDiagnosticTrace {
        lock.lock()
        defer { lock.unlock() }
        var trace = native ?? .empty
        trace.callerMarks = marks
        return trace
    }
}

extension JavaScriptExecutor {
    /// Same admission, worker, strict preflight, native call and result validation as `runV2`;
    /// the only difference is the opt-in collector. Failures and early rejections keep their trace.
    func runV2Diagnosed(packageJSON: Data, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async -> JavaScriptDiagnosedRun {
        let collector = JavaScriptDiagnosticCollector()
        let outcome: Result<Data, JavaScriptExecutionError>
        do {
            outcome = .success(try await runV2(packageJSON: packageJSON, hook: hook, eventJSON: eventJSON,
                                               configJSON: configJSON, collector: collector))
        } catch {
            outcome = .failure(error as? JavaScriptExecutionError ?? .internalFailure)
        }
        collector.mark(.returned)
        return JavaScriptDiagnosedRun(outcome: outcome, trace: collector.snapshot())
    }
}
