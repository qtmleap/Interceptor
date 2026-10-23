import AutomationCore
@testable import AutomationRuntime
import XCTest

/// `Interceptor.saveJSON(key, jsonText)` through the real shared C runtime (`qjs_run_v2_fetch_save`), response.onLeave only.
/// Intended Swift interface: `JavaScriptFetchExecutor.SaveJSON = @Sendable (String, String) async throws -> Void` and
/// `runV2(... configJSON:, saveJSON: SaveJSON? = nil, transport:)`.
final class JavaScriptSaveJSONTests: XCTestCase, @unchecked Sendable {
    private let file = "hooks/api.example.com/credentials/GET.js"
    private let route = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onLeave":"hooks/api.example.com/credentials/GET.js"}}}"#
    private let event = Data(#"{"request":{"method":"GET","host":"api.example.com","path":"/credentials"},"response":{"status":200,"headers":{},"body":{"accessToken":"t"}}}"#.utf8)
    private let config = Data("{}".utf8)
    private let url = "https://api.example.com/v1/profile"
    private static let oneMiB = 1024 * 1024

    private struct SaveFailure: Error {}

    private actor Saves {
        var items: [(key: String, text: String)] = []
        var cancelled = 0
        func add(_ k: String, _ t: String) { items.append((k, t)) }
        func markCancelled() { cancelled += 1 }
    }

    private func package(_ source: String, files: Bool? = true) throws -> Data {
        let code = try JSONValue.string(source).jsonString()
        let write = files.map { #"{"requestBody":false,"responseBody":false,"files":\#($0)}"# } ?? #"{"requestBody":false,"responseBody":false}"#
        let m = #"{"schemaVersion":2,"id":"22222222-2222-4222-8222-222222222222","name":"Sample","version":"1.0.0","matches":[\#(route)],"read":{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":\#(write),"endpointBindings":[],"settings":{},"outbound":{}}"#
        return Data(#"{"manifest":\#(m),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
    }

    private func run(_ body: String, top: String = "", files: Bool? = true, hook: JavaScriptHook = .responseLeave,
                     executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(), saves: Saves = Saves(),
                     save: JavaScriptFetchExecutor.SaveJSON? = nil,
                     transport: @escaping JavaScriptFetchExecutor.Transport = { _ in JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8)) }) async throws -> [[String: Any]]
    {
        let pkg = try package("\(top)Interceptor.attach({response:{onLeave:\(body)}});", files: files)
        let callback: JavaScriptFetchExecutor.SaveJSON = save ?? { k, t in await saves.add(k, t) }
        let data = try await executor.runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config, saveJSON: callback, transport: transport)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["actions"] as? [[String: Any]])
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ body: String, top: String = "", files: Bool? = true,
                             executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(), saves: Saves = Saves(),
                             save: JavaScriptFetchExecutor.SaveJSON? = nil, line: UInt = #line) async
    {
        do {
            let r = try await run(body, top: top, files: files, executor: executor, saves: saves, save: save)
            XCTFail("expected \(expected), got \(r)", line: line)
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    /// Hook that must see `saveJSON` reject (catchably) and the host callback never run.
    private func assertRejectsWithoutCallback(_ args: String, files: Bool? = true, line: UInt = #line) async throws {
        let saves = Saves()
        _ = try await run("async () => { try { await Interceptor.saveJSON(\(args)); } catch (e) { return; } throw new Error('accepted'); }", files: files, saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 0, "callback must not run for \(args)", line: line)
    }

    // MARK: exact interface and bytes

    func testSaveJSONDeliversExactKeyAndOriginalText() async throws {
        let saves = Saves()
        _ = try await run("async () => { await Interceptor.saveJSON('history', '{\"a\":1}'); }", saves: saves)
        let items = await saves.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.key, "history")
        XCTAssertEqual(items.first?.text, "{\"a\":1}")
    }

    func testOriginalUTF8BytesWhitespaceOrderAndEscapesArePreserved() async throws {
        let original = "  {\n\t\"z\" : 1 ,\"a\":[1.0, 1e2, -0],\"s\":\"日本語😀é\\u00e9\\ud83d\\ude00\\/\",\"n\":null }\r\n"
        let bytes = Data(original.utf8)
        let saves = Saves()
        _ = try await run("async () => { const r = await fetch('\(url)'); const t = await r.text(); await Interceptor.saveJSON('k', t); }", saves: saves, transport: { _ in
            JavaScriptFetchResponse(status: 200, body: bytes)
        })
        let items = await saves.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(Data(try XCTUnwrap(items.first).text.utf8), bytes)
    }

    func testUnicodeKeyAndTextAreNotNormalizedOrEscaped() async throws {
        let saves = Saves()
        let key = "e\u{0301}-日本-😀" // decomposed é must stay decomposed
        let text = "{\"k\":\"e\u{0301}\"}"
        _ = try await run("async () => { await Interceptor.saveJSON(\(try JSONValue.string(key).jsonString()), \(try JSONValue.string(text).jsonString())); }", saves: saves)
        let items = await saves.items
        XCTAssertEqual(Array(try XCTUnwrap(items.first).key.utf8), Array(key.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(items.first).text.utf8), Array(text.utf8))
    }

    func testAcceptsAllJSONValueKindsAtTopLevel() async throws {
        let saves = Saves()
        let docs = ["{}", "[]", "0", "-1.5e3", "\"s\"", "true", "false", "null", " [1, {\"a\": []}] "]
        let literal = try JSONValue.array(docs.map { .string($0) }).jsonString()
        _ = try await run("async () => { for (const d of \(literal)) await Interceptor.saveJSON('k', d); }", saves: saves)
        let got = await saves.items.map(\.text)
        XCTAssertEqual(got, docs)
    }

    func testSequentialAwaitedSavesRunInOrderAndSameKeyRepeats() async throws {
        let saves = Saves()
        _ = try await run("async () => { await Interceptor.saveJSON('a', '1'); await Interceptor.saveJSON('a', '2'); await Interceptor.saveJSON('b', '3'); }", saves: saves)
        let items = await saves.items
        XCTAssertEqual(items.map(\.key), ["a", "a", "b"])
        XCTAssertEqual(items.map(\.text), ["1", "2", "3"])
    }

    func testPromiseSettlesOnlyAfterCallbackReturns() async throws {
        let saves = Saves()
        _ = try await run("async () => { const p = Interceptor.saveJSON('k', '{}'); if (!(p instanceof Promise)) throw new Error('not a promise'); const v = await p; if (v !== undefined) throw new Error('value'); }", saves: saves) 
        let n = await saves.items.count
        XCTAssertEqual(n, 1)
        let order = Saves()
        _ = try await run("async () => { await Interceptor.saveJSON('k', '{}'); await fetch('\(url)'); }", saves: order, save: { k, t in
            try await Task.sleep(nanoseconds: 200_000_000)
            await order.add(k, t)
        }) { _ in
            let done = await order.items.count
            XCTAssertEqual(done, 1, "fetch must start only after the awaited save completed")
            return JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    // MARK: permission

    func testDeniedOrAbsentFilesPermissionRejectsWithoutCallback() async throws {
        for files in [false, nil] as [Bool?] {
            try await assertRejectsWithoutCallback("'k', '{}'", files: files)
            // Uncaught rejection is a script error, still without I/O.
            let saves = Saves()
            await expectError(.scriptError, "async () => { await Interceptor.saveJSON('k', '{}'); }", files: files, saves: saves)
            let n = await saves.items.count
            XCTAssertEqual(n, 0)
        }
    }

    func testMissingSaveCallbackRejectsEvenWithPermission() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave:async () => { try { await Interceptor.saveJSON('k', '{}'); } catch (e) { return; } throw new Error('accepted'); }}});")
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    // MARK: key and JSON validation

