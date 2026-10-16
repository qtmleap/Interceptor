import XCTest
@testable import AutomationCore

final class JSONAndEncodingTests: XCTestCase {
    private func parse(_ s: String) throws -> JSONValue { try StrictJSON.parse(Data(s.utf8)) }

    func testEscapedEquivalentDuplicateKeys() {
        assertThrows(.duplicateKey, try parse(#"{"a":1,"a":2}"#))
        assertThrows(.duplicateKey, try parse(#"{"a":1,"\u0061":2}"#))
        assertThrows(.duplicateKey, try parse(#"{"\ud83d\ude00":1,"😀":2}"#))
        assertThrows(.duplicateKey, try parse(#"{"😀":1,"😀":2}"#))
    }
    func testInvalidUTF8AndSurrogates() {
        for bytes: [UInt8] in [[0x22, 0xFF, 0x22], [0x22, 0xC0, 0x80, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22], [0x22, 0xE2, 0x82, 0x22], [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22]] {
            XCTAssertThrowsError(try StrictJSON.parse(Data(bytes)), "\(bytes)")
        }
        for s in [#""\udc00""#, #""\ud800x""#, #""\ud800A""#, #""\ud800\ud800""#] { XCTAssertThrowsError(try parse(s), s) }
        XCTAssertEqual(try parse(#""😀""#), .string("😀"))
        XCTAssertEqual(try parse("\"é\""), .string("é"))
    }
    func testControlCharsAndTrailing() {
        for s in ["\"a\nb\"", "{} {}", "[1,]", "{\"a\":1,}", "01", "-", "1.", ".5", "1e", "+1", "tru", "NaN", "", " "] {
            XCTAssertThrowsError(try parse(s), s)
        }
        XCTAssertEqual(try parse(" \n\t{ } \r"), .object([:]))
    }
    func testDepthBoundary() throws {
        XCTAssertNoThrow(try parse(String(repeating: "[", count: 64) + String(repeating: "]", count: 64)))
        assertThrows(.limitExceeded, try parse(String(repeating: "[", count: 65) + String(repeating: "]", count: 65)))
    }
    func testNumericPrecision() throws {
        XCTAssertEqual(try parse("9007199254740991"), .integer(9_007_199_254_740_991))
        XCTAssertEqual(try parse("-9007199254740991"), .integer(-9_007_199_254_740_991))
        XCTAssertThrowsError(try parse("9007199254740992"))
        XCTAssertThrowsError(try parse("99999999999999999999"))
        XCTAssertThrowsError(try parse("1e999"))
        XCTAssertEqual(try parse("1.5"), .double(1.5))
        XCTAssertEqual(try parse("1e2"), .double(100))
        XCTAssertEqual(try parse("-0"), .integer(0))
    }
    func testEncodeRoundTripAndEscapes() throws {
        let v: JSONValue = .object(["b": .array([.integer(1), .double(2.5), .null, .bool(false)]), "a": .string("q\"\\\n\u{1}é")])
        let d = try v.data()
        XCTAssertEqual(String(decoding: d, as: UTF8.self), #"{"a":"q\"\\\n\u0001é","b":[1,2.5,null,false]}"#)
        XCTAssertEqual(try JSONValue(parsing: d), v)
        XCTAssertThrowsError(try JSONValue.double(.infinity).data())
        XCTAssertThrowsError(try JSONValue.double(.nan).data())
    }
    func testBase64MustBeCanonical() throws {
        XCTAssertEqual(try StrictBase64.decode("AQID"), Data([1, 2, 3]))
        for s in ["AQI", "AQI=\n", "AQ==\n", "AR==", "AQJ=", "AQ=A", " AQID", "AQ-_", "AQID====", "A Q=="] {
            assertThrows(.invalidBase64, try StrictBase64.decode(s))
        }
    }
    func testDateCodec() {
        XCTAssertEqual(DateCodec.parse("2027-01-15T08:00:00Z")?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(DateCodec.string(Date(timeIntervalSince1970: 1_800_000_000)), "2027-01-15T08:00:00Z")
        XCTAssertNotNil(DateCodec.parse("2028-02-29T00:00:00Z"))
        for s in ["2027-02-29T00:00:00Z", "2027-01-15T08:00:00.5Z", "2027-01-15T08:00:00+00:00", "2027-01-15 08:00:00Z", "2027-13-01T00:00:00Z", "2027-01-15T24:00:00Z", "2027-01-15T08:00:60Z", "2027-01-15t08:00:00z"] {
            XCTAssertNil(DateCodec.parse(s), s)
        }
        for t in [0.0, 951_782_400, 1_709_164_800, 4_102_444_799] {
            XCTAssertEqual(DateCodec.parse(DateCodec.string(Date(timeIntervalSince1970: t)))?.timeIntervalSince1970, t)
        }
    }
    func testSemVer() {
        for ok in ["1.2.3", "0.0.0", "1.0.0-alpha.1", "1.0.0+build.5", "1.0.0-rc.1+x"] { XCTAssertNoThrow(try SemVer(parsing: ok), ok) }
        for bad in ["1.2", "01.2.3", "1.2.3-", "1.2.3-01", "v1.2.3", "1.2.3.4", "", "1.0.0-a..b"] { XCTAssertThrowsError(try SemVer(parsing: bad), bad) }
    }
}

final class URLTests: XCTestCase {
    func testHostRules() throws {
        for s in ["https://127.0.0.1/x.json", "https://[::1]/x.json", "https://a.com./x.json", "https://localhost./x.json", "https://1.2.3.4.5/x", "https://a_b.com/x", "https://-a.com/x", "https://exa mple.com/x", "https://example/x.json", "https://a.com:0/x", "https://a.com:65536/x", "https://a.com:/x", "https://a.com:08080/x", "https://%61.com/x", "", "https://"] {
            assertThrows(.invalidURL, try RepositoryURL(parsing: s))
        }
        XCTAssertEqual(try RepositoryURL(parsing: "https://localhost/").canonical, "https://localhost/repository.json")
        XCTAssertEqual(try RepositoryURL(parsing: "https://xn--bcher-kva.example/").canonical, "https://xn--bcher-kva.example/repository.json")
    }
    func testPortAndCase() throws {
        XCTAssertEqual(try RepositoryURL(parsing: "https://Example.com:8443/Repo/Index.JSON").canonical, "https://example.com:8443/Repo/Index.JSON")
        XCTAssertEqual(try RepositoryURL(parsing: "https://example.com:443/a/").canonical, "https://example.com/a/repository.json")
        XCTAssertEqual(try RepositoryURL(parsing: "https://example.com"), try RepositoryURL(parsing: "https://example.com:443/repository.json"))
        XCTAssertNotEqual(try RepositoryURL(parsing: "https://example.com:8443/"), try RepositoryURL(parsing: "https://example.com/"))
    }
    func testPackageURLKeepsPortAndDirectory() throws {
        let u = try RepositoryURL(parsing: "https://example.com:8443/a/b/repository.json")
        XCTAssertEqual(try u.packageURL(path: "p/x.json").absoluteString, "https://example.com:8443/a/b/p/x.json")
        XCTAssertThrowsError(try u.packageURL(path: ""))
        XCTAssertThrowsError(try u.packageURL(path: String(repeating: "a", count: 300)))
    }
}
