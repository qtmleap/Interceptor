import AutomationCore
import Foundation
import XCTest
@testable import AutomationRuntime

final class ManifestFileRoutingTests: XCTestCase, @unchecked Sendable {
    private let file = "hooks/api.example.com/search/POST.js"
    private let script = "Interceptor.attach({request:{onEnter(req,cfg){req.body.limit=5;}}});"

    private func package(_ source: String? = nil, host: String = "api.example.com", phase: String = "onEnter",
                         extraFile: Bool = false) throws -> (Data, Data) {
        var matches: [[String: Any]] = [["hosts": [host], "methods": ["POST"], "path": ["kind": "exact", "value": "/search"],
                                        "hooks": ["request": [phase: file]]]]
        var files = [file: source ?? script]
        if extraFile {
            let other = "hooks/other.example.com/search/POST.js"
            matches.append(["hosts": ["other.example.com"], "methods": ["POST"], "path": ["kind": "exact", "value": "/search"],
                            "hooks": ["request": ["onEnter": other]]])
            files[other] = "throw new Error('nonmatching source must never evaluate');"
        }
        let manifest: [String: Any] = ["schemaVersion": 2, "id": "00000000-0000-4000-8000-000000000001", "name": "Routes", "version": "2.0.0",
            "matches": matches, "read": ["metadata": [], "headers": [], "queryKeys": [], "body": ["mode": "json"]],
            "write": ["requestBody": true, "responseBody": true], "endpointBindings": [], "settings": [:]]
        return (try JSONSerialization.data(withJSONObject: ["manifest": manifest, "sourceFiles": files]),
                try JSONSerialization.data(withJSONObject: manifest))
    }

    private func invoke(_ source: String? = nil, eventHost: String = "api.example.com", manifestHost: String = "api.example.com",
                        hook: JavaScriptHook = .requestEnter, extraFile: Bool = false) async throws -> String {
        let (bytes, _) = try package(source, host: manifestHost, extraFile: extraFile)
        let event = try JSONSerialization.data(withJSONObject: ["request": ["method": "POST", "host": eventHost, "path": "/search", "body": ["limit": 50]]])
        let result = try await JavaScriptExecutor().runV2(packageJSON: bytes, hook: hook,
            eventJSON: event, configJSON: Data("{}".utf8))
        return String(decoding: result, as: UTF8.self)
    }

