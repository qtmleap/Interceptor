import CryptoKit
import XCTest
@testable import AutomationCore

let now = Date(timeIntervalSince1970: 1_800_000_000)
let repoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let pluginID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
let iso: @Sendable (Date) -> String = { DateCodec.string($0) }

func manifestJSON(name: String = "P", version: String = "1.0.0", subscriptions: String? = nil, read: String? = nil,
                  bindings: String = #"["alert"]"#, settings: String = "{}", extra: String = "", schema: String = "1") -> String {
    let subs = subscriptions ?? #"[{"phase":"request.completed","match":{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/v1/jobs"}}}]"#
    let rd = read ?? #"{"metadata":["method","host"],"headers":["x-a"],"queryKeys":["q"],"body":{"mode":"none"}}"#
    return #"{"schemaVersion":\#(schema),"id":"\#(pluginID)","name":"\#(name)","version":"\#(version)","subscriptions":\#(subs),"read":\#(rd),"endpointBindings":\#(bindings),"settings":\#(settings)\#(extra)}"#
}

func packageBytes(name: String = "P", version: String = "1.0.0", manifest: String? = nil, source: String = "function onRequest(){return {actions:[]}}") -> Data {
    Data(#"{"manifest":\#(manifest ?? manifestJSON(name: name, version: version)),"source":"\#(source)"}"#.utf8)
}

func entry(for bytes: Data, name: String = "P", version: String = "1.0.0") -> IndexEntry {
    IndexEntry(id: pluginID, name: name, version: version, packagePath: "p.json", sha256: Digest.sha256Hex(bytes), size: bytes.count)
}

func indexJSON(id: UUID = repoID, sequence: Int = 1, pkg: Data = packageBytes(), issued: Date = now, expires: Date = now.addingTimeInterval(86_400), extra: String = "") -> Data {
    let e = entry(for: pkg)
    return Data(#"{"schemaVersion":1,"id":"\#(id)","name":"R","sequence":\#(sequence),"issuedAt":"\#(iso(issued))","expiresAt":"\#(iso(expires))","plugins":[{"id":"\#(e.id)","name":"P","version":"1.0.0","packagePath":"p.json","sha256":"\#(e.sha256)","size":\#(e.size)}]\#(extra)}"#.utf8)
}

func envelope(_ payload: Data, key: Curve25519.Signing.PrivateKey? = nil, payloadText: String? = nil) throws -> Data {
    var sig = ""
    if let key {
        let s = try key.signature(for: Data("InterceptorRepository/v1".utf8) + [0] + payload)
        sig = #","signature":{"algorithm":"ed25519","publicKey":"\#(key.publicKey.rawRepresentation.base64EncodedString())","value":"\#(s.base64EncodedString())"}"#
    }
    return Data(#"{"schemaVersion":1,"payload":"\#(payloadText ?? payload.base64EncodedString())"\#(sig)}"#.utf8)
}

let url: @Sendable () -> RepositoryURL = { (try? RepositoryURL(parsing: "https://example.com/r/repository.json"))! }

/// Test-only record of the exact directories this process created; nothing else is ever deleted.
final class TempRegistry: @unchecked Sendable {
    static let shared = TempRegistry()
    private let lock = NSLock()
    private var directories: [URL] = []
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterceptorAutomationTests-\(UUID().uuidString)")

    func makeFile() -> URL {
        lock.lock(); defer { lock.unlock() }
        let dir = root.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { XCTFail("temp directory: \(error)") }
        directories.append(dir)
        return dir.appendingPathComponent("catalog.json")
    }

    func cleanUp() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        for dir in directories where fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch { XCTFail("cleanup \(dir.lastPathComponent): \(error)") }
        }
        directories.removeAll()
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true { try? fm.removeItem(at: root) }
    }
}

class AutomationTestCase: XCTestCase {
    override func tearDown() { TempRegistry.shared.cleanUp(); super.tearDown() }
}

func tempFile() -> URL { TempRegistry.shared.makeFile() }

func snap(_ payload: Data, key: Curve25519.Signing.PrivateKey? = nil, at: Date = now) throws -> VerifiedSnapshot {
    try RepositoryEnvelope.verify(envelope: envelope(payload, key: key), url: url(), now: at)
}

func assertThrows<T>(_ e: AutomationError, _ f: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try f(), file: file, line: line) { XCTAssertEqual($0 as? AutomationError, e, file: file, line: line) }
}
