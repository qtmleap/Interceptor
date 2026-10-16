import CryptoKit
import XCTest
@testable import AutomationCore

final class ManifestTests: XCTestCase {
    private func check(_ m: String, _ e: AutomationError? = nil, source: String = "x", line: UInt = #line) {
        let b = packageBytes(manifest: m, source: source)
        if let e { assertThrows(e, try PluginPackage.validate(b), line: line) } else { XCTAssertNoThrow(try PluginPackage.validate(b), line: line) }
    }
    func testFullManifestPreserved() throws {
        let p = try PluginPackage.validate(packageBytes())
        XCTAssertEqual(p.manifest.subscriptions.count, 1)
        XCTAssertEqual(p.manifest.subscriptions[0].phase, .requestCompleted)
        XCTAssertEqual(p.manifest.subscriptions[0].path, .exact("/v1/jobs"))
        XCTAssertEqual(p.manifest.read.headers, ["x-a"])
        XCTAssertEqual(p.manifest.endpointBindings, ["alert"])
        XCTAssertEqual(p.manifest.json.objectValue?["schemaVersion"], .integer(1))
    }
    func testRequiredKeysAndUnknownRejected() {
        check(manifestJSON(extra: #","bogus":1"#), .invalidManifest)
        check(manifestJSON(schema: "2"), .invalidManifest)
        check(#"{"id":"\#(pluginID)","name":"P","version":"1.0.0"}"#, .invalidManifest)
        check(manifestJSON(name: ""), .invalidManifest)
        check(manifestJSON(name: String(repeating: "n", count: 81)), .invalidManifest)
        check(manifestJSON(name: String(repeating: "n", count: 80)))
        check(manifestJSON(version: "1.0"), .invalidManifest)
    }
    func testSubscriptions() {
        check(manifestJSON(subscriptions: "[]"), .invalidManifest)
        let nine = "[" + Array(repeating: #"{"phase":"request.completed","match":{"hosts":["a.com"]}}"#, count: 9).joined(separator: ",") + "]"
        check(manifestJSON(subscriptions: nine), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"bogus","match":{"hosts":["a.com"]}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":[]}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["A.com"]}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["a.com"],"methods":["post"]}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["a.com"],"status":{"min":200,"max":299}}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"response.completed","match":{"hosts":["a.com"],"status":{"min":500,"max":499}}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"response.completed","match":{"hosts":["a.com"],"status":{"min":99,"max":200}}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"response.completed","match":{"hosts":["a.com"],"status":{"min":500,"max":599}}}]"#))
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["a.com"],"path":{"kind":"regex","value":"/a"}}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["a.com"],"path":{"kind":"prefix","value":"a"}}}]"#), .invalidManifest)
        check(manifestJSON(subscriptions: #"[{"phase":"request.completed","match":{"hosts":["a.com"],"path":{"kind":"prefix","value":"/a%2"}}}]"#), .invalidManifest)
    }
    func testReadDeclarations() {
        let hdr = #"[{"phase":"request.headers","match":{"hosts":["a.com"]}}]"#
        check(manifestJSON(subscriptions: hdr, read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"raw"}}"#), .invalidManifest)
        check(manifestJSON(subscriptions: hdr, read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}}"#))
        check(manifestJSON(read: #"{"metadata":["secret"],"headers":[],"queryKeys":[],"body":{"mode":"none"}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":["a b"],"queryKeys":[],"body":{"mode":"none"}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":["A","a"],"queryKeys":[],"body":{"mode":"none"}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["/a/b","/c~0~1"]}}"#))
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["a"]}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["/~2"]}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":[]}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none","pointers":["/a"]}}"#), .invalidManifest)
        let many = Array((0..<33).map { "\"/p\($0)\"" }).joined(separator: ",")
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":[\#(many)]}}"#), .invalidManifest)
        check(manifestJSON(read: #"{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"jsonPointers","pointers":["/\#(String(repeating: "a", count: 256))"]}}"#), .invalidManifest)
    }
    func testBindingsAndSettings() {
        check(manifestJSON(bindings: "[]"))
        check(manifestJSON(bindings: #"["a","b","c","d"]"#))
        check(manifestJSON(bindings: #"["a","b","c","d","e"]"#), .invalidManifest)
        check(manifestJSON(bindings: #"["a","a"]"#), .invalidManifest)
        check(manifestJSON(bindings: #"["1a"]"#), .invalidManifest)
        check(manifestJSON(settings: "[]"), .invalidManifest)
        check(manifestJSON(settings: #"{"n":1.5,"b":[1,{"x":null}]}"#))
        check(manifestJSON(settings: #"{"n":1e999}"#), .invalidManifest)
        var deep = "1"
        for _ in 0..<16 { deep = "{\"a\":\(deep)}" }       // nesting 16
        check(manifestJSON(settings: deep))
        check(manifestJSON(settings: "{\"a\":\(deep)}"), .invalidManifest)  // 17
        check(manifestJSON(settings: #"{"k":"\#(String(repeating: "x", count: 8_192))"}"#), .invalidManifest)
    }
    func testSourceAndPackageCaps() {
        XCTAssertNoThrow(try PluginPackage.validate(packageBytes(source: String(repeating: "a", count: Limits.source))))
        assertThrows(.limitExceeded, try PluginPackage.validate(packageBytes(source: String(repeating: "a", count: Limits.source + 1))))
        assertThrows(.limitExceeded, try PluginPackage.validate(Data(count: Limits.package + 1)))
        assertThrows(.limitExceeded, try PluginPackage.validate(Data()))
        assertThrows(.invalidManifest, try PluginPackage.validate(Data(#"{"manifest":{},"source":"x","extra":1}"#.utf8)))
        assertThrows(.invalidManifest, try PluginPackage.validate(Data("[]".utf8)))
    }
    func testTemplateIsMetadataOnly() throws {
        let t = try PluginPackage.template()
        XCTAssertEqual(t.manifest.read.body, .none)
        XCTAssertEqual(t.manifest.subscriptions[0].hosts, ["example.com"])
        XCTAssertTrue(t.manifest.endpointBindings.isEmpty)
    }
}

final class EnvelopeTests: XCTestCase {
    func testStrictBase64Payload() throws {
        let p = indexJSON()
        for bad in [p.base64EncodedString() + "\\n", p.base64EncodedString() + "A", "!!!!"] {
            assertThrows(.invalidBase64, try RepositoryEnvelope.verify(envelope: envelope(p, payloadText: bad), url: url(), now: now))
        }
    }
    func testSignatureDomainAndExactBytes() throws {
        let k = Curve25519.Signing.PrivateKey(), p = indexJSON()
        func env(_ msg: Data, pub: Data? = nil) throws -> Data {
            let s = try k.signature(for: msg)
            return Data(#"{"schemaVersion":1,"payload":"\#(p.base64EncodedString())","signature":{"algorithm":"ed25519","publicKey":"\#((pub ?? k.publicKey.rawRepresentation).base64EncodedString())","value":"\#(s.base64EncodedString())"}}"#.utf8)
        }
        XCTAssertNoThrow(try RepositoryEnvelope.verify(envelope: try env(Data("InterceptorRepository/v1".utf8) + [0] + p), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: try env(p), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: try env(Data("InterceptorRepository/v1".utf8) + p), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: try env(Data("InterceptorRepository/v1".utf8) + [0] + p + [0x20]), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: try env(Data("InterceptorRepository/v1".utf8) + [0] + p, pub: Data(count: 31)), url: url(), now: now))
    }
    func testSignatureObjectStrict() throws {
        let k = Curve25519.Signing.PrivateKey(), p = indexJSON()
        let good = try String(decoding: envelope(p, key: k), as: UTF8.self)
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: Data(good.replacingOccurrences(of: "ed25519", with: "rsa").utf8), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: Data(good.replacingOccurrences(of: #""value""#, with: #""extra":1,"value""#).utf8), url: url(), now: now))
    }
    func testPayloadTamperingWithValidSignatureShapeFails() throws {
        let k = Curve25519.Signing.PrivateKey()
        let signed = try String(decoding: envelope(indexJSON(), key: k), as: UTF8.self)
        let other = indexJSON(sequence: 2).base64EncodedString()
        let start = signed.range(of: #""payload":""#)!.upperBound, end = signed[start...].firstIndex(of: "\"")!
        let tampered = signed.replacingCharacters(in: start..<end, with: other)
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: Data(tampered.utf8), url: url(), now: now))
    }
    func testClockBoundaries() throws {
        let e = now.addingTimeInterval(100)
        XCTAssertNoThrow(try snap(indexJSON(issued: now, expires: e), at: now))
        assertThrows(.expired, try snap(indexJSON(issued: now, expires: e), at: e))             // expiresAt == now is expired
        XCTAssertNoThrow(try snap(indexJSON(issued: now, expires: e), at: e.addingTimeInterval(-1)))
        XCTAssertNoThrow(try snap(indexJSON(issued: now.addingTimeInterval(300), expires: now.addingTimeInterval(900)), at: now))
        assertThrows(.notYetValid, try snap(indexJSON(issued: now.addingTimeInterval(301), expires: now.addingTimeInterval(900)), at: now))
        XCTAssertNoThrow(try snap(indexJSON(issued: now, expires: now.addingTimeInterval(90 * 86_400)), at: now))
        assertThrows(.lifetimeTooLong, try snap(indexJSON(issued: now, expires: now.addingTimeInterval(90 * 86_400 + 1)), at: now))
        assertThrows(.invalidJSON, try snap(indexJSON(issued: now.addingTimeInterval(10), expires: now.addingTimeInterval(5)), at: now.addingTimeInterval(-100)))
    }
    func testIndexFieldRules() throws {
        let e = entry(for: packageBytes())
        func idx(plugins: String, sequence: String = "1") -> Data {
            Data(#"{"schemaVersion":1,"id":"\#(repoID)","name":"R","sequence":\#(sequence),"issuedAt":"\#(iso(now))","expiresAt":"\#(iso(now.addingTimeInterval(60)))","plugins":\#(plugins)}"#.utf8)
        }
        func plugin(id: UUID = e.id, path: String = "p.json", sha: String = e.sha256, size: Int = e.size, version: String = "1.0.0") -> String {
            #"{"id":"\#(id)","name":"P","version":"\#(version)","packagePath":"\#(path)","sha256":"\#(sha)","size":\#(size)}"#
        }
        func rejects(_ d: Data, _ line: UInt = #line) { XCTAssertThrowsError(try RepositoryEnvelope.verify(envelope: envelope(d), url: url(), now: now), line: line) }
        XCTAssertNoThrow(try RepositoryEnvelope.verify(envelope: envelope(idx(plugins: "[\(plugin())]")), url: url(), now: now))
        XCTAssertNoThrow(try RepositoryEnvelope.verify(envelope: envelope(idx(plugins: "[]", sequence: "9007199254740991")), url: url(), now: now))
        rejects(idx(plugins: "[]", sequence: "9007199254740992"))
        rejects(idx(plugins: "[]", sequence: "1.0"))
        rejects(idx(plugins: "[]", sequence: "-1"))
        rejects(idx(plugins: "[\(plugin()),\(plugin())]"))
        rejects(idx(plugins: "[\(plugin(path: "/abs.json"))]"))
        rejects(idx(plugins: "[\(plugin(path: "../x.json"))]"))
        rejects(idx(plugins: "[\(plugin(sha: e.sha256.uppercased()))]"))
        rejects(idx(plugins: "[\(plugin(sha: String(e.sha256.dropLast())))]"))
        rejects(idx(plugins: "[\(plugin(size: 0))]"))
        rejects(idx(plugins: "[\(plugin(size: Limits.package + 1))]"))
        rejects(idx(plugins: "[\(plugin(version: "latest"))]"))
        XCTAssertNoThrow(try RepositoryEnvelope.verify(envelope: envelope(idx(plugins: "[\(plugin(size: Limits.package))]")), url: url(), now: now))
        let hundredOne = (0..<101).map { _ in plugin(id: UUID()) }.joined(separator: ",")
        assertThrows(.limitExceeded, try RepositoryEnvelope.verify(envelope: envelope(idx(plugins: "[\(hundredOne)]")), url: url(), now: now))
        let hundred = (0..<100).map { _ in plugin(id: UUID()) }.joined(separator: ",")
        XCTAssertNoThrow(try RepositoryEnvelope.verify(envelope: envelope(idx(plugins: "[\(hundred)]")), url: url(), now: now))
    }
    func testPayloadAndEnvelopeLimits() throws {
        let big = Data(count: Limits.payload + 1)
        assertThrows(.limitExceeded, try RepositoryEnvelope.verify(envelope: envelope(big), url: url(), now: now))
        assertThrows(.invalidSignature, try RepositoryEnvelope.verify(envelope: Data(#"{"schemaVersion":1,"payload":"","signature":null}"#.utf8), url: url(), now: now))
        assertThrows(.invalidJSON, try RepositoryEnvelope.verify(envelope: Data(#"{"schemaVersion":2,"payload":""}"#.utf8), url: url(), now: now))
    }
}