    func testConditionFreeAttachEditsSelectedJSON() async throws {
        let result = try await invoke()
        XCTAssertEqual(result, #"{"actions":[],"mutation":{"body":{"limit":5}}}"#)
    }

    func testNonmatchingSourcesDoNotEvaluate() async throws {
        let miss = try await invoke("throw new Error('must not load');", eventHost: "none.example.com")
        let hit = try await invoke(extraFile: true)
        XCTAssertEqual(miss, #"{"actions":[]}"#)
        XCTAssertEqual(hit, #"{"actions":[],"mutation":{"body":{"limit":5}}}"#)
    }

    func testChangingOnlyManifestChangesTheTarget() async throws {
        let miss = try await invoke(manifestHost: "other.example.com")
        let hit = try await invoke(eventHost: "other.example.com", manifestHost: "other.example.com")
        XCTAssertEqual(miss, #"{"actions":[]}"#)
        XCTAssertEqual(hit, #"{"actions":[],"mutation":{"body":{"limit":5}}}"#)
    }

    func testManifestWithoutTheInvokedPhaseDoesNotEvaluateSource() async throws {
        let result = try await invoke("throw new Error('wrong phase');", hook: .requestLeave)
        XCTAssertEqual(result, #"{"actions":[]}"#)
    }
}

extension ManifestFileRoutingTests {
    private func editedPackage(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: package().0) as? [String: Any])
        edit(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func result(_ bytes: Data, host: String = "api.example.com", hook: JavaScriptHook = .requestEnter) async throws -> String {
        let event = try JSONSerialization.data(withJSONObject: ["request": ["method": "POST", "host": host, "path": "/search", "body": ["limit": 50]]])
        let bytes = try await JavaScriptExecutor().runV2(packageJSON: bytes, hook: hook, eventJSON: event, configJSON: Data("{}".utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func rejects(_ bytes: Data, error expected: JavaScriptExecutionError = .invalidInput,
                         host: String = "api.example.com", line: UInt = #line) async {
        do { _ = try await result(bytes, host: host); XCTFail("expected \(expected)", line: line) }
        catch { XCTAssertEqual(error as? JavaScriptExecutionError, expected, line: line) }
    }

    func testUnsafeSourcePathsAndUnreferencedFilesAreRejectedOnMiss() async throws {
        for name in ["", "/absolute.js", "../up.js", "a/../b.js", "a//b.js", "a/./b.js", "a\\b.js", "a%20b.js", "é.js", "https://x/a.js", String(repeating: "a", count: 257)] {
            let bytes = try editedPackage { root in
                root["sourceFiles"] = [name: "throw new Error('must not evaluate');"]
                var manifest = root["manifest"] as! [String: Any]
                var routes = manifest["matches"] as! [[String: Any]]
                routes[0]["hooks"] = ["request": ["onEnter": name]]
                manifest["matches"] = routes; root["manifest"] = manifest
            }
            await rejects(bytes, host: "miss.example.com")
        }
        let unreferenced = try editedPackage { root in root["sourceFiles"] = [file: script, "extra.js": ""] }
        await rejects(unreferenced, host: "miss.example.com")
        let missing = try editedPackage { root in root["sourceFiles"] = ["other.js": script] }
        await rejects(missing, host: "miss.example.com")
        let wrongType = try editedPackage { root in root["sourceFiles"] = [file: 42] }
        await rejects(wrongType, host: "miss.example.com")
        let nul = try editedPackage { root in root["sourceFiles"] = [file: "\0"] }
        await rejects(nul, host: "miss.example.com")
    }

    func testFullPackageShapeAndDecodedSourceBudgetAreValidatedOnMiss() async throws {
        await rejects(try editedPackage { $0["source"] = script }, host: "miss.example.com")
        await rejects(try editedPackage { $0["extra"] = 1 }, host: "miss.example.com")
        await rejects(try editedPackage { $0["sourceFiles"] = [:] }, host: "miss.example.com")
        await rejects(try editedPackage { $0["sourceFiles"] = [file: String(repeating: "x", count: 131_073)] }, host: "miss.example.com")
        var oversized = try package().0
        oversized.append(Data(repeating: 0x20, count: 262_145 - oversized.count))
        await rejects(oversized, host: "miss.example.com")
        let malformed = try package("let = ;", extraFile: true).0
        let miss = try await result(malformed, host: "miss.example.com")
        XCTAssertEqual(miss, #"{"actions":[]}"#)
    }

    func testAmbiguousSamePhaseRejectsBeforeEvaluation() async throws {
        let bytes = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            let routes = manifest["matches"] as! [[String: Any]]
            manifest["matches"] = routes + routes
            root["manifest"] = manifest
            root["sourceFiles"] = [file: "throw new Error('must not evaluate');"]
        }
        await rejects(bytes)
    }

    func testRegistrationRequiresExactSelectedFilePhaseUnion() async throws {
        for source in ["", "Interceptor.attach({});", "Interceptor.attach({request:{onLeave(){}}});",
                       "Interceptor.attach({request:{onEnter(){},onLeave(){}}});", "Interceptor.attach({request:{onEnter(){}},response:{onEnter(){}}});"] {
            await rejects(try package(source).0, error: .scriptError)
        }
        let bytes = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            var routes = manifest["matches"] as! [[String: Any]]
            var other = routes[0]
            other["hosts"] = ["other.example.com"]
            other["hooks"] = ["request": ["onLeave": file]]
            routes.append(other); manifest["matches"] = routes; root["manifest"] = manifest
            root["sourceFiles"] = [file: "Interceptor.attach({request:{onEnter(r){r.body.limit=3;},onLeave(){throw new Error('wrong route phase');}}});"]
        }
        let enter = try await result(bytes)
        XCTAssertEqual(enter, #"{"actions":[],"mutation":{"body":{"limit":3}}}"#)
        let leave = try await result(bytes, hook: .requestLeave)
        XCTAssertEqual(leave, #"{"actions":[]}"#)
        let missingUnion = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            var routes = manifest["matches"] as! [[String: Any]]
            routes[0]["hooks"] = ["request": ["onEnter": file, "onLeave": file]]
            manifest["matches"] = routes; root["manifest"] = manifest
        }
        await rejects(missingUnion, error: .scriptError)
    }

    func testDifferentPhaseFilesAndArbitrarySafeFilenamesAreSelectedNatively() async throws {
        let bytes = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            var routes = manifest["matches"] as! [[String: Any]]
            routes[0]["hooks"] = ["request": ["onEnter": "custom/enter.js", "onLeave": "leave-source"]]
            manifest["matches"] = routes; root["manifest"] = manifest
            root["sourceFiles"] = ["custom/enter.js": script, "leave-source": "Interceptor.attach({request:{onLeave(){}}});"]
        }
        let enter = try await result(bytes)
        XCTAssertEqual(enter, #"{"actions":[],"mutation":{"body":{"limit":5}}}"#)
        let leave = try await result(bytes, hook: .requestLeave)
        XCTAssertEqual(leave, #"{"actions":[]}"#)
    }
}

extension ManifestFileRoutingTests {
    func testSixtyFourReferencedFilesAreAcceptedAndSixtyFiveAreRejected() async throws {
        let bytes = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            var routes: [[String: Any]] = []
            var files: [String: String] = [:]
            for index in 0..<16 {
                let prefix = "route\(index)"
                let names = ["\(prefix)-request-enter.js", "\(prefix)-request-leave.js", "\(prefix)-response-enter.js", "\(prefix)-response-leave.js"]
                routes.append(["hosts": [index == 0 ? "api.example.com" : "route\(index).example.com"], "methods": ["POST"], "path": ["kind": "exact", "value": "/search"],
                               "hooks": ["request": ["onEnter": names[0], "onLeave": names[1]], "response": ["onEnter": names[2], "onLeave": names[3]]]])
                for (phase, name) in names.enumerated() {
                    let leg = phase < 2 ? "request" : "response", method = phase % 2 == 0 ? "onEnter" : "onLeave"
                    files[name] = "Interceptor.attach({\(leg):{\(method)(){}}});"
                }
            }
            manifest["matches"] = routes; root["manifest"] = manifest; root["sourceFiles"] = files
        }
        let output = try await result(bytes)
        XCTAssertEqual(output, #"{"actions":[]}"#)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var files = root["sourceFiles"] as! [String: String]
        files["surplus.js"] = ""; root["sourceFiles"] = files
        await rejects(try JSONSerialization.data(withJSONObject: root), host: "miss.example.com")
    }

    func testCanonicalManifestCapIsIndependentOfPackageCap() async throws {
        let bytes = try editedPackage { root in
            var manifest = root["manifest"] as! [String: Any]
            let longFile = String(repeating: "s", count: 253) + ".js"
            manifest["matches"] = (0..<16).map { index in
                ["hosts": ["api.example.com"], "methods": ["POST"], "path": ["kind": "exact", "value": "/" + String(repeating: "p", count: 1020) + String(index)],
                 "hooks": ["request": ["onEnter": longFile, "onLeave": longFile], "response": ["onEnter": longFile, "onLeave": longFile]]] as [String: Any]
            }
            root["manifest"] = manifest; root["sourceFiles"] = [longFile: script]
        }
        XCTAssertLessThan(bytes.count, JavaScriptLimits.maxPackageBytes)
        await rejects(bytes, host: "miss.example.com")
    }
}
