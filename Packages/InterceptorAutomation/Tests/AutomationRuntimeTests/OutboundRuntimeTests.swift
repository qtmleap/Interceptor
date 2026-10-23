import XCTest
import AutomationCore
@testable import AutomationRuntime

/// `Interceptor.send` HTTP intent collection through the real shared C runtime (`qjs_run_v2`).
final class OutboundRuntimeTests: XCTestCase, @unchecked Sendable {
    private let endpoint = "11111111-1111-1111-1111-111111111111"
    private let file = "hooks/api.example.com/credentials/GET.js"
    private let config = Data(#"{}"#.utf8)
    private let route = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onLeave":"hooks/api.example.com/credentials/GET.js"}}}"#
    private let profile = #"{"url":"https://api.example.com/v1/profile","method":"GET","headers":["authorization","cookie"]}"#

    private func manifest(outbound: String? = nil, schema: Int = 2) -> Data {
        let ob = outbound ?? #"{"profile":\#(profile),"other":{"url":"https://other.example.org/","method":"GET","headers":[]}}"#
        return Data(#"{"schemaVersion":\#(schema),"id":"22222222-2222-4222-8222-222222222222","name":"Sample","version":"1.0.0","matches":[\#(route)],"read":{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{},"outbound":\#(ob)}"#.utf8)
    }

    private let event = Data(#"{"request":{"method":"GET","host":"api.example.com","path":"/credentials"},"response":{"status":200,"headers":{},"body":{"accessToken":"t"}}}"#.utf8)

    private func run(_ body: String, top: String = "", manifest: Data? = nil, hook: JavaScriptHook = .responseLeave) async throws -> [[String: Any]] {
        let source = "\(top)Interceptor.attach({response:{onLeave(res){\(body)}}});"
        let code = try JSONValue.string(source).jsonString()
        let m = String(decoding: manifest ?? self.manifest(), as: UTF8.self)
        let package = Data(#"{"manifest":\#(m),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
        let data = try await JavaScriptExecutor().runV2(packageJSON: package, hook: hook, eventJSON: event, configJSON: config)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["actions"] as? [[String: Any]])
    }

    private func expectError(_ expected: JavaScriptExecutionError, _ body: String, top: String = "", manifest: Data? = nil, line: UInt = #line) async {
        do {
            let r = try await run(body, top: top, manifest: manifest)
            XCTFail("expected \(expected), got \(r)", line: line)
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    private func webhook(_ n: Int) -> String { "{type:'webhook',endpointId:'\(endpoint)',json:{n:\(n)}}" }

    // MARK: collection and wire shape

    func testSendRecordsExactWireIntentAndReturnsUndefined() async throws {
        let actions = try await run("const r = Interceptor.send('profile', {headers:{cookie:'a=b', authorization:'Bearer \"x\\\\\"'}}); if (r !== undefined) throw new Error('x');")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(Set(actions[0].keys), ["type", "binding", "headers"])
        XCTAssertEqual(actions[0]["type"] as? String, "http")
        XCTAssertEqual(actions[0]["binding"] as? String, "profile")
        XCTAssertEqual(actions[0]["headers"] as? [String: String], ["authorization": "Bearer \"x\\\"", "cookie": "a=b"])
    }

    func testEmptyHeadersAndTabValueAreAccepted() async throws {
        let actions = try await run("Interceptor.send('other', {headers:{}}); Interceptor.send('profile', {headers:{authorization:'a\\tb'}});")
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual((actions[1]["headers"] as? [String: String])?["authorization"], "a\tb")
    }

    func testSendsAreFIFOThenReturnedWebhooksAndShareTheTwoActionCap() async throws {
        let actions = try await run("Interceptor.send('profile',{headers:{}}); return {actions:[\(webhook(1))]};")
        XCTAssertEqual(actions.map { $0["type"] as? String }, ["http", "webhook"])
        let two = try await run("Interceptor.send('profile',{headers:{}}); Interceptor.send('other',{headers:{}});")
        XCTAssertEqual(two.map { $0["binding"] as? String }, ["profile", "other"])
        await expectError(.invalidResult, "Interceptor.send('profile',{headers:{}}); Interceptor.send('profile',{headers:{}}); return {actions:[\(webhook(1))]};")
        await expectError(.scriptError, "Interceptor.send('profile',{headers:{}}); Interceptor.send('profile',{headers:{}}); Interceptor.send('profile',{headers:{}});")
        await expectError(.invalidResult, "Interceptor.send('profile',{headers:{}}); return {actions:[\(webhook(1)),\(webhook(2))]};")
    }

    func testSnapshotIsNotAffectedByLaterMutation() async throws {
        let actions = try await run("const h = {authorization:'one'}; Interceptor.send('profile',{headers:h}); h.authorization='two'; h.cookie='x';")
        XCTAssertEqual(actions[0]["headers"] as? [String: String], ["authorization": "one"])
    }

    func testReturnedHTTPActionIsRejected() async {
        await expectError(.invalidResult, "return {actions:[{type:'http',binding:'profile',headers:{}}]};")
    }

    // MARK: sticky failures

    func testTopLevelCallIsStickyFailure() async {
        await expectError(.scriptError, "", top: "Interceptor.send('profile',{headers:{}});")
        await expectError(.scriptError, "", top: "try { Interceptor.send('profile',{headers:{}}); } catch (e) {}")
    }

    func testCaughtInvalidCallsStillFail() async {
        let invalid = [
            "Interceptor.send('nope',{headers:{}})",
            "Interceptor.send('profile',{headers:{'x-undeclared':'1'}})",
            "Interceptor.send('profile',{headers:{Authorization:'1'}})",
            "Interceptor.send('profile')",
            "Interceptor.send('profile',{headers:{}},1)",
            "Interceptor.send('profile',{})",
            "Interceptor.send('profile',{headers:{}, url:'https://evil.example.com/'})",
            "Interceptor.send('profile',{headers:{}, method:'POST'})",
            "Interceptor.send('profile',null)",
            "Interceptor.send('profile',{headers:null})",
            "Interceptor.send('profile',{headers:[]})",
            "Interceptor.send(1,{headers:{}})",
            "Interceptor.send({toString(){return 'profile';}},{headers:{}})",
            "Interceptor.send('profile',{headers:{authorization:1}})",
            "Interceptor.send('profile',{headers:{authorization:{toString(){return 'a';}}}})",
            "Interceptor.send('profile',{headers:{authorization:'a\\r\\nb'}})",
            "Interceptor.send('profile',{headers:{authorization:'a\\u00e9'}})",
            "Interceptor.send('profile',{headers:{authorization:'a\\u007f'}})",
            "Interceptor.send('profile',{headers:{authorization:'a'.repeat(4097)}})",
            "Interceptor.send('profile',{get headers(){return {};}})",
            "Interceptor.send('profile',{headers:{get authorization(){return 'x';}}})",
            "Interceptor.send('profile',new Proxy({headers:{}},{}))",
            "Interceptor.send('profile',{headers:new Proxy({},{})})",
            "Interceptor.send('profile',{headers:Object.defineProperty({}, 'authorization', {value:'x', enumerable:false})})",
            "Interceptor.send('profile',{headers:{authorization:'x', [Symbol('s')]:'y'}})",
            "Interceptor.send('profile',{headers:{toJSON(){return {};}}})",
        ]
        for call in invalid {
            await expectError(.scriptError, "try { \(call); } catch (e) {} return {actions:[]};")
            await expectError(.scriptError, "\(call);")
        }
    }

    func testBoundariesAreAccepted() async throws {
        let value = String(repeating: "a", count: 4096)
        let actions = try await run("Interceptor.send('profile',{headers:{authorization:'\(value)',cookie:'\(value)'}});")
        XCTAssertEqual(actions.count, 1)
    }

    func testCombinedHeaderByteBudgetIsInclusive() async throws {
        let m = manifest(outbound: decl(headers: #"["authorization","cookie","x"]"#))
        let actions = try await run("Interceptor.send('profile',{headers:{authorization:'a'.repeat(4096),cookie:'b'.repeat(4096)}});", manifest: m)
        XCTAssertEqual(actions.count, 1)
        await expectError(.scriptError, "try{Interceptor.send('profile',{headers:{authorization:'a'.repeat(4096),cookie:'b'.repeat(4096),x:'c'}});}catch{}", manifest: m)
    }

    func testOutboundURLGrammarMatchesCoreForEncodedPathsAndDNSLabels() async {
        await accepts(decl(url: "https://api.example.1a/%E6%97%A5%E6%9C%AC%E8%AA%9E"))
        await accepts(decl(url: "https://api.example.com/%80"))
    }

    func testCallbackAndRegistrationConstraints() async {
        await expectError(.scriptError, "", top: "const send = Interceptor.send; try { send('profile',{headers:{}}); } catch (e) {}")
    }

    func testNoFetchAndSendIsNotAliasedToFetch() async throws {
        let actions = try await run("return {actions:[{type:'webhook',endpointId:'\(endpoint)',json:{f:typeof fetch,k:Object.keys(Interceptor).join(','),n:Interceptor.send.length}}]};")
        let json = try XCTUnwrap(actions[0]["json"] as? [String: Any])
        XCTAssertEqual(json["f"] as? String, "undefined")
        XCTAssertEqual(json["k"] as? String, "attach,send,Storage")
    }

    // MARK: manifest outbound grammar

    private func accepts(_ outbound: String, line: UInt = #line) async {
        do { _ = try await run("", manifest: manifest(outbound: outbound)) } catch { XCTFail("rejected \(outbound): \(error)", line: line) }
    }
    private func rejects(_ outbound: String, line: UInt = #line) async {
        await expectError(.invalidInput, "", manifest: manifest(outbound: outbound), line: line)
    }
    private func decl(url: String = "https://api.example.com/v1/profile", headers: String = #"["authorization"]"#, method: String = "GET", extra: String = "") -> String {
        #"{"profile":{"url":"\#(url)","method":"\#(method)","headers":\#(headers)\#(extra)}}"#
    }

    func testManifestOutboundIsOptionalAndSchemaTwoOnly() async throws {
        let m = String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: #","outbound":{"profile":\#(profile),"other":{"url":"https://other.example.org/","method":"GET","headers":[]}}"#, with: "")
        XCTAssertFalse(m.contains("outbound"))
        _ = try await run("", manifest: Data(m.utf8))
        await expectError(.invalidInput, "", manifest: manifest(schema: 1))
        await expectError(.scriptError, "Interceptor.send('profile',{headers:{}});", manifest: Data(m.utf8))
        await accepts("{}")
    }

    func testManifestDeclarationGrammar() async {
        await accepts(decl())
        await accepts(decl(headers: "[]"))
        await accepts(decl(url: "https://a.example.com/a%2Fb/c?".replacingOccurrences(of: "?", with: "")))
        await accepts(decl(headers: #"["x-api-key","a1","!#$%&'*+-.^_`|~"]"#))
        await accepts(decl(headers: #"["a","b","c","d","e","f","g","h"]"#))
        await rejects(decl(extra: #","body":""#))
        await rejects(decl(method: "POST"))
        await rejects(decl(method: "get"))
        await rejects(#"{"profile":{"url":"https://api.example.com/","method":"GET"}}"#)
        await rejects(#"{"profile":{"url":"https://api.example.com/","headers":[]}}"#)
        await rejects(#"{"profile":"https://api.example.com/"}"#)
        await rejects("[]")
        await rejects("null")
        await rejects(#"{"1bad":{"url":"https://api.example.com/","method":"GET","headers":[]}}"#)
        await rejects(#"{"a-b":{"url":"https://api.example.com/","method":"GET","headers":[]}}"#)
        let five = (1...5).map { #""b\#($0)":{"url":"https://api.example.com/","method":"GET","headers":[]}"# }.joined(separator: ",")
        await rejects("{\(five)}")
        let four = (1...4).map { #""b\#($0)":{"url":"https://api.example.com/","method":"GET","headers":[]}"# }.joined(separator: ",")
        await accepts("{\(four)}")
        await rejects(decl(url: "https://api.example.com/", headers: #"["a","b","c","d","e","f","g","h","i"]"#))
        await rejects(decl(headers: #"["authorization","authorization"]"#))
        await rejects(decl(headers: #"["Authorization"]"#))
        await rejects(decl(headers: #"["bad name"]"#))
        await rejects(decl(headers: #"[""]"#))
        await rejects(decl(headers: "[\"\(String(repeating: "a", count: 129))\"]"))
        await rejects(decl(headers: #"[1]"#))
        for denied in ["host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer", "expect", "keep-alive", "set-cookie", "proxy-authorization", "proxy-x"] {
            await rejects(decl(headers: "[\"\(denied)\"]"))
        }
    }

    func testManifestURLGrammar() async {
        let bad = [
            "http://api.example.com/", "HTTPS://api.example.com/", "https://api.example.com", "https://API.example.com/",
            "https://localhost/", "https://example/", "https://api.local/", "https://a.localhost/", "https://127.0.0.1/", "https://1.2.3.4/",
            "https://[::1]/", "https://api.example.com./", "https://api.example.com:443/", "https://api.example.com:8443/",
            "https://user@api.example.com/", "https://user:pw@api.example.com/", "https://api.example.com/?q=1", "https://api.example.com/#f",
            "https://api.example.com/a?b", "https://api.example.com/a#b", "https://api.example.com//x y", "https://api.example.com/a\\\\b",
            "https://api.example.com/%", "https://api.example.com/%4", "https://api.example.com/%zz", "https://api.example.com/%00",
            "https://api.example.com/%1f", "https://api.example.com/%7f", "https://api.example.com/%5c", "https://api.example.com/%5C",
            "https://api.example.com/\\u00e9", "https://api.example.com/\\t", "https://a_b.example.com/",
            "https://-a.example.com/", "https://a..example.com/", "https://api.example.1/", "https://api.123/",
            "https://api.example.com/" + String(repeating: "a", count: 1024),
            "https://api.example.com/" + String(repeating: "a", count: 2100),
            "",
        ]
        for url in bad { await rejects(decl(url: url)) }
        await accepts(decl(url: "https://api.example.com/" + String(repeating: "a", count: 1023)))
        await accepts(decl(url: "https://api.example.com/%41%2f%7E"))
    }
}
