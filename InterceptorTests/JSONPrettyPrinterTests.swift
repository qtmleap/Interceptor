import AutomationCore
import AutomationRuntime
@testable import Interceptor
import XCTest

@MainActor
final class JSONPrettyPrinterTests: XCTestCase {
    private let limit = JavaScriptLimits.maxEventBytes

    /// Removes JSON whitespace outside strings, so two texts can be compared token for token.
    private func tokens(_ text: String) -> [UInt8] {
        var out = [UInt8](), inString = false, escaped = false
        for byte in text.utf8 {
            if inString {
                out.append(byte)
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true; out.append(byte)
            } else if ![0x20, 0x09, 0x0A, 0x0D].contains(byte) {
                out.append(byte)
            }
        }
        return out
    }

    func testNestedLayoutIsExactAndEmptyContainersStayInline() {
        let input = #"{"a":{},"b":[],"c":[1,{"d":null,"e":[true,false]}],"f":"x"}"#
        let expected = """
        {
          "a": {},
          "b": [],
          "c": [
            1,
            {
              "d": null,
              "e": [
                true,
                false
              ]
            }
          ],
          "f": "x"
        }
        """
        XCTAssertEqual(JSONPrettyPrinter.format(input, maxBytes: limit), expected)
        XCTAssertEqual(JSONPrettyPrinter.format(" \n\t{ \"a\" :\r\n 1 }  ", maxBytes: limit), "{\n  \"a\": 1\n}")
    }

    func testNumberLexemesKeyOrderAndEscapesAreByteForByteTheSame() {
        let input = #"{"z":1.0e+2,"big":12345678901234567890.5,"neg":-0.0,"cap":1E5,"a":0.10,"s":"café \/ \"q\" \\ \r\n \t 😀 日本語 😀"}"#
        let output = JSONPrettyPrinter.format(input, maxBytes: limit)
        XCTAssertNotEqual(output, input)
        XCTAssertEqual(tokens(output), tokens(input), "only whitespace outside strings may change")
        XCTAssertTrue(output.contains(#""z": 1.0e+2"#))
        XCTAssertTrue(output.contains("12345678901234567890.5"))
        XCTAssertTrue(output.contains("-0.0"))
        XCTAssertTrue(output.contains("1E5"))
        XCTAssertTrue(output.contains(#""a": 0.10"#))
        let order = ["\"z\"", "\"big\"", "\"neg\"", "\"cap\"", "\"a\"", "\"s\""].compactMap { output.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted(), "key order is preserved, not sorted")
        XCTAssertTrue(output.contains(#"\r\n"#), "escaped CRLF stays escaped")
        XCTAssertFalse(output.utf8.contains(0x0D))
    }

    func testWhitespaceInsideStringsIsNeverTouched() {
        let input = #"{"k  ey":"  a  ,  b : { }  "}"#
        XCTAssertEqual(JSONPrettyPrinter.format(input, maxBytes: limit), "{\n  \"k  ey\": \"  a  ,  b : { }  \"\n}")
    }

    func testInvalidIncompleteDuplicateAndNonObjectInputsAreReturnedUnchanged() {
        let unchanged = ["", "   ", "{", #"{"a":"#, #"{"a":1,}"#, #"{"a":1} x"#, #"{"a":1,"a":2}"#, #"{"a":1,"a":2}"#,
                         "[1,2]", "42", #""text""#, "\u{FEFF}{\"a\":1}", "{\"a\":\"\u{0001}\"}", #"{"a":01}"#, #"{"a":"\ud800"}"#]
        for text in unchanged {
            XCTAssertEqual(JSONPrettyPrinter.format(text, maxBytes: limit), text)
        }
    }

    func testDisplayModeAcceptsAnyStrictValue() {
        XCTAssertEqual(JSONPrettyPrinter.format("[1,2]", maxBytes: limit, objectOnly: false), "[\n  1,\n  2\n]")
        XCTAssertEqual(JSONPrettyPrinter.format("5", maxBytes: limit, objectOnly: false), "5")
        XCTAssertEqual(JSONPrettyPrinter.format("[1,", maxBytes: limit, objectOnly: false), "[1,")
    }

    func testOversizeInputAndExpansionBeyondTheLimitFallBackToRaw() {
        let compact = #"{"a":{"b":[1,2,3]}}"#
        let pretty = JSONPrettyPrinter.format(compact, maxBytes: limit)
        XCTAssertGreaterThan(pretty.utf8.count, compact.utf8.count)
        XCTAssertEqual(JSONPrettyPrinter.format(compact, maxBytes: pretty.utf8.count), pretty)
        XCTAssertEqual(JSONPrettyPrinter.format(compact, maxBytes: pretty.utf8.count - 1), compact, "must not grow beyond the cap")
        XCTAssertEqual(JSONPrettyPrinter.format(compact, maxBytes: compact.utf8.count), compact)
        XCTAssertEqual(JSONPrettyPrinter.format(compact, maxBytes: compact.utf8.count - 1), compact, "oversize raw input")
        let big = #"{"a":""# + String(repeating: "x", count: limit) + #""}"#
        XCTAssertEqual(JSONPrettyPrinter.format(big, maxBytes: limit), big)
    }

    func testFormattingIsIdempotentAndKeepsTheValue() throws {
        let inputs = [#"{"a":[1,{"b":"c"}],"d":{}}"#, SyntheticFixture.configJSON, "{ }"]
        for input in inputs {
            let once = JSONPrettyPrinter.format(input, maxBytes: limit)
            XCTAssertEqual(JSONPrettyPrinter.format(once, maxBytes: limit), once)
            XCTAssertEqual(try JSONValue(parsing: Data(once.utf8)), try JSONValue(parsing: Data(input.utf8)))
        }
    }

    func testEveryFixtureIsAlreadyFormattedAndRuntimeBytesAreUnaffected() throws {
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .responseLeave, .request, .response] {
            let text = SyntheticFixture.eventJSON(for: hook)
            XCTAssertEqual(JSONPrettyPrinter.format(text, maxBytes: limit), text)
            XCTAssertTrue(text.contains("\n  "), "\(hook) fixture is multi-line")
            XCTAssertEqual(ScriptSession.boundedJSON(text, max: limit), try JSONValue(parsing: Data(text.utf8)).data())
        }
        let config = SyntheticFixture.configJSON
        XCTAssertEqual(JSONPrettyPrinter.format(config, maxBytes: JavaScriptLimits.maxConfigBytes), config)
    }

    func testPresentationFormattingDoesNotChangeBoundedRuntimeBytes() {
        let spaced = "{ \"b\" : 1.50 , \"a\" : [ 1 ] }"
        let pretty = JSONPrettyPrinter.format(spaced, maxBytes: limit)
        XCTAssertEqual(ScriptSession.boundedJSON(pretty, max: limit), ScriptSession.boundedJSON(spaced, max: limit))
    }
}
