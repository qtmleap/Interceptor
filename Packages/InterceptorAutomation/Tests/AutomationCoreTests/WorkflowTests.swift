import XCTest
@testable import AutomationCore

final class WorkflowTests: XCTestCase {
    func testV2ManifestRequiresWorkflowAndPreservesV1() throws {
        XCTAssertThrowsError(try PluginPackage.validate(packageBytes(manifest: manifestJSON(schema: "2"))))
        let workflow = #",\"workflow\":{\"endpointBinding\":\"alert\",\"sameOrigin\":{\"methods\":[\"GET\"],\"paths\":[{\"kind\":\"prefix\",\"value\":\"/api\"}],\"inheritHeaders\":{\"mode\":\"allEndToEnd\"}},\"responseRead\":{\"metadata\":[\"status\"],\"headers\":[],\"queryKeys\":[],\"body\":{\"mode\":\"none\"}}}"#.replacingOccurrences(of: "\\\"", with: "\"")
        let package = try PluginPackage.validate(packageBytes(manifest: manifestJSON(extra: workflow, schema: "2")))
        XCTAssertEqual(package.manifest.schemaVersion, 2)
        XCTAssertEqual(package.manifest.workflow?.endpointBinding, "alert")
        XCTAssertEqual(try PluginPackage.validate(packageBytes()).manifest.schemaVersion, 1)
        XCTAssertThrowsError(try PluginPackage.validate(packageBytes(manifest: manifestJSON(extra: workflow))))
    }

    func testCanonicalPathAndBoundaryMatching() throws {
        XCTAssertEqual(try WorkflowPath.canonicalize("/api/%61/%c3%a9/"), "/api/a/%C3%A9/")
        for path in ["//host", "/a//b", "/a/../b", "/%2e", "/%2f", "/%5c", "/%25", "/%C0%AF", "/%FF", "/a?q=1", "/a#b", "/a\\b"] {
            XCTAssertThrowsError(try WorkflowPath.canonicalize(path), path)
        }
        let scope = try WorkflowPathScope(kind: .prefix, value: "/api")
        XCTAssertTrue(scope.matches("/api/account")); XCTAssertTrue(scope.matches("/api"))
        XCTAssertFalse(scope.matches("/apix"))
        XCTAssertFalse(try WorkflowPathScope(kind: .prefix, value: "/api/").matches("/api"))
    }

    func testStrictPlanningIntentAndMaximumRawBody() throws {
        let bytes = Data(repeating: 1, count: 32 * 1024)
        let json = JSONValue.object(["actions": .array([.object(["type": .string("sameOrigin"), "method": .string("POST"), "path": .string("/api/%61"), "body": .object(["mode": .string("raw"), "base64": .string(bytes.base64EncodedString()), "contentType": .string("application/octet-stream")])])])])
        let result = try WorkflowPlanningResult(parsing: json.data())
        XCTAssertEqual(result.intent?.path, "/api/a")
        XCTAssertEqual(result.intent?.wireBody, bytes)
        for text in [#"{"actions":[{"type":"sameOrigin","method":"GET","path":"/","body":{"mode":"json","value":null}}]}"#, #"{"actions":[{"type":"sameOrigin","method":"TRACE","path":"/"}]}"#, #"{"actions":[{"type":"sameOrigin","method":"GET","path":"/","url":"https://evil"}]}"#] {
            XCTAssertThrowsError(try WorkflowPlanningResult(parsing: Data(text.utf8)))
        }
        let pairs = #"{"actions":[{"type":"sameOrigin","method":"GET","path":"/","query":[{"name":"a&b","value":"=/%"},{"name":"flag","value":null}]}]}"#
        XCTAssertEqual(try WorkflowPlanningResult(parsing: Data(pairs.utf8)).intent?.encodedQuery, "a%26b=%3D%2F%25&flag")
    }
}

