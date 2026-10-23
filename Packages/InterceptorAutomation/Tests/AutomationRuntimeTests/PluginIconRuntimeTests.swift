import AutomationCore
@testable import AutomationRuntime
import Foundation
import XCTest

/// The VM independently admits package metadata before evaluating code. Decorative assets must not
/// disable any lifecycle hook or fetch/createFile, and must never enter the source-file map.
final class PluginIconRuntimeTests: XCTestCase, @unchecked Sendable {
    private let sourcePath = "hooks/api.example.com/search/POST.js"
    private let iconBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAEElEQVR4AQEFAPr/AAAAAAAABQABZHiVOAAAAABJRU5ErkJggg=="
    private let event = Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search","headers":{},"query":{},"body":{"limit":50,"query":"x"}},"response":{"status":200,"headers":{},"body":{"ok":true}}}"#.utf8)
    private let config = Data(#"{"endpoints":{"preview":"5E1D0C4A-0000-4000-8000-00000000A001"}}"#.utf8)

    func testSDKIconPackageExecutesAllFourHooksWithoutChangingBehavior() async throws {
        let baseline = Data(sdkIconRuntimeBaseline.utf8)
        let decorated = try package()
        _ = try PluginPackage.validate(decorated)
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .responseLeave] {
            let expected = try await run(baseline, hook: hook)
            let actual = try await run(decorated, hook: hook)
            XCTAssertEqual(try JSONValue(parsing: actual), try JSONValue(parsing: expected), hook.rawValue)
            if hook == .requestEnter {
                let result = try XCTUnwrap(JSONSerialization.jsonObject(with: actual) as? [String: Any])
                let mutation = try XCTUnwrap(result["mutation"] as? [String: Any])
                XCTAssertEqual((mutation["body"] as? [String: Any])?["limit"] as? Int, 5)
            }
        }
    }

    func testIconPackageCanFetchAndCreateFileFromResponseLeave() async throws {
        let bytes = Data("{\"results\":[1]}".utf8)
        let recorder = Recorder()
        let source = """
        Interceptor.attach({response:{async onLeave(){
          const response = await fetch('https://api.example.com/history', {method:'POST', body:'{}'});
          await Interceptor.createFile({storage:Interceptor.Storage.iCloudDrive,
            atPath:'Salmon Run/history.json',contents:await response.text()});
        }}});
        """
        let input = try package { object, manifest in
            manifest["write"] = ["requestBody": false, "responseBody": false, "files": true]
            var routes = manifest["matches"] as! [[String: Any]]
            routes[0]["hooks"] = ["response": ["onLeave": self.sourcePath]]
            manifest["matches"] = routes
            object["sourceFiles"] = [self.sourcePath: source]
        }
        _ = try PluginPackage.validate(input)
        let result = try await JavaScriptFetchExecutor().runV2(
            packageJSON: input, hook: .responseLeave, eventJSON: event, configJSON: config,
            createFile: { destination, contents in await recorder.write(destination, contents) },
            transport: { request in
                await recorder.fetch(request)
                return JavaScriptFetchResponse(status: 200, body: bytes)
            })
        XCTAssertEqual(try JSONValue(parsing: result), .object(["actions": .array([])]))
        let state = await recorder.snapshot()
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(state.requests.first?.url, "https://api.example.com/history")
        XCTAssertEqual(state.requests.first?.method, "POST")
        XCTAssertEqual(state.files.count, 1)
        XCTAssertEqual(state.files.first?.0.storage, .icloud)
        XCTAssertEqual(state.files.first?.0.atPath, "Salmon Run/history.json")
        XCTAssertEqual(state.files.first?.1, bytes)
    }

