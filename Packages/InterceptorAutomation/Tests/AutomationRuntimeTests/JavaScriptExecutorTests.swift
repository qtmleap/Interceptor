import XCTest
@testable import AutomationRuntime

/// Exercises the real runtime only. Pathological scripts rely on the runtime's own 50 ms deadline;
/// run the suite under an external process timeout so a runtime bug cannot hang XCTest forever.
final class JavaScriptExecutorTests: XCTestCase, @unchecked Sendable {
    private let endpoint = "11111111-1111-1111-1111-111111111111"
    private let event = Data(#"{"method":"GET","url":"https://example.com/a","status":200}"#.utf8)
    private let config = Data(#"{"threshold":3}"#.utf8)
    /// Wall tolerance for process scheduling; separate from the 50 ms interpreter deadline.
    private let wallLimit: TimeInterval = 0.5

    // MARK: helpers

    private func run(_ source: String, hook: JavaScriptHook = .request, event: Data? = nil, config: Data? = nil,
                     executor: JavaScriptExecutor = JavaScriptExecutor()) async throws -> Data {
        try await executor.run(source: source, hook: hook, eventJSON: event ?? self.event, configJSON: config ?? self.config)
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ source: String, hook: JavaScriptHook = .request,
                             maxWall: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let start = ContinuousClock.now
        do {
            let data = try await run(source, hook: hook)
            XCTFail("expected \(expected), got \(String(decoding: data, as: UTF8.self))", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? JavaScriptExecutionError, expected, file: file, line: line)
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, maxWall ?? wallLimit, "wall time", file: file, line: line)
    }

    private func actions(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["actions"] as? [[String: Any]], file: file, line: line)
    }

    private func action(_ jsonExpr: String) -> String {
        "{type:'webhook',endpointId:'\(endpoint)',json:\(jsonExpr)}"
    }

    private func handler(_ body: String, hook: JavaScriptHook = .request) -> String {
        "function \(hook.functionName)(event, config) { \(body) }"
    }

    // MARK: real transforms

    func testOnRequestTransformsEventAndConfig() async throws {
        let src = handler("return {actions:[\(action("{url:event.url,method:event.method,t:config.threshold*2}"))]};")
        let result = try await actions(run(src))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["type"] as? String, "webhook")
        XCTAssertEqual(result[0]["endpointId"] as? String, endpoint)
        let json = try XCTUnwrap(result[0]["json"] as? [String: Any])
        XCTAssertEqual(json["url"] as? String, "https://example.com/a")
        XCTAssertEqual(json["method"] as? String, "GET")
        XCTAssertEqual(json["t"] as? Int, 6)
    }

    func testOnResponseTransformsAndIgnoresOtherHook() async throws {
        let src = handler("return {actions:[\(action("{status:event.status}"))]};", hook: .response)
        let result = try await actions(run(src, hook: .response))
        XCTAssertEqual((result[0]["json"] as? [String: Any])?["status"] as? Int, 200)
        // Only onResponse is defined, so the request hook is not callable.
        await expectError(.scriptError, src, hook: .request)
    }

