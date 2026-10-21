import AutomationRuntime
import CQuickJS
import Foundation
import XCTest

/// Exercise the exported C manifest validator for the optional `publishedAt` key directly.
final class PublicationDateBridgeTests: XCTestCase {
    private static let source = "Interceptor.attach({request:{onEnter(r){r.body.x=2;}}});"

    /// Raw manifest JSON with `extra` appended as a final member (raw text, so NUL/duplicates are testable).
    private func manifest(extra: String) -> String {
        let tail = extra.isEmpty ? "" : ",\(extra)"
        return #"{"schemaVersion":2,"id":"00000000-0000-4000-8000-000000000001","name":"Dated","version":"1.0.0","matches":[{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"selected.js"}}}],"read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"json"}},"write":{"requestBody":true,"responseBody":false},"endpointBindings":[],"settings":{}"# + tail + "}"
    }

    private func run(extra: String) throws -> Int32 {
        let token = try XCTUnwrap(qjs_cancel_token_new())
        defer { qjs_cancel_token_free(token) }
        var limits = QJSLimits(deadline_ms: 50, heap_bytes: 8 * 1024 * 1024, stack_bytes: 256 * 1024,
                               max_source_bytes: 131_072, max_event_bytes: 65_536, max_config_bytes: 8_192,
                               max_result_bytes: 32_768, max_result_depth: 32, max_actions: 2)
        let event = Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search","body":{"x":1}}}"#.utf8)
        let config = Data("{}".utf8)
        let package = Data(("{\"manifest\":" + manifest(extra: extra) + ",\"sourceFiles\":{\"selected.js\":\"" + Self.source + "\"}}").utf8)
        var result = package.withUnsafeBytes { src in
            event.withUnsafeBytes { ev in
                config.withUnsafeBytes { cfg in
                    "request.onEnter".withCString { phase in
                        qjs_run_v2(token, &limits, src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count,
                                   phase, ev.baseAddress?.assumingMemoryBound(to: UInt8.self), ev.count,
                                   cfg.baseAddress?.assumingMemoryBound(to: UInt8.self), cfg.count)
                    }
                }
            }
        }
        defer { qjs_result_free(&result) }
        return result.status
    }

    private func date(_ value: String) throws -> Int32 {
        try run(extra: "\"publishedAt\":\"\(value)\"")
    }

    func testAbsentAndValidDatesAreAccepted() throws {
        XCTAssertEqual(try run(extra: ""), Int32(QJS_OK))
        for value in ["2024-02-29T00:00:00Z", "2000-02-29T12:34:56Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z"] {
            XCTAssertEqual(try date(value), Int32(QJS_OK), value)
        }
    }

    func testInvalidCalendarValuesAreRejected() throws {
        for value in ["1900-02-29T00:00:00Z", "2023-02-29T00:00:00Z", "0000-01-01T00:00:00Z",
                      "2024-13-01T00:00:00Z", "2024-00-01T00:00:00Z", "2024-04-31T00:00:00Z", "2024-01-00T00:00:00Z",
                      "2024-01-01T24:00:00Z", "2024-01-01T00:60:00Z", "2024-01-01T23:59:60Z"]
        {
            XCTAssertEqual(try date(value), Int32(QJS_INVALID_INPUT), value)
        }
    }

    func testMalformedTextIsRejected() throws {
        for value in ["2024-01-01", "2024-01-01 00:00:00Z", "2024-01-01T00:00:00z", "2024-01-01t00:00:00Z",
                      "2024-01-01T00:00:00.000Z", "2024-01-01T00:00:00+00:00", "2024-01-01T00:00:00",
                      " 2024-01-01T00:00:00Z", "2024-01-01T00:00:00Z ", "2024-01-01T00:00:00Z\\n",
                      "２０２４-01-01T00:00:00Z", "2024-01-01T00:00:0\\u00e9Z", "+024-01-01T00:00:00Z", ""]
        {
            XCTAssertEqual(try date(value), Int32(QJS_INVALID_INPUT), value)
        }
    }

    func testEmbeddedNulWrongTypeAndUnknownKeyAreRejected() throws {
        XCTAssertEqual(try date("2024-01-01T00:00:0\\u00000Z"), Int32(QJS_INVALID_INPUT))
        for raw in ["null", "1", "true", "[]", "{}", "[\"2024-01-01T00:00:00Z\"]"] {
            XCTAssertEqual(try run(extra: "\"publishedAt\":\(raw)"), Int32(QJS_INVALID_INPUT), raw)
        }
        XCTAssertEqual(try run(extra: "\"publishedAT\":\"2024-01-01T00:00:00Z\""), Int32(QJS_INVALID_INPUT))
        XCTAssertEqual(try run(extra: "\"publishedAt\":\"2024-01-01T00:00:00Z\",\"extra\":1"), Int32(QJS_INVALID_INPUT))
    }

    func testDuplicatePublishedAtIsRejectedByStrictJSON() throws {
        XCTAssertEqual(try run(extra: "\"publishedAt\":\"2024-01-01T00:00:00Z\",\"publishedAt\":\"2024-01-01T00:00:00Z\""),
                       Int32(QJS_INVALID_INPUT))
    }
}
