import AutomationCore
import AutomationRepository
import AutomationRuntime
import CryptoKit
import Foundation
@testable import Interceptor

/// Builds real, verified snapshots/packages through the production Core validators.
enum AutomationFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let url: RepositoryURL = {
        guard let url = try? RepositoryURL(parsing: "https://plugins.example.com/repository.json") else {
            preconditionFailure("Invalid fixture repository URL")
        }
        return url
    }()

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
    }

    static func package(name: String, id: UUID = UUID(), source: String? = nil) throws -> PluginPackage {
        let bytes = try AutomationTemplate.packageBytes(name: name, id: id)
        guard let source else { return try PluginPackage.validate(bytes) }
        let root = try JSONValue(parsing: bytes).objectValue!
        return try PluginPackage.validate(try JSONValue.object(["manifest": root["manifest"]!, "source": .string(source)]).data())
    }

    static func entry(for p: PluginPackage) -> JSONValue {
        .object(["id": .string(p.manifest.id.uuidString), "name": .string(p.manifest.name), "version": .string(p.manifest.version),
                 "packagePath": .string("\(p.manifest.id.uuidString).json"), "sha256": .string(p.revision), "size": .integer(Int64(p.bytes.count))])
    }

    static func snapshot(packages: [PluginPackage], sequence: Int64 = 1, key: Curve25519.Signing.PrivateKey? = nil,
                         repositoryID: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) throws -> VerifiedSnapshot {
        let index: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string(repositoryID.uuidString), "name": .string("Example Repo"), "sequence": .integer(sequence),
            "issuedAt": .string(iso(now.addingTimeInterval(-60))), "expiresAt": .string(iso(now.addingTimeInterval(86_400))),
            "plugins": .array(packages.map(entry)),
        ])
        let payload = try index.data()
        var envelope: [String: JSONValue] = ["schemaVersion": .integer(1), "payload": .string(payload.base64EncodedString())]
        if let key {
            let signature = try key.signature(for: Data("InterceptorRepository/v1".utf8) + [0] + payload)
            envelope["signature"] = .object(["algorithm": .string("ed25519"), "publicKey": .string(key.publicKey.rawRepresentation.base64EncodedString()),
                                             "value": .string(signature.base64EncodedString())])
        }
        return try RepositoryEnvelope.verify(envelope: try JSONValue.object(envelope).data(), url: url, now: now)
    }

    static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("automation-ui-\(UUID().uuidString)/catalog.json")
    }
}

/// Records calls; never touches the network. Can hold a request open to test cancellation.
final class FakeRepositoryClient: RepositoryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _previews = 0, _packages = 0
    let snapshot: VerifiedSnapshot
    let packages: [UUID: PluginPackage]
    var delayNanoseconds: UInt64 = 0
    /// When set, `preview` throws it (after the delay) instead of returning the snapshot.
    private var _previewError: Error?
    var previewError: Error? { get { lock.withLock { _previewError } } set { lock.withLock { _previewError = newValue } } }
    var previewCount: Int { lock.withLock { _previews } }
    var packageCount: Int { lock.withLock { _packages } }

    init(snapshot: VerifiedSnapshot, packages: [PluginPackage]) {
        self.snapshot = snapshot; self.packages = Dictionary(uniqueKeysWithValues: packages.map { ($0.manifest.id, $0) })
    }

    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot {
        lock.withLock { _previews += 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error = previewError { throw error }
        return snapshot
    }

    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage {
        lock.withLock { _packages += 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return packages[entry.id]!
    }
}

/// Scripted runtime double: completes with a canned result when released, and records inputs/cancellation.
final class FakeScriptRunner: ScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var _runs = [(source: String, hook: JavaScriptHook)](), _cancels = 0
    private var ignoresCancellation = false
    func setCancellationIgnored(_ ignored: Bool) { lock.withLock { ignoresCancellation = ignored } }
    var runs: [(source: String, hook: JavaScriptHook)] { lock.withLock { _runs } }
    var cancelCount: Int { lock.withLock { _cancels } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func run(source: String, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { c in lock.withLock { _runs.append((source, hook)); continuation = c } }
    }

    func cancel() {
        let c = lock.withLock { _cancels += 1; if ignoresCancellation { return Optional<CheckedContinuation<Data, Error>>.none }; defer { continuation = nil }; return continuation }
        c?.resume(throwing: JavaScriptExecutionError.cancelled)
    }

    func finish(_ result: Result<Data, Error>) {
        let c = lock.withLock { defer { continuation = nil }; return continuation }
        c?.resume(with: result)
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return condition()
}
