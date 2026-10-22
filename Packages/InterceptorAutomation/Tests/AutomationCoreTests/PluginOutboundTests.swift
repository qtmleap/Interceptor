import XCTest
@testable import AutomationCore

/// Optional schema-2 `outbound` declarations and exact HTTP intent validation (no networking).
final class PluginOutboundTests: XCTestCase {
    private static let match = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onEnter":"selected.js"}}}"#
    private static let read = #"{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}}"#
    private static let write = #"{"requestBody":false,"responseBody":false}"#
    private static let profile = #"{"url":"https://api.example.com/v1/profile","method":"GET","headers":["authorization","cookie"]}"#

    private func package(outbound: String? = #"{"profile":\#(profile)}"#, schema: String = "2") -> Data {
        var fields = [
            #""schemaVersion":\#(schema)"#, #""id":"\#(pluginID)""#, #""name":"Hook""#, #""version":"1.0.0""#,
            #""matches":[\#(Self.match)]"#, #""read":\#(Self.read)"#, #""write":\#(Self.write)"#,
            #""settings":{}"#, #""endpointBindings":["alert"]"#,
        ]
        if let outbound { fields.append(#""outbound":\#(outbound)"#) }
        return Data(#"{"manifest":{\#(fields.joined(separator: ","))},"sourceFiles":{"selected.js":"Interceptor.attach({response:{onEnter(){}}});"}}"#.utf8)
    }
    private func decl(url: String = "https://api.example.com/v1/profile", headers: String = #"["authorization"]"#, method: String = "GET", extra: String = "") -> String {
        #"{"profile":{"url":"\#(url)","method":"\#(method)","headers":\#(headers)\#(extra)}}"#
    }
    private func manifest(_ outbound: String? = nil) throws -> PluginManifest {
        try PluginPackage.validate(package(outbound: outbound ?? #"{"profile":\#(Self.profile)}"#)).manifest
    }
    private func rejects(_ outbound: String, line: UInt = #line) {
        assertThrows(.invalidManifest, try PluginPackage.validate(package(outbound: outbound)), line: line)
    }
    private func accepts(_ outbound: String, line: UInt = #line) {
        XCTAssertNoThrow(try PluginPackage.validate(package(outbound: outbound)), line: line)
    }
    private func action(binding: String = "profile", headers: String = #"{"authorization":"Bearer abc"}"#, extra: String = "") -> JSONValue {
        try! JSONValue(parsing: Data(#"{"type":"http","binding":"\#(binding)","headers":\#(headers)\#(extra)}"#.utf8))
    }

    func testOutboundIsOptionalAndSchemaTwoOnly() throws {
        XCTAssertEqual(try manifest().outbound["profile"],
                       PluginOutboundEndpoint(url: "https://api.example.com/v1/profile", method: "GET", headers: ["authorization", "cookie"]))
        XCTAssertTrue(try PluginPackage.validate(package(outbound: nil)).manifest.outbound.isEmpty)
        XCTAssertNoThrow(try PluginPackage.validate(package(outbound: "{}")))
        let v1 = Data(#"{"manifest":\#(manifestJSON(extra: #","outbound":{}"#)),"source":"function onRequest(){return {actions:[]}}"}"#.utf8)
        assertThrows(.invalidManifest, try PluginPackage.validate(v1))
    }

    func testEndpointDerivedParts() throws {
        let e = try manifest().outbound["profile"]!
        XCTAssertEqual(e.host, "api.example.com")
        XCTAssertEqual(e.path, "/v1/profile")
    }

    func testDeclarationShapeIsStrict() {
        accepts(decl())
        accepts(decl(headers: "[]"))
        rejects(decl(extra: #","body":""#))
        rejects(decl(method: "DELETE"))
        rejects(decl(method: "get"))
        rejects(#"{"profile":{"url":"https://api.example.com/","method":"GET"}}"#)
        rejects(#"{"profile":{"url":"https://api.example.com/","headers":[]}}"#)
        rejects(#"{"profile":"https://api.example.com/"}"#)
        rejects(#"[]"#)
    }

    func testBindingKeysUseExistingGrammarIndependentOfLegacyBindings() {
        let e = #"{"url":"https://api.example.com/","method":"GET","headers":[]}"#
        accepts("{" + ["a", "b", "c", "d"].map { #""\#($0)":\#(e)"# }.joined(separator: ",") + "}")
        rejects("{" + ["a", "b", "c", "d", "e"].map { #""\#($0)":\#(e)"# }.joined(separator: ",") + "}")
        accepts(#"{"\#(String(repeating: "a", count: 32))":\#(e)}"#)
        rejects(#"{"\#(String(repeating: "a", count: 33))":\#(e)}"#)
        rejects(#"{"1bad":\#(e)}"#)
        rejects(#"{"bad-name":\#(e)}"#)
        rejects(#"{"":\#(e)}"#)
    }

    func testURLGrammar() {
        accepts(decl(url: "https://api.example.com/"))
        accepts(decl(url: "https://a.b.example.com/p%2Fq/r"))
        accepts(decl(url: "https://api.example.com//"))
        for bad in [
            "http://api.example.com/", "https://api.example.com", "https://API.example.com/", "https://api.example.com:443/",
            "https://api.example.com:8443/", "https://user@api.example.com/", "https://user:pw@api.example.com/",
            "https://api.example.com/?q=1", "https://api.example.com/#f", "https://127.0.0.1/", "https://[::1]/",
            "https://localhost/", "https://example/", "https://printer.local/", "https://api.example.com./",
            "https://api.example.com/a b", "https://api.example.com/a%zz", "https://api.example.com/a%", "https://api.example.com/a%0d%0a",
            "https://api.example.com/a%00", "https://api.example.com/a%5cb", "https://api.example.com/a\\b", "https://api.example.com/\u{e9}",
            "https://api.example.com/a\\r\\nb", "https://api.example.com/a\\tb", "//api.example.com/",
            "https://-a.example.com/", "https://a..example.com/", "https://1.2.3.4/", "https://0x7f.1/", "https://xn--a.example.com./",
        ] {
            rejects(decl(url: bad))
        }
    }

    func testURLLengthBounds() {
        let prefix = "https://api.example.com"
        accepts(decl(url: prefix + "/" + String(repeating: "a", count: 1023)))
        rejects(decl(url: prefix + "/" + String(repeating: "a", count: 1024)))
        let labels = (0..<4).map { _ in String(repeating: "a", count: 59) }.joined(separator: ".")
        accepts(decl(url: "https://\(labels).example.com/" + String(repeating: "a", count: 1023)))
    }

    func testURLGrammarMatchesEncodedPathsAndDNSLabelPolicy() {
        accepts(decl(url: "https://api.example.1a/%E6%97%A5%E6%9C%AC%E8%AA%9E"))
        accepts(decl(url: "https://api.example.com/%80"))
        rejects(decl(url: "https://api.example.123/"))
    }

    func testHeaderNameRules() {
        accepts(decl(headers: #"["authorization","cookie","x-api-key","x_a","a1","!#$%&'*+-.^_`|~"]"#))
        accepts(decl(headers: "[" + (0..<8).map { #""h\#($0)""# }.joined(separator: ",") + "]"))
        rejects(decl(headers: "[" + (0..<9).map { #""h\#($0)""# }.joined(separator: ",") + "]"))
        rejects(decl(headers: #"["a","a"]"#))
        rejects(decl(headers: #"["Authorization"]"#))
        rejects(decl(headers: #"[""]"#))
        rejects(decl(headers: #"["a b"]"#))
        rejects(decl(headers: #"["a:b"]"#))
        rejects(decl(headers: #"[":authority"]"#))
        rejects(decl(headers: #"["\#(String(repeating: "a", count: 129))"]"#))
        accepts(decl(headers: #"["\#(String(repeating: "a", count: 128))"]"#))
        rejects(decl(headers: "[1]"))
        for denied in ["host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer", "expect",
                       "keep-alive", "set-cookie", "proxy-authorization", "proxy-x", "proxy-connection"] {
            rejects(decl(headers: #"["\#(denied)"]"#))
        }
    }

    func testPolicyConstantsAndHeaderHelper() {
        XCTAssertEqual(PluginOutboundPolicy.maxURLBytes, 2048)
        XCTAssertEqual(PluginOutboundPolicy.maxPathBytes, 1024)
        XCTAssertEqual(PluginOutboundPolicy.maxBindingNameBytes, 32)
        XCTAssertEqual(PluginOutboundPolicy.maxDeclaredHeaders, 8)
        XCTAssertEqual(PluginOutboundPolicy.maxHeaderNameBytes, 128)
        XCTAssertEqual(PluginOutboundPolicy.maxHeaderValueBytes, 4096)
        XCTAssertEqual(PluginOutboundPolicy.maxTotalHeaderValueBytes, 8192)
        XCTAssertTrue(PluginOutboundPolicy.isAllowedHeaderName("authorization"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderName("Authorization"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderName("host"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderName("proxy-authorization"))
        XCTAssertTrue(PluginOutboundPolicy.isAllowedHeaderValue("Bearer a\tb ~"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderValue("a\r\nb"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderValue("a\u{7f}"))
        XCTAssertFalse(PluginOutboundPolicy.isAllowedHeaderValue("\u{e9}"))
    }

    func testValidIntent() throws {
        let m = try manifest()
        let i = try PluginOutboundIntent.validating(action(headers: #"{"authorization":"Bearer abc","cookie":"s=1; t=2"}"#), manifest: m)
        XCTAssertEqual(i.binding, "profile")
        XCTAssertEqual(i.endpoint, m.outbound["profile"])
        XCTAssertEqual(i.headers, ["authorization": "Bearer abc", "cookie": "s=1; t=2"])
        XCTAssertEqual(try PluginOutboundIntent.validating(action(headers: "{}"), manifest: m).headers, [:])
        XCTAssertEqual(try PluginOutboundIntent.validating(action(headers: #"{"authorization":""}"#), manifest: m).headers, ["authorization": ""])
    }

    func testIntentRejections() throws {
        let m = try manifest()
        func bad(_ a: JSONValue, _ e: PluginOutboundIntentError, line: UInt = #line) {
            XCTAssertThrowsError(try PluginOutboundIntent.validating(a, manifest: m), line: line) { XCTAssertEqual($0 as? PluginOutboundIntentError, e, line: line) }
        }
        bad(action(extra: #","method":"GET""#), .malformed)
        bad(action(extra: #","url":"https://evil.example/""#), .malformed)
        bad(try JSONValue(parsing: Data(#"{"type":"http","binding":"profile"}"#.utf8)), .malformed)
        bad(try JSONValue(parsing: Data(#"{"type":"http","headers":{}}"#.utf8)), .malformed)
        bad(try JSONValue(parsing: Data(#"{"type":"webhook","binding":"profile","headers":{}}"#.utf8)), .malformed)
        bad(try JSONValue(parsing: Data(#"{"type":"http","binding":1,"headers":{}}"#.utf8)), .malformed)
        bad(try JSONValue(parsing: Data(#"{"type":"http","binding":"profile","headers":[]}"#.utf8)), .malformed)
        bad(try JSONValue(parsing: Data(#"[]"#.utf8)), .malformed)
        bad(action(binding: "other"), .unknownBinding)
        bad(action(binding: "alert"), .unknownBinding)
        bad(action(headers: #"{"x-other":"1"}"#), .undeclaredHeader)
        bad(action(headers: #"{"Authorization":"1"}"#), .undeclaredHeader)
        bad(action(headers: #"{"authorization":1}"#), .malformed)
        bad(action(headers: #"{"authorization":"a\r\nb: c"}"#), .invalidHeaderValue)
        bad(action(headers: #"{"authorization":"a\u0000b"}"#), .invalidHeaderValue)
        bad(action(headers: #"{"authorization":"é"}"#), .invalidHeaderValue)
    }

    func testIntentValueCaps() throws {
        let m = try manifest()
        let ok = String(repeating: "a", count: 4096)
        XCTAssertNoThrow(try PluginOutboundIntent.validating(action(headers: #"{"authorization":"\#(ok)","cookie":"\#(ok)"}"#), manifest: m))
        XCTAssertThrowsError(try PluginOutboundIntent.validating(action(headers: #"{"authorization":"\#(ok)a"}"#), manifest: m)) {
            XCTAssertEqual($0 as? PluginOutboundIntentError, .limitExceeded)
        }
        // Sum cap: declare three headers so 3 x 4096 > 8192.
        let three = try manifest(decl(headers: #"["a","b","c"]"#))
        XCTAssertThrowsError(try PluginOutboundIntent.validating(action(headers: #"{"a":"\#(ok)","b":"\#(ok)","c":"x"}"#), manifest: three)) {
            XCTAssertEqual($0 as? PluginOutboundIntentError, .limitExceeded)
        }
    }

    func testOutboundDoesNotChangeEndpointBindings() throws {
        XCTAssertEqual(try manifest().endpointBindings, ["alert"])
    }

    // MARK: POST/PUT methods and optional exact JSON body (PHASE1: RED until implemented)

    private func writeManifest(method: String = "POST") throws -> PluginManifest {
        try manifest(decl(headers: #"["authorization","content-type"]"#, method: method))
    }
    private func bodyAction(_ body: String?, binding: String = "profile") -> JSONValue {
        var extra = ""
        if let body { extra = #","jsonBody":\#(try! JSONValue.string(body).jsonString())"# }
        return action(binding: binding, headers: "{}", extra: extra)
    }
    private func intent(_ body: String?, method: String = "POST") throws -> PluginOutboundIntent {
        try PluginOutboundIntent.validating(bodyAction(body), manifest: writeManifest(method: method))
    }
    private func badIntent(_ body: String?, method: String = "POST", _ e: PluginOutboundIntentError, line: UInt = #line) throws {
        let m = try writeManifest(method: method)
        XCTAssertThrowsError(try PluginOutboundIntent.validating(bodyAction(body), manifest: m), line: line) {
            XCTAssertEqual($0 as? PluginOutboundIntentError, e, line: line)
        }
    }

    func testPostAndPutDeclarationsAreAcceptedButOtherMethodsAreNot() throws {
        accepts(decl(method: "POST"))
        accepts(decl(method: "PUT"))
        accepts(decl(method: "GET"))
        XCTAssertEqual(try writeManifest(method: "PUT").outbound["profile"]?.method, "PUT")
        for bad in ["DELETE", "PATCH", "HEAD", "OPTIONS", "post", "put", "Post", "Put", "get", "", " POST", "POST "] {
            rejects(decl(method: bad))
        }
    }

    func testMethodChangeAltersPackageRevision() throws {
        let get = try PluginPackage.validate(package(outbound: decl(method: "GET"))).revision
        let post = try PluginPackage.validate(package(outbound: decl(method: "POST"))).revision
        let put = try PluginPackage.validate(package(outbound: decl(method: "PUT"))).revision
        XCTAssertEqual(Set([get, post, put]).count, 3)
    }

    func testLegacyGetIntentHasNoBody() throws {
        let i = try PluginOutboundIntent.validating(action(), manifest: manifest())
        XCTAssertNil(i.jsonBody)
    }

    func testPostPutWithoutBodyIsValidEmptyBody() throws {
        for method in ["POST", "PUT"] {
            XCTAssertNil(try intent(nil, method: method).jsonBody)
        }
    }

    func testJSONBodyIsForwardedAsExactSerializedBytesWithoutReencoding() throws {
        // Spellings a parse/re-encode round trip would normalise (number format, escapes, key order, non-ASCII).
        let exact = #"{"z":1e+21,"a":[0.1,1.5,4294967296],"s":"a\"b\\c\n\u0001é日本😀"}"#
        for method in ["POST", "PUT"] {
            let i = try intent(exact, method: method)
            XCTAssertEqual(i.jsonBody, Data(exact.utf8))
            XCTAssertEqual(i.endpoint.method, method)
        }
        XCTAssertEqual(try intent("null").jsonBody, Data("null".utf8))
        XCTAssertEqual(try intent("0").jsonBody, Data("0".utf8))
        XCTAssertEqual(try intent(#""x""#).jsonBody, Data(#""x""#.utf8))
        XCTAssertEqual(try intent("[]").jsonBody, Data("[]".utf8))
        XCTAssertEqual(try intent("{}").jsonBody, Data("{}".utf8))
    }

    func testEmptyStringBodyIsInvalidJSONNotAbsentBody() throws {
        try badIntent("", .malformed)
    }

    func testGetRejectsAnyJSONBody() throws {
        for body in ["null", "{}", #"{"a":1}"#] { try badIntent(body, method: "GET", .malformed) }
    }

    func testJSONBodyMustBeStrictJSONString() throws {
        for bad in ["{", "{'a':1}", #"{"a":1,}"#, "[1,]", "01", "NaN", "Infinity", "undefined", #"{"a":1}{"b":2}"#,
                    #"{"a":1,"a":2}"#, "\u{FEFF}{}", #""\ud800""#] {
            try badIntent(bad, .malformed)
        }
        // Non-string jsonBody values.
        let m = try writeManifest()
        for raw in [#"{"a":1}"#, "null", "1", "[]"] {
            let a = action(headers: "{}", extra: #","jsonBody":\#(raw)"#)
            XCTAssertThrowsError(try PluginOutboundIntent.validating(a, manifest: m)) {
                XCTAssertEqual($0 as? PluginOutboundIntentError, .malformed)
            }
        }
    }

    func testJSONBodyByteCapIsInclusiveAtUTF8Length() throws {
        let ascii = #"{"a":""# + String(repeating: "x", count: 8184) + #""}"#
        XCTAssertEqual(ascii.utf8.count, 8192)
        XCTAssertEqual(try intent(ascii).jsonBody?.count, 8192)
        let over = #"{"a":""# + String(repeating: "x", count: 8185) + #""}"#
        XCTAssertEqual(over.utf8.count, 8193)
        try badIntent(over, .limitExceeded)
        // 4092 two-byte characters: 8192 UTF-8 bytes but only 4092 characters.
        let wide = #"{"a":""# + String(repeating: "\u{e9}", count: 4092) + #""}"#
        XCTAssertEqual(wide.utf8.count, 8192)
        XCTAssertEqual(try intent(wide).jsonBody?.count, 8192)
        let wider = #"{"a":""# + String(repeating: "\u{e9}", count: 4092) + #"x"}"#
        XCTAssertEqual(wider.utf8.count, 8193)
        try badIntent(wider, .limitExceeded)
    }

    func testJSONBodyDepthCapIs16() throws {
        func nested(_ n: Int) -> String { String(repeating: "[", count: n) + String(repeating: "]", count: n) }
        XCTAssertEqual(try intent(nested(16)).jsonBody, Data(nested(16).utf8))
        try badIntent(nested(17), .limitExceeded)
        let obj16 = String(repeating: #"{"a":"#, count: 16) + "1" + String(repeating: "}", count: 16)
        XCTAssertNoThrow(try intent(obj16))
        try badIntent(String(repeating: #"{"a":"#, count: 17) + "1" + String(repeating: "}", count: 17), .limitExceeded)
    }

    func testIntentKeysetIsExactWithOptionalJSONBodyOnly() throws {
        let m = try writeManifest()
        XCTAssertNoThrow(try PluginOutboundIntent.validating(action(headers: "{}"), manifest: m))
        for extra in [#","body":"{}""#, #","json":{}"#, #","method":"POST""#, #","jsonBody":"{}","json":{}"#] {
            XCTAssertThrowsError(try PluginOutboundIntent.validating(action(headers: "{}", extra: extra), manifest: m)) {
                XCTAssertEqual($0 as? PluginOutboundIntentError, .malformed)
            }
        }
    }

    func testBodyDoesNotChangeHeaderValidation() throws {
        let m = try writeManifest()
        let a = action(headers: #"{"authorization":"Bearer abc"}"#, extra: #","jsonBody":"{}""#)
        let i = try PluginOutboundIntent.validating(a, manifest: m)
        XCTAssertEqual(i.headers, ["authorization": "Bearer abc"])
        XCTAssertEqual(i.jsonBody, Data("{}".utf8))
        XCTAssertThrowsError(try PluginOutboundIntent.validating(action(headers: #"{"x-other":"1"}"#, extra: #","jsonBody":"{}""#), manifest: m)) {
            XCTAssertEqual($0 as? PluginOutboundIntentError, .undeclaredHeader)
        }
    }
}

extension PluginOutboundTests {
    func testJSONContentTypeMustAgreeWithNativeFraming() throws {
        let m = try manifest(decl(headers: #"["content-type"]"#, method: "POST"))
        XCTAssertThrowsError(try PluginOutboundIntent.validating(action(headers: #"{"content-type":"text/plain"}"#, extra: #","jsonBody":"{}""#), manifest: m)) {
            XCTAssertEqual($0 as? PluginOutboundIntentError, .invalidHeaderValue)
        }
        let good = try PluginOutboundIntent.validating(action(headers: #"{"content-type":"application/json"}"#, extra: #","jsonBody":"{}""#), manifest: m)
        XCTAssertEqual(good.jsonBody, Data("{}".utf8))
    }
}

extension PluginOutboundTests {
    func testSharedOutboundMethodConformance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/outbound-conformance.json")
        let root = try JSONValue(parsing: Data(contentsOf: url))
        let rows = try XCTUnwrap(root.objectValue?["cases"]?.arrayValue)
        for row in rows {
            let fields = try XCTUnwrap(row.objectValue)
            let outbound = try XCTUnwrap(fields["outbound"]).jsonString()
            guard case .bool(let valid)? = fields["valid"] else { return XCTFail("invalid shared fixture") }
            if valid { accepts(outbound) } else { rejects(outbound) }
        }
    }
}