    func testEmptyActionsAllowed() async throws {
        let result = try await actions(run(handler("return {actions:[]};")))
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingHandlerAndThrowAreScriptErrors() async {
        await expectError(.scriptError, "var x = 1;")
        await expectError(.scriptError, handler("throw new Error('boom');"))
        await expectError(.scriptError, "this is not javascript (")
        await expectError(.scriptError, handler("throw {toString(){ for(;;){} }};"))
    }

    // MARK: deadlines

    func testTopLevelInfiniteLoopTimesOut() async {
        await expectError(.timeout, "for(;;){}\n" + handler("return {actions:[]};"), maxWall: 0.15)
        await expectError(.timeout, "while(true){}", maxWall: 0.15)
    }

    func testHandlerInfiniteLoopTimesOut() async {
        await expectError(.timeout, handler("for(;;){}"), maxWall: 0.15)
        await expectError(.timeout, handler("var i=0; while(true){ i++; }"), maxWall: 0.15)
    }

    func testCatastrophicRegexTimesOut() async {
        let src = handler("return {actions:[\(action("/^(a+)+$/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!')"))]};")
        await expectError(.timeout, src)
    }

    /// Design decision: the native validator reads own data descriptors only and rejects accessors,
    /// function-valued properties (so `toJSON`) and Proxy objects *before* invoking anything. A
    /// malicious getter/toJSON/trap therefore never runs, and the result is `invalidResult` rather
    /// than `timeout`. The 0.15 s wall bound proves the loops were not entered (a run would burn
    /// the full 50 ms and then report `timeout`).
    func testGetterToJSONAndProxyAreRejectedWithoutInvocation() async {
        await expectError(.invalidResult, handler("return {get actions(){ for(;;){} }};"), maxWall: 0.15)
        await expectError(.invalidResult, handler("return {actions:[{type:'webhook',endpointId:'\(endpoint)',get json(){ for(;;){} }}]};"), maxWall: 0.15)
        await expectError(.invalidResult, handler("return {actions:[\(action("{toJSON(){ for(;;){} }}"))]};"), maxWall: 0.15)
        await expectError(.invalidResult, handler("return new Proxy({}, {get(){ for(;;){} }, ownKeys(){ for(;;){} }});"), maxWall: 0.15)
        await expectError(.invalidResult, handler("return {actions:new Proxy([], {get(){ for(;;){} }})};"), maxWall: 0.15)
        await expectError(.invalidResult, handler("return {actions:[\(action("new Proxy({}, {ownKeys(){ for(;;){} }})"))]};"), maxWall: 0.15)
    }

    func testHandlerLoopInsideEvaluatedHandlerStillTimesOutAfterGetterDefinition() async {
        // Getter defined but handler itself loops: the deadline, not the validator, ends it.
        await expectError(.timeout, handler("var o={get x(){return 1}}; for(;;){}"), maxWall: 0.15)
    }

    // MARK: native-heavy builtins (a single builtin call does the work; only interrupt polling in the
    // engine's native loops can stop it)

    func testNativeHeavyBuiltinsAreBounded() async {
        let heavy = [
            "'x'.repeat(1<<20).split('').sort().join('')",
            "new Array(1<<22).fill(0).map((_, i) => i).sort((a, b) => b - a).length",
            "JSON.stringify(Array.from({length: 200000}, (_, i) => ({i, s: 'abc' + i}))).length",
            "'a'.repeat(1<<22).replace(/a/g, 'bb').length",
            "Array.from({length: 1<<20}, (_, i) => i).reduce((a, b) => a + b, 0)",
            "new Map(Array.from({length: 1<<19}, (_, i) => [i, i])).size",
            "/(x+x+)+y/.exec('x'.repeat(5000))",
            "'x'.repeat(1<<21).localeCompare('y'.repeat(1<<21))",
        ]
        for expr in heavy {
            let start = ContinuousClock.now
            do {
                _ = try await run(handler("var r = \(expr); return {actions:[]};"))
            } catch {
                let e = error as? JavaScriptExecutionError
                XCTAssertTrue(e == .timeout || e == .memoryOrStack, "\(expr) -> \(String(describing: error))")
            }
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(500), expr)
        }
    }

    func testBigIntNativeConversionHasAnOperandLimit() async {
        // BigInt decimal conversion is a native loop; the interpreter interrupt cannot preempt it.
        await expectError(.memoryOrStack,
                          handler("let n=(1n<<1000000n)-1n; let decimal=n.toString(10); return {actions:[]};"),
                          maxWall: 0.15)
    }

    func testBigIntCreationPathsCannotBypassOperandLimit() async {
        let expressions = [
            "BigInt('9'.repeat(10000))",
            "1n << 1000000n",
            "2n ** 1000000n",
            "3n ** 100000n",
            "3n ** (2n ** 40n)",
            "(1n<<5000n) * (1n<<5000n)",
            "eval('(1n<<1000000n).toString(10)')",
            "Function('return (1n<<1000000n).toString(10)')()",
            String(repeating: "9", count: 10000) + "n",
            "0x" + String(repeating: "f", count: 10000) + "n",
        ]
        for expression in expressions {
            await expectError(.memoryOrStack, handler("let value = \(expression); return {actions:[]};"), maxWall: 0.15)
        }
    }

    func testCappedBigIntNativeOperationsStillObeyDeadlineAndRecover() async throws {
        let executor = JavaScriptExecutor()
        let code = handler("let x=(1n<<4000n)-1n; for(;;) { let y=x*x; let a=y/x; let b=y%x; let s=y.toString(10)+y.toString(36); }")
        let start = ContinuousClock.now
        do {
            _ = try await run(code, executor: executor)
            XCTFail("expected the deadline")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .timeout) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(150))
        let recovered = try await actions(run(handler("return {actions:[]};"), executor: executor))
        XCTAssertTrue(recovered.isEmpty)
    }

