import AutomationCore
@testable import AutomationRuntime
import XCTest

/// `Interceptor.createFile({storage, atPath, contents})` through the real shared C runtime (`qjs_run_v2_fetch_files`),
/// response.onLeave only. Swift interface: `JavaScriptFetchExecutor.CreateFile = @Sendable (PluginFileDestination, Data)
/// async throws -> Void` and `runV2(... configJSON:, createFile: CreateFile? = nil, transport:)`.
final class JavaScriptCreateFileTests: XCTestCase, @unchecked Sendable {
    private let file = "hooks/api.example.com/credentials/GET.js"
    private let route = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onLeave":"hooks/api.example.com/credentials/GET.js"}}}"#
    private let event = Data(#"{"request":{"method":"GET","host":"api.example.com","path":"/credentials"},"response":{"status":200,"headers":{},"body":{"accessToken":"t"}}}"#.utf8)
    private let config = Data("{}".utf8)
    private let url = "https://api.example.com/v1/profile"
    private static let oneMiB = 1024 * 1024

    private struct WriteFailure: Error {}

    private struct Write: Equatable {
        var storage: PluginFileStorage
        var path: String
        var contents: Data
        var text: String { String(decoding: contents, as: UTF8.self) }
    }

    private actor Writes {
        var items: [Write] = []
        var cancelled = 0
        func add(_ d: PluginFileDestination, _ c: Data) { items.append(Write(storage: d.storage, path: d.atPath, contents: c)) }
        func markCancelled() { cancelled += 1 }
    }

    private func package(_ source: String, files: Bool? = true, route override: String? = nil) throws -> Data {
        let code = try JSONValue.string(source).jsonString()
        let selectedRoute = override ?? route
        let write = files.map { #"{"requestBody":false,"responseBody":false,"files":\#($0)}"# } ?? #"{"requestBody":false,"responseBody":false}"#
        let m = #"{"schemaVersion":2,"id":"22222222-2222-4222-8222-222222222222","name":"Sample","version":"1.0.0","matches":[\#(selectedRoute)],"read":{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":\#(write),"endpointBindings":[],"settings":{},"outbound":{}}"#
        return Data(#"{"manifest":\#(m),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
    }

    private func run(_ body: String, top: String = "", files: Bool? = true, hook: JavaScriptHook = .responseLeave,
                     executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(), writes: Writes = Writes(),
                     create: JavaScriptFetchExecutor.CreateFile? = nil,
                     transport: @escaping JavaScriptFetchExecutor.Transport = { _ in JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8)) }) async throws -> [[String: Any]]
    {
        let pkg = try package("\(top)Interceptor.attach({response:{onLeave:\(body)}});", files: files)
        let callback: JavaScriptFetchExecutor.CreateFile = create ?? { d, c in await writes.add(d, c) }
        let data = try await executor.runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config, createFile: callback, transport: transport)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["actions"] as? [[String: Any]])
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ body: String, top: String = "", files: Bool? = true,
                             executor: JavaScriptFetchExecutor = JavaScriptFetchExecutor(), writes: Writes = Writes(),
                             create: JavaScriptFetchExecutor.CreateFile? = nil, line: UInt = #line) async
    {
        do {
            let r = try await run(body, top: top, files: files, executor: executor, writes: writes, create: create)
            XCTFail("expected \(expected), got \(r)", line: line)
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    /// `Interceptor.createFile({...})` source for a call with the given option-object literal.
    private func call(_ options: String) -> String { "Interceptor.createFile(\(options))" }

    private func opts(path: String = "'f.txt'", storage: String = "Interceptor.Storage.local", contents: String = "'x'") -> String {
        "{storage: \(storage), atPath: \(path), contents: \(contents)}"
    }

    /// The hook must see createFile reject catchably and the host callback never run.
    private func assertRejectsWithoutCallback(_ expression: String, files: Bool? = true, line: UInt = #line) async throws {
        let writes = Writes()
        _ = try await run("async () => { try { await \(expression); } catch (e) { return; } throw new Error('accepted'); }", files: files, writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 0, "callback must not run for \(expression)", line: line)
    }

    // MARK: exact interface and bytes

    func testGrantedWriteBatchCanUseMoreThanFetchOnlyCpuBudget() async throws {
        let writes = Writes()
        _ = try await run("async () => { const start = Date.now(); while (Date.now() - start < 350) {} await \(call(opts())); }", writes: writes)
        let count = await writes.items.count
        XCTAssertEqual(count, 1)
    }

    func testMissingFilesGrantKeepsShortCpuBudget() async {
        for files in [false, nil] as [Bool?] {
            await expectError(.timeout, "async () => { const start = Date.now(); while (Date.now() - start < 350) {} }", files: files)
        }
    }

    func testCreateFileDeliversStoragePathAndRawNonJSONText() async throws {
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'Salmon Run/history.json'", storage: "Interceptor.Storage.iCloudDrive", contents: "'raw text not JSON'"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items, [Write(storage: .icloud, path: "Salmon Run/history.json", contents: Data("raw text not JSON".utf8))])
    }

    func testCreateFileAcceptsEmptyTextAndReplacesSaveJSON() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          if (typeof Interceptor.saveJSON !== 'undefined') throw new Error('saveJSON alias remains');
          if (typeof Interceptor.createFile !== 'function' || Interceptor.createFile.length !== 1) throw new Error('shape');
          const v = await \(call(opts(path: "'empty.txt'", contents: "''")));
          if (v !== undefined) throw new Error('value');
        }
        """, writes: writes)
        let items = await writes.items
        XCTAssertEqual(items, [Write(storage: .local, path: "empty.txt", contents: Data())])
    }

    func testRawTextPreservesUTF8NulWhitespaceAndNormalization() async throws {
        let original = "  {\n\t\"z\" : 1 ,\"a\":[1.0, 1e2, -0],\"s\":\"日本語😀é\\u00e9\\ud83d\\ude00\\/\",\"n\":null }\r\n"
        let decomposed = "e\u{0301}-日本-😀 \u{0}nul\u{0}"
        let bytes = Data(original.utf8)
        let writes = Writes()
        _ = try await run("""
        async () => {
          const t = await (await fetch('\(url)')).text();
          await \(call(opts(path: "'a.txt'", contents: "t")));
          await \(call(opts(path: "'b.txt'", contents: try JSONValue.string(decomposed).jsonString())));
        }
        """, writes: writes, transport: { _ in JavaScriptFetchResponse(status: 200, body: bytes) })
        let items = await writes.items
        XCTAssertEqual(items.map(\.contents), [bytes, Data(decomposed.utf8)])
    }

    func testNonJSONAndInvalidJSONContentsAreNeverParsedOrRequireExtension() async throws {
        let docs = ["", " ", "{bad", "[1 2]", "NaN", "{\"a\":1,\"a\":2}", String(repeating: "[", count: 200), "{\"a\":\"\u{0001}\"}", "plain"]
        let literal = try JSONValue.array(docs.map { .string($0) }).jsonString()
        let writes = Writes()
        _ = try await run("async () => { let i = 0; for (const d of \(literal)) await \(call(opts(path: "'noext' + (i++)", contents: "d"))); }", writes: writes)
        let got = await writes.items.map(\.text)
        XCTAssertEqual(got, docs)
    }

    func testSequentialAwaitedWritesRunInOrderAndSamePathRepeats() async throws {
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'a'", contents: "'1'"))); await \(call(opts(path: "'a'", contents: "'2'"))); await \(call(opts(path: "'b'", contents: "'3'"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["a", "a", "b"])
        XCTAssertEqual(items.map(\.text), ["1", "2", "3"])
    }

    func testPromiseSettlesOnlyAfterCallbackReturns() async throws {
        let writes = Writes()
        _ = try await run("async () => { const p = \(call(opts())); if (!(p instanceof Promise)) throw new Error('not a promise'); const v = await p; if (v !== undefined) throw new Error('value'); }", writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 1)
        let order = Writes()
        _ = try await run("async () => { await \(call(opts())); await fetch('\(url)'); }", writes: order, create: { d, c in
            try await Task.sleep(nanoseconds: 200_000_000)
            await order.add(d, c)
        }) { _ in
            let done = await order.items.count
            XCTAssertEqual(done, 1, "fetch must start only after the awaited write completed")
            return JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    // MARK: binary contents

    func testUint8ArrayBytesAreExactIncludingZerosEmptyAndHighBytes() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          const all = new Uint8Array(256);
          for (let i = 0; i < 256; i++) all[i] = i;
          await \(call(opts(path: "'all.bin'", contents: "all")));
          await \(call(opts(path: "'zero.bin'", contents: "new Uint8Array([0, 0, 0])")));
          await \(call(opts(path: "'empty.bin'", contents: "new Uint8Array(0)")));
          await \(call(opts(path: "'nul-text'", contents: "'a\\u0000b'")));
        }
        """, writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["all.bin", "zero.bin", "empty.bin", "nul-text"])
        XCTAssertEqual(items[0].contents, Data((0 ... 255).map { UInt8($0) }))
        XCTAssertEqual(items[1].contents, Data([0, 0, 0]))
        XCTAssertEqual(items[2].contents, Data())
        XCTAssertEqual(items[3].contents, Data([0x61, 0, 0x62]))
    }

    func testUint8ArraySubviewsAndOffsetsSendOnlyTheViewedBytes() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          const buffer = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]).buffer;
          await \(call(opts(path: "'mid'", contents: "new Uint8Array(buffer, 2, 3)")));
          await \(call(opts(path: "'tail'", contents: "new Uint8Array(buffer, 6)")));
          await \(call(opts(path: "'sub'", contents: "new Uint8Array(buffer).subarray(1, 4)")));
          await \(call(opts(path: "'zero-len'", contents: "new Uint8Array(buffer, 8)")));
        }
        """, writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.contents), [Data([3, 4, 5]), Data([7, 8]), Data([2, 3, 4]), Data()])
    }

    func testBinarySizeLimitIsOneMiBInclusive() async throws {
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'big'", contents: "new Uint8Array(\(Self.oneMiB)).fill(7)"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.first?.contents.count, Self.oneMiB)
        XCTAssertEqual(items.first?.contents.allSatisfy { $0 == 7 }, true)
        try await assertRejectsWithoutCallback(call(opts(contents: "new Uint8Array(\(Self.oneMiB + 1))")))
    }

    func testOtherBinaryShapesAreRejectedWithoutCallback() async throws {
        let rejected = [
            "new ArrayBuffer(4)", "new Uint8ClampedArray(4)", "new Int8Array(4)", "new Uint16Array(2)", "new Int32Array(1)",
            "new Float64Array(1)", "new DataView(new ArrayBuffer(4))", "[1, 2, 3]", "{length: 1, 0: 1}",
            "new Proxy(new Uint8Array(2), {})", "new Proxy({}, {})", "Object.create(Uint8Array.prototype)",
            "null", "undefined", "42", "true", "Symbol('s')", "{toString() { return 'x'; }}", "new String('x')",
        ]
        for contents in rejected {
            try await assertRejectsWithoutCallback(call(opts(contents: contents)))
        }
    }

    func testSharedBuffersDoNotExistAndCannotReachTheHost() async throws {
        _ = try await run("""
        async () => {
          for (const name of ['SharedArrayBuffer', 'Atomics', 'WebAssembly']) {
            if (typeof globalThis[name] !== 'undefined') throw new Error(name);
          }
          if (typeof Uint8Array !== 'function' || typeof ArrayBuffer !== 'function') throw new Error('missing');
          if (!(Uint8Array.prototype.constructor === Uint8Array)) throw new Error('shape');
        }
        """)
    }

    func testDetachedViewsAreRejectedWithoutCallback() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          const bytes = new Uint8Array([1, 2, 3]);
          const moved = bytes.buffer.transfer ? bytes.buffer.transfer() : null;
          if (!moved) return;   // runtime without ArrayBuffer.prototype.transfer cannot detach from script
          if (bytes.byteLength !== 0) throw new Error('not detached');
          try { await \(call(opts(contents: "bytes"))); } catch (e) { return; }
          throw new Error('accepted detached view');
        }
        """, writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 0)
    }

    func testBytesAreCapturedAtCallTimeNotAliasedAfterwards() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          const bytes = new Uint8Array([1, 2, 3]);
          const p = \(call(opts(contents: "bytes")));
          bytes[0] = 99;
          await p;
        }
        """, writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.first?.contents, Data([1, 2, 3]))
    }

    func testTypedArrayGlobalsExistOnlyInDeferredLeaveRuntime() async throws {
        // Synchronous v2 phases and the legacy v1 executor keep the previous surface (no typed arrays, no shared memory).
        let sync = try package("Interceptor.attach({request:{onEnter(){ if (typeof Uint8Array !== 'undefined' || typeof ArrayBuffer !== 'undefined' || typeof SharedArrayBuffer !== 'undefined' || typeof Atomics !== 'undefined') throw new Error('typed arrays'); }, onLeave(){}}, response:{onEnter(){}, onLeave(){}}});")
        _ = try await JavaScriptExecutor().runV2(packageJSON: sync, hook: .requestEnter, eventJSON: event, configJSON: config)
        // The deferred response.onLeave runtime (with or without a create callback) has Uint8Array but never shared memory.
        let leave = try package("Interceptor.attach({response:{onLeave:async () => { if (typeof Uint8Array !== 'function' || typeof SharedArrayBuffer !== 'undefined' || typeof Atomics !== 'undefined') throw new Error('surface'); }}});", files: nil)
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: leave, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }
    // MARK: Enum, options object and descriptors

    func testStorageEnumIsAvailableBeforeMultiPhaseSourceEvaluation() async throws {
        let multiRoute = route.replacingOccurrences(of: "\"hooks\":{", with: "\"hooks\":{\"request\":{\"onEnter\":\"\(file)\"},")
        let source = """
        const target = Interceptor.Storage.iCloudDrive;
        Interceptor.attach({request:{onEnter(){if(target !== 'icloud') throw new Error('storage');}},
          response:{onLeave(){if(target !== 'icloud') throw new Error('storage');}}});
        """
        let pkg = try package(source, route: multiRoute)
        _ = try await JavaScriptExecutor().runV2(packageJSON: pkg, hook: .requestEnter, eventJSON: event, configJSON: config)
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    func testOptionsWithCustomPrototypesAreRejectedWithoutCallbacks() async throws {
        for expression in [
            "Object.assign(Object.create({marker: 1}), {storage: Interceptor.Storage.local, atPath: 'a', contents: 'x'})",
            "new (class Options { constructor() { this.storage = Interceptor.Storage.local; this.atPath = 'a'; this.contents = 'x'; } })()",
        ] {
            try await assertRejectsWithoutCallback("Interceptor.createFile(\(expression))")
        }
    }

    func testStorageEnumValuesAreImmutable() async throws {
        _ = try await run("""
        async () => {
          const s = Interceptor.Storage;
          if (s.local !== 'local' || s.iCloudDrive !== 'icloud') throw new Error('values');
          if (Object.keys(s).sort().join(',') !== 'iCloudDrive,local') throw new Error('keys');
          if (!Object.isFrozen(s)) throw new Error('not frozen');
          try { s.local = 'x'; s.extra = 'y'; delete s.iCloudDrive; } catch (e) {}
          if (s.local !== 'local' || s.iCloudDrive !== 'icloud' || 'extra' in s) throw new Error('mutated');
          for (const key of ['local', 'iCloudDrive']) {
            const d = Object.getOwnPropertyDescriptor(s, key);
            if (d.writable || d.configurable || !d.enumerable) throw new Error('descriptor ' + key);
          }
          const b = Object.getOwnPropertyDescriptor(Interceptor, 'Storage');
          if (b.writable || b.configurable) throw new Error('binding');
          for (const attempt of [() => { Interceptor.Storage = {}; }, () => { delete Interceptor.Storage; },
                                 () => Object.defineProperty(Interceptor, 'Storage', {value: {}}),
                                 () => Object.defineProperty(s, 'local', {value: 'icloud'}),
                                 () => Object.setPrototypeOf(s, {})]) {
            try { attempt(); } catch (e) {}
            if (Interceptor.Storage !== s || s.local !== 'local') throw new Error('replaced');
          }
          if (Object.getPrototypeOf(s) !== Object.prototype) throw new Error('prototype');
        }
        """)
    }

    func testInterceptorSurfaceKeepsAttachSendAndAddsCreateFileAndStorage() async throws {
        _ = try await run("async () => { const keys = Object.keys(Interceptor).sort().join(','); if (keys !== 'Storage,attach,createFile,send' && keys !== 'Storage,attach,createFile') throw new Error(keys); if (typeof fetch !== 'function' || typeof Interceptor.attach !== 'function') throw new Error('shape'); }")
    }

    func testOptionsObjectMustBeExactlyThreeOwnEnumerableDataProperties() async throws {
        let bad = [
            "{storage: Interceptor.Storage.local, atPath: 'a'}", "{storage: Interceptor.Storage.local, contents: 'x'}",
            "{atPath: 'a', contents: 'x'}", "{}",
            "{storage: Interceptor.Storage.local, atPath: 'a', contents: 'x', extra: 1}",
            "{storage: Interceptor.Storage.local, atPath: 'a', contents: 'x', [Symbol('s')]: 1}",
            "{storage: Interceptor.Storage.local, atPath: 'a', contents: 'x', 0: 1}",
            "Object.defineProperty({storage: Interceptor.Storage.local, atPath: 'a'}, 'contents', {value: 'x', enumerable: false})",
            "Object.create({storage: Interceptor.Storage.local, atPath: 'a', contents: 'x'})",
            "Object.assign(Object.create({contents: 'x'}), {storage: Interceptor.Storage.local, atPath: 'a'})",
            "new Proxy({storage: Interceptor.Storage.local, atPath: 'a', contents: 'x'}, {})",
            "['local', 'a', 'x']", "'a'", "null", "undefined", "42", "() => {}", "new Map()",
        ]
        for options in bad {
            try await assertRejectsWithoutCallback("Interceptor.createFile(\(options))")
        }
        try await assertRejectsWithoutCallback("Interceptor.createFile()")
        try await assertRejectsWithoutCallback("Interceptor.createFile(\(opts()), 1)")
    }

    func testAccessorsAndProxiesAreRejectedWithoutInvokingUserCode() async throws {
        let writes = Writes()
        _ = try await run("""
        async () => {
          let invoked = 0;
          const getter = {storage: Interceptor.Storage.local, atPath: 'a'};
          Object.defineProperty(getter, 'contents', {get() { invoked++; return 'x'; }, enumerable: true});
          const proxy = new Proxy({storage: Interceptor.Storage.local, atPath: 'a', contents: 'x'}, {
            get() { invoked++; }, getOwnPropertyDescriptor() { invoked++; }, ownKeys() { invoked++; return []; }, has() { invoked++; }, getPrototypeOf() { invoked++; return null; },
          });
          const stringy = {toString() { invoked++; return 'local'; }};
          const objectContents = {storage: Interceptor.Storage.local, atPath: 'a', contents: {toString() { invoked++; return 'x'; }}};
          const objectPath = {storage: Interceptor.Storage.local, atPath: {toString() { invoked++; return 'a'; }}, contents: 'x'};
          const objectStorage = {storage: stringy, atPath: 'a', contents: 'x'};
          const bytes = new Uint8Array(1);
          Object.defineProperty(bytes, 'buffer', {get() { invoked++; return new ArrayBuffer(1); }});
          Object.defineProperty(bytes, 'length', {get() { invoked++; return 1; }});
          Object.defineProperty(bytes, 'byteOffset', {get() { invoked++; return 0; }});
          const viewOverride = {storage: Interceptor.Storage.local, atPath: 'a', contents: bytes};
          for (const o of [getter, proxy, objectContents, objectPath, objectStorage]) {
            try { await Interceptor.createFile(o); throw new Error('accepted'); } catch (e) { if (String(e && e.message) === 'accepted') throw e; }
          }
          // Instance-level shadowing of typed array accessors must not steer the bytes the host receives.
          await Interceptor.createFile(viewOverride);
          if (invoked !== 0) throw new Error('user code ran ' + invoked);
        }
        """, writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.contents), [Data([0])], "only the pristine-class view with shadowed accessors is accepted, using real bytes")
    }

    func testStorageValuesMustBeTheExactEnumStrings() async throws {
        for storage in ["'LOCAL'", "'iCloudDrive'", "'cloud'", "'local '", "'icloud\\u0000'", "''", "'iCloud'", "1", "null", "undefined", "{}", "Interceptor.Storage", "Symbol('local')"] {
            try await assertRejectsWithoutCallback(call(opts(storage: storage)))
        }
        // The raw strings are equivalent to the Enum values.
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'a'", storage: "'local'"))); await \(call(opts(path: "'b'", storage: "'icloud'"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.storage), [.local, .icloud])
    }

    // MARK: structural path validation

    func testPathWithCombiningMarkAfterSlashPreservesScalarComponents() async throws {
        let path = "a/\u{0301}b.txt"
        let writes = Writes()
        let callback: JavaScriptFetchExecutor.CreateFile = { destination, contents in
            XCTAssertEqual(Array(destination.atPath.utf8), Array(path.utf8))
            XCTAssertEqual(destination.pathComponents, ["a", "\u{0301}b.txt"])
            await writes.add(destination, contents)
        }
        let literal = try JSONValue.string(path).jsonString()
        _ = try await run("async () => { await \(call(opts(path: literal))); }", writes: writes, create: callback)
        let items = await writes.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.contents, Data("x".utf8))
    }

    func testCombiningMarkDoesNotHideLeadingDotFromCPathValidation() async throws {
        let path = try JSONValue.string(".\u{0301}hidden").jsonString()
        let writes = Writes()
        _ = try await run("""
        async () => {
          for (let i = 0; i < 64; i++) {
            try { await \(call(opts(path: path))); } catch (e) {}
          }
          await \(call(opts(path: "'visible.txt'")));
        }
        """, writes: writes)
        // A Swift-only rejection would consume all 64 submitted-host attempts. The valid final write proves
        // the leading-dot path was rejected by C before reaching its callback or consuming the write budget.
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["visible.txt"])
    }

    func testStructurallyInvalidPathsRejectWithoutCallback() async throws {
        let long = String(repeating: "a", count: 256)
        let deep = (0 ... 8).map { "d\($0)" }.joined(separator: "/")
        let paths = [
            "''", "'/abs'", "'/'", "'a//b'", "'a/'", "'a/b/'", "'.'", "'..'", "'a/./b'", "'a/../b'", "'../a'", "'.hidden'", "'a/.hidden'",
            "'a\\\\b'", "'a:b'", "'C:/x'", "'a\\u0000b'", "'a\\nb'", "'a\\tb'", "'a\\u007fb'", "'a\\u0085b'", "'a\\u009fb'", "'\\ud800'", "'x\\udc00'",
            "'\(long)'", "'ok/\(long)'", "'\(deep)'", "42", "null", "undefined", "{}", "['a']", "new String('a')",
        ]
        for path in paths {
            try await assertRejectsWithoutCallback(call(opts(path: path)))
        }
    }

    func testPathLimitsAreInclusiveUTF8ByteBounds() async throws {
        let component255 = String(repeating: "a", count: 255)
        let wide = String(repeating: "あ", count: 85) // 255 bytes
        let deep8 = (0 ..< 8).map { "d\($0)" }.joined(separator: "/")
        let max1024 = [component255, component255, component255, String(repeating: "c", count: 254), "d"].joined(separator: "/")
        XCTAssertEqual(max1024.utf8.count, 1024)
        let writes = Writes()
        _ = try await run("""
        async () => {
          for (const p of ['\(component255)', '\(wide)', '\(deep8)', '\(max1024)', 'a.b/c d/é.txt', 'ends.', 'Salmon Run/history.json', 'emoji😀/x']) {
            await \(call(opts(path: "p")));
          }
        }
        """, writes: writes)
        let paths = await writes.items.map(\.path)
        XCTAssertEqual(paths, [component255, wide, deep8, max1024, "a.b/c d/é.txt", "ends.", "Salmon Run/history.json", "emoji😀/x"])
        try await assertRejectsWithoutCallback(call(opts(path: "'\(max1024)x'")))
        try await assertRejectsWithoutCallback(call(opts(path: "'\(String(repeating: "あ", count: 86))'")))
    }

    func testPathSpellingIsDeliveredVerbatimWithoutNormalizationOrCaseFolding() async throws {
        // C only validates structure; Core owns NFC and case aliases (it rejects non-NFC, which this callback sees as `try?` failure).
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'Äb/ÄB.TXT'"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["Äb/ÄB.TXT"])
        let decomposed = Writes()
        _ = try await run("async () => { try { await \(call(opts(path: "'e\\u0301.txt'"))); } catch (e) { return; } throw new Error('non-NFC accepted'); }", writes: decomposed)
        let none = await decomposed.items.count
        XCTAssertEqual(none, 0, "non-NFC spellings are refused by Core's destination validation, never rewritten")
    }

    // MARK: permission

    func testDeniedOrAbsentFilesPermissionRejectsWithoutCallback() async throws {
        for files in [false, nil] as [Bool?] {
            try await assertRejectsWithoutCallback(call(opts()), files: files)
            let writes = Writes()
            await expectError(.scriptError, "async () => { await \(call(opts())); }", files: files, writes: writes)
            let n = await writes.items.count
            XCTAssertEqual(n, 0)
        }
    }

    func testMissingCreateCallbackRejectsEvenWithPermission() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave:async () => { try { await \(call(opts())); } catch (e) { return; } throw new Error('accepted'); }}});")
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    // MARK: per-invocation budgets

    func testWriteCountCapIs64() async throws {
        let writes = Writes()
        _ = try await run("async () => { let rejected = 0; for (let i = 0; i < 65; i++) { try { await \(call(opts(path: "'k' + i"))); } catch (e) { rejected++; } } if (rejected !== 1) throw new Error('r' + rejected); }", writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 64)
    }

    func testEmptyFilesCountTowardTheWriteCount() async throws {
        let writes = Writes()
        _ = try await run("async () => { let rejected = 0; for (let i = 0; i < 65; i++) { try { await \(call(opts(path: "'e' + i", contents: "new Uint8Array(0)"))); } catch (e) { rejected++; } } if (rejected !== 1) throw new Error('r' + rejected); }", writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 64)
    }

    func testSubmittedBytesCapIs16MiBAcrossTextAndBinary() async throws {
        let writes = Writes()
        // 16 files of exactly 1 MiB are accepted (mixed text/binary); the 17th is rejected and never reaches the host.
        _ = try await run("""
        async () => {
          const text = 'a'.repeat(\(Self.oneMiB));
          const bin = new Uint8Array(\(Self.oneMiB));
          let rejected = 0;
          for (let i = 0; i < 17; i++) {
            try { await \(call(opts(path: "'k' + i", contents: "i % 2 ? bin : text"))); } catch (e) { rejected++; }
          }
          if (rejected !== 1) throw new Error('r' + rejected);
        }
        """, writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 16)
    }

    func testTextSizeLimitIsOneMiBOfUTF8BytesNotCharacters() async throws {
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'ok'", contents: "'a'.repeat(\(Self.oneMiB))"))); }", writes: writes)
        let ok = await writes.items
        XCTAssertEqual(ok.first?.contents.count, Self.oneMiB)
        try await assertRejectsWithoutCallback(call(opts(contents: "'a'.repeat(\(Self.oneMiB + 1))")))
        // 349_526 three-byte scalars = 1_048_578 bytes > 1 MiB although only 349_526 UTF-16 units.
        try await assertRejectsWithoutCallback(call(opts(contents: "'あ'.repeat(349526)")))
        let fits = Writes()
        _ = try await run("async () => { await \(call(opts(path: "'wide'", contents: "'あ'.repeat(349525)"))); }", writes: fits)
        let wide = await fits.items
        XCTAssertEqual(wide.first?.contents.count, 349_525 * 3)
    }

    func testTextRejectsLoneSurrogatesButKeepsPairs() async throws {
        for contents in ["'\\ud800'", "'a\\udc00'", "'\\ud83d'", "'\\ude00\\ud83d'", "'x\\ud800y'"] {
            try await assertRejectsWithoutCallback(call(opts(contents: contents)))
        }
        let writes = Writes()
        _ = try await run("async () => { await \(call(opts(contents: "'\\ud83d\\ude00'"))); }", writes: writes)
        let items = await writes.items
        XCTAssertEqual(items.first?.contents, Data("😀".utf8))
    }

    func testRejectedAttemptsDoNotConsumeWriteBudget() async throws {
        let writes = Writes()
        _ = try await run("async () => { for (let i = 0; i < 100; i++) { try { await \(call(opts(path: "''"))); } catch (e) {} } for (let i = 0; i < 64; i++) await \(call(opts(path: "'k' + i"))); }", writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 64)
    }

    func testHostFailedAttemptsStillConsumeBothBudgets() async throws {
        let attempts = Writes()
        _ = try await run("async () => { let failed = 0; for (let i = 0; i < 64; i++) { try { await \(call(opts(path: "'k' + i"))); } catch (e) { failed++; } } if (failed !== 64) throw new Error('f' + failed); try { await \(call(opts(path: "'extra'"))); } catch (e) { return; } throw new Error('65th reached host'); }", writes: attempts, create: { d, c in
            await attempts.add(d, c)
            throw WriteFailure()
        })
        let n = await attempts.items.count
        XCTAssertEqual(n, 64, "failed host attempts count against the 64-write budget")

        let bytes = Writes()
        _ = try await run("""
        async () => {
          const t = 'a'.repeat(\(Self.oneMiB));
          let failed = 0, refused = 0;
          for (let i = 0; i < 17; i++) {
            try { await \(call(opts(path: "'k' + i", contents: "t"))); } catch (e) { if (i < 16) failed++; else refused++; }
          }
          if (failed !== 16 || refused !== 1) throw new Error(failed + '/' + refused);
        }
        """, writes: bytes, create: { d, c in
            await bytes.add(d, c)
            throw WriteFailure()
        })
        let reached = await bytes.items.count
        XCTAssertEqual(reached, 16, "failed host attempts count against the 16 MiB budget")
    }

    func testFetchAndWriteBudgetsAreSeparate() async throws {
        let writes = Writes()
        let fetches = Writes()
        _ = try await run("async () => { for (let i = 0; i < 64; i++) { await fetch('\(url)'); } for (let i = 0; i < 64; i++) await \(call(opts(path: "'k' + i"))); try { await fetch('\(url)'); } catch (e) { try { await \(call(opts(path: "'x'"))); } catch (f) { return; } } throw new Error('caps'); }", writes: writes, transport: { req in
            await fetches.add(try PluginFileDestination(storage: .local, atPath: "fetch"), Data(req.url.utf8))
            return JavaScriptFetchResponse(status: 200, body: Data())
        })
        let s = await writes.items.count, f = await fetches.items.count
        XCTAssertEqual(s, 64)
        XCTAssertEqual(f, 64)
    }

    // MARK: errors and cancellation

    func testHostFailureRejectsCatchablyAndLaterWritesProceed() async throws {
        let writes = Writes()
        _ = try await run("async () => { try { await \(call(opts(path: "'bad'"))); } catch (e) { await \(call(opts(path: "'good'"))); return; } throw new Error('not rejected'); }", create: { d, c in
            if d.atPath == "bad" { throw WriteFailure() }
            await writes.add(d, c)
        })
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["good"])
    }

    func testRejectionDoesNotLeakHostErrorDetail() async throws {
        struct Secret: Error, CustomStringConvertible { var description: String { "/private/var/secret/path" } }
        let actions = try await run("async () => { try { await \(call(opts())); } catch (e) { if (String(e && e.message).includes('secret') || String(e).includes('/private')) throw new Error('leaked'); return; } throw new Error('x'); }", create: { _, _ in throw Secret() })
        XCTAssertEqual(actions.count, 0)
    }

    func testUncaughtWriteFailureIsScriptErrorAndStopsTheHook() async {
        let writes = Writes()
        await expectError(.scriptError, "async () => { await \(call(opts(path: "'a'"))); await \(call(opts(path: "'b'"))); await \(call(opts(path: "'c'"))); }", writes: writes, create: { d, c in
            if d.atPath == "b" { throw WriteFailure() }
            await writes.add(d, c)
        })
        let paths = await writes.items.map(\.path)
        XCTAssertEqual(paths, ["a"])
    }

    func testCancelDuringWriteCancelsTaskAndThrowsCancelled() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let writes = Writes()
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { try { await \(self.call(self.opts())); } catch (e) {} await \(self.call(self.opts(path: "'after'"))); }", executor: executor, writes: writes, create: { _, _ in
                    started.fulfill()
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { await writes.markCancelled(); throw error }
                })
                return nil
            } catch { return error }
        }
        await fulfillment(of: [started], timeout: 5)
        executor.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let cancelled = await writes.cancelled
        XCTAssertEqual(cancelled, 1, "host callback task must be cancelled and awaited before runV2 returns")
        let after = await writes.items.count
        XCTAssertEqual(after, 0, "script must not continue after cancellation")
        executor.cancel()
        _ = try await run("() => {}", executor: executor)
    }

    func testTaskCancellationDuringWriteThrowsCancelled() async throws {
        let started = expectation(description: "started")
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { await \(self.call(self.opts())); }", create: { _, _ in
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
        let writes = Writes()
        let task = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try await self.run("async () => { await \(self.call(self.opts())); }", writes: writes); return nil } catch { return error }
        }
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let n = await writes.items.count
        XCTAssertEqual(n, 0)
    }

    func testCpuBudgetExcludesWriteWaitOnly() async throws {
        _ = try await run("async () => { await \(call(opts())); }", create: { _, _ in try await Task.sleep(nanoseconds: 600_000_000) })
        await expectError(.timeout, "async () => { await \(call(opts())); for (;;) {} }")
    }

    func testSameExecutorStaysSingleFlightDuringWrite() async throws {
        let executor = JavaScriptFetchExecutor()
        let started = expectation(description: "started")
        let first = Task { _ = try await self.run("async () => { await \(self.call(self.opts())); }", executor: executor, create: { _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 400_000_000)
        }) }
        await fulfillment(of: [started], timeout: 5)
        await expectError(.busy, "() => {}", executor: executor)
        _ = try await first.value
        _ = try await run("() => {}", executor: executor)
    }

    func testLateSuccessfulHostWriteAfterCallbackTimeoutRejectsAfterDrain() async throws {
        // The callback timeout is a stable 10 s (+250 ms grace). The host ignores cancellation and commits at ~10.4 s.
        let writes = Writes()
        let clock = ContinuousClock()
        let begin = clock.now
        let actions = try await run("async () => { try { await \(call(opts(path: "'late'", contents: "'{\"a\":1}'"))); } catch (e) { return; } throw new Error('late success reported as success'); }",
                                    writes: writes, create: { d, c in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 10.4) { cont.resume() }
            }
            await writes.add(d, c)
        })
        let elapsed = begin.duration(to: clock.now)
        XCTAssertEqual(actions.count, 0)
        let items = await writes.items
        XCTAssertEqual(items.map(\.path), ["late"], "committed write is retained and was drained before runV2 returned")
        XCTAssertEqual(items.first?.text, "{\"a\":1}")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(10_400))
    }

    // MARK: response JSON scanning (fetch, unrelated to createFile)

    /// ~1 MiB object whose 16384 distinct keys all share one FNV-1a 32-bit hash (Joux multicollision), so the native
    /// duplicate-key scan degrades to quadratic probing: valid JSON within every size/depth cap, yet far slower than
    /// the one-second batch CPU budget. Built from the public FNV-1a definition, independent of the C implementation.
    private static let collidingKeysDocument: String = {
        func step(_ h: UInt32, _ bytes: [UInt8]) -> UInt32 {
            bytes.reduce(h) { ($0 ^ UInt32($1)) &* 16777619 }
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var state: UInt32 = 2166136261
        var pairs: [([UInt8], [UInt8])] = []
        for _ in 0 ..< 14 {
            var seen: [UInt32: [UInt8]] = [:]
            var found: ([UInt8], [UInt8])?
            search: for a in alphabet { for b in alphabet { for c in alphabet { for d in alphabet {
                let block = [a, b, c, d]
                let h = step(state, block)
                if let other = seen[h] { found = (other, block); state = h; break search }
                seen[h] = block
            } } } }
            guard let f = found else { fatalError("no FNV collision block found") }
            pairs.append(f)
        }
        var keys: [[UInt8]] = [[]]
        for (x, y) in pairs { keys = keys.flatMap { [$0 + x, $0 + y] } }
        var json = "{"
        for (i, key) in keys.enumerated() {
            if i > 0 { json += "," }
            json += "\"" + String(decoding: key, as: UTF8.self) + "\":0"
        }
        return json + "}"
    }()

    func testCollidingKeysDocumentFixtureIsValidWithinLimits() {
        let doc = Self.collidingKeysDocument
        XCTAssertLessThanOrEqual(doc.utf8.count, Self.oneMiB)
        XCTAssertGreaterThan(doc.utf8.count, 900_000)
        XCTAssertNotNil(try? JSONValue(parsing: Data(doc.utf8)))
    }

    func testCreateFileNeverScansItsContents() async throws {
        // The same pathological document that makes a JSON scan exceed the CPU budget is written verbatim and promptly.
        let bytes = Data(Self.collidingKeysDocument.utf8)
        let writes = Writes()
        let clock = ContinuousClock()
        let begin = clock.now
        _ = try await run("async () => { const t = await (await fetch('\(url)')).text(); await \(call(opts(path: "'big'", contents: "t"))); }", writes: writes, transport: { _ in
            JavaScriptFetchResponse(status: 200, body: bytes)
        })
        let elapsed = begin.duration(to: clock.now)
        let items = await writes.items
        XCTAssertEqual(items.first?.contents, bytes)
        XCTAssertLessThan(elapsed, .milliseconds(900))
    }

    func testResponseJSONScannerStopsPromptlyOnCancel() async throws {
        let executor = JavaScriptFetchExecutor()
        let writes = Writes()
        let clock = ContinuousClock()
        let fetched = expectation(description: "fetched")
        let bytes = Data(Self.collidingKeysDocument.utf8)
        let task = Task { () -> Error? in
            do {
                _ = try await self.run("async () => { await (await fetch('\(self.url)')).json(); }",
                                       executor: executor, writes: writes, transport: { _ in
                    fetched.fulfill()
                    return JavaScriptFetchResponse(status: 200, body: bytes)
                })
                return nil
            } catch { return error }
        }
        await fulfillment(of: [fetched], timeout: 5)
        try await Task.sleep(nanoseconds: 60_000_000) // let the scan start
        let cancelAt = clock.now
        executor.cancel()
        let error = await task.value
        let after = cancelAt.duration(to: clock.now)
        XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled)
        let n = await writes.items.count
        XCTAssertEqual(n, 0)
        XCTAssertLessThan(after, .milliseconds(400), "cancel must interrupt the validation scan")
    }

    func testGrantAndCountAreCheckedBeforeExpensiveConversion() async throws {
        let clock = ContinuousClock()
        let big = "'a'.repeat(\(Self.oneMiB))"
        let denied = Writes()
        var begin = clock.now
        _ = try await run("async () => { try { await \(call(opts(contents: big))); } catch (e) { return; } throw new Error('accepted'); }", files: false, writes: denied)
        var elapsed = begin.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(400), "files not granted: reject before converting")
        var n = await denied.items.count
        XCTAssertEqual(n, 0)

        let capped = Writes()
        begin = clock.now
        _ = try await run("async () => { for (let i = 0; i < 64; i++) await \(call(opts(path: "'k' + i"))); try { await \(call(opts(contents: big))); } catch (e) { return; } throw new Error('accepted'); }", writes: capped)
        elapsed = begin.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(400), "write count exhausted: reject before converting")
        n = await capped.items.count
        XCTAssertEqual(n, 64)
    }

    // MARK: phase, probe and global shape

    func testOnlyResponseLeaveAcceptsFilesMode() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave(){}}});")
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .request, .response] {
            let writes = Writes()
            do {
                _ = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config,
                                                              createFile: { d, c in await writes.add(d, c) }) { _ in JavaScriptFetchResponse(status: 200, body: Data()) }
                XCTFail("accepted \(hook)")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput) }
            let n = await writes.items.count
            XCTAssertEqual(n, 0)
        }
    }

    func testCreateFileIsNotExposedOutsideDeferredLeaveRuntime() async throws {
        let src = "Interceptor.attach({request:{onEnter(){ if (typeof Interceptor.createFile !== 'undefined' || Interceptor.Storage.local !== 'local' || typeof createFile !== 'undefined') throw new Error('exposed'); }, onLeave(){}}, response:{onEnter(){ if (typeof Interceptor.createFile !== 'undefined' || Interceptor.Storage.iCloudDrive !== 'icloud') throw new Error('exposed'); }, onLeave(){}}});"
        let pkg = try package(src)
        for hook in [JavaScriptHook.requestEnter, .responseEnter] {
            _ = try await JavaScriptExecutor().runV2(packageJSON: pkg, hook: hook, eventJSON: event, configJSON: config)
        }
        let globalProbe = try package("Interceptor.attach({response:{onLeave:async () => { if (typeof createFile !== 'undefined' || typeof globalThis.createFile !== 'undefined' || typeof Storage !== 'undefined' || typeof saveJSON !== 'undefined') throw new Error('global'); }}});")
        _ = try await JavaScriptFetchExecutor().runV2(packageJSON: globalProbe, hook: .responseLeave, eventJSON: event, configJSON: config, createFile: { _, _ in XCTFail("no call") }) { _ in
            JavaScriptFetchResponse(status: 200, body: Data())
        }
    }

    func testSchedulingProbeDefersCreateFileWithoutAnyIO() async throws {
        let executor = JavaScriptExecutor()
        let invocation = call("{storage: Interceptor.Storage.local, atPath: 'k', contents: 'x'}")
        for callback in ["() => { \(invocation); }",
                         "() => { try { \(invocation); } catch(e) {} }",
                         "async () => { await \(invocation); }",
                         "() => { try { Interceptor.createFile(); } catch(e) {} }"]
        {
            for files in [true, false] as [Bool?] {
                let pkg = try package("Interceptor.attach({response:{onLeave:" + callback + "}});", files: files)
                do {
                    _ = try await executor.runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
                    XCTFail("expected a scheduling signal for \(callback)")
                } catch { XCTAssertTrue(error is JavaScriptAsyncRequired, "\(error)") }
            }
        }
        // A synchronous hook that never touches createFile still completes inline.
        let sync = try package("Interceptor.attach({response:{onLeave(){return {actions:[]};}}});")
        let output = try await executor.runV2(packageJSON: sync, hook: .responseLeave, eventJSON: event, configJSON: config, detectAsync: true)
        XCTAssertEqual(try JSONValue(parsing: output), .object(["actions": .array([])]))
    }

    func testTopLevelCreateFileIsStickyInvalid() async {
        let writes = Writes()
        await expectError(.scriptError, "() => {}", top: "try { \(call(opts())); } catch (e) {}\n", writes: writes)
        let n = await writes.items.count
        XCTAssertEqual(n, 0)
    }

    func testNeverSettlingPromiseAfterWriteIsScriptError() async {
        await expectError(.scriptError, "async () => { await \(call(opts())); await new Promise(() => {}); }")
    }

    // MARK: existing fetch compatibility

    func testFetchOnlyCallSitesStillWorkWithoutCreateCallback() async throws {
        let pkg = try package("Interceptor.attach({response:{onLeave:async () => { const r = await fetch('\(url)'); const j = await r.json(); if (j.a !== 1) throw new Error('x'); }}});", files: nil)
        let data = try await JavaScriptFetchExecutor().runV2(packageJSON: pkg, hook: .responseLeave, eventJSON: event, configJSON: config) { _ in
            JavaScriptFetchResponse(status: 200, body: Data("{\"a\":1}".utf8))
        }
        XCTAssertEqual(try JSONValue(parsing: data), .object(["actions": .array([])]))
    }

    func testFetchRequestShapeUnchangedWhenCreateCallbackIsPresent() async throws {
        let writes = Writes()
        let seen = FetchSeen()
        _ = try await run("async () => { await fetch('\(url)'); }", writes: writes, transport: { req in
            await seen.add(req)
            return JavaScriptFetchResponse(status: 200, body: Data())
        })
        let reqs = await seen.items
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs.first?.method, "GET")
        XCTAssertEqual(reqs.first?.maxResponseBytes, Self.oneMiB)
        XCTAssertLessThanOrEqual(reqs.first?.timeoutMilliseconds ?? .max, 5000)
        let n = await writes.items.count
        XCTAssertEqual(n, 0)
    }

    private actor FetchSeen {
        var items: [JavaScriptFetchRequest] = []
        func add(_ r: JavaScriptFetchRequest) { items.append(r) }
    }
}