    func testInvalidKeysRejectWithoutCallback() async throws {
        let long = String(repeating: "a", count: 1025)
        let wide = String(repeating: "あ", count: 342) // 1026 UTF-8 bytes
        for args in ["'', '{}'", "'a\\u0000b', '{}'", "'\\u0000', '{}'", "'\(long)', '{}'", "'\(wide)', '{}'", "'\\ud800', '{}'",
                     "42, '{}'", "null, '{}'", "undefined, '{}'", "{}, '{}'", "'k'"]
        {
            try await assertRejectsWithoutCallback(args)
        }
    }

    func testKeyLengthLimitIsUTF8BytesInclusive() async throws {
        let saves = Saves()
        let ascii = String(repeating: "a", count: 1024)
        let wide = String(repeating: "あ", count: 341) + "a" // 1024 bytes exactly
        _ = try await run("async () => { await Interceptor.saveJSON('\(ascii)', '{}'); await Interceptor.saveJSON('\(wide)', '{}'); await Interceptor.saveJSON('x', '{}'); }", saves: saves)
        let keys = await saves.items.map(\.key)
        XCTAssertEqual(keys, [ascii, wide, "x"])
        // Keys are logical, not paths: separators and dots are accepted verbatim, not interpreted.
        let paths = Saves()
        _ = try await run("async () => { await Interceptor.saveJSON('../a/b\\\\c', '{}'); await Interceptor.saveJSON('.', '{}'); }", saves: paths)
        let pk = await paths.items.map(\.key)
        XCTAssertEqual(pk, ["../a/b\\c", "."])
    }