extension WorkflowTests {
    func testHeaderPolicyPreservesOrderAndRegeneratesBodyFields() throws {
        let authority = try WorkflowAuthority(host: "api.example.com", port: 443)
        let fields = [WorkflowHeaderField(name: "Host", value: "api.example.com"), .init(name: "Connection", value: "X-Hop"), .init(name: "X-Hop", value: "secret"), .init(name: "Authorization", value: "Bearer native"), .init(name: "Content-Encoding", value: "gzip"), .init(name: "Digest", value: "old"), .init(name: "Idempotency-Key", value: "old"), .init(name: "X-Order", value: "1"), .init(name: "X-Order", value: "2")]
        let inherited = try WorkflowHeaderPolicy.inherit(original: fields, authority: authority, declaration: .allEndToEnd, grant: .allEndToEnd, body: .raw(Data([1]), contentType: "application/octet-stream"))
        XCTAssertEqual(inherited.map(\.name), ["Authorization", "X-Order", "X-Order", "Host", "Content-Type"])
        XCTAssertEqual(inherited.map(\.value), ["Bearer native", "1", "2", "api.example.com", "application/octet-stream"])
        XCTAssertThrowsError(try WorkflowHeaderPolicy.inherit(original: fields + [.init(name: "Authorization", value: "other")], authority: authority, declaration: .allEndToEnd, grant: .allEndToEnd, body: nil))
        XCTAssertThrowsError(try WorkflowHeaderPolicy.inherit(original: fields + [.init(name: "Connection", value: "a,,b")], authority: authority, declaration: .names([]), grant: .names([]), body: nil))
    }
    func testProjectionOmitsUnreadFieldsAndDistinguishesMissingNullAndInvalidJSON() throws {
        let read = try PluginManifest.readDeclaration(StrictJSON.parse(Data(#"{"metadata":["status"],"headers":["x-ok"],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["/data","/missing","/nil"]}}"#.utf8)))
        let projection = try WorkflowProjection.project(metadata: ["status": .integer(401), "host": .string("secret")], headers: [.init(name: "X-Ok", value: "1"), .init(name: "Authorization", value: "secret"), .init(name: "x-ok", value: "2")], query: [], body: .complete(Data(#"{"data":1,"nil":null}"#.utf8)), read: read, headersEnabled: true)
        let text = String(decoding: try projection.data(), as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertTrue(text.contains("\"found\":false")); XCTAssertTrue(text.contains("\"value\":null"))
        let invalid = try WorkflowProjection.project(metadata: [:], headers: [], query: [], body: .complete(Data("{".utf8)), read: read, headersEnabled: true)
        XCTAssertEqual(invalid, .object(["headers": .array([]), "body": .object(["state": .string("unavailable"), "reason": .string("invalidJSON")])]))
    }
}

extension WorkflowTests {
    func testLocalOnlyManifestStrictScopesAndSingleBinding() throws {
        let workflow = #",\"workflow\":{\"sameOrigin\":{\"methods\":[\"GET\"],\"paths\":[{\"kind\":\"exact\",\"value\":\"/api\"}],\"inheritHeaders\":{\"mode\":\"names\",\"names\":[]}},\"responseRead\":{\"metadata\":[],\"headers\":[],\"queryKeys\":[],\"body\":{\"mode\":\"none\"}}}"#.replacingOccurrences(of: "\\\"", with: "\"")
        XCTAssertNil(try PluginPackage.validate(packageBytes(manifest: manifestJSON(bindings: "[]", extra: workflow, schema: "2"))).manifest.workflow?.endpointBinding)
        XCTAssertThrowsError(try PluginPackage.validate(packageBytes(manifest: manifestJSON(extra: workflow, schema: "2"))))
        for changed in [workflow.replacingOccurrences(of: #""methods":["GET"]"#, with: #""methods":["TRACE"]"#), workflow.replacingOccurrences(of: #""methods":["GET"]"#, with: #""methods":["GET","GET"]"#), workflow.replacingOccurrences(of: #""names":[]"#, with: #""names":["Cookie","cookie"]"#), workflow.replacingOccurrences(of: #""metadata":[]"#, with: #""metadata":["host"]"#)] {
            XCTAssertThrowsError(try PluginPackage.validate(packageBytes(manifest: manifestJSON(bindings: "[]", extra: changed, schema: "2"))))
        }
    }
    func testBodyAndContinuationComponentLimits() throws {
        func result(_ body: JSONValue, continuation: JSONValue? = nil) throws -> Data {
            var action: [String: JSONValue] = ["type": .string("sameOrigin"), "method": .string("POST"), "path": .string("/"), "body": body]
            action["continuation"] = continuation
            return try JSONValue.object(["actions": .array([.object(action)])]).data()
        }
        for bytes in [32767, 32768, 32769] {
            let json: JSONValue = .object(["mode": .string("raw"), "base64": .string(Data(repeating: 0, count: bytes).base64EncodedString()), "contentType": .string("text/plain; charset=utf-8")])
            if bytes <= 32768 { XCTAssertEqual(try WorkflowPlanningResult(parsing: result(json)).intent?.wireBody?.count, bytes) }
            else { XCTAssertThrowsError(try WorkflowPlanningResult(parsing: result(json))) }
        }
        for invalid in ["AB==", "YQ", "YQ==\n", "YQ-_"] {
            XCTAssertThrowsError(try WorkflowPlanningResult(parsing: result(.object(["mode": .string("raw"), "base64": .string(invalid), "contentType": .string("text/plain")]))))
        }
        for contentType in ["text/plain\r\nx: evil", "text/plain; broken", "text", "text/plain; a=\"unterminated"] {
            XCTAssertThrowsError(try WorkflowPlanningResult(parsing: result(.object(["mode": .string("raw"), "base64": .string(""), "contentType": .string(contentType)]))))
        }
        for size in [8191, 8192, 8193] {
            let continuation: JSONValue = .object(["a": .string(String(repeating: "a", count: size - 8))])
            XCTAssertEqual(try continuation.data().count, size)
            if size <= 8192 { _ = try WorkflowPlanningResult(parsing: result(.object(["mode": .string("json"), "value": .null]), continuation: continuation)) }
            else { XCTAssertThrowsError(try WorkflowPlanningResult(parsing: result(.object(["mode": .string("json"), "value": .null]), continuation: continuation))) }
        }
    }
    func testStrictResultInputWithBothMaximumRawProjectionsAndEndpointPolicy() throws {
        let raw: JSONValue = .object(["state": .string("complete"), "mode": .string("raw"), "base64": .string(Data(repeating: 0, count: 32768).base64EncodedString())])
        let input: JSONValue = .object(["operationID": .string(pluginID.uuidString), "eventID": .string(pluginID.uuidString), "exchangeID": .string(repoID.uuidString), "phase": .string("http.result"), "time": .string("2026-10-18T10:00:00Z"), "request": .object(["body": raw]), "response": .object(["status": .integer(500), "body": raw])])
        try WorkflowInput.validate(input.data(), httpResult: true)
        XCTAssertGreaterThan(try input.data().count, 65536)
        XCTAssertNil(try WorkflowResult(parsing: Data(#"{"actions":[]}"#.utf8), endpointID: nil).delivery)
        let action = Data("{\"actions\":[{\"type\":\"webhook\",\"endpointId\":\"\(pluginID.uuidString)\",\"json\":null}]}".utf8)
        XCTAssertThrowsError(try WorkflowResult(parsing: action, endpointID: nil))
        XCTAssertThrowsError(try WorkflowResult(parsing: action, endpointID: repoID))
        XCTAssertEqual(try WorkflowResult(parsing: action, endpointID: pluginID).delivery?.payloadBytes, Data("null".utf8))
        for config in [#"{}"#, #"{"settings":{},"endpoints":{},"headers":{}}"#, #"{"settings":[],"endpoints":{}}"#, #"{"settings":{},"settings":{},"endpoints":{}}"#] { XCTAssertThrowsError(try WorkflowInput.validateConfig(Data(config.utf8))) }
    }
}


extension WorkflowTests {
    func testHeadersDefaultOffForAllProjectionsWithoutChangingBodiesOrNativeInheritance() throws {
        let read = try PluginManifest.readDeclaration(StrictJSON.parse(Data(#"{"metadata":["method","status"],"headers":["x-approved"],"queryKeys":[],"body":{"mode":"raw"}}"#.utf8)))
        let fields: [WorkflowHeaderField] = [.init(name: "Host", value: "api.example.com"), .init(name: "X-Approved", value: "visible only on consent"), .init(name: "Authorization", value: "native secret")]
        for metadata: [String: JSONValue] in [["method": .string("POST")], ["status": .integer(200)]] {
            let off = try WorkflowProjection.project(metadata: metadata, headers: fields, query: [], body: .complete(Data("body".utf8)), read: read)
            let on = try WorkflowProjection.project(metadata: metadata, headers: fields, query: [], body: .complete(Data("body".utf8)), read: read, headersEnabled: true)
            guard case .object(let offFields) = off, case .object(let onFields) = on else { return XCTFail("object projection") }
            XCTAssertNil(offFields["headers"])
            XCTAssertEqual(onFields["headers"], .array([.object(["name": .string("x-approved"), "value": .string("visible only on consent")])]))
            XCTAssertEqual(offFields["body"], onFields["body"])
        }
        let native = try WorkflowHeaderPolicy.inherit(original: fields, authority: WorkflowAuthority(host: "api.example.com"), declaration: .names(["authorization"]), grant: .names(["authorization"]), body: nil)
        XCTAssertEqual(native.first, .init(name: "Authorization", value: "native secret"))
    }
}
