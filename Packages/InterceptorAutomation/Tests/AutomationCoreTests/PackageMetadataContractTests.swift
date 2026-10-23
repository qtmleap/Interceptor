import XCTest
@testable import AutomationCore

/// Optional display metadata (author, summary, category): manifest schema 1+2, strict Index entry fields and
/// present-field cross-checks. Display text only; nothing here is a trust claim.
final class PackageMetadataContractTests: XCTestCase {
    private static let match = #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"selected.js"}}}"#

    private func v2(extra: String = "") -> Data {
        let m = #"{"schemaVersion":2,"id":"\#(pluginID)","name":"P","version":"1.0.0","matches":[\#(Self.match)],"read":{"metadata":["method"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},"write":{"requestBody":false,"responseBody":false},"settings":{},"endpointBindings":[]\#(extra)}"#
        return Data(#"{"manifest":\#(m),"sourceFiles":{"selected.js":"Interceptor.attach({request:{onEnter(){}}});"}}"#.utf8)
    }
    private func v1(extra: String = "") -> Data { packageBytes(manifest: manifestJSON(extra: extra)) }
    private func extra(_ value: String) -> String { #","category":\#(value)"# }

    // MARK: manifest

    func testAbsentCategoryIsNilAndOldPackagesUnchanged() throws {
        XCTAssertNil(try PluginPackage.validate(v1()).manifest.category)
        XCTAssertNil(try PluginPackage.validate(v2()).manifest.category)
    }

    func testCategoryAcceptedVerbatimInBothSchemas() throws {
        for text in ["Network", "  padded  ", "ネットワーク 👩🏽", "a b"] {
            let json = try JSONValue.string(text).jsonString()
            for bytes in [v1(extra: extra(json)), v2(extra: extra(json))] {
                let p = try PluginPackage.validate(bytes)
                XCTAssertEqual(p.manifest.category, text)
                XCTAssertEqual(p.manifest.json.objectValue?["category"], .string(text))
            }
        }
    }

    func testCategoryScalarAndByteBoundaries() throws {
        func ok(_ s: String, _ bad: Bool = false, line: UInt = #line) throws {
            let json = try JSONValue.string(s).jsonString()
            for bytes in [v1(extra: extra(json)), v2(extra: extra(json))] {
                if bad { assertThrows(.invalidManifest, try PluginPackage.validate(bytes), line: line) }
                else { XCTAssertNoThrow(try PluginPackage.validate(bytes), line: line) }
            }
        }
        try ok("a")
        try ok(String(repeating: "a", count: 80))
        try ok(String(repeating: "a", count: 81), true)
        try ok(String(repeating: "あ", count: 80))          // 240 bytes
        try ok(String(repeating: "😀", count: 64))          // 256 bytes, 64 scalars
        try ok(String(repeating: "😀", count: 65), true)     // 260 bytes
        try ok(String(repeating: "😀", count: 63) + "abcd")        // 256 bytes, 67 scalars
        try ok(String(repeating: "😀", count: 63) + "abcde", true) // 257 bytes
    }

    func testCategoryScalarLimitCountsScalarsNotGraphemes() throws {
        // 80 combining sequences of "e" + U+0301 = 160 scalars (80 graphemes, 240 bytes): over the scalar limit.
        let s = String(repeating: "e\u{301}", count: 80)
        XCTAssertEqual(s.count, 80)
        let json = try JSONValue.string(s).jsonString()
        assertThrows(.invalidManifest, try PluginPackage.validate(v2(extra: extra(json))))
        assertThrows(.invalidManifest, try PluginPackage.validate(v1(extra: extra(json))))
        // 40 sequences = 80 scalars is accepted.
        let fits = try JSONValue.string(String(repeating: "e\u{301}", count: 40)).jsonString()
        XCTAssertNoThrow(try PluginPackage.validate(v2(extra: extra(fits))))
    }

    func testCategoryInvalidValuesRejected() {
        for bad in [#""""#, #""   ""#, #"" ""#, #""　""#, #""a\nb""#, #""a\tb""#, #""a\u0000b""#, #""a\u007fb""#, #""a\u0085b""#,
                    #""a b""#, #""a b""#, #""a​b""#, #""a‮b""#, #""a⁦b""#, #""a﻿b""#, #""a­b""#,
                    #""👩🏽‍💻""#, "null", "1", "true", "[]", "{}"] {
            assertThrows(.invalidManifest, try PluginPackage.validate(v1(extra: extra(bad))))
            assertThrows(.invalidManifest, try PluginPackage.validate(v2(extra: extra(bad))))
        }
    }

    func testCategoryRejectsEveryUnicodeForbiddenScalarInBothSchemas() throws {
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = UnicodeScalar(value) else { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                let json = try JSONValue.string("a" + String(scalar) + "b").jsonString()
                assertThrows(.invalidManifest, try PluginPackage.validate(v1(extra: extra(json))))
                assertThrows(.invalidManifest, try PluginPackage.validate(v2(extra: extra(json))))
            default: continue
            }
        }
    }

    func testExistingAuthorSummaryValidationIsNotTightened() throws {
        // Unchanged: grapheme-counted. 80 combining sequences (160 scalars) are still accepted for author.
        let s = try JSONValue.string(String(repeating: "e\u{301}", count: 80)).jsonString()
        let p = try PluginPackage.validate(v2(extra: #","author":\#(s)"#))
        XCTAssertEqual(p.manifest.author?.unicodeScalars.count, 160)
    }

    // MARK: index

    private func payload(entryExtra: String, bytes: Data) -> Data {
        let e = entry(for: bytes)
        return Data(#"{"schemaVersion":1,"id":"\#(repoID)","name":"R","sequence":1,"issuedAt":"\#(iso(now))","expiresAt":"\#(iso(now.addingTimeInterval(86_400)))","plugins":[{"id":"\#(e.id)","name":"P","version":"1.0.0","packagePath":"p.json","sha256":"\#(e.sha256)","size":\#(e.size)\#(entryExtra)}]}"#.utf8)
    }
    private func verify(entryExtra: String, bytes: Data = PackageMetadataContractTests.v1Bytes()) throws -> IndexEntry {
        let snapshot = try RepositoryEnvelope.verify(envelope: try envelope(payload(entryExtra: entryExtra, bytes: bytes)), url: url(), now: now)
        return snapshot.index.plugins[0]
    }
    private static func v1Bytes(_ extra: String = "") -> Data { packageBytes(manifest: manifestJSON(extra: extra)) }

    func testLegacyIndexEntryHasNoMetadata() throws {
        let e = try verify(entryExtra: "")
        XCTAssertNil(e.author); XCTAssertNil(e.summary); XCTAssertNil(e.category)
    }

    func testIndexEntryParsesOptionalFieldsVerbatim() throws {
        let e = try verify(entryExtra: #","author":" Ann ","summary":"リクエスト 👩🏽","category":"Network""#)
        XCTAssertEqual(e.author, " Ann ")
        XCTAssertEqual(e.summary, "リクエスト 👩🏽")
        XCTAssertEqual(e.category, "Network")
        let one = try verify(entryExtra: #","category":"Only""#)
        XCTAssertNil(one.author); XCTAssertEqual(one.category, "Only")
    }

    func testIndexEntryRejectsInvalidAndUnknownFields() {
        let long = String(repeating: "a", count: 81)
        let bad = [#","category":null"#, #","category":1"#, #","category":"""#, #","category":" ""#, #","category":"a\u0000b""#, #","category":"\#(long)""#,
                   #","category":"😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀""#,
                   #","author":null"#, #","author":[]"#, #","author":"a b""#, #","summary":"""#, #","summary":7"#,
                   #","hosts":["a.example.com"]"#, #","unknown":"x""#, #","category":"a","category":"b""#]
        for e in bad {
            XCTAssertThrowsError(try verify(entryExtra: e), e)
        }
    }

    func testIndexRoundTripsExactMetadataAndRejectsMismatch() throws {
        let extraManifest = #","author":"Ann","summary":"Does things","category":"Network""#
        let bytes = Self.v1Bytes(extraManifest)
        let e = try verify(entryExtra: #","author":"Ann","summary":"Does things","category":"Network""#, bytes: bytes)
        let p = try PluginPackage.validate(bytes, against: e)
        XCTAssertEqual(p.manifest.category, "Network")

        // Subset and fully omitted entries are accepted.
        for extra in ["", #","category":"Network""#, #","author":"Ann","summary":"Does things""#] {
            let entry = try verify(entryExtra: extra, bytes: bytes)
            XCTAssertNoThrow(try PluginPackage.validate(bytes, against: entry))
        }
        // Present-but-different (or manifest-absent) values are rejected.
        for extra in [#","category":"network""#, #","category":"Network ""#, #","author":"Bob""#, #","summary":"Other""#] {
            let entry = try verify(entryExtra: extra, bytes: bytes)
            assertThrows(.metadataMismatch, try PluginPackage.validate(bytes, against: entry))
        }
        let plain = Self.v1Bytes()
        for extra in [#","category":"Network""#, #","author":"Ann""#, #","summary":"x""#] {
            let entry = try verify(entryExtra: extra, bytes: plain)
            assertThrows(.metadataMismatch, try PluginPackage.validate(plain, against: entry))
        }
    }

    func testSchema2CategoryRoundTripsThroughIndex() throws {
        let bytes = v2(extra: extra(#""Tools""#))
        let e = try verify(entryExtra: #","category":"Tools""#, bytes: bytes)
        // v2 package manifest name/version are P / 1.0.0, matching the entry.
        XCTAssertEqual(try PluginPackage.validate(bytes, against: e).manifest.category, "Tools")
    }
}
