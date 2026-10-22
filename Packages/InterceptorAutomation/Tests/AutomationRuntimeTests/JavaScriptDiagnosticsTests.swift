import XCTest
import CQuickJS
import AutomationCore
@testable import AutomationRuntime

/// Diagnostic trace of the real shared v2 runtime (50 ms deadline, strict package, public envelope).
/// No scheduler-dependent timing assertions: only ordering, presence, metadata and consistency.
final class JavaScriptDiagnosticsTests: XCTestCase, @unchecked Sendable {
    private let endpoint = "11111111-1111-1111-1111-111111111111"
    private let manifestID = "22222222-2222-4222-8222-222222222222"
    private let file = "hooks/api.example.com/search/POST.js"
    private let config = Data(#"{"limit":5}"#.utf8)
    private let deadlineNanos = UInt64(JavaScriptLimits.deadlineMilliseconds) * 1_000_000
    private let fullTrace: [JavaScriptDiagnosticPhase] = JavaScriptDiagnosticPhase.allCases
    private let setupTrace: [JavaScriptDiagnosticPhase] = [.preflight, .inputCopy, .inputScan, .runtime, .context, .jsonParse, .package, .configEvent, .selection]
    private let callerOrder = JavaScriptCallerPhase.allCases

    // MARK: fixtures

    private var match: String {
        #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"\#(file)","onLeave":"\#(file)"},"response":{"onEnter":"\#(file)","onLeave":"\#(file)"}}}"#
    }

    private func manifest(requestWrite: Bool = true) -> String {
        #"{"schemaVersion":2,"id":"\#(manifestID)","name":"Sample","version":"1.0.0","matches":[\#(match)],"read":{"metadata":["method","host","path","status"],"headers":["X-A"],"queryKeys":["q"],"body":{"mode":"json"}},"write":{"requestBody":\#(requestWrite),"responseBody":true},"endpointBindings":[],"settings":{"limit":5}}"#
    }

    private func package(_ source: String, requestWrite: Bool = true) throws -> Data {
        let code = try JSONValue.string(source).jsonString()
        return Data(#"{"manifest":\#(manifest(requestWrite: requestWrite)),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
    }

    private func event(host: String = "api.example.com") -> Data {
        Data(#"{"request":{"method":"POST","host":"\#(host)","path":"/search","headers":{"x-a":"1","Authorization":"secret"},"query":{"q":"1","token":"t"},"body":{"limit":10,"q":"x"}},"response":{"status":200,"headers":{"X-A":"r"},"body":{"ok":true}}}"#.utf8)
    }

    private func attach(_ requestEnter: String = "", requestLeave: String = "") -> String {
        "Interceptor.attach({request:{onEnter(request,config){\(requestEnter)},onLeave(){\(requestLeave)}},response:{onEnter(){},onLeave(){}}});"
    }

    private func marker(_ name: String) -> String { "return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{ran:'\(name)'}}]};" }

    private func ordinary(_ pkg: Data, _ hook: JavaScriptHook, event: Data? = nil) async -> Result<Data, JavaScriptExecutionError> {
        do { return .success(try await JavaScriptExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event ?? self.event(), configJSON: config)) }
        catch { return .failure(error as? JavaScriptExecutionError ?? .internalFailure) }
    }

    private func diagnosed(_ pkg: Data, _ hook: JavaScriptHook = .requestEnter, event: Data? = nil,
                           executor: JavaScriptExecutor = JavaScriptExecutor()) async -> JavaScriptDiagnosedRun {
        await executor.runV2Diagnosed(packageJSON: pkg, hook: hook, eventJSON: event ?? self.event(), configJSON: config)
    }

    /// Wall is always monotonic; thread CPU only when supported (zero otherwise).
    private func assertMonotonic(_ trace: JavaScriptDiagnosticTrace, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(trace.records, trace.records.dropFirst()) {
            XCTAssertLessThanOrEqual(a.wallNanos, b.wallNanos, "wall \(a.phase)->\(b.phase)", file: file, line: line)
            XCTAssertLessThanOrEqual(a.threadCPUNanos, b.threadCPUNanos, "cpu \(a.phase)->\(b.phase)", file: file, line: line)
        }
    }

    // MARK: normal path

    func testDiagnosedNormalRunRecordsAllPhasesForEveryHookWithOrdinaryOutcome() async throws {
        let pkg = try package(attach(marker("a"), requestLeave: marker("b")))
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .responseLeave] {
            let normal = await ordinary(pkg, hook)
            let run = await diagnosed(pkg, hook)
            XCTAssertEqual(run.outcome, normal, "\(hook)")
            XCTAssertEqual(run.trace.records.map(\.phase), fullTrace, "\(hook)")
            XCTAssertEqual(run.trace.stopOrigin, .none, "\(hook)")
            XCTAssertNil(run.trace.stopPhase, "\(hook)")
            XCTAssertEqual(run.trace.nativeStatus, Int32(QJS_OK), "\(hook)")
            assertMonotonic(run.trace)
        }
    }

    func testPhaseListSeparatesTheRequiredIntervals() {
        // scans/copies, runtime, context, JSON parse, package validation, config/event, selection,
        // original body, API install, eval, callbacks, result, final acceptance, teardown.
        XCTAssertEqual(JavaScriptDiagnosticPhase.allCases.count, 17, "boundaries are entered-phase records; completion is the next record")
        XCTAssertLessThanOrEqual(JavaScriptDiagnosticPhase.allCases.count, Int(QJS_DIAG_CAPACITY))
    }

    func testCallerBoundariesAreOrderedMonotonicWallMarks() async throws {
        let run = await diagnosed(try package(attach(marker("a"))))
        XCTAssertEqual(run.trace.callerMarks.map(\.phase), callerOrder)
        for (a, b) in zip(run.trace.callerMarks, run.trace.callerMarks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.uptimeNanos, b.uptimeNanos, "\(a.phase)->\(b.phase)")
        }
    }

