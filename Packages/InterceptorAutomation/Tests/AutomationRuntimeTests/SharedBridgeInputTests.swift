import AutomationRuntime
import CQuickJS
import Foundation
import XCTest

/// Exercise the exported C boundary directly, without Swift's strict-JSON preflight.
final class SharedBridgeInputTests: XCTestCase {
    private func run(body: String) throws -> Int32 {
        let token = try XCTUnwrap(qjs_cancel_token_new())
        defer { qjs_cancel_token_free(token) }
        var limits = QJSLimits(deadline_ms: 50, heap_bytes: 8 * 1024 * 1024, stack_bytes: 256 * 1024,
                               max_source_bytes: 131_072, max_event_bytes: 65_536, max_config_bytes: 8_192,
                               max_result_bytes: 32_768, max_result_depth: 32, max_actions: 2)
        let source = Data("Interceptor.attach({hosts:['api.example.com']},{request:{onEnter(r){r.body.x=2;}}});".utf8)
        let event = Data("{\"request\":{\"method\":\"POST\",\"host\":\"api.example.com\",\"path\":\"/search\",\"body\":\(body)}}".utf8)
        let config = Data("{}".utf8)
        let manifest = Data(#"{"schemaVersion":2,"id":"00000000-0000-4000-8000-000000000001","name":"Numbers","version":"1.0.0","matches":[{"hosts":["api.example.com"]}],"read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":{"requestBody":true,"responseBody":false},"endpointBindings":[],"settings":{}}"#.utf8)
        var result = source.withUnsafeBytes { src in
            event.withUnsafeBytes { ev in
                config.withUnsafeBytes { cfg in
                    manifest.withUnsafeBytes { man in
                        "request.onEnter".withCString { phase in
                            qjs_run_v2(token, &limits, src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count,
                                       phase, ev.baseAddress?.assumingMemoryBound(to: UInt8.self), ev.count,
                                       cfg.baseAddress?.assumingMemoryBound(to: UInt8.self), cfg.count,
                                       man.baseAddress?.assumingMemoryBound(to: UInt8.self), man.count)
                        }
                    }
                }
            }
        }
        defer { qjs_result_free(&result) }
        return result.status
    }

    func testUnsafeIntegerTokensCannotBeRoundedDuringAnUnrelatedMutation() throws {
        for number in ["9007199254740992", "-9007199254740992", "12345678901234567890"] {
            XCTAssertEqual(try run(body: "{\"id\":\(number),\"x\":1}"), Int32(QJS_INVALID_INPUT), number)
        }
        for number in ["9007199254740991", "-9007199254740991", "1.25"] {
            XCTAssertEqual(try run(body: "{\"id\":\(number),\"x\":1}"), Int32(QJS_OK), number)
        }
        XCTAssertEqual(try run(body: #"{"id":"12345678901234567890","x":1}"#), Int32(QJS_OK))
    }
}