    func testOrdinaryBigIntCalculationAndConversionRemainAvailable() async throws {
        let src = handler("return {actions:[\(action("{small:Number(20n+22n),digits:(2n**4000n).toString(10)}"))]};")
        let result = try await actions(run(src))
        let json = try XCTUnwrap(result.first?["json"] as? [String: Any])
        XCTAssertEqual(json["small"] as? Int, 42)
        let digits = try XCTUnwrap(json["digits"] as? String)
        XCTAssertEqual(digits.count, 1205)
        XCTAssertTrue(digits.hasPrefix("1318204093"))
        await expectError(.invalidResult, handler("return {actions:[\(action("1n"))]};"))
    }

    func testThrownValuesAreNeverStringified() async {
        // toString/valueOf/message getter on thrown values must not be invoked (they loop forever).
        await expectError(.scriptError, handler("throw {toString(){ for(;;){} }, valueOf(){ for(;;){} }};"), maxWall: 0.15)
        await expectError(.scriptError, handler("var e=new Error('x'); Object.defineProperty(e,'message',{get(){ for(;;){} }}); throw e;"), maxWall: 0.15)
        await expectError(.scriptError, handler("throw new Proxy({}, {get(){ for(;;){} }});"), maxWall: 0.15)
        await expectError(.scriptError, "throw {toString(){ for(;;){} }};", maxWall: 0.15)
    }

    // MARK: memory and stack

    func testRecursionIsBounded() async {
        await expectError(.memoryOrStack, handler("function f(n){ return f(n+1)+1; } return f(0);"))
    }

    func testHeapExhaustionIsBounded() async {
        await expectError(.memoryOrStack, handler("var a=[]; for(;;){ a.push(new Array(100000).fill(1)); }"))
        await expectError(.memoryOrStack, handler("var s='x'; for(;;){ s+=s; }"))
    }

    // MARK: result validation