    func testMalformedAssetPairsAreRejectedBeforeBothRuntimeEntryPoints() async throws {
        let edits: [(inout [String: Any], inout [String: Any]) -> Void] = [
            { object, _ in object.removeValue(forKey: "assets") },
            { _, manifest in manifest.removeValue(forKey: "icon") },
            { object, _ in object["assets"] = [:] as [String: String] },
            { object, _ in object["assets"] = NSNull() },
            { object, _ in object["assets"] = ["other.png": self.iconBase64] },
            { object, _ in object["assets"] = ["icon.png": self.iconBase64, "extra.png": self.iconBase64] },
            { object, _ in object["assets"] = ["icon.png": 1] },
            { _, manifest in manifest["icon"] = NSNull() },
            { object, manifest in manifest["icon"] = "../icon.png"; object["assets"] = ["../icon.png": self.iconBase64] },
            { object, manifest in manifest["icon"] = "icon.PNG"; object["assets"] = ["icon.PNG": self.iconBase64] },
            { object, _ in object["assets"] = ["icon.png": "AB=="] },
            { object, _ in object["assets"] = ["icon.png": "AA"] },
            { object, _ in object["assets"] = ["icon.png": self.iconBase64 + "\n"] },
            { object, _ in object["assets"] = ["icon.png": ""] },
            { object, _ in object["assets"] = ["icon.png": Data(repeating: 0, count: 65_537).base64EncodedString()] },
            { object, manifest in
                let files = object["sourceFiles"] as! [String: String]
                object["sourceFiles"] = ["icon.png": files[self.sourcePath]!]
                var routes = manifest["matches"] as! [[String: Any]]
                routes[0]["hooks"] = ["request": ["onEnter": "icon.png"]]
                manifest["matches"] = routes
            }
        ]
        for (index, edit) in edits.enumerated() {
            let input = try package(edit)
            do { _ = try await run(input); XCTFail("sync accepted malformed asset case \(index)") }
            catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput, "sync case \(index)") }
            do {
                _ = try await JavaScriptFetchExecutor().runV2(
                    packageJSON: input, hook: .responseLeave, eventJSON: event, configJSON: config,
                    createFile: { _, _ in XCTFail("invalid package reached file callback") },
                    transport: { _ in
                        XCTFail("invalid package reached transport")
                        return JavaScriptFetchResponse(status: 200, body: Data())
                    })
                XCTFail("fetch accepted malformed asset case \(index)")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput, "fetch case \(index)") }
        }
    }

    private func package(_ edit: ((inout [String: Any], inout [String: Any]) -> Void)? = nil) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sdkIconRuntimeBaseline.utf8)) as? [String: Any])
        var manifest = object["manifest"] as! [String: Any]
        manifest["icon"] = "icon.png"
        object["assets"] = ["icon.png": iconBase64]
        edit?(&object, &manifest)
        object["manifest"] = manifest
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    private func run(_ input: Data, hook: JavaScriptHook = .requestEnter) async throws -> Data {
        try await JavaScriptExecutor().runV2(packageJSON: input, hook: hook, eventJSON: event, configJSON: config)
    }

    private actor Recorder {
        var requests: [JavaScriptFetchRequest] = []
        var files: [(PluginFileDestination, Data)] = []
        func fetch(_ request: JavaScriptFetchRequest) { requests.append(request) }
        func write(_ destination: PluginFileDestination, _ contents: Data) { files.append((destination, contents)) }
        func snapshot() -> (requests: [JavaScriptFetchRequest], files: [(PluginFileDestination, Data)]) { (requests, files) }
    }
}

// Exact SDK baseline package from the icon/runtime integration repro, kept self-contained for CI.
private let sdkIconRuntimeBaseline = #"""
{"manifest":{"endpointBindings":["preview"],"id":"76532D8C-608A-4EA3-AC16-755BABF2AB7E","matches":[{"hooks":{"request":{"onEnter":"hooks/api.example.com/search/POST.js","onLeave":"hooks/api.example.com/search/POST.js"},"response":{"onEnter":"hooks/api.example.com/search/POST.js","onLeave":"hooks/api.example.com/search/POST.js"}},"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"}}],"name":"Request summary","read":{"body":{"mode":"json"},"headers":[],"metadata":["method","host","path","status"],"queryKeys":[]},"schemaVersion":2,"settings":{},"version":"2.0.0","write":{"requestBody":true,"responseBody":true}},"sourceFiles":{"hooks/api.example.com/search/POST.js":"\"use strict\";\nInterceptor.attach({\n    request: {\n        onEnter(req, cfg) {\n            if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body))\n                return;\n            req.body.limit = 5;\n        },\n        onLeave(req, cfg) {\n            const endpointId = cfg.endpoints?.preview;\n            if (!endpointId)\n                return;\n            return { actions: [{ type: 'webhook', endpointId,\n                        json: { summary: req.method + ' ' + req.host + req.path } }] };\n        }\n    },\n    response: {\n        onEnter(res, cfg) {\n            if (!res.body || typeof res.body !== 'object' || Array.isArray(res.body))\n                return;\n            res.body.maintenance = true;\n        },\n        onLeave(res, cfg) {\n            const endpointId = cfg.endpoints?.preview;\n            if (!endpointId)\n                return;\n            return { actions: [{ type: 'webhook', endpointId,\n                        json: { path: res.request.path, status: res.status } }] };\n        }\n    }\n});\n"}}
"""#
