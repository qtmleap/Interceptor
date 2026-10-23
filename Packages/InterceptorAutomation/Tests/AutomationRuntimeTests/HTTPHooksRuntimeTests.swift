import XCTest
import AutomationCore
@testable import AutomationRuntime

/// Four dotted HTTP lifecycle phases through the real shared C runtime (`qjs_run_v2`).
final class HTTPHooksRuntimeTests: XCTestCase, @unchecked Sendable {
    private let endpoint = "11111111-1111-1111-1111-111111111111"
    private let match = #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js","onLeave":"hooks/api.example.com/search/POST.js"},"response":{"onEnter":"hooks/api.example.com/search/POST.js","onLeave":"hooks/api.example.com/search/POST.js"}}}"#
    private let file = "hooks/api.example.com/search/POST.js"
    private let config = Data(#"{"limit":5}"#.utf8)

    private let manifestID = "22222222-2222-4222-8222-222222222222"

    /// Full strict schemaVersion 2 manifest (same shape as the SDK/CLI samples).
    private func manifest(matches: String? = nil, requestWrite: Bool = true, responseWrite: Bool = true,
                          metadata: String = #"["method","host","path","status"]"#, headers: String = #"["X-A"]"#,
                          queryKeys: String = #"["q"]"#, bodyMode: String = "json", extra: String = "") -> Data {
        Data(#"{"schemaVersion":2,"id":"\#(manifestID)","name":"Sample","version":"1.0.0","matches":[\#(matches ?? match)],"read":{"metadata":\#(metadata),"headers":\#(headers),"queryKeys":\#(queryKeys),"body":{"mode":"\#(bodyMode)"}},"write":{"requestBody":\#(requestWrite),"responseBody":\#(responseWrite)},"endpointBindings":[],"settings":{"limit":5}\#(extra)}"#.utf8)
    }

    /// Public envelope: no identity field; matching data is the unfiltered request/response.
    private func event(host: String = "api.example.com", method: String = "POST", path: String = "/search", status: Int = 200,
                       requestBody: String? = #"{"limit":10,"q":"x"}"#, responseBody: String? = #"{"ok":true}"#,
                       envelope: String = "") -> Data {
        let rb = requestBody.map { #","body":\#($0)"# } ?? ""
        let sb = responseBody.map { #","body":\#($0)"# } ?? ""
        return Data(#"{\#(envelope)"request":{"method":"\#(method)","host":"\#(host)","path":"\#(path)","headers":{"x-a":"1","Authorization":"secret","X-Other":"o"},"query":{"q":"1","token":"t"}\#(rb)},"response":{"status":\#(status),"headers":{"X-A":"r","Set-Cookie":"c"}\#(sb)}}"#.utf8)
    }

    private func run(_ source: String, _ hook: JavaScriptHook, event: Data? = nil, manifest: Data? = nil,
                     executor: JavaScriptExecutor = JavaScriptExecutor()) async throws -> [String: Any] {
        let code = try JSONValue.string(source).jsonString()
        let manifestText = String(decoding: manifest ?? self.manifest(), as: UTF8.self)
        let packageText = "{\"manifest\":\(manifestText),\"sourceFiles\":{\"\(file)\":\(code)}}"
        let package = Data(packageText.utf8)
        let data = try await executor.runV2(packageJSON: package, hook: hook, eventJSON: event ?? self.event(), configJSON: config)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ source: String, _ hook: JavaScriptHook = .requestEnter,
                             event: Data? = nil, manifest: Data? = nil, line: UInt = #line) async {
        do {
            let r = try await run(source, hook, event: event, manifest: manifest)
            XCTFail("expected \(expected), got \(r)", line: line)
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    private func attach(_ request: String = "", _ response: String = "") -> String {
        func complete(_ handlers: String) -> String {
            var all = handlers
            for phase in ["onEnter", "onLeave"] where !handlers.contains(phase) {
                if !all.isEmpty { all += "," }
                all += phase + "(){}"
            }
            return all
        }
        return "Interceptor.attach({request:{\(complete(request))},response:{\(complete(response))}});"
    }

    private func marker(_ name: String) -> String { "{actions:[{type:'webhook',endpointId:'\(endpoint)',json:{ran:'\(name)'}}]}" }

    // MARK: API shape

    func testPhaseRawValuesAreTheFourDottedNames() {
        XCTAssertEqual(JavaScriptHook.requestEnter.rawValue, "request.onEnter")
        XCTAssertEqual(JavaScriptHook.requestLeave.rawValue, "request.onLeave")
        XCTAssertEqual(JavaScriptHook.responseEnter.rawValue, "response.onEnter")
        XCTAssertEqual(JavaScriptHook.responseLeave.rawValue, "response.onLeave")
        XCTAssertEqual(JavaScriptHook.allCases.count, 6)
    }

    func testLegacyAndV2EntryPointsDoNotCross() async throws {
        let executor = JavaScriptExecutor()
        let legacy = try await executor.run(source: "function onRequest(e,c){return {actions:[]};}", hook: .request,
                                            eventJSON: Data(#"{"a":1}"#.utf8), configJSON: config)
        XCTAssertEqual(String(decoding: legacy, as: UTF8.self), #"{"actions":[]}"#)
        do {
            _ = try await executor.run(source: "function onRequest(e,c){return {actions:[]};}", hook: .requestEnter,
                                       eventJSON: Data(#"{"a":1}"#.utf8), configJSON: config)
            XCTFail("legacy run must reject dotted phases")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput) }
        await expectError(.invalidInput, attach("onEnter(){}"), .request)
    }

    // MARK: callback arguments and phases

    func testEnterCallbackReceivesOwnLegThenConfigWithoutHostIdentity() async throws {
        let src = attach("onEnter(request, config) { return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{limit:config.limit,method:request.method,hasIdentity:'identity' in request,hasResponse:'response' in request,body:request.body.q}}]}; }")
        let r = try await run(src, .requestEnter)
        let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
        XCTAssertEqual(json["limit"] as? Int, 5)
        XCTAssertEqual(json["method"] as? String, "POST")
        XCTAssertEqual(json["hasIdentity"] as? Bool, false)
        XCTAssertEqual(json["hasResponse"] as? Bool, false)
        XCTAssertEqual(json["body"] as? String, "x")
    }

    func testResponseCallbackReceivesResponseWithRequestIdentity() async throws {
        let src = attach("", "onEnter(response, config) { return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{status:response.status,reqMethod:response.request.method,same:response.request===response.request,ok:response.body.ok}}]}; }")
        let r = try await run(src, .responseEnter)
        let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
        XCTAssertEqual(json["status"] as? Int, 200)
        XCTAssertEqual(json["reqMethod"] as? String, "POST")
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testOnlyTheInvokedPhaseCallbackRuns() async throws {
        let src = attach("onEnter(){return \(marker("reqEnter"));}, onLeave(){return \(marker("reqLeave"));}",
                         "onEnter(){return \(marker("resEnter"));}, onLeave(){return \(marker("resLeave"));}")
        for (hook, name) in [(JavaScriptHook.requestEnter, "reqEnter"), (.requestLeave, "reqLeave"), (.responseEnter, "resEnter"), (.responseLeave, "resLeave")] {
            let r = try await run(src, hook)
            let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
            XCTAssertEqual(json["ran"] as? String, name)
            XCTAssertEqual((r["actions"] as? [Any])?.count, 1)
        }
    }

    func testMissingOptionalCallbackAndUndefinedReturnYieldEmptyActions() async throws {
        var r = try await run(attach("onEnter(){}"), .requestEnter)
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        XCTAssertNil(r["mutation"])
        r = try await run(attach("onEnter(){}"), .requestLeave)
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
    }

    // MARK: matching precedes callbacks

    func testNonMatchingTrafficNeverInvokesCallbacks() async throws {
        let src = attach("onEnter(){ throw new Error('must not run'); }")
        for ev in [event(host: "other.example.com"),
                   event(method: "GET"),
                   event(path: "/search/x")] {
            let r = try await run(src, .requestEnter, event: ev)
            XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        }
    }

    func testPrefixStatusAndMultipleHostMethodSelectorsAreRejected() async {
        for route in [
            #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"prefix","value":"/search"},"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js"}}}"#,
            #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"status":{"min":200,"max":299},"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js"}}}"#,
            #"{"hosts":["api.example.com","b.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js"}}}"#,
            #"{"hosts":["api.example.com"],"methods":["POST","GET"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js"}}}"#
        ] { await expectError(.invalidInput, attach("onEnter(){}"), manifest: manifest(matches: route)) }
    }

    func testTwoArgumentAttachIsRejectedBeforeAnyCallback() async {
        let src = attach("onEnter(){ return \(marker("a")); }") + "Interceptor.attach({hosts:['evil.example.com']},{request:{onEnter(){}}});"
        await expectError(.scriptError, src)
    }

    func testSwallowedAttachFailureStillFailsExecution() async {
        let src = "try { Interceptor.attach({},{}); } catch (e) {}" + attach("onEnter(){}")
        await expectError(.scriptError, src)
    }

    func testSwallowedLateAttachFailureDiscardsMutationAndActions() async {
        await expectError(.scriptError, attach("onEnter(r){r.body.limit=1;try{Interceptor.attach({});}catch(e){}return \(marker("late"));}"))
    }

    func testSameMatchMayBeReusedAndMaxSixteenRegistrations() async throws {
        let sixteen = String(repeating: attach("onEnter(){}"), count: 16)
        let r = try await run(sixteen, .requestEnter)
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        await expectError(.scriptError, sixteen + attach("onEnter(){}"))
    }

    func testMalformedAttachArgumentsFail() async {
        for bad in ["Interceptor.attach()", "Interceptor.attach(null)", "Interceptor.attach({}, {})",
                    "Interceptor.attach({request:{onEnter:1}})", "Interceptor.attach({request:{onFoo(){}}})",
                    "Interceptor.attach({other:{}})", "Interceptor.attach({request:null})",
                    "Interceptor.attach({get request(){throw new Error('getter');}})",
                    "Interceptor.attach(new Proxy({request:{onEnter(){}}},{ownKeys(){while(true){}}}))",
                    "Interceptor.attach({request:{get onEnter(){while(true){}}}})"] {
            await expectError(.scriptError, bad)
        }
    }

    // MARK: body mutation

    func testEnterBodyMutationIsReturnedAsMutationBody() async throws {
        let src = attach("onEnter(request, config) { request.body.limit = config.limit; request.body.added = [1,'two',{three:null}]; }")
        let r = try await run(src, .requestEnter)
        let body = try XCTUnwrap((r["mutation"] as? [String: Any])?["body"] as? [String: Any])
        XCTAssertEqual(body["limit"] as? Int, 5)
        XCTAssertEqual(body["q"] as? String, "x")
        XCTAssertEqual((body["added"] as? [Any])?.count, 3)
        XCTAssertEqual(Set(r.keys), ["actions", "mutation"])
        XCTAssertEqual(Set(((r["mutation"] as? [String: Any]) ?? [:]).keys), ["body"])
    }

    func testResponseEnterBodyMutationUsesResponseWriteGrant() async throws {
        let src = attach("", "onEnter(response) { response.body.maintenance = true; }")
        let r = try await run(src, .responseEnter)
        let body = try XCTUnwrap((r["mutation"] as? [String: Any])?["body"] as? [String: Any])
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["maintenance"] as? Bool, true)
        XCTAssertEqual(body.count, 2)
        // Without the response grant the body is read-only: the edit is rejected, not silently dropped.
        await expectError(.scriptError, src, .responseEnter, manifest: manifest(responseWrite: false))
        // The request-body grant never authorizes the response body.
        await expectError(.scriptError, src, .responseEnter, manifest: manifest(requestWrite: true, responseWrite: false))
    }

    func testRequestWriteGrantIsRequiredForRequestMutation() async throws {
        let src = attach("onEnter(request) { request.body.limit = 1; }")
        await expectError(.scriptError, src, manifest: manifest(requestWrite: false))
        // Reading remains possible and yields no mutation.
        let r = try await run(attach("onEnter(request) { return \(marker("read")); }"), .requestEnter, manifest: manifest(requestWrite: false))
        XCTAssertNil(r["mutation"])
        XCTAssertEqual((r["actions"] as? [Any])?.count, 1)
        for edit in ["request.body = {}", "delete request.body.q", "request.body.nested = 1", "Object.defineProperty(request.body,'q',{value:1})",
                     "Object.assign(request.body,{a:1})", "request.body.q = 'y'"] {
            await expectError(.scriptError, attach("onEnter(request) { \(edit); }"), manifest: manifest(requestWrite: false), line: #line)
        }
    }

    func testLeavePhasesAreReadOnlyAndRejectEdits() async throws {
        for hook in [JavaScriptHook.requestLeave, .responseLeave] {
            let leg = hook == .requestLeave ? "request" : "response"
            let edits = ["\(leg).body.limit = 99", "\(leg).body.ok = false", "delete \(leg).body.\(leg == "request" ? "q" : "ok")", "\(leg).body = {}", "\(leg).body.added = 1",
                         "Object.defineProperty(\(leg).body,'k',{value:1})", "\(leg).headers['x-a'] = 'z'", "\(leg).headers.n = '1'",
                         "delete \(leg).headers['x-a']", "\(leg).headers = {}", "Object.freeze(\(leg)); \(leg).extra = 1",
                         "Object.setPrototypeOf(\(leg).body, null)"]
            for edit in edits {
                let src = leg == "request" ? attach("onLeave(request) { \(edit); }") : attach("", "onLeave(response) { \(edit); }")
                // Not every edit mentions an existing key, but each must throw (read-only or non-extensible).
                do {
                    let r = try await run(src, hook)
                    XCTFail("\(hook.rawValue): `\(edit)` was accepted: \(r)")
                } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError, "\(hook.rawValue): \(edit)") }
            }
            // Pure reads (and returning input as action JSON) still work and never yield mutation.
            let read = attach("onLeave(r){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{b:r.body}}]}; }",
                              "onLeave(r){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{b:r.body,q:r.request.body}}]}; }")
            let r = try await run(read, hook)
            XCTAssertNil(r["mutation"], hook.rawValue)
            XCTAssertEqual((r["actions"] as? [Any])?.count, 1)
        }
    }

    func testResponseRequestAndMetadataAreReadOnlyInEveryPhase() async throws {
        for hook in [JavaScriptHook.responseEnter, .responseLeave] {
            let phase = hook == .responseEnter ? "onEnter" : "onLeave"
            for edit in ["response.request.method = 'GET'", "response.request.body.limit = 1", "response.request.headers['x-a'] = 'z'",
                         "response.request.query.q = '2'", "delete response.request.body", "response.request = null",
                         "response.status = 500", "response.headers['x-a'] = 'z'", "response.request.extra = 1",
                         "Object.defineProperty(response.request, 'path', {value: '/x'})", "response.request.body.q += 'y'"] {
                do {
                    let r = try await run(attach("", "\(phase)(response) { \(edit); }"), hook)
                    XCTFail("\(hook.rawValue): `\(edit)` accepted: \(r)")
                } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError, "\(hook.rawValue): \(edit)") }
            }
        }
    }

    func testEnterMetadataHeaderQueryAndConfigEditsAreRejectedWhileBodyStaysWritable() async throws {
        for edit in ["request.method = 'GET'", "request.host = 'x'", "request.path = '/y'", "request.headers['x-a'] = '2'", "request.headers.n = '2'",
                     "delete request.headers['x-a']", "request.query.q = '2'", "request.query.n = '2'", "request.extra = 1", "config.limit = 9",
                     "config.n = 1", "delete config.limit", "Object.defineProperty(request, 'method', {value: 'GET'})",
                     "Object.defineProperty(request.headers, 'x-a', {value: '2'})", "Object.setPrototypeOf(request, null)"] {
            do {
                let r = try await run(attach("onEnter(request, config) { \(edit); }"), .requestEnter)
                XCTFail("`\(edit)` accepted: \(r)")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError, edit) }
        }
        let ok = try await run(attach("onEnter(request) { request.body.limit = 1; delete request.body.q; request.body.list = [1,2]; request.body.list.push(3); }"), .requestEnter)
        let body = try XCTUnwrap((ok["mutation"] as? [String: Any])?["body"] as? [String: Any])
        XCTAssertEqual(body["limit"] as? Int, 1)
        XCTAssertNil(body["q"])
        XCTAssertEqual((body["list"] as? [Int]), [1, 2, 3])
    }

    func testFrozenInputsStillSerializeAsPlainJSONInActions() async throws {
        let json = try await probe("{req:r,cfg:{...r}}", .requestEnter, manifest: manifest(requestWrite: false))
        XCTAssertEqual((json["req"] as? [String: Any])?["method"] as? String, "POST")
        XCTAssertEqual(((json["req"] as? [String: Any])?["body"] as? [String: Any])?["limit"] as? Int, 10)
        let resp = try await probe("{r:r}", .responseEnter)
        XCTAssertEqual(((resp["r"] as? [String: Any])?["request"] as? [String: Any])?["method"] as? String, "POST")
    }

    func testUnchangedTreeProducesNoMutationEvenWhenReassigned() async throws {
        let src = attach("onEnter(request) { const b = request.body; request.body = {limit: b.limit, q: b.q}; b.limit = b.limit; }")
        let r = try await run(src, .requestEnter)
        XCTAssertNil(r["mutation"])
        // Representation differences that do not change the JSON tree (key order, number spelling) are not mutations.
        let ev = event(requestBody: #"{"q":"x","limit":1.0e1}"#)
        let r2 = try await run(attach("onEnter(request) { request.body.limit = 10; }"), .requestEnter, event: ev)
        XCTAssertNil(r2["mutation"])
    }

    func testDeepUnchangedBodyBeyondResultDepthIsNotAnError() async throws {
        let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        let r = try await run(attach("onEnter(){}"), .requestEnter, event: event(requestBody: deep))
        XCTAssertNil(r["mutation"])
    }

    func testMutationOfAbsentOrNonDataBodyFailsClosed() async {
        // The leg is non-extensible, so a body can never be added where none was granted/sent.
        await expectError(.scriptError, attach("onEnter(request) { request.body = {a:1}; }"), event: event(requestBody: nil))
        await expectError(.invalidResult, attach("onEnter(request) { delete request.body; }"))
        await expectError(.invalidResult, attach("onEnter(request) { Object.defineProperty(request,'body',{get(){return {};}}); }"))
    }

    func testInvalidMutatedBodiesFailClosed() async {
        for body in ["undefined", "() => 1", "Symbol('s')", "1n", "new Date(0)", "new Proxy({}, {})", "Promise.resolve(1)",
                     "(function(){ const o = {}; o.self = o; return o; })()", "{get x(){return 1;}}", "{[Symbol('k')]: 1}",
                     "NaN", "Infinity", "'\\ud800'", "new Map()", "new String('x')"] {
            await expectError(.invalidResult, attach("onEnter(request) { request.body = \(body); }"))
        }
    }

    func testMutatedBodyOverResultLimitFailsClosed() async {
        await expectError(.invalidResult, attach("onEnter(request) { request.body = {a: 'x'.repeat(40000)}; }"))
    }

    func testNonBodyChangesDoNotCreateMutation() async throws {
        for edit in ["request.method = 'GET'", "request.headers['x-b'] = '2'", "request.url = 'https://evil.example/'"] {
            await expectError(.scriptError, attach("onEnter(request) { \(edit); }"))
        }
    }

    // MARK: result validation

    func testExtrasFromCallbacksFailClosed() async {
        for ret in ["{actions:[],mutation:{body:{}}}", "{actions:[],headers:{a:'b'}}", "{actions:[],status:204}", "{mutation:{body:{}}}",
                    "{actions:[],mutation:{headers:{}}}", "{}", "[]", "1", "'s'", "Promise.resolve({actions:[]})", "new Proxy({actions:[]},{})",
                    "{get actions(){return [];}}", "{actions:[{type:'webhook',endpointId:'bad',json:{}}]}",
                    "{actions:[{type:'other',endpointId:'\(endpoint)',json:{}}]}", "{actions:new Proxy([],{})}", "{actions:[],[Symbol('x')]:1}",
                    "{actions:[{type:'webhook',endpointId:'\(endpoint)',json:undefined}]}"] {
            await expectError(.invalidResult, attach("onEnter() { return \(ret); }"))
        }
    }

    func testActionsAreBoundedAcrossAllCallbacksOfAPhase() async throws {
        let one = "{actions:[{type:'webhook',endpointId:'\(endpoint)',json:{n:1}}]}"
        let two = attach("onEnter(){return \(one);}") + attach("onEnter(){return \(one);}")
        let r = try await run(two, .requestEnter)
        XCTAssertEqual((r["actions"] as? [Any])?.count, 2)
        await expectError(.invalidResult, two + attach("onEnter(){return \(one);}"))
        await expectError(.invalidResult, attach("onEnter(){return {actions:[\(one.dropFirst(10).dropLast(2)),\(one.dropFirst(10).dropLast(2)),\(one.dropFirst(10).dropLast(2))]};}"))
    }

    func testCallbacksRunInRegistrationOrderAndShareTheBodyTree() async throws {
        let src = attach("onEnter(r){ r.body.order = 'a'; }") + attach("onEnter(r){ r.body.order += 'b'; }")
        let r = try await run(src, .requestEnter)
        XCTAssertEqual(((r["mutation"] as? [String: Any])?["body"] as? [String: Any])?["order"] as? String, "ab")
    }

    // MARK: isolation

    func testEachPhaseUsesAFreshVMWithNoMutableState() async throws {
        let src = "var counter = (typeof counter === 'undefined' ? 0 : counter) + 1; globalThis.leak = (globalThis.leak || 0) + 1;"
            + attach("onEnter(){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{counter:counter,leak:leak}}]}; }")
        let executor = JavaScriptExecutor()
        for _ in 0..<3 {
            let r = try await run(src, .requestEnter, executor: executor)
            let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
            XCTAssertEqual(json["counter"] as? Int, 1)
            XCTAssertEqual(json["leak"] as? Int, 1)
        }
    }

    func testNoNativeNetworkFilesystemOrCredentialAPIsAreExposed() async throws {
        let names = ["require", "process", "fetch", "XMLHttpRequest", "WebSocket", "setTimeout", "setInterval", "std", "os", "console",
                     "print", "scriptArgs", "importScripts", "Deno", "Bun", "navigator", "localStorage", "Worker", "SharedArrayBuffer", "Atomics"]
        let probes = names.map { "'\($0)':typeof \($0)" }.joined(separator: ",")
        let src = attach("onEnter(){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{\(probes),keys:Object.keys(Interceptor).join(',')}}]}; }")
        let r = try await run(src, .requestEnter)
        let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
        for name in names { XCTAssertEqual(json[name] as? String, "undefined", name) }
        XCTAssertEqual(json["keys"] as? String, "attach,send,Storage")
    }

    func testHostCapturedIntrinsicsSurviveUserTampering() async throws {
        let tamper = """
        Object.defineProperty(Object.prototype, 'hosts', {set(v){ throw new Error('setter'); }, get(){ return ['evil.example.com']; }, configurable: true});
        Object.defineProperty(Object.prototype, 'status', {value: 999, configurable: true, writable: true});
        Array.prototype.push = function(){ throw new Error('push'); };
        Array.prototype.indexOf = function(){ return 0; };
        Object.defineProperty(Array.prototype, 0, {set(v){ throw new Error('index'); }, configurable: true});
        Object.defineProperty(Object.prototype, 'value', {get(){ return 'evil'; }, configurable: true});
        Object.keys = function(){ return []; };
        Object.getOwnPropertyDescriptor = function(){ return undefined; };
        Reflect.ownKeys = function(){ return []; };
        Function.prototype.call = function(){ throw new Error('call'); };
        Function.prototype.bind = function(){ throw new Error('bind'); };
        JSON.stringify = function(){ return '"x"'; };
        String.prototype.startsWith = function(){ return true; };
        Array.isArray = function(){ return false; };
        """
        let src = tamper + attach("onEnter(request){ request.body.t = 1; }")
        let r = try await run(src, .requestEnter)
        let body = try XCTUnwrap((r["mutation"] as? [String: Any])?["body"] as? [String: Any])
        XCTAssertEqual(body["limit"] as? Int, 10)
        XCTAssertEqual(body["q"] as? String, "x")
        XCTAssertEqual(body["t"] as? Int, 1)
        XCTAssertEqual(body.count, 3)
        // Tampering must not make non-matching traffic match either.
        let miss = try await run(tamper + attach("onEnter(){ throw new Error('no'); }"), .requestEnter, event: event(host: "other.example.com"))
        XCTAssertEqual((miss["actions"] as? [Any])?.count, 0)
    }

    func testCallbackCannotWidenAccessToUnreadData() async throws {
        // The callback only holds the granted view; the unfiltered envelope is not reachable.
        let probe = "onEnter(request) { return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{keys:Object.keys(request).join(','),proto:Object.getPrototypeOf(request)===Object.prototype}}]}; }"
        let r = try await run(attach(probe), .requestEnter)
        let json = try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
        XCTAssertEqual(json["keys"] as? String, "method,host,path,headers,query,body")
    }

    // MARK: bounds

    func testManifestAndEventBoundsAreEnforced() async {
        await expectError(.invalidInput, attach("onEnter(){}"), manifest: Data(repeating: 0x20, count: 32 * 1024 + 1))
        await expectError(.invalidInput, attach("onEnter(){}"), manifest: Data())
        await expectError(.invalidInput, attach("onEnter(){}"), manifest: Data("[]".utf8))
        await expectError(.invalidInput, attach("onEnter(){}"), manifest: manifest(matches: ""))
        await expectError(.invalidInput, attach("onEnter(){}"), event: Data("{}".utf8))
        await expectError(.invalidInput, attach("onEnter(){}"), event: Data(#"{"response":{"status":200}}"#.utf8))
        await expectError(.invalidInput, attach("", "onEnter(){}"), .responseEnter,
                          event: Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search"}}"#.utf8))
        await expectError(.invalidInput, attach("", "onEnter(){}"), .responseEnter, event: event(status: 99))
    }

    // MARK: public envelope (no caller identity)

    func testPrivateIdentityFieldAndUnknownEnvelopeKeysAreRejected() async {
        let src = attach("onEnter(){}")
        let identity = #""identity":{"method":"POST","host":"api.example.com","path":"/search"},"#
        await expectError(.invalidInput, src, event: event(envelope: identity))
        await expectError(.invalidInput, src, event: event(envelope: #""extra":1,"#))
        // A reduced private-shape event is not an envelope at all.
        await expectError(.invalidInput, src, event: Data((#"{"# + identity + #""request":{}}"#).utf8))
    }

    func testOptionalEnvelopeFieldsAreValidated() async throws {
        let src = attach("onEnter(){}")
        let good = #""id":"00000000-0000-4000-8000-000000000001","exchangeID":"00000000-0000-4000-8000-000000000002","phase":"request.onEnter","time":"2026-01-01T00:00:00Z","#
        let r = try await run(src, .requestEnter, event: event(envelope: good))
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        await expectError(.invalidInput, src, event: event(envelope: #""id":"nope","#))
        await expectError(.invalidInput, src, event: event(envelope: #""phase":"response.onEnter","#))
        await expectError(.invalidInput, src, event: event(envelope: #""time":1,"#))
    }

    func testSDKFixtureShapeEventWithFullManifestRuns() async throws {
        // Mirrors fixtures/request-event.json and the sample manifest: only the declared body is readable.
        let ev = Data(#"{"id":"00000000-0000-4000-8000-000000000001","exchangeID":"00000000-0000-4000-8000-000000000002","phase":"request.onEnter","time":"2026-01-01T00:00:00Z","request":{"method":"POST","host":"api.example.com","path":"/search","body":{"query":"x","limit":50}}}"#.utf8)
        let src = attach("onEnter(request, config) { request.body.limit = Math.min(request.body.limit, config.limit); }")
        let r = try await run(src, .requestEnter, event: ev)
        XCTAssertEqual(((r["mutation"] as? [String: Any])?["body"] as? [String: Any])?["limit"] as? Int, 5)
    }

    // MARK: read grants are applied before JS sees traffic

    private func probe(_ expr: String, _ hook: JavaScriptHook = .requestEnter, manifest: Data? = nil) async throws -> [String: Any] {
        let leg = hook == .requestEnter || hook == .requestLeave ? "request" : "response"
        let phase = hook == .requestEnter || hook == .responseEnter ? "onEnter" : "onLeave"
        let src = attach(leg == "request" ? "\(phase)(r){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:\(expr)}]}; }" : "",
                         leg == "response" ? "\(phase)(r){ return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:\(expr)}]}; }" : "")
        let r = try await run(src, hook, manifest: manifest)
        return try XCTUnwrap(((r["actions"] as? [[String: Any]])?.first)?["json"] as? [String: Any])
    }

    func testDeniedMetadataIsAbsentButStillUsedForMatching() async throws {
        let m = manifest(metadata: "[]")
        let json = try await probe("{keys:Object.keys(r).join(',')}", manifest: m)
        XCTAssertEqual(json["keys"] as? String, "headers,query,body")
        let some = try await probe("{keys:Object.keys(r).join(',')}", manifest: manifest(metadata: #"["host"]"#))
        XCTAssertEqual(some["keys"] as? String, "host,headers,query,body")
        // Matching used the unfiltered envelope even though nothing was granted.
        let miss = try await run(attach("onEnter(){ throw new Error('no'); }"), .requestEnter, event: event(path: "/other"), manifest: m)
        XCTAssertEqual((miss["actions"] as? [Any])?.count, 0)
        let resp = try await probe("{keys:Object.keys(r).join(','),req:Object.keys(r.request).join(',')}", .responseEnter, manifest: m)
        XCTAssertEqual(resp["keys"] as? String, "headers,body,request")
        XCTAssertEqual(resp["req"] as? String, "headers,query,body")
        let status = try await probe("{status:r.status,keys:Object.keys(r).join(',')}", .responseEnter)
        XCTAssertEqual(status["status"] as? Int, 200)
    }

    func testDeniedHeadersAreFilteredCaseInsensitivelyAndLowercased() async throws {
        let json = try await probe("{h:JSON.stringify(r.headers)}")
        XCTAssertEqual(json["h"] as? String, #"{"x-a":"1"}"#)
        let none = try await probe("{h:JSON.stringify(r.headers)}", manifest: manifest(headers: "[]"))
        XCTAssertEqual(none["h"] as? String, "{}")
        let resp = try await probe("{h:JSON.stringify(r.headers),rh:JSON.stringify(r.request.headers)}", .responseEnter)
        XCTAssertEqual(resp["h"] as? String, #"{"x-a":"r"}"#)
        XCTAssertEqual(resp["rh"] as? String, #"{"x-a":"1"}"#)
        let two = try await probe("{h:Object.keys(r.headers).sort().join(',')}", manifest: manifest(headers: #"["X-Other","authorization"]"#))
        XCTAssertEqual(two["h"] as? String, "authorization,x-other")
    }

    func testDeniedQueryKeysAreFilteredExactly() async throws {
        let json = try await probe("{q:JSON.stringify(r.query)}")
        XCTAssertEqual(json["q"] as? String, #"{"q":"1"}"#)
        let none = try await probe("{q:JSON.stringify(r.query)}", manifest: manifest(queryKeys: "[]"))
        XCTAssertEqual(none["q"] as? String, "{}")
        // Query names are case-sensitive: "Q" grants nothing for "q".
        let case1 = try await probe("{q:JSON.stringify(r.query)}", manifest: manifest(queryKeys: #"["Q"]"#))
        XCTAssertEqual(case1["q"] as? String, "{}")
    }

    func testBodyModeNoneHidesBodyAndForbidsMutation() async throws {
        let m = manifest(bodyMode: "none")
        let json = try await probe("{has:'body' in r,t:typeof r.body}", manifest: m)
        XCTAssertEqual(json["has"] as? Bool, false)
        let resp = try await probe("{has:'body' in r}", .responseEnter, manifest: m)
        XCTAssertEqual(resp["has"] as? Bool, false)
        // Without a granted body there is nothing to write: the leg is non-extensible even with the write grant.
        await expectError(.scriptError, attach("onEnter(r){ r.body = {a:1}; }"), manifest: m)
    }

    func testSecretsNeverReachCallbacksThroughAnyPath() async throws {
        let json = try await probe("{all:JSON.stringify([r, r.request])}")
        let all = try XCTUnwrap(json["all"] as? String)
        for secret in ["secret", "Authorization", "authorization", "token", "Set-Cookie", "c\"", "X-Other"] {
            XCTAssertFalse(all.contains(secret), secret)
        }
        let resp = try await probe("{all:JSON.stringify(r)}", .responseEnter)
        let text = try XCTUnwrap(resp["all"] as? String)
        for secret in ["secret", "token", "Set-Cookie", "X-Other", "Authorization"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testMalformedEnvelopeMapsAreRejected() async {
        let src = attach("onEnter(){}")
        for bad in [#""headers":{"x-a":1}"#, #""headers":[]"#, #""query":{"q":null}"#, #""query":"q=1""#] {
            let ev = Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search",\#(bad)}}"#.utf8)
            await expectError(.invalidInput, src, event: ev)
        }
        // Duplicate header names that differ only by case are ambiguous.
        await expectError(.invalidInput, src, event: Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search","headers":{"X-A":"1","x-a":"2"}}}"#.utf8))
        // A path with a query string is not a request path.
        await expectError(.invalidInput, src, event: event(path: "/search?x=1"))
    }

    // MARK: strict full v2 manifest (the Rust CLI reaches this entry directly)

    private func expectManifestRejected(_ data: Data, line: UInt = #line) async {
        await expectError(.invalidInput, attach("onEnter(){}"), manifest: data, line: line)
    }

    func testFullPublicManifestIsAccepted() async throws {
        let r = try await run(attach("onEnter(){}"), .requestEnter, manifest: manifest(extra: #","author":"Someone","summary":"Does things""#))
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        let bound = Data(String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: #""endpointBindings":[]"#, with: #""endpointBindings":["Hook","b_2"]"#).utf8)
        _ = try await run(attach("onEnter(){}"), .requestEnter, manifest: bound)
    }

    func testWrongSchemaVersionsAreRejected() async {
        let good = String(decoding: manifest(), as: UTF8.self)
        for v in ["1", "3", "0", "2.5", #""2""#, "null", "true"] {
            await expectManifestRejected(Data(good.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":\#(v)"#).utf8))
        }
        // Legacy v1 shape is never accepted by the v2 entry.
        await expectManifestRejected(Data(#"{"schemaVersion":1,"id":"\#(manifestID)","name":"x","version":"1.0.0","subscriptions":[],"read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},"endpointBindings":[],"settings":{}}"#.utf8))
    }

    func testMissingRequiredManifestFieldsAreRejected() async {
        let good = String(decoding: manifest(), as: UTF8.self)
        for key in ["schemaVersion", "id", "name", "version", "matches", "read", "write", "endpointBindings", "settings"] {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(good.utf8)) as? [String: Any] else { return XCTFail() }
            var copy = obj
            copy[key] = nil
            await expectManifestRejected(try! JSONSerialization.data(withJSONObject: copy))
        }
        // Partial sub-objects.
        for (from, to) in [(#""queryKeys":["q"],"#, ""), (#""headers":["X-A"],"#, ""), (#""metadata":["method","host","path","status"],"#, ""),
                           (#""body":{"mode":"json"}"#, #""body":{}"#), (#","responseBody":true"#, ""), (#""requestBody":true,"#, "")] {
            await expectManifestRejected(Data(good.replacingOccurrences(of: from, with: to).utf8))
        }
    }

    func testUnknownManifestFieldsAreRejected() async {
        let good = String(decoding: manifest(), as: UTF8.self)
        await expectManifestRejected(manifest(extra: #","subscriptions":[]"#))
        await expectManifestRejected(manifest(extra: #","extra":1"#))
        await expectManifestRejected(Data(good.replacingOccurrences(of: #""mode":"json""#, with: #""mode":"json","pointers":["/a"]"#).utf8))
        await expectManifestRejected(Data(good.replacingOccurrences(of: #""responseBody":true"#, with: #""responseBody":true,"headers":true"#).utf8))
        await expectManifestRejected(Data(good.replacingOccurrences(of: #""queryKeys":["q"]"#, with: #""queryKeys":["q"],"x":[]"#).utf8))
        await expectManifestRejected(Data(good.replacingOccurrences(of: #""hosts":["api.example.com"]"#, with: #""hosts":["api.example.com"],"host":"x""#).utf8))
    }

    func testInvalidManifestValuesAreRejected() async {
        await expectManifestRejected(manifest(metadata: #"["body"]"#))
        await expectManifestRejected(manifest(metadata: #"["host","host"]"#))
        await expectManifestRejected(manifest(headers: #"["X-A","x-a"]"#))
        await expectManifestRejected(manifest(headers: #"["bad header"]"#))
        await expectManifestRejected(manifest(queryKeys: #"[""]"#))
        await expectManifestRejected(manifest(queryKeys: #"["q","q"]"#))
        await expectManifestRejected(manifest(bodyMode: "raw"))
        await expectManifestRejected(manifest(bodyMode: "jsonPointers"))
        await expectManifestRejected(manifest(bodyMode: "full"))
        await expectManifestRejected(manifest(matches: #"{"hosts":["API.example.com"]}"#))
        await expectManifestRejected(manifest(matches: #"{"hosts":["a.example.com"],"methods":["post"]}"#))
        await expectManifestRejected(manifest(matches: #"{"hosts":["a.example.com"],"path":{"kind":"exact","value":"search"}}"#))
        await expectManifestRejected(manifest(matches: #"{"hosts":["a.example.com"],"path":{"kind":"glob","value":"/*"}}"#))
        await expectManifestRejected(manifest(matches: #"{"hosts":["a.example.com"],"status":{"min":99,"max":200}}"#))
        let good = String(decoding: manifest(), as: UTF8.self)
        for (from, to) in [(#""id":"\#(manifestID)""#, #""id":"not-a-uuid""#), (#""version":"1.0.0""#, #""version":"1.0""#),
                           (#""version":"1.0.0""#, #""version":"01.0.0""#), (#""name":"Sample""#, #""name":"""#),
                           (#""endpointBindings":[]"#, #""endpointBindings":["a","b","c","d","e"]"#),
                           (#""endpointBindings":[]"#, #""endpointBindings":["1bad"]"#), (#""endpointBindings":[]"#, #""endpointBindings":["a","a"]"#),
                           (#""settings":{"limit":5}"#, #""settings":[]"#), (#""write":{"requestBody":true"#, #""write":{"requestBody":1"#)] {
            await expectManifestRejected(Data(good.replacingOccurrences(of: from, with: to).utf8))
        }
        // 17 registrations/matches.
        await expectManifestRejected(manifest(matches: Array(repeating: match, count: 17).joined(separator: ",")))
    }

    func testDuplicateManifestKeysAreRejected() async {
        let good = String(decoding: manifest(), as: UTF8.self)
        await expectManifestRejected(Data(good.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":2,"schemaVersion":2"#).utf8))
    }

    func testCallbackAndRegistrationInfiniteLoopsTimeOutAndRecover() async throws {
        let executor = JavaScriptExecutor()
        for src in [attach("onEnter(){ for (;;) {} }"), "for (;;) {}" + attach("onEnter(){}")] {
            do { _ = try await run(src, .requestEnter, executor: executor); XCTFail("expected timeout") }
            catch { XCTAssertEqual(error as? JavaScriptExecutionError, .timeout) }
        }
        let r = try await run(attach("onEnter(){}"), .requestEnter, executor: executor)
        XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
    }

    func testRequestAssociationReadsFromRequestLegInResponsePhases() async {
        await expectError(.scriptError, attach("", "onEnter(r){ return r.request.nothing.x; }"), .responseEnter)
    }
}