    func testInvalidJSONRejectsWithoutCallback() async throws {
        for text in ["", " ", "{bad", "{\"a\":1,}", "[1 2]", "'single'", "{\"a\":01}", "NaN", "Infinity", "{\"a\":1} x", "{\"a\":1}{\"b\":2}",
                     "\"\\ud800\"x", "\"unterminated", "/* c */ {}", "{\"a\":\"\u{0001}\"}"]
        {
            let literal = try JSONValue.string(text).jsonString()
            try await assertRejectsWithoutCallback("'k', \(literal)")
        }
        for args in ["'k', 1", "'k', {}", "'k', null", "'k', undefined", "'k', ['x']"] {
            try await assertRejectsWithoutCallback(args)
        }
    }

    func testNestingDepthLimitIs64() async throws {
        func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        let saves = Saves()
        _ = try await run("async () => { await Interceptor.saveJSON('ok', '\(nested(64))'); }", saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 1)
        try await assertRejectsWithoutCallback("'deep', '\(nested(65))'")
        let objects = String(repeating: "{\"a\":", count: 65) + "0" + String(repeating: "}", count: 65)
        try await assertRejectsWithoutCallback("'deep', '\(objects)'")
    }

    func testJSONSizeLimitIsOneMiBInclusive() async throws {
        let exact = "\"" + String(repeating: "a", count: Self.oneMiB - 2) + "\""
        let over = "\"" + String(repeating: "a", count: Self.oneMiB - 1) + "\""
        let saves = Saves()
        _ = try await run("async () => { const t = '\"' + 'a'.repeat(\(Self.oneMiB - 2)) + '\"'; await Interceptor.saveJSON('big', t); }", saves: saves)
        let items = await saves.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text.utf8.count, exact.utf8.count)
        XCTAssertEqual(items.first?.text, exact)
        let rejected = Saves()
        _ = try await run("async () => { const t = '\"' + 'a'.repeat(\(Self.oneMiB - 1)) + '\"'; try { await Interceptor.saveJSON('big', t); } catch (e) { return; } throw new Error('accepted'); }", saves: rejected)
        let none = await rejected.items.count
        XCTAssertEqual(none, 0)
        XCTAssertEqual(exact.utf8.count, Self.oneMiB)
        XCTAssertEqual(over.utf8.count, Self.oneMiB + 1)
    }

    func testLimitIsMeasuredInUTF8BytesNotCharacters() async throws {
        // 349_526 three-byte scalars + quotes = 1_048_580 bytes > 1 MiB, though only 349_528 UTF-16 units.
        let saves = Saves()
        _ = try await run("async () => { const t = '\"' + 'あ'.repeat(349526) + '\"'; try { await Interceptor.saveJSON('big', t); } catch (e) { return; } throw new Error('accepted'); }", saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 0)
    }

    func testOneMiBUnicodeEscapedResponseFitsHeapWithoutDuplication() async throws {
        // fetch text() then saveJSON of a near-1MiB multibyte/escaped document must not exhaust the QuickJS heap.
        var body = "[\"" + String(repeating: "日", count: 300_000) + "\",\""
        body += String(repeating: "\\u00e9", count: 20_000) + "\"]"
        XCTAssertLessThanOrEqual(body.utf8.count, Self.oneMiB)
        let bytes = Data(body.utf8)
        let saves = Saves()
        _ = try await run("async () => { const t = await (await fetch('\(url)')).text(); await Interceptor.saveJSON('big', t); }", saves: saves, transport: { _ in
            JavaScriptFetchResponse(status: 200, body: bytes)
        })
        let items = await saves.items
        XCTAssertEqual(Data(try XCTUnwrap(items.first).text.utf8), bytes)
    }

    // MARK: per-invocation budgets

    func testSaveCountCapIs64() async throws {
        let saves = Saves()
        _ = try await run("async () => { let rejected = 0; for (let i = 0; i < 65; i++) { try { await Interceptor.saveJSON('k' + i, '{}'); } catch (e) { rejected++; } } if (rejected !== 1) throw new Error('r' + rejected); }", saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 64)
    }

    func testSubmittedBytesCapIs16MiB() async throws {
        let saves = Saves()
        // 16 documents of exactly 1 MiB are accepted; the 17th is rejected and never reaches the host.
        _ = try await run("""
        async () => {
          const t = '"' + 'a'.repeat(\(Self.oneMiB - 2)) + '"';
          let rejected = 0;
          for (let i = 0; i < 17; i++) { try { await Interceptor.saveJSON('k' + i, t); } catch (e) { rejected++; } }
          if (rejected !== 1) throw new Error('r' + rejected);
        }
        """, saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 16)
    }

    func testRejectedAttemptsDoNotConsumeSaveBudget() async throws {
        let saves = Saves()
        _ = try await run("async () => { for (let i = 0; i < 100; i++) { try { await Interceptor.saveJSON('', '{}'); } catch (e) {} } for (let i = 0; i < 64; i++) await Interceptor.saveJSON('k' + i, '{}'); }", saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 64)
    }

    func testFetchAndSaveBudgetsAreSeparate() async throws {
        let saves = Saves()
        let fetches = Saves()
        _ = try await run("async () => { for (let i = 0; i < 64; i++) { await fetch('\(url)'); } for (let i = 0; i < 64; i++) await Interceptor.saveJSON('k' + i, '{}'); try { await fetch('\(url)'); } catch (e) { try { await Interceptor.saveJSON('x', '{}'); } catch (f) { return; } } throw new Error('caps'); }", saves: saves, transport: { req in
            await fetches.add(req.url, "")
            return JavaScriptFetchResponse(status: 200, body: Data())
        })
        let s = await saves.items.count, f = await fetches.items.count
        XCTAssertEqual(s, 64)
        XCTAssertEqual(f, 64)
    }

    // MARK: errors and cancellation

    func testHostFailureRejectsCatchablyAndLaterSavesProceed() async throws {
        let saves = Saves()
        _ = try await run("async () => { try { await Interceptor.saveJSON('bad', '{}'); } catch (e) { await Interceptor.saveJSON('good', '[]'); return; } throw new Error('not rejected'); }", save: { k, t in
            if k == "bad" { throw SaveFailure() }
            await saves.add(k, t)
        })
        let items = await saves.items
        XCTAssertEqual(items.map(\.key), ["good"])
    }

    func testRejectionDoesNotLeakHostErrorDetail() async throws {
        struct Secret: Error, CustomStringConvertible { var description: String { "/private/var/secret/path" } }
        let actions = try await run("async () => { try { await Interceptor.saveJSON('k', '{}'); } catch (e) { if (String(e && e.message).includes('secret') || String(e).includes('/private')) throw new Error('leaked'); return; } throw new Error('x'); }", save: { _, _ in throw Secret() })
        XCTAssertEqual(actions.count, 0)
    }

    func testUncaughtSaveFailureIsScriptErrorAndStopsTheHook() async {
        let saves = Saves()
        await expectError(.scriptError, "async () => { await Interceptor.saveJSON('a', '{}'); await Interceptor.saveJSON('b', '{}'); await Interceptor.saveJSON('c', '{}'); }", saves: saves, save: { k, t in
            if k == "b" { throw SaveFailure() }
            await saves.add(k, t)
        })
        let keys = await saves.items.map(\.key)
        XCTAssertEqual(keys, ["a"])
    }

    func testCancelDuringSaveCancelsTaskAndThrowsCancelled() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let saves = Saves()
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { try { await Interceptor.saveJSON('k', '{}'); } catch (e) {} await Interceptor.saveJSON('after', '{}'); }", executor: executor, saves: saves, save: { _, _ in
                    started.fulfill()
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { await saves.markCancelled(); throw error }
                })
                return nil
            } catch { return error }
        }
        await fulfillment(of: [started], timeout: 5)
        executor.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let cancelled = await saves.cancelled
        XCTAssertEqual(cancelled, 1, "host callback task must be cancelled and awaited before runV2 returns")
        let after = await saves.items.count
        XCTAssertEqual(after, 0, "script must not continue after cancellation")
        executor.cancel()
        _ = try await run("() => {}", executor: executor)
    }

    func testTaskCancellationDuringSaveThrowsCancelled() async throws {
        let started = expectation(description: "started")
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { await Interceptor.saveJSON('k', '{}'); }", save: { _, _ in
                    started.fulfill()
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                })
                return nil
            } catch { return error }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
    }

    func testCancelledBeforeRunNeverInvokesCallback() async {
        let saves = Saves()
        let task = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try await self.run("async () => { await Interceptor.saveJSON('k', '{}'); }", saves: saves); return nil } catch { return error }
        }
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let n = await saves.items.count
        XCTAssertEqual(n, 0)
    }

    func testCpuBudgetExcludesSaveWaitOnly() async throws {
        _ = try await run("async () => { await Interceptor.saveJSON('k', '{}'); }", save: { _, _ in try await Task.sleep(nanoseconds: 600_000_000) })
        await expectError(.timeout, "async () => { await Interceptor.saveJSON('k', '{}'); for (;;) {} }")
    }

    func testSameExecutorStaysSingleFlightDuringSave() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let first = Task { _ = try await self.run("async () => { await Interceptor.saveJSON('k', '{}'); }", executor: executor, save: { _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 400_000_000)
        }) }
        await fulfillment(of: [started], timeout: 5)
        await expectError(.busy, "() => {}", executor: executor)
        _ = try await first.value
        _ = try await run("() => {}", executor: executor)
    }

    // MARK: phase, probe and global shape

    func testOnlyResponseLeaveAcceptsSaveMode() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave(){}}});")
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .request, .response] {
            let saves = Saves()
            do {
                _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config,
                                                              saveJSON: { k, t in await saves.add(k, t) }) { _ in JavaScriptFetchResponse(status: 200, body: Data()) }
                XCTFail("accepted \(hook)")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput) }
            let n = await saves.items.count
            XCTAssertEqual(n, 0)
        }
    }

    func testSaveJSONIsNotExposedOutsideDeferredLeaveRuntime() async throws {
        // Legacy/non-fetch runtime (including the scheduling probe's sync path): no saveJSON on Interceptor in other phases.
        let src = "Interceptor.attach({request:{onEnter(){ if (typeof Interceptor.saveJSON !== 'undefined' || typeof saveJSON !== 'undefined') throw new Error('exposed'); }, onLeave(){}}, response:{onEnter(){ if (typeof Interceptor.saveJSON !== 'undefined') throw new Error('exposed'); }, onLeave(){}}});"
        let pkg = try package(src)
        for hook in [JavaScriptHook.requestEnter, .responseEnter] {
            _ = try await JavaScriptExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config)
        }
        let globalProbe = try package("Interceptor.attach({response:{onLeave:async () => { if (typeof saveJSON !== 'undefined' || typeof globalThis.saveJSON !== 'undefined') throw new Error('global'); }}});")
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: globalProbe, hook: .responseLeave, eventJSON: event, configJSON: config, saveJSON: { _, _ in XCTFail("no call") }) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    func testSchedulingProbeDefersSaveJSONWithoutAnyIO() async throws {
        let executor = JavaScriptExecutor()
        for callback in ["() => { Interceptor.saveJSON('k', '{}'); }",
                         "() => { try { Interceptor.saveJSON('k', '{}'); } catch(e) {} }",
                         "async () => { await Interceptor.saveJSON('k', '{}'); }"]
        {
            for files in [true, false] as [Bool?] {
                let pkg = try package("Interceptor.attach({response:{onLeave:" + callback + "}});", files: files)
                do {
                    _ = try await executor.runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
                    XCTFail("expected a scheduling signal for \(callback)")
                } catch { XCTAssertTrue(error is JavaScriptAsyncRequired, "\(error)") }
            }
        }
        // A synchronous hook that never touches saveJSON still completes inline.
        let sync = try package("Interceptor.attach({response:{onLeave(){return {actions:[]};}}});")
        let output = try await executor.runV2(packageJSON: sync, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
        XCTAssertEqual(try JSONValue(parsing: output), .object(["actions": .array([])]))
    }

    func testTopLevelSaveJSONIsStickyInvalid() async {
        let saves = Saves()
        await expectError(.scriptError, "() => {}", top: "try { Interceptor.saveJSON('k', '{}'); } catch (e) {}\n", saves: saves)
        let n = await saves.items.count
        XCTAssertEqual(n, 0)
    }

    func testNeverSettlingPromiseAfterSaveIsScriptError() async {
        await expectError(.scriptError, "async () => { await Interceptor.saveJSON('k', '{}'); await new Promise(() => {}); }")
    }

    func testInterceptorSurfaceKeepsSaveJSONAlongsideFetchOnly() async throws {
        _ = try await run("async () => { const keys = Object.keys(Interceptor).sort().join(','); if (keys !== 'attach,saveJSON,send' && keys !== 'attach,saveJSON') throw new Error(keys); if (typeof Interceptor.saveJSON !== 'function' || typeof fetch !== 'function') throw new Error('shape'); if (Interceptor.saveJSON.length !== 2) throw new Error('arity'); }")
    }

    // MARK: existing fetch compatibility

    func testFetchOnlyCallSitesStillWorkWithoutSaveCallback() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave:async () => { const r = await fetch('\(url)'); const j = await r.json(); if (j.a !== 1) throw new Error('x'); }}});", files: nil)
        let data = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8))
        }
        XCTAssertEqual(try JSONValue(parsing: data), .object(["actions": .array([])]))
    }

    func testFetchRequestShapeUnchangedWhenSaveCallbackIsPresent() async throws {
        let fetches = Saves()
        let seen = FetchSeen()
        _ = try await run("async () => { await fetch('\(url)'); }", saves: fetches, transport: { req in
            await seen.add(req)
            return JavaScriptFetchResponse(status: 200, body: Data())
        })
        let reqs = await seen.items
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs.first?.method, "GET")
        XCTAssertEqual(reqs.first?.maxResponseBytes, Self.oneMiB)
        XCTAssertLessThanOrEqual(reqs.first?.timeoutMilliseconds ?? .max, 5000)
        let n = await fetches.items.count
        XCTAssertEqual(n, 0)
    }

    private actor FetchSeen {
        var items: [JavaScriptFetchRequest] = []
        func add(_ r: JavaScriptFetchRequest) { items.append(r) }
    }
}