    func testRejectsAsyncResults() async {
        await expectError(.invalidResult, handler("return Promise.resolve({actions:[]});"))
        await expectError(.invalidResult, "async function onRequest(){ return {actions:[]}; }")
        await expectError(.invalidResult, handler("return {then(r){ r({actions:[]}); }};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{then(){}}"))]};"))
    }

    func testPromiseJobsAreNotDrained() async throws {
        // A queued microtask must not run before the (synchronous) result is read.
        let src = "var ran=false; Promise.resolve().then(()=>{ran=true;});\n"
            + handler("return {actions:[\(action("{ran:ran}"))]};")
        let result = try await actions(run(src))
        XCTAssertEqual((result[0]["json"] as? [String: Any])?["ran"] as? Bool, false)
    }

    func testRejectsInvalidValues() async {
        await expectError(.invalidResult, handler("var o={}; o.self=o; return {actions:[\(action("o"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{n:NaN}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{n:Infinity}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{f(){}}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{f:()=>1}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{b:1n}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{s:Symbol('x')}"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("{u:undefined}"))]};"))
        await expectError(.invalidResult, handler("return undefined;"))
        await expectError(.invalidResult, handler("return 'text';"))
        await expectError(.invalidResult, handler("return {};"))
        await expectError(.invalidResult, handler("return {actions:{}};"))
    }

    func testRejectsInvalidActions() async {
        await expectError(.invalidResult, handler("return {actions:[{type:'fetch',endpointId:'\(endpoint)',json:{}}]};"))
        await expectError(.invalidResult, handler("return {actions:[{type:'webhook',json:{}}]};"))
        await expectError(.invalidResult, handler("return {actions:[{type:'webhook',endpointId:'not-a-uuid',json:{}}]};"))
        await expectError(.invalidResult, handler("return {actions:[{type:'webhook',endpointId:'\(endpoint)'}]};"))
        await expectError(.invalidResult, handler("return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{},extra:1}]};"))
        await expectError(.invalidResult, handler("return {actions:[],extra:1};"))
        await expectError(.invalidResult, handler("return {actions:[1]};"))
    }

    func testMaxTwoActions() async throws {
        let a = action("{}")
        let two = try await actions(run(handler("return {actions:[\(a),\(a)]};")))
        XCTAssertEqual(two.count, 2)
        await expectError(.invalidResult, handler("return {actions:[\(a),\(a),\(a)]};"))
    }

    func testResultSizeCap() async throws {
        // Total result bytes must stay <= 32 KiB.
        let ok = handler("return {actions:[\(action("{s:'x'.repeat(20000)}"))]};")
        let data = try await run(ok)
        XCTAssertLessThanOrEqual(data.count, JavaScriptLimits.maxResultBytes)
        await expectError(.invalidResult, handler("return {actions:[\(action("{s:'x'.repeat(40000)}"))]};"))
        let a = action("{s:'x'.repeat(10000)}")
        await expectError(.invalidResult, handler("return {actions:[\(a),\(a),\(a)]};")) // also >2 actions
    }

    func testResultDepthCap() async throws {
        func nested(_ depth: Int) -> String {
            "(function(){ var v=1; for(var i=0;i<\(depth);i++){ v={a:v}; } return v; })()"
        }
        // Depth counts the whole result: root object, actions array, action, then json value.
        _ = try await run(handler("return {actions:[\(action(nested(20)))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action(nested(40)))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action(nested(5000)))]};"))
    }

    // MARK: sandbox surface

    func testNoHostCapabilitiesExposed() async throws {
        let names = ["fetch", "XMLHttpRequest", "WebSocket", "std", "os", "scriptArgs", "console", "print",
                     "require", "module", "exports", "process", "setTimeout", "setInterval", "setImmediate",
                     "clearTimeout", "queueMicrotask", "importScripts", "SharedArrayBuffer", "WebAssembly",
                     "navigator", "window", "document", "native", "bridge", "webkit"]
        for name in names {
            let src = handler("return {actions:[\(action("{t:typeof globalThis['\(name)']}"))]};")
            let result = try await actions(run(src))
            XCTAssertEqual((result[0]["json"] as? [String: Any])?["t"] as? String, "undefined", "\(name) must not be exposed")
        }
    }

    func testAtomicsCannotBlock() async throws {
        // Either Atomics is absent or wait cannot block; never hangs past the deadline.
        let src = handler("""
        if (typeof Atomics === 'undefined' || typeof SharedArrayBuffer === 'undefined') return {actions:[]};
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10000); return {actions:[]};
        """)
        let start = ContinuousClock.now
        _ = try? await run(src)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testImportsAndEvalOfModulesFail() async {
        // Dynamic import() synchronously returns a Promise (the load job is never drained, and no
        // module loader exists), so the result is rejected as async rather than as a script error.
        await expectError(.invalidResult, handler("return import('os');"))
        await expectError(.scriptError, "import * as os from 'os';\n" + handler("return {actions:[]};"))
    }

    // MARK: fresh state

    func testEachRunUsesFreshGlobals() async throws {
        let src = "globalThis.counter = (globalThis.counter || 0) + 1; Object.prototype.polluted = (Object.prototype.polluted||0)+1;\n"
            + handler("return {actions:[\(action("{c:globalThis.counter,p:({}).polluted}"))]};")
        let executor = JavaScriptExecutor()
        for _ in 0..<3 {
            let result = try await actions(run(src, executor: executor))
            let json = try XCTUnwrap(result[0]["json"] as? [String: Any])
            XCTAssertEqual(json["c"] as? Int, 1)
            XCTAssertEqual(json["p"] as? Int, 1)
        }
    }

    // MARK: cancellation and recovery

    func testExplicitCancellationAndRecovery() async throws {
        let executor = JavaScriptExecutor()
        let long = "for(;;){}"
        let task = Task { try await self.run(long, executor: executor) }
        try await Task.sleep(for: .milliseconds(5))
        executor.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            // 5 ms is well inside the 50 ms deadline.
            XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        }
        let ok = try await actions(run(handler("return {actions:[]};"), executor: executor))
        XCTAssertTrue(ok.isEmpty)
    }

    func testIdleCancelDoesNotPoisonNextRun() async throws {
        let executor = JavaScriptExecutor()
        executor.cancel()
        let ok = try await actions(run(handler("return {actions:[]};"), executor: executor))
        XCTAssertTrue(ok.isEmpty)
    }

    func testRecoversAfterTimeoutAndMemoryFailures() async throws {
        let executor = JavaScriptExecutor()
        for bad in ["for(;;){}", handler("function f(){ return f()+1; } return f();")] {
            _ = try? await run(bad, executor: executor)
            let ok = try await actions(run(handler("return {actions:[\(action("{ok:true}"))]};"), executor: executor))
            XCTAssertEqual(ok.count, 1)
        }
    }

    // MARK: input caps

    func testInputAndSourceCaps() async throws {
        let ok = handler("return {actions:[]};")
        let executor = JavaScriptExecutor()
        func expectInvalid(_ source: String, event: Data? = nil, config: Data? = nil, line: UInt = #line) async {
            do {
                _ = try await run(source, event: event, config: config, executor: executor)
                XCTFail("expected invalidInput", line: line)
            } catch {
                XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput, line: line)
            }
        }
        let bigSource = ok + String(repeating: " ", count: JavaScriptLimits.maxSourceBytes)
        await expectInvalid(bigSource)
        await expectInvalid("")
        await expectInvalid(ok, event: Data(#"{"a":"\#(String(repeating: "x", count: JavaScriptLimits.maxEventBytes))"}"#.utf8))
        await expectInvalid(ok, config: Data(#"{"a":"\#(String(repeating: "x", count: JavaScriptLimits.maxConfigBytes))"}"#.utf8))
        await expectInvalid(ok, event: Data("not json".utf8))
        await expectInvalid(ok, config: Data())
        await expectInvalid(ok, event: Data(#"{"a":1,"a":2}"#.utf8))
        await expectInvalid(ok, event: Data([0xFF, 0xFE]))
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        await expectInvalid(ok, event: Data(deep.utf8))
        // NUL byte in source must not be truncated into something valid.
        await expectInvalid(ok + "\u{0}garbage")
        // Boundary inputs are accepted.
        let atLimit = String(ok + String(repeating: " ", count: JavaScriptLimits.maxSourceBytes - ok.utf8.count))
        XCTAssertEqual(atLimit.utf8.count, JavaScriptLimits.maxSourceBytes)
        _ = try await run(atLimit, executor: executor)
    }

// MARK: repeated-run and cancel races

    func testRepeatedRunsStayFastAndIsolated() async throws {
        let executor = JavaScriptExecutor()
        let src = handler("return {actions:[\(action("{n:config.threshold}"))]};")
        let start = ContinuousClock.now
        for _ in 0..<200 {
            let result = try await actions(run(src, executor: executor))
            XCTAssertEqual((result[0]["json"] as? [String: Any])?["n"] as? Int, 3)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    func testCancelRaceNeverCrashesOrPoisonsLaterRuns() async throws {
        let executor = JavaScriptExecutor()
        let ok = handler("return {actions:[]};")
        for round in 0..<60 {
            let source = round % 2 == 0 ? "for(;;){}" : ok
            let task = Task { try await self.run(source, executor: executor) }
            // Vary the cancel point: before start, mid-flight, and after completion.
            try await Task.sleep(for: .microseconds(round % 5 == 0 ? 0 : (round % 7) * 400))
            if round % 3 == 0 { task.cancel() } else { executor.cancel() }
            do { _ = try await task.value }
            catch {
                let e = error as? JavaScriptExecutionError
                XCTAssertTrue(e == .cancelled || e == .timeout || e == .busy, "round \(round): \(String(describing: error))")
            }
            // A stale cancel must never leak into the next admitted job.
            let next = try await actions(run(ok, executor: executor))
            XCTAssertTrue(next.isEmpty, "round \(round)")
        }
    }

    func testTaskCancelDoesNotAffectLaterJobsAndCancelAfterFinishIsHarmless() async throws {
        let executor = JavaScriptExecutor()
        let ok = handler("return {actions:[]};")
        let done = try await actions(run(ok, executor: executor))
        XCTAssertTrue(done.isEmpty)
        executor.cancel() // after finish
        let again = try await actions(run(ok, executor: executor))
        XCTAssertTrue(again.isEmpty)

        let task = Task { try await self.run("for(;;){}", executor: executor) }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled) }
        let later = try await actions(run(ok, executor: executor))
        XCTAssertTrue(later.isEmpty)
    }

    func testAlreadyCancelledTaskIsRejectedBeforeRunning() async {
        let task = Task { () -> Data in
            try await Task.sleep(for: .milliseconds(20))
            return try await self.run(self.handler("return {actions:[]};"))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected an error") }
        catch { XCTAssertNotNil(error) }
    }

    func testConcurrentExecutorsAreIndependent() async throws {
        let a = JavaScriptExecutor(), b = JavaScriptExecutor()
        async let ra = run("for(;;){}", executor: a)
        async let rb = run(handler("return {actions:[]};"), executor: b)
        let okB = try await actions(rb)
        XCTAssertTrue(okB.isEmpty)
        do { _ = try await ra; XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? JavaScriptExecutionError, .timeout) }
    }

    func testStrictDTOEdgeCases() async throws {
        await expectError(.invalidResult, handler("return {actions:[\(action("{a:[1,,3]}"))]};"))               // holes
        await expectError(.invalidResult, handler("var a=[1]; a.x=1; return {actions:[\(action("a"))]};"))       // extra array prop
        await expectError(.invalidResult, handler("var o={}; o[Symbol('k')]=1; return {actions:[\(action("o"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("new Date(0)"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("new Map()"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("new Error('x')"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("/re/"))]};"))
        await expectError(.invalidResult, handler("return {actions:[\(action("'\\ud800'"))]};"))               // lone surrogate
        await expectError(.invalidResult, handler("var a={}; var b={a:a}; a.b=b; return {actions:[\(action("a"))]};"))
        // Shared (non-cyclic) DAG that expands beyond the byte cap must fail fast, not hang.
        await expectError(.invalidResult, handler("var l={s:'x'.repeat(1000)}; for(var i=0;i<30;i++){ l={a:l,b:l}; } return {actions:[\(action("l"))]};"), maxWall: 0.3)
        let ok = try await actions(run(handler("return {actions:[\(action("{a:[1,2.5,-0,'é😀',null,true,{}]}"))]};")))
        XCTAssertEqual(ok.count, 1)
    }

    func testExtraThenableAndNonObjectInputs() async {
        await expectError(.invalidResult, handler("return Object.assign(Promise.resolve(), {actions:[]});"))
    }

    // MARK: admission

    func testSecondConcurrentInvocationIsBusyNotQueued() async throws {
        let executor = JavaScriptExecutor()
        let start = ContinuousClock.now
        let outcomes = await withTaskGroup(of: JavaScriptExecutionError?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try await self.run("for(;;){}", executor: executor); return nil }
                    catch { return error as? JavaScriptExecutionError }
                }
            }
            var all: [JavaScriptExecutionError?] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertTrue(outcomes.contains(.busy), "expected immediate busy rejections")
        XCTAssertTrue(outcomes.contains(.timeout), "one admitted run must hit its deadline")
        XCTAssertTrue(outcomes.allSatisfy { $0 == .busy || $0 == .timeout })
        // An unbounded queue would serialize 8 x 50 ms deadlines.
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(350))
        let ok = try await actions(run(handler("return {actions:[]};"), executor: executor))
        XCTAssertTrue(ok.isEmpty)
    }
}