    func testDiagnosedMutationAndReadOnlyOutcomesMatchOrdinary() async throws {
        let body = "request.body.limit=1; request.body.q='y'; return {actions:[]};"
        let writablePackage = try package(attach(body), requestWrite: true)
        let writableNormal = await ordinary(writablePackage, .requestEnter)
        let writable = await diagnosed(writablePackage)
        XCTAssertEqual(writable.outcome, writableNormal)
        let data = try XCTUnwrap(try? writable.outcome.get(), "writable mutation must succeed")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mutation = try XCTUnwrap(object["mutation"] as? [String: Any])
        let newBody = try XCTUnwrap(mutation["body"] as? [String: Any])
        XCTAssertEqual(newBody["limit"] as? Int, 1)
        XCTAssertEqual(newBody["q"] as? String, "y")
        XCTAssertEqual(writable.trace.records.map(\.phase), fullTrace)

        let readonlyPackage = try package(attach(body), requestWrite: false)
        let readonlyNormal = await ordinary(readonlyPackage, .requestEnter)
        let readonly = await diagnosed(readonlyPackage)
        XCTAssertEqual(readonlyNormal, .failure(.scriptError))
        XCTAssertEqual(readonly.outcome, readonlyNormal)
        XCTAssertEqual(readonly.trace.records.last?.phase, .exit)
        XCTAssertEqual(readonly.trace.nativeStatus, Int32(QJS_SCRIPT_ERROR))
        XCTAssertEqual(readonly.trace.stopOrigin, .none)
    }

    func testTraceIsBoundedFixedCapacityScalarRecords() async throws {
        let run = await diagnosed(try package(attach(marker("a"))))
        XCTAssertEqual(run.trace.capacity, Int(QJS_DIAG_CAPACITY))
        XCTAssertLessThanOrEqual(Int(QJS_DIAG_CAPACITY), 32)
        XCTAssertGreaterThan(run.trace.records.count, 0)
        XCTAssertLessThanOrEqual(run.trace.records.count, Int(QJS_DIAG_CAPACITY))
        XCTAssertLessThanOrEqual(MemoryLayout<QJSDiagnostics>.size, 1024 + 512, "native record block stays small and string-free")
        let dump = String(describing: run.trace)
        for secret in ["secret", "api.example.com", endpoint, "webhook", file] {
            XCTAssertFalse(dump.contains(secret), "trace must carry no payload: \(secret)")
        }
    }

