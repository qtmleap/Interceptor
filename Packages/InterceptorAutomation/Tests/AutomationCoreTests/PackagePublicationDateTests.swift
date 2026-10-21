@testable import AutomationCore
import XCTest

/// Optional publisher-declared `publishedAt` (DateCodec grammar). Display metadata only.
final class PackagePublicationDateTests: XCTestCase {
    private static let match = #"{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/search"},"hooks":{"request":{"onEnter":"selected.js"}}}"#

    private func v2(extra: String = "") -> Data {
        let m = #"{"schemaVersion":2,"id":"\#(pluginID)","name":"P","version":"1.0.0","matches":[\#(Self.match)],"read":{"metadata":["method"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},"write":{"requestBody":false,"responseBody":false},"settings":{},"endpointBindings":[]\#(extra)}"#
        return Data(#"{"manifest":\#(m),"sourceFiles":{"selected.js":"Interceptor.attach({request:{onEnter(){}}});"}}"#.utf8)
    }

    private func v1(extra: String = "") -> Data {
        packageBytes(manifest: manifestJSON(extra: extra))
    }

    private func extra(_ value: String) -> String {
        #","publishedAt":\#(value)"#
    }

    private let valid = "2026-10-19T23:59:59Z"

    func testAbsentIsNil() throws {
        XCTAssertNil(try PluginPackage.validate(v1()).manifest.publishedAt)
        XCTAssertNil(try PluginPackage.validate(v2()).manifest.publishedAt)
    }

    func testValidDateParsedAndPreservedExactlyInBothSchemas() throws {
        let expected = DateCodec.parse(valid)
        XCTAssertNotNil(expected)
        for bytes in [v1(extra: extra(#""\#(valid)""#)), v2(extra: extra(#""\#(valid)""#))] {
            let p = try PluginPackage.validate(bytes)
            XCTAssertEqual(p.manifest.publishedAt, expected)
            XCTAssertEqual(p.manifest.json.objectValue?["publishedAt"], .string(valid))
        }
    }

    func testLeapDayAccepted() throws {
        XCTAssertNoThrow(try PluginPackage.validate(v1(extra: extra(#""2024-02-29T00:00:00Z""#))))
    }

    func testInvalidValuesRejectedInBothSchemas() {
        for bad in [#""2026-10-19T23:59:59+00:00""#, #""2026-10-19T23:59:59.000Z""#, #""2026-10-19t23:59:59z""#, #""2026-10-19T23:59:59z""#,
                    #""2026-10-19""#, #""2026-10-19 23:59:59Z""#, #""2026-02-30T00:00:00Z""#, #""2025-02-29T00:00:00Z""#,
                    #""2026-13-01T00:00:00Z""#, #""2026-10-19T24:00:00Z""#, #""2026-10-19T23:60:00Z""#, #""2026-10-19T23:59:60Z""#,
                    #""0000-01-01T00:00:00Z""#, #"" 2026-10-19T23:59:59Z""#, #""""#, "null", "1", "true", "[]", "{}"]
        {
            try assertThrows(.invalidManifest, PluginPackage.validate(v1(extra: extra(bad))))
            try assertThrows(.invalidManifest, PluginPackage.validate(v2(extra: extra(bad))))
        }
    }

    func testReplacingSourceKeepsExactDateString() throws {
        let p1 = try PluginPackage.validate(v1(extra: extra(#""\#(valid)""#)))
        let e1 = try p1.replacingSource("function onRequest(){}")
        XCTAssertEqual(e1.manifest.publishedAt, p1.manifest.publishedAt)
        XCTAssertEqual(e1.manifest.json.objectValue?["publishedAt"], .string(valid))

        let p2 = try PluginPackage.validate(v2(extra: extra(#""\#(valid)""#)))
        let e2 = try p2.replacingSource("Interceptor.attach({});", file: "selected.js")
        XCTAssertEqual(e2.manifest.json.objectValue?["publishedAt"], .string(valid))
        XCTAssertEqual(e2.manifest.publishedAt, p2.manifest.publishedAt)
    }

    func testChangedDateChangesRevisionAndAbsentDiffers() throws {
        let a = try PluginPackage.validate(v1(extra: extra(#""2026-10-19T00:00:00Z""#)))
        let b = try PluginPackage.validate(v1(extra: extra(#""2026-10-19T00:00:01Z""#)))
        let none = try PluginPackage.validate(v1())
        XCTAssertEqual(Set([a.revision, b.revision, none.revision]).count, 3)
    }

    func testDuplicateKeyStillRejected() {
        let dup = v1(extra: extra(#""\#(valid)","publishedAt":"\#(valid)""#))
        XCTAssertThrowsError(try PluginPackage.validate(dup))
    }

    func testIndexEntryWithPublishedAtStillRejected() throws {
        let bytes = v1(extra: extra(#""\#(valid)""#))
        let e = entry(for: bytes)
        let payload = Data(#"{"schemaVersion":1,"id":"\#(repoID)","name":"R","sequence":1,"issuedAt":"\#(iso(now))","expiresAt":"\#(iso(now.addingTimeInterval(86_400)))","plugins":[{"id":"\#(e.id)","name":"P","version":"1.0.0","packagePath":"p.json","sha256":"\#(e.sha256)","size":\#(e.size),"publishedAt":"\#(valid)"}]}"#.utf8)
        XCTAssertThrowsError(try RepositoryEnvelope.verify(envelope: envelope(payload), url: url(), now: now))
    }
}
