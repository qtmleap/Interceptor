import XCTest
@testable import AutomationCore

/// Schema 2 (four HTTP lifecycle hooks) manifest validation through the existing PluginPackage.validate entry.
final class HTTPHooksManifestTests: XCTestCase {
    private static let match = #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"selected.js"}}}"#
    private static let read = #"{"metadata":["method","host"],"headers":["x-a"],"queryKeys":["q"],"body":{"mode":"json"}}"#
    private static let write = #"{"requestBody":true,"responseBody":false}"#

    private func v2(matches: String = "[\(match)]", read: String = read, write: String = write, bindings: String = #"["alert"]"#, extra: String = "", schema: String = "2",
                    omit: String? = nil) -> Data {
        var fields = [
            #""schemaVersion":\#(schema)"#, #""id":"\#(pluginID)""#, #""name":"Hook""#, #""version":"1.0.0""#,
            #""matches":\#(matches)"#, #""read":\#(read)"#, #""write":\#(write)"#, #""settings":{}"#, #""endpointBindings":\#(bindings)"#,
        ]
        if let omit { fields.removeAll { $0.hasPrefix(#""\#(omit)""#) } }
        let manifest = "{" + fields.joined(separator: ",") + extra + "}"
        return Data(#"{"manifest":\#(manifest),"sourceFiles":{"selected.js":"Interceptor.attach({request:{onEnter(){}}});"}}"#.utf8)
    }

    private func accepts(_ data: Data, line: UInt = #line) {
        XCTAssertNoThrow(try PluginPackage.validate(data), line: line)
    }
    private func rejects(_ data: Data, line: UInt = #line) {
        assertThrows(.invalidManifest, try PluginPackage.validate(data), line: line)
    }

    func testSchemaTwoManifestIsAccepted() throws {
        let p = try PluginPackage.validate(v2())
        XCTAssertEqual(p.manifest.json.objectValue?["schemaVersion"], .integer(2))
        XCTAssertEqual(p.manifest.json.objectValue?["write"]?.objectValue?["requestBody"], .bool(true))
    }

    func testMatchesBoundsAndShape() {
        accepts(v2(matches: "[\(Self.match)]"))
        accepts(v2(matches: "[" + Array(repeating: Self.match, count: 16).joined(separator: ",") + "]"))
        rejects(v2(matches: "[]"))
        rejects(v2(matches: "[" + Array(repeating: #"{"hosts":["a.com"]}"#, count: 17).joined(separator: ",") + "]"))
        rejects(v2(matches: #"[{"hosts":["A.com"]}]"#))
        rejects(v2(matches: #"[{"hosts":["a.com"],"methods":["post"]}]"#))
        rejects(v2(matches: #"[{"hosts":["a.com"],"path":{"kind":"glob","value":"/*"}}]"#))
        rejects(v2(matches: #"[{"hosts":["a.com"],"bogus":1}]"#))
        rejects(v2(matches: #"[{"hosts":["a.com"],"status":{"min":200,"max":299}}]"#))
        rejects(v2(matches: #"[{"hosts":["a.com"],"status":{"min":300,"max":200}}]"#))
    }

    func testWriteDeclarationIsStrict() {
        accepts(v2(write: #"{"requestBody":false,"responseBody":true}"#))
        rejects(v2(write: #"{"requestBody":true}"#))
        rejects(v2(write: #"{"requestBody":true,"responseBody":false,"headers":true}"#))
        rejects(v2(write: #"{"requestBody":"yes","responseBody":false}"#))
        rejects(v2(omit: "write"))
    }

    func testReadBodyModesAreNoneOrJSONOnly() {
        accepts(v2(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}}"#))
        rejects(v2(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"raw"}}"#))
        rejects(v2(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["/a"]}}"#))
        rejects(v2(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"json","pointers":["/a"]}}"#))
    }

    func testV2RequiresBoundedEndpointBindingsAndHasNoSubscriptions() {
        accepts(v2(bindings: "[]"))
        accepts(v2(bindings: #"["a","b","c","d"]"#))
        rejects(v2(bindings: #"["a","b","c","d","e"]"#))
        rejects(v2(bindings: #"["a","a"]"#))
        rejects(v2(bindings: #"["1bad"]"#))
        rejects(v2(omit: "endpointBindings"))
        rejects(v2(extra: #","subscriptions":[{"phase":"request.completed","match":{"hosts":["a.com"]}}]"#))
        rejects(v2(omit: "matches"))
        rejects(v2(omit: "read"))
        rejects(v2(omit: "settings"))
        rejects(v2(extra: #","bogus":1"#))
    }

    func testV2PublicManifestAPIAndExactRouting() throws {
        let m = try PluginPackage.validate(v2(write: #"{"requestBody":true,"responseBody":true}"#)).manifest
        XCTAssertEqual(m.schemaVersion, 2)
        XCTAssertTrue(m.writeRequestBody)
        XCTAssertTrue(m.writeResponseBody)
        XCTAssertTrue(m.subscriptions.isEmpty)
        XCTAssertEqual(m.read.body, .json)
        XCTAssertEqual(m.endpointBindings, ["alert"])
        let match = try XCTUnwrap(m.matches.first)
        XCTAssertEqual(match.hosts, ["api.example.com"])
        XCTAssertEqual(match.methods, ["POST"])
        XCTAssertEqual(match.path, .exact("/search"))
        XCTAssertNil(match.status)
        XCTAssertEqual(match.hooks, ["request.onEnter": "selected.js"])
        XCTAssertTrue(match.matches(method: "POST", host: "api.example.com", path: "/search", status: nil))
        XCTAssertFalse(match.matches(method: "POST", host: "api.example.com", path: "/search/", status: nil))
        XCTAssertFalse(match.matches(method: "POST", host: "API.example.com", path: "/search", status: nil))
        XCTAssertFalse(match.matches(method: "GET", host: "api.example.com", path: "/search", status: 200))
        XCTAssertFalse(match.matches(method: "POST", host: "b.example.com", path: "/search", status: 200))
    }

    func testV2RequiresExactHostMethodPathAndHooks() {
        for omitted in ["hosts", "methods", "path", "hooks"] {
            var route = try! JSONSerialization.jsonObject(with: Data(Self.match.utf8)) as! [String: Any]
            route[omitted] = nil
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: [route]), as: UTF8.self)
            rejects(v2(matches: json))
        }
        rejects(v2(matches: "[" + Self.match.replacingOccurrences(of: "exact", with: "prefix") + "]"))
        rejects(v2(matches: "[" + Self.match.replacingOccurrences(of: #"["POST"]"#, with: #"["POST","GET"]"#) + "]"))
        rejects(v2(matches: "[" + Self.match.replacingOccurrences(of: #"["api.example.com"]"#, with: #"["api.example.com","b.com"]"#) + "]"))
    }

    func testV1ManifestHasNoMatchesOrWrites() throws {
        let m = try PluginPackage.validate(packageBytes()).manifest
        XCTAssertEqual(m.schemaVersion, 1)
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertFalse(m.writeRequestBody)
        XCTAssertFalse(m.writeResponseBody)
    }

    func testV2AcceptsOptionalDisplayFields() {
        accepts(v2(extra: #","author":"Example","summary":"Limits results.""#))
        rejects(v2(extra: #","author":"""#))
    }

    func testV1PackagesStillParseUnchanged() throws {
        let p = try PluginPackage.validate(packageBytes())
        XCTAssertEqual(p.manifest.subscriptions.count, 1)
        rejects(v2(schema: "3"))
        rejects(v2(schema: "1"))
    }
}