    func testMetadataCapturesEffectiveLimitsSizesAndSelection() async throws {
        let pkg = try package(attach(marker("a")))
        let ev = event()
        let run = await diagnosed(pkg, event: ev)
        let t = run.trace
        XCTAssertTrue(t.limitsValid)
        XCTAssertEqual(t.deadlineMilliseconds, JavaScriptLimits.deadlineMilliseconds)
        XCTAssertEqual(t.deadlineRelativeNanos, deadlineNanos)
        XCTAssertEqual(t.heapBytes, JavaScriptLimits.heapBytes)
        XCTAssertEqual(t.stackBytes, JavaScriptLimits.stackBytes)
        XCTAssertEqual(t.maxResultBytes, JavaScriptLimits.maxResultBytes)
        XCTAssertEqual(t.packageLength, UInt64(pkg.count))
        XCTAssertEqual(t.eventLength, UInt64(ev.count))
        XCTAssertEqual(t.configLength, UInt64(config.count))
        XCTAssertGreaterThan(t.sourceLength, 0)
        XCTAssertEqual(t.resultLength, UInt64(try XCTUnwrap(try? run.outcome.get()).count))
        XCTAssertEqual(t.routeCount, 1)
        XCTAssertEqual(t.fileCount, 1)
        XCTAssertEqual(t.selectedRoute, 0)
        XCTAssertEqual(t.selectedSource, 0)
        XCTAssertGreaterThanOrEqual(t.registrationCount, 1)
    }

    func testWallClockAndOptionalThreadCPUAreConsistent() async throws {
        let run = await diagnosed(try package(attach("var s=0; for(var i=0;i<20000;i++){s+=i;}")))
        XCTAssertTrue(run.trace.wallSupported)
        let exit = try XCTUnwrap(run.trace.records.last)
        XCTAssertGreaterThan(exit.wallNanos, 0)
        if run.trace.threadCPUSupported {
            XCTAssertGreaterThan(exit.threadCPUNanos, 0)
        } else {
            XCTAssertTrue(run.trace.records.allSatisfy { $0.threadCPUNanos == 0 }, "unsupported CPU reports zero")
        }
        assertMonotonic(run.trace)
    }

    // MARK: first sticky stop: phase and origin are independent scalars

    /// Real wall-clock observations: a setup/scheduling expiry is explicitly inconclusive for
    /// loop interruption. Deterministic pre-cancel coverage below proves only first-stop precedence.
    func testEvalLoopTimeoutObservation() async throws {
        let pkg = try package("for(;;){}\n" + attach())
        let normal = await ordinary(pkg, .requestEnter)
        let run = await diagnosed(pkg)
        try recordTimeoutObservation(run, ordinary: normal, expectedLoopPhase: .eval, name: "eval-loop")
    }

    func testCallbackLoopTimeoutObservation() async throws {
        let pkg = try package(attach("for(;;){}"))
        let normal = await ordinary(pkg, .requestEnter)
        let run = await diagnosed(pkg)
        try recordTimeoutObservation(run, ordinary: normal, expectedLoopPhase: .callbacks, name: "callback-loop")
    }

