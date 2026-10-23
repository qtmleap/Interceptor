import AutomationCore
@testable import AutomationRuntime
import XCTest

/// Standard global `fetch` through the real shared C runtime (`qjs_run_v2_fetch`), response.onLeave only.
final class JavaScriptFetchTests: XCTestCase, @unchecked Sendable {
    private let file = "hooks/api.example.com/credentials/GET.js"
    private let route = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onLeave":"hooks/api.example.com/credentials/GET.js"}}}"#
    private let event = Data(#"{"request":{"method":"GET","host":"api.example.com","path":"/credentials"},"response":{"status":200,"headers":{},"body":{"accessToken":"t"}}}"#.utf8)
    private let config = Data("{}".utf8)
    private let url = "https://api.example.com/v1/profile"

    private func package(_ source: String) throws -> Data {
        let code = try JSONValue.string(source).jsonString()
        let m = #"{"schemaVersion":2,"id":"22222222-2222-4222-8222-222222222222","name":"Sample","version":"1.0.0","matches":[\#(route)],"read":{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{},"outbound":{}}"#
        return Data(#"{"manifest":\#(m),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
    }

    private func run(_ body: String, top: String = "", executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(),
                     transport: @escaping JavaScriptFetchExecutor.Transport = { _ in JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8)) }) async throws -> [[String: Any]]
    {
        let pkg = try package("\(top)Interceptor.attach({response:{onLeave:\(body)}});")
        let data = try await executor.runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config, transport: transport)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["actions"] as? [[String: Any]])
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ body: String, top: String = "", executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(), line: UInt = #line,
                             transport: @escaping JavaScriptFetchExecutor.Transport = { _ in JavaScriptFetchResponse(status: 200, body: Data("{}".utf8)) }) async
    {
        do {
            let r = try await run(body, top: top, executor: executor, transport: transport)
            XCTFail("expected \(expected), got \(r)", line: line)
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    private actor Recorder {
        var requests: [JavaScriptFetchRequest] = []
        func add(_ r: JavaScriptFetchRequest) {
            requests.append(r)
        }
    }

    func testAsyncAwaitFetchJsonAndStatus() async throws {
        let rec = Recorder()
        let actions = try await run("async (res) => { const r = await fetch('\(url)'); const j = await r.json(); if (r.status !== 200 || !r.ok || j.a !== 1) throw new Error('x'); }") { req in
            await rec.add(req)
            return JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8))
        }
        XCTAssertEqual(actions.count, 0)
        let seen = await rec.requests
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].url, url)
        XCTAssertEqual(seen[0].method, "GET")
        XCTAssertEqual(seen[0].maxResponseBytes, 1024 * 1024)
        XCTAssertLessThanOrEqual(seen[0].timeoutMilliseconds, 5000)
    }

    func testPostBodyHeadersAndDefaultContentType() async throws {
        let rec = Recorder()
        _ = try await run("async () => { await fetch('\(url)', {method:'post', headers:{Authorization:'Bearer x'}, body:'{\"k\":1}'}); }") { req in
            await rec.add(req)
            return JavaScriptFetchResponse(status: 204, body: Data())
        }
        let all = await rec.requests
        let r = try XCTUnwrap(all.first)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers, ["authorization": "Bearer x", "content-type": "application/json"])
        XCTAssertEqual(r.body, Data("{\"k\":1}".utf8))
    }

    func testResponseTextAndNonOkStatus() async throws {
        _ = try await run("async () => { const r = await fetch('\(url)'); if (r.ok || r.status !== 404 || (await r.text()) !== 'nope') throw new Error('x'); }") { _ in
            JavaScriptFetchResponse(status: 404, body: Data("nope".utf8))
        }
    }

    func testNetworkErrorIsCatchable() async throws {
        struct Boom: Error {}
        _ = try await run("async () => { try { await fetch('\(url)'); } catch (e) { return; } throw new Error('not rejected'); }") { _ in throw Boom() }
    }

    func testInvalidJSONRejectsCatchably() async throws {
        _ = try await run("async () => { const r = await fetch('\(url)'); try { await r.json(); } catch (e) { return; } throw new Error('x'); }") { _ in
            JavaScriptFetchResponse(status: 200, body: Data("{bad".utf8))
        }
    }

    func testResponseBodyCanOnlyBeConsumedOnce() async throws {
        _ = try await run("async () => { const r = await fetch('\(url)'); if (r.bodyUsed) throw new Error('used early'); await r.json(); if (!r.bodyUsed) throw new Error('not consumed'); try { await r.text(); } catch (e) { return; } throw new Error('read twice'); }")
    }

    func testInvalidRequestsRejectCatchably() async throws {
        let bad = ["'http://api.example.com/x'", "'https://127.0.0.1/x'", "'https://api.example.com:8443/x'", "'https://api.example.com/x?q=1'",
                   "'\(url)', {method:'DELETE'}", "'\(url)', {headers:{host:'x'}}", "'\(url)', {headers:{'accept-encoding':'gzip'}}",
                   "'\(url)', {body:'{}'}", "'\(url)', {method:'POST', body:'not json'}", "'\(url)', {redirect:'follow'}", "42"]
        for args in bad {
            _ = try await run("async () => { try { await fetch(\(args)); } catch (e) { return; } throw new Error('accepted'); }") { _ in
                XCTFail("transport must not be called for \(args)")
                return JavaScriptFetchResponse(status: 200, body: Data())
            }
        }
    }

    func testRequestCapIs64() async throws {
        let counter = Recorder()
        _ = try await run("async () => { let rejected = 0; for (let i = 0; i < 65; i++) { try { await fetch('\(url)'); } catch (e) { rejected++; } } if (rejected !== 1) throw new Error('r' + rejected); }") { req in
            await counter.add(req)
            return JavaScriptFetchResponse(status: 200, body: Data())
        }
        let n = await counter.requests.count
        XCTAssertEqual(n, 64)
    }

    func testAggregateResponseCapFailsClosed() async {
        let big = Data(repeating: 0x61, count: 1024 * 1024)
        await expectError(.memoryOrStack, "async () => { for (let i = 0; i < 17; i++) { const r = await fetch('\(url)'); void r; } }",
                          transport: { _ in JavaScriptFetchResponse(status: 200, body: big) })
    }

    func testOversizedResponseIsNetworkError() async throws {
        _ = try await run("async () => { try { await fetch('\(url)'); } catch (e) { return; } throw new Error('x'); }") { _ in
            JavaScriptFetchResponse(status: 200, body: Data(repeating: 0x61, count: 1024 * 1024 + 1))
        }
    }

    func testTopLevelFetchIsStickyInvalid() async {
        await expectError(.scriptError, "() => {}", top: "try { fetch('\(url)'); } catch (e) {}\n")
    }

    func testNeverSettlingPromiseIsScriptError() async {
        await expectError(.scriptError, "() => new Promise(() => {})")
    }

    func testRejectedReturnedPromiseIsScriptError() async {
        await expectError(.scriptError, "async () => { throw new Error('x'); }")
    }

    func testCpuBudgetExcludesTransportWaitOnly() async throws {
        _ = try await run("async () => { await fetch('\(url)'); }") { _ in
            try await Task.sleep(nanoseconds: 600_000_000)
            return JavaScriptFetchResponse(status: 200, body: Data())
        }
        await expectError(.timeout, "async () => { await fetch('\(url)'); for (;;) {} }")
    }

    func testCancelDuringTransportCancelsTaskAndThrows() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let cancelled = Recorder()
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { await fetch('\(self.url)'); }", executor: executor) { _ in
                    started.fulfill()
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { await cancelled.add(JavaScriptFetchRequest(url: "c", method: "", headers: [:], body: nil, timeoutMilliseconds: 0, maxResponseBytes: 0)); throw error }
                    return JavaScriptFetchResponse(status: 200, body: Data())
                }
                return nil
            } catch { return error }
        }
        await fulfillment(of: [started], timeout: 5)
        executor.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let c = await cancelled.requests.count
        XCTAssertEqual(c, 1)
        executor.cancel() // idle cancel is harmless
        _ = try await run("() => {}", executor: executor)
    }

    func testCancelBeforeRunDoesNotPoisonNextRun() async throws {
        let executor = JavaScriptFetchExecutor()
        executor.cancel()
        _ = try await run("async () => { await fetch('\(url)'); }", executor: executor)
    }

    func testSameExecutorIsSingleFlight() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let first = Task { _ = try await self.run("async () => { await fetch('\(self.url)'); }", executor: executor) { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 400_000_000)
            return JavaScriptFetchResponse(status: 200, body: Data())
        } }
        await fulfillment(of: [started], timeout: 5)
        await expectError(.busy, "() => {}", executor: executor)
        _ = try await first.value
        _ = try await run("() => {}", executor: executor)
    }

    func testGlobalAdmissionAllowsTwoInstances() async throws {
        let started = expectation(description: "two started"); started.expectedFulfillmentCount = 2
        let slow: JavaScriptFetchExecutor.Transport = { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 500_000_000)
            return JavaScriptFetchResponse(status: 200, body: Data())
        }
        let body = "async () => { await fetch('\(url)'); }"
        let a = Task { _ = try await self.run(body, transport: slow) }
        let b = Task { _ = try await self.run(body, transport: slow) }
        await fulfillment(of: [started], timeout: 5)
        await expectError(.busy, "() => {}") // third fresh executor
        _ = try await a.value
        _ = try await b.value
    }

    func testNonLeavePhasesAndLegacyHooksRejectFetchMode() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave(){}}});")
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .request, .response] {
            do {
                _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config) { _ in
                    JavaScriptFetchResponse(status: 200, body: Data())
                }
                XCTFail("accepted \(hook)")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput) }
        }
    }

    func testSchedulingProbePreservesSyncAndDefersAsyncWithoutNetwork() async throws {
        let executor = JavaScriptExecutor()
        let sync = try package("Interceptor.attach({response:{onLeave(){return {actions:[]};}}});")
        let output = try await executor.runV2(packageJSON: sync, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
        XCTAssertEqual(try JSONValue(parsing: output), .object(["actions": .array([])]))
        for callback in ["async () => {}", "() => { fetch('https://api.example.com/x'); }", "() => { try { fetch('https://api.example.com/x'); } catch(e) {} }"] {
            let pkg = try package("Interceptor.attach({response:{onLeave:" + callback + "}});")
            do {
                _ = try await executor.runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
                XCTFail("expected a scheduling signal")
            } catch { XCTAssertTrue(error is JavaScriptAsyncRequired, "\(error)") }
        }
        let bad = try package("Interceptor.attach({response:{onLeave(){throw new Error('legacy failure');}}});")
        do {
            _ = try await executor.runV2(packageJSON: bad, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
            XCTFail("legacy sync error must remain immediate")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
    }

    func testLegacyRuntimeHasNoGlobalFetch() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave(){ if (typeof fetch !== 'undefined') throw new Error('x'); }}});")
        _ = try await JavaScriptExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config)
    }
}
