import XCTest
import AutomationCore
@testable import AutomationRuntime

/// The C runtime has its own schema-2 allowlist; it must accept a valid category and reject invalid ones.
final class PackageCategoryRuntimeTests: XCTestCase, @unchecked Sendable {
    private let file = "hooks/a.js"

    private func run(extra: String) async throws -> [String: Any] {
        let match = #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"\#(file)"}}}"#
        let manifest = #"{"schemaVersion":2,"id":"22222222-2222-4222-8222-222222222222","name":"Sample","version":"1.0.0","matches":[\#(match)],"read":{"metadata":["method"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},"write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}\#(extra)}"#
        let code = try JSONValue.string("Interceptor.attach({request:{onEnter(){}}});").jsonString()
        let package = Data(#"{"manifest":\#(manifest),"sourceFiles":{"\#(file)":\#(code)}}"#.utf8)
        let event = Data(#"{"request":{"method":"POST","host":"api.example.com","path":"/search","headers":{},"query":{}},"response":{"status":200,"headers":{}}}"#.utf8)
        let data = try await JavaScriptExecutor().runV2(packageJSON: package, hook: .requestEnter, eventJSON: event, configJSON: Data("{}".utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testValidCategoryExecutesThroughCRuntime() async throws {
        for text in ["Network", "ネットワーク", String(repeating: "😀", count: 64), String(repeating: "a", count: 80)] {
            let r = try await run(extra: #","category":\#(try JSONValue.string(text).jsonString())"#)
            XCTAssertEqual((r["actions"] as? [Any])?.count, 0)
        }
        // Absent category still runs (legacy).
        _ = try await run(extra: "")
    }

    func testInvalidCategoryIsRejectedByCRuntime() async {
        let bads = [#""""#, #"" ""#, #""a\nb""#, #""a b""#, #""a​b""#, #""a‮b""#, #""\#(String(repeating: "a", count: 81))""#,
                    #""\#(String(repeating: "😀", count: 65))""#, "null", "1", "[]", "{}"]
        for bad in bads {
            do {
                _ = try await run(extra: #","category":\#(bad)"#)
                XCTFail("accepted \(bad.prefix(20))")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput, "\(bad.prefix(20))") }
        }
    }

    func testCategoryRejectsEveryUnicodeForbiddenScalar() async throws {
        // Use Swift's category data as the independent parser-contract oracle, rather than
        // repeating the C implementation's ranges (notably U+08E2 and U+110BD).
        for scalar in forbiddenScalars {
            let category = "a" + String(scalar) + "b"
            do {
                _ = try await run(extra: #", "category":\#(try JSONValue.string(category).jsonString())"#)
                XCTFail("accepted category containing U+\(String(scalar.value, radix: 16, uppercase: true))")
            } catch {
                XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput,
                               "U+\(String(scalar.value, radix: 16, uppercase: true))")
            }
        }
    }

    func testCategoryAcceptsValidNeighborsOfForbiddenScalarRanges() async throws {
        let forbidden = Set(forbiddenScalars.map(\.value))
        let neighbors = forbidden.flatMap { value -> [UInt32] in
            [value > 0 ? value - 1 : value, value < 0x10FFFF ? value + 1 : value]
        }
        for value in Set(neighbors).subtracting(forbidden).sorted() {
            guard let scalar = UnicodeScalar(value) else { continue }
            let category = "a" + String(scalar) + "b"
            let result = try await run(extra: #", "category":\#(try JSONValue.string(category).jsonString())"#)
            XCTAssertEqual((result["actions"] as? [Any])?.count, 0, "U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    func testCategoryFixPreservesLegacyAuthorAndSummaryAdmission() async throws {
        // These Cf scalars were omitted by the legacy C display-text predicate. This
        // category-only change must not silently tighten existing author/summary input.
        let legacyText = try JSONValue.string("a\u{8E2}\u{110BD}b").jsonString()
        for field in ["author", "summary"] {
            let result = try await run(extra: #", "\#(field)":\#(legacyText)"#)
            XCTAssertEqual((result["actions"] as? [Any])?.count, 0, field)
        }
    }

    private var forbiddenScalars: [UnicodeScalar] {
        (UInt32(0)...0x10FFFF).compactMap { value in
            guard let scalar = UnicodeScalar(value) else { return nil }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return scalar
            default: return nil
            }
        }
    }
}