    /// Persists bounded scalar evidence before validating or skipping. A skip is UNVERIFIED loop
    /// coverage, never evidence that the engine interrupted the requested loop.
    private func recordTimeoutObservation(_ run: JavaScriptDiagnosedRun,
                                          ordinary: Result<Data, JavaScriptExecutionError>? = nil,
                                          expectedLoopPhase: JavaScriptDiagnosticPhase?, name: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let t = run.trace
        let observed = expectedLoopPhase.map { t.stopPhase == $0 && t.stopOrigin == .interrupt } ?? false
        let phaseRecord = t.records.first { $0.phase == t.stopPhase }
        let consistent = run.outcome == .failure(.timeout) && (ordinary == nil || ordinary == .failure(.timeout)) &&
            t.nativeStatus == Int32(QJS_TIMEOUT) && t.stopStatus == Int32(QJS_TIMEOUT) &&
            t.stopOrigin != .none && phaseRecord != nil && t.records.last?.phase == .exit &&
            t.nativeRecordAnomalies == 0 && t.deadlineRelativeNanos == deadlineNanos &&
            t.stopWallNanos >= (phaseRecord?.wallNanos ?? UInt64.max) &&
            t.stopWallNanos <= (t.records.last?.wallNanos ?? 0)
        func outcome(_ value: Result<Data, JavaScriptExecutionError>?) -> [String: Any] {
            switch value {
            case .none: return ["kind": "not-run"]
            case .some(.success(let data)): return ["kind": "success", "resultBytes": data.count]
            case .some(.failure(let error)): return ["kind": "failure", "error": String(describing: error)]
            }
        }
        let coverage = !consistent ? "invalid-observation" : expectedLoopPhase == nil ? "not-claimed-recovery" : observed ? "observed" : "INCONCLUSIVE-unverified"
        let evidence: [String: Any] = [
            "name": name, "coverage": coverage, "expectedLoopPhase": Int(expectedLoopPhase?.rawValue ?? 0),
            "expectedLoopInterruptionObserved": observed, "consistentTimeout": consistent,
            "ordinaryOutcome": outcome(ordinary), "diagnosedOutcome": outcome(run.outcome),
            "nativeStatus": Int(t.nativeStatus ?? -1), "stopStatus": Int(t.stopStatus),
            "stopPhase": Int(t.stopPhase?.rawValue ?? 0), "stopOrigin": Int(t.stopOrigin.rawValue),
            "stopWallNs": t.stopWallNanos, "stopThreadCPUNs": t.stopThreadCPUNanos,
            "deadlineRelativeNs": t.deadlineRelativeNanos, "decoderAnomalies": t.nativeRecordAnomalies,
            "records": t.records.map { r -> [String: Any] in ["phase": Int(r.phase.rawValue), "wallNs": r.wallNanos, "threadCPUNs": r.threadCPUNanos] },
            "callerMarks": t.callerMarks.map { m -> [String: Any] in ["phase": m.phase.rawValue, "uptimeNs": m.uptimeNanos] }
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        // Unbuffered test stdout is retained by CI even when no dedicated output path is supplied.
        FileHandle.standardOutput.write(Data("diagnostics-loop-observation ".utf8) + data + Data([10]))
        if let prefix = ProcessInfo.processInfo.environment["DIAGNOSTICS_EVIDENCE_OUTPUT"], !prefix.isEmpty {
            try data.write(to: URL(fileURLWithPath: prefix + "." + name + ".json"), options: .atomic)
        }
        guard consistent else {
            XCTFail("Unexpected/inconsistent timeout observation; scalar evidence persisted", file: file, line: line)
            return
        }
        assertMonotonic(t, file: file, line: line)
        if expectedLoopPhase != nil && !observed {
            throw XCTSkip("INCONCLUSIVE: loop interruption UNVERIFIED; first stop phase=\(t.stopPhase?.rawValue ?? 0), origin=\(t.stopOrigin.rawValue). Evidence persisted; no retry.")
        }
    }

    func testPreCancelledNativeTokenStopsFirstInPreflightByInlinePollWithoutEvaluation() throws {
        let pkg = try package(attach("for(;;){}"))
        let ev = event()
        let token = try XCTUnwrap(qjs_cancel_token_new())
        defer { qjs_cancel_token_free(token) }
        qjs_cancel_token_cancel(token)
        var limits = QJSLimits(deadline_ms: JavaScriptLimits.deadlineMilliseconds, heap_bytes: JavaScriptLimits.heapBytes,
                               stack_bytes: JavaScriptLimits.stackBytes, max_source_bytes: JavaScriptLimits.maxSourceBytes,
                               max_event_bytes: JavaScriptLimits.maxEventBytes, max_config_bytes: JavaScriptLimits.maxConfigBytes,
                               max_result_bytes: JavaScriptLimits.maxResultBytes, max_result_depth: JavaScriptLimits.maxResultDepth,
                               max_actions: JavaScriptLimits.maxActions)
        var diag = QJSDiagnostics()
        var result = pkg.withUnsafeBytes { p in ev.withUnsafeBytes { e in config.withUnsafeBytes { c in
            qjs_run_v2_diagnostic(token, &limits, p.baseAddress?.assumingMemoryBound(to: UInt8.self), p.count, "request.onEnter",
                                  e.baseAddress?.assumingMemoryBound(to: UInt8.self), e.count,
                                  c.baseAddress?.assumingMemoryBound(to: UInt8.self), c.count, &diag)
        } } }
        defer { qjs_result_free(&result) }
        let trace = JavaScriptDiagnosticTrace(native: diag)
        XCTAssertEqual(result.status, Int32(QJS_CANCELLED))
        XCTAssertEqual(trace.nativeStatus, Int32(QJS_CANCELLED))
        XCTAssertEqual(trace.stopStatus, Int32(QJS_CANCELLED))
        XCTAssertEqual(trace.capacity, Int(QJS_DIAG_CAPACITY))
        XCTAssertEqual(trace.stopOrigin, .inlinePoll)
        XCTAssertEqual(trace.stopPhase, .preflight)
        XCTAssertEqual(trace.records.map(\.phase), [.preflight, .exit])
        XCTAssertEqual(trace.interruptPolls, 0, "no VM existed yet")
        XCTAssertEqual(trace.inlinePolls, 1)
        XCTAssertTrue(trace.wallSupported)
        XCTAssertEqual(trace.selectedRoute, -1)
        XCTAssertEqual(trace.sourceLength, 0, "nothing was selected or evaluated")
    }

    func testNullDiagnosticsPathMatchesDiagnosticEntryResult() throws {
        let pkg = try package(attach(marker("a")))
        let ev = event()
        func run(_ diagnostics: UnsafeMutablePointer<QJSDiagnostics>?) -> (Int32, Data?) {
            var limits = QJSLimits(deadline_ms: JavaScriptLimits.deadlineMilliseconds, heap_bytes: JavaScriptLimits.heapBytes,
                                   stack_bytes: JavaScriptLimits.stackBytes, max_source_bytes: JavaScriptLimits.maxSourceBytes,
                                   max_event_bytes: JavaScriptLimits.maxEventBytes, max_config_bytes: JavaScriptLimits.maxConfigBytes,
                                   max_result_bytes: JavaScriptLimits.maxResultBytes, max_result_depth: JavaScriptLimits.maxResultDepth,
                                   max_actions: JavaScriptLimits.maxActions)
            var result = pkg.withUnsafeBytes { p in ev.withUnsafeBytes { e in config.withUnsafeBytes { c in
                qjs_run_v2_diagnostic(nil, &limits, p.baseAddress?.assumingMemoryBound(to: UInt8.self), p.count, "request.onEnter",
                                      e.baseAddress?.assumingMemoryBound(to: UInt8.self), e.count,
                                      c.baseAddress?.assumingMemoryBound(to: UInt8.self), c.count, diagnostics)
            } } }
            defer { qjs_result_free(&result) }
            return (result.status, result.data.map { Data(bytes: $0, count: result.length) })
        }
        var diag = QJSDiagnostics()
        let off = run(nil)
        let on = run(&diag)
        XCTAssertEqual(off.0, Int32(QJS_OK))
        XCTAssertEqual(off.0, on.0)
        XCTAssertEqual(off.1, on.1)
        XCTAssertEqual(diag.count, UInt32(JavaScriptDiagnosticPhase.allCases.count))
    }

    func testCancellationBeforeVMKeepsOrdinaryErrorAndSwiftRecordsWithoutNativeExecution() async throws {
        let pkg = try package(attach(marker("a")))
        let before = Task { () -> JavaScriptDiagnosedRun in
            withUnsafeCurrentTask { $0?.cancel() }
            return await diagnosed(pkg)
        }
        let early = await before.value
        XCTAssertEqual(early.outcome, .failure(.cancelled))
        XCTAssertTrue(early.trace.records.isEmpty, "no native run was forced")
        XCTAssertEqual(early.trace.callerMarks.map(\.phase), [.called, .returned])
        XCTAssertEqual(early.trace.stopOrigin, .none)
    }

    func testCancellationDuringRunIsEitherTypedOutcomeWithRetainedTrace() async throws {
        let loop = try package(attach("for(;;){}"))
        let during = Task { await diagnosed(loop) }
        await Task.yield()
        during.cancel()
        let run = await during.value
        // Cancel races the 50 ms deadline by design; either first stop is a valid typed outcome.
        switch run.outcome {
        case .failure(.cancelled), .failure(.timeout): break
        default: XCTFail("unexpected \(run.outcome)")
        }
        XCTAssertFalse(run.trace.callerMarks.isEmpty)
        if !run.trace.records.isEmpty { // cancellation before the worker started has no native trace
            XCTAssertEqual(run.trace.records.last?.phase, .exit)
            XCTAssertNotEqual(run.trace.stopOrigin, .none)
            XCTAssertNotNil(run.trace.stopPhase)
            XCTAssertEqual(run.trace.stopStatus, run.trace.nativeStatus)
        }
    }

    // MARK: recovery and error parity

    func testNextRunAfterTimeoutUsesFreshVMAndTraceIsNotShared() async throws {
        let executor = JavaScriptExecutor()
        let state = try package("globalThis.leak = 1;" + attach("if (globalThis.leak === 1 && 'seen' in globalThis) { for(;;){} } globalThis.seen = 1; \(marker("ok"))"))
        let slow = try package(attach("for(;;){}"))
        let first = await diagnosed(slow, executor: executor)
        try recordTimeoutObservation(first, expectedLoopPhase: nil, name: "recovery-timeout")
        for _ in 0..<2 {
            let run = await diagnosed(state, executor: executor)
            let expected = await ordinary(state, .requestEnter)
            XCTAssertEqual(run.outcome, expected)
            XCTAssertEqual(run.trace.records.map(\.phase), fullTrace)
            XCTAssertEqual(run.trace.stopOrigin, .none)
            XCTAssertNil(run.trace.stopPhase)
        }
    }

    func testEveryErrorClassMatchesOrdinaryAndKeepsTrace() async throws {
        let big = Data(repeating: 0x20, count: JavaScriptLimits.maxEventBytes + 1)
        // reachesNative: false means rejected by the Swift guard before the worker.
        let cases: [(String, Data, JavaScriptHook, Data?, JavaScriptExecutionError, Bool)] = [
            ("scriptError", try package(attach("throw new Error('secret-detail');")), .requestEnter, nil, .scriptError, true),
            ("invalidResult", try package(attach("return {actions:[{type:'nope'}]};")), .requestEnter, nil, .invalidResult, true),
            ("memoryOrStack", try package(attach("var s='x'; for(;;){ s+=s; }")), .requestEnter, nil, .memoryOrStack, true),
            ("invalidInput-hook", try package(attach()), .request, nil, .invalidInput, false),
            ("invalidInput-package", Data("{}".utf8), .requestEnter, nil, .invalidInput, true),
            ("cap-event", try package(attach()), .requestEnter, big, .invalidInput, false),
        ]
        for (name, pkg, hook, ev, expected, native) in cases {
            let normal = await ordinary(pkg, hook, event: ev)
            let run = await diagnosed(pkg, hook, event: ev)
            XCTAssertEqual(normal, .failure(expected), name)
            XCTAssertEqual(run.outcome, normal, name)
            XCTAssertEqual(run.trace.stopOrigin, .none, name)
            XCTAssertEqual(run.trace.callerMarks.first?.phase, .called, name)
            XCTAssertEqual(run.trace.callerMarks.last?.phase, .returned, name)
            if native {
                XCTAssertEqual(run.trace.capacity, Int(QJS_DIAG_CAPACITY), "\(name): failed runs retain the native trace")
                XCTAssertEqual(run.trace.records.first?.phase, .preflight, name)
                XCTAssertEqual(run.trace.records.last?.phase, .exit, name)
                XCTAssertNotNil(run.trace.nativeStatus, name)
            } else {
                XCTAssertTrue(run.trace.records.isEmpty, "\(name): rejected before any native call")
                XCTAssertEqual(run.trace.callerMarks.map(\.phase), [.called, .returned], name)
            }
        }
    }

    func testNonMatchingTrafficRunsSetupStagesButNoEvalOrCallbacks() async throws {
        let pkg = try package("throw new Error('must not evaluate');" + attach("throw new Error('no');"))
        let other = event(host: "other.example.com")
        let normal = await ordinary(pkg, .requestEnter, event: other)
        let run = await diagnosed(pkg, event: other)
        XCTAssertEqual(run.outcome, normal)
        XCTAssertEqual(try? run.outcome.get(), Data(#"{"actions":[]}"#.utf8))
        XCTAssertEqual(run.trace.records.map(\.phase), setupTrace + [.finalAcceptance, .teardown, .exit])
        XCTAssertEqual(run.trace.stopOrigin, .none)
        XCTAssertEqual(run.trace.selectedRoute, -1)
        XCTAssertEqual(run.trace.selectedSource, -1)
        XCTAssertEqual(run.trace.sourceLength, 0)
        XCTAssertEqual(run.trace.registrationCount, 0)
    }

    func testDiagnosticsAreNotVisibleToJavaScript() async throws {
        let probe = "return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{d:typeof Interceptor.diagnostics,k:Object.keys(Interceptor).join(','),g:Object.getOwnPropertyNames(globalThis).filter(function(n){return /diag|trace|clock/i.test(n)}).join(',')}}]};"
        let pkg = try package(attach(probe))
        let normal = await ordinary(pkg, .requestEnter)
        let run = await diagnosed(pkg)
        XCTAssertEqual(run.outcome, normal, "same JS-visible behavior with tracing on")
        let data = try XCTUnwrap(try? run.outcome.get())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""d":"undefined""#), text)
        XCTAssertTrue(text.contains(#""g":"""#), text)
        XCTAssertFalse(run.trace.records.isEmpty, "tracing was actually on")
    }

    // MARK: observational

    /// 30 alternating-order pairs on one synthetic fixture. No speed assertion; scalar measurements
    /// only (no payloads) go to DIAGNOSTICS_EVIDENCE_OUTPUT when that test-only variable is set.
    func testObservationalOrdinaryVersusDiagnosedMeasurements() async throws {
        let pkg = try package(attach("var s=0; for(var i=0;i<2000;i++){s+=i;} \(marker("bench"))"))
        let outputURL = ProcessInfo.processInfo.environment["DIAGNOSTICS_EVIDENCE_OUTPUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let evidence = try await collectObservations(pkg: pkg, ev: event(), pairs: 30, outputURL: outputURL)
        // Persistence happens before any assertion about an observed runtime outcome.
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        for sample in samples {
            XCTAssertEqual((sample["ordinaryOutcome"] as? [String: Any])?["kind"] as? String, "success")
            XCTAssertEqual((sample["diagnosedOutcome"] as? [String: Any])?["kind"] as? String, "success")
            XCTAssertEqual(sample["outcomesMatch"] as? Bool, true)
            XCTAssertEqual(sample["nativePhasesComplete"] as? Bool, true)
        }
    }

    func testObservationalFailureIsPersistedBeforeAssertions() async throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-retention-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let pkg = try package(attach("for(;;){}"))
        _ = try await collectObservations(pkg: pkg, ev: event(), pairs: 1, outputURL: outputURL)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            XCTFail("A genuine timeout must persist the observation instead of losing it"); return
        }
        if let prefix = ProcessInfo.processInfo.environment["DIAGNOSTICS_EVIDENCE_OUTPUT"], !prefix.isEmpty {
            try Data(contentsOf: outputURL).write(to: URL(fileURLWithPath: prefix + ".expected-timeout-retention.json"), options: .atomic)
        }
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [String: Any])
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual((sample["ordinaryOutcome"] as? [String: Any])?["error"] as? String, "timeout")
        XCTAssertEqual((sample["diagnosedOutcome"] as? [String: Any])?["error"] as? String, "timeout")
    }

    func testMalformedNativeRecordMetadataIsBoundedAndVisible() {
        var native = QJSDiagnostics()
        native.capacity = QJS_DIAG_CAPACITY + 1
        native.count = 1 // safe assertion RED: the unknown record must not disappear silently
        withUnsafeMutableBytes(of: &native.records) { raw in
            let records = raw.bindMemory(to: QJSDiagnosticRecord.self)
            records[0].phase = 999
        }
        let trace = JavaScriptDiagnosticTrace(native: native)
        XCTAssertTrue(trace.records.isEmpty)
        XCTAssertGreaterThanOrEqual(trace.nativeRecordAnomalies, 2, "invalid reported capacity and unknown phase are visible")

        // Even maximum reported sizes cannot index beyond the actual imported C tuple.
        native.capacity = UInt32.max
        native.count = UInt32.max
        withUnsafeMutableBytes(of: &native.records) { raw in
            let records = raw.bindMemory(to: QJSDiagnosticRecord.self)
            for i in 0..<records.count { records[i].phase = Int32(QJS_DIAG_PHASE_PREFLIGHT) }
            records[0].phase = 999
        }
        let oversized = JavaScriptDiagnosticTrace(native: native)
        XCTAssertEqual(oversized.capacity, Int(QJS_DIAG_CAPACITY))
        XCTAssertEqual(oversized.records.count, Int(QJS_DIAG_CAPACITY) - 1)
        XCTAssertGreaterThanOrEqual(oversized.nativeRecordAnomalies, 3)
    }

    /// Collects every typed outcome and bounded trace, including genuine stops. No runtime-result
    /// assertion or throwing outcome.get() may precede the atomic evidence write.
    private func collectObservations(pkg: Data, ev: Data, pairs: Int, outputURL: URL?) async throws -> [String: Any] {
        precondition((1...30).contains(pairs))
        let executor = JavaScriptExecutor()
        var samples: [[String: Any]] = []
        var firstTrace: JavaScriptDiagnosticTrace?
        func outcomeRecord(_ outcome: Result<Data, JavaScriptExecutionError>) -> [String: Any] {
            switch outcome {
            case .success(let data): return ["kind": "success", "resultBytes": data.count]
            case .failure(let error): return ["kind": "failure", "error": String(describing: error)]
            }
        }
        for pair in 0..<pairs {
            var ordinaryNanos: UInt64 = 0, diagnosedNanos: UInt64 = 0
            var run: JavaScriptDiagnosedRun?
            var normal: Result<Data, JavaScriptExecutionError> = .failure(.internalFailure)
            for step in 0..<2 {
                if (step == 0) == (pair % 2 == 0) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    run = await executor.runV2Diagnosed(packageJSON: pkg, hook: .requestEnter, eventJSON: ev, configJSON: config)
                    diagnosedNanos = DispatchTime.now().uptimeNanoseconds - start
                } else {
                    let start = DispatchTime.now().uptimeNanoseconds
                    do { normal = .success(try await executor.runV2(packageJSON: pkg, hook: .requestEnter, eventJSON: ev, configJSON: config)) }
                    catch { normal = .failure(error as? JavaScriptExecutionError ?? .internalFailure) }
                    ordinaryNanos = DispatchTime.now().uptimeNanoseconds - start
                }
            }
            // The loop always executes the diagnosed arm exactly once; no result assertion here.
            guard let diagnosed = run else { preconditionFailure("missing measurement arm") }
            let t = diagnosed.trace
            if firstTrace == nil { firstTrace = t }
            var sample: [String: Any] = [
                "pair": pair, "diagnosedFirst": pair % 2 == 0,
                "ordinaryNs": ordinaryNanos, "diagnosedNs": diagnosedNanos,
                "ordinaryOutcome": outcomeRecord(normal), "diagnosedOutcome": outcomeRecord(diagnosed.outcome),
                "outcomesMatch": normal == diagnosed.outcome,
                "nativePhasesComplete": t.records.map(\.phase) == fullTrace,
                "cWallNs": t.nativeWallNanos(from: .preflight, to: .exit) ?? 0,
                "cThreadCPUNs": t.nativeCPUNanos(from: .preflight, to: .exit) ?? 0,
                "status": Int(t.nativeStatus ?? -1),
                "trace": [
                    "nativeInvoked": t.nativeStatus != nil, "nativeStatus": Int(t.nativeStatus ?? -1),
                    "stopStatus": Int(t.stopStatus), "stopOrigin": Int(t.stopOrigin.rawValue),
                    "stopPhase": Int(t.stopPhase?.rawValue ?? 0), "stopWallNs": t.stopWallNanos,
                    "stopThreadCPUNs": t.stopThreadCPUNanos,
                    "decoderAnomalies": t.nativeRecordAnomalies,
                    "interruptPolls": t.interruptPolls, "inlinePolls": t.inlinePolls,
                    "wallSupported": t.wallSupported, "threadCPUSupported": t.threadCPUSupported,
                    "records": t.records.map { ["phase": Int($0.phase.rawValue), "wallNs": $0.wallNanos, "threadCPUNs": $0.threadCPUNanos] },
                    "callerMarks": t.callerMarks.map { ["phase": $0.phase.rawValue, "uptimeNs": $0.uptimeNanos] }
                ]
            ]
            for (key, a, b) in [("evalWallNs", JavaScriptDiagnosticPhase.eval, JavaScriptDiagnosticPhase.callbacks),
                                ("callbacksWallNs", .callbacks, .result)] {
                sample[key] = t.nativeWallNanos(from: a, to: b) ?? 0
            }
            if let value = t.callerNanos(from: .called, to: .admitted) { sample["admissionNs"] = value }
            if let value = t.callerNanos(from: .admitted, to: .workerStarted) { sample["workerStartNs"] = value }
            samples.append(sample)
        }
        let reference = firstTrace ?? .empty
        let evidence: [String: Any] = [
            "pairs": pairs, "deadlineMs": reference.deadlineMilliseconds,
            "heapBytes": reference.heapBytes, "stackBytes": reference.stackBytes,
            "maxResultBytes": reference.maxResultBytes,
            "packageBytes": pkg.count, "eventBytes": ev.count, "configBytes": config.count,
            "sourceBytes": reference.sourceLength, "resultBytes": reference.resultLength,
            "threadCPUSupported": reference.threadCPUSupported, "samples": samples
        ]
        if let outputURL {
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: outputURL, options: .atomic)
        }
        let ordinary = samples.compactMap { $0["ordinaryNs"] as? UInt64 }.sorted()[pairs / 2]
        let diagnosed = samples.compactMap { $0["diagnosedNs"] as? UInt64 }.sorted()[pairs / 2]
        print("diagnostics-observation pairs=\(pairs) ordinaryMedianNs=\(ordinary) diagnosedMedianNs=\(diagnosed)")
        return evidence
    }
}
