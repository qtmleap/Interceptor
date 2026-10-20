import Foundation
import XCTest
@testable import AutomationCore

final class ActivationInitializationInterleavingTests: AutomationTestCase {
    private func package(_ id: UUID = UUID()) throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(id.uuidString)","name":"Race","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"a.js"}}}],
        "read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},
        "sourceFiles":{"a.js":"Interceptor.attach({request:{onEnter(){}}});"}}
        """.utf8))
    }

    func testInitializationDuringMissingReadPreservesUnchangedAdmission() async throws {
        let file = tempFile(), shared = file.appendingPathExtension("activation")
        let coordinator = InstallationCoordinator(catalogURL: file, activationURL: shared)
        let before = try coordinator.state(), candidate = try package()
        let interleaving = InitializationReadInterleaving()
        let reader = PluginActivationStore(fileURL: shared, writer: { try $0.replace(with: $1) },
                                           reader: { try interleaving.read($0) })
        interleaving.arm {
            _ = try coordinator.importLocal(candidate.bytes, expectedSelectionGeneration: before.selectionGeneration)
        }
        let observed = try await reader.snapshot()
        XCTAssertEqual(observed, before.activation)
        let current = await reader.isCurrent(admitted: before.activation)
        XCTAssertTrue(current, "An unchanged grant must remain admitted during disabled installation")
    }

    func testInitializationDuringV1ReadPreservesUnchangedAdmission() async throws {
        try await assertLegacyInterleaving(cached: false)
    }

    func testInitializationDuringCachedV1ReadPreservesUnchangedAdmission() async throws {
        try await assertLegacyInterleaving(cached: true)
    }

    private func assertLegacyInterleaving(cached: Bool) async throws {
        let file = tempFile(), shared = file.appendingPathExtension("activation")
        let first = try package(), second = try package()
        let installed = try await AutomationStore(fileURL: file).importLocal(first.bytes)
        let legacy = PluginActivationStore(fileURL: shared)
        let empty = try await legacy.snapshot()
        let admitted = try await legacy.activate(first, revisionID: installed.id, expectedGeneration: empty.generation)
        let coordinator = InstallationCoordinator(catalogURL: file, activationURL: shared)
        let before = try coordinator.state(), interleaving = InitializationReadInterleaving()
        let reader = PluginActivationStore(fileURL: shared, writer: { try $0.replace(with: $1) },
                                           reader: { try interleaving.read($0) })
        if cached {
            let initial = try await reader.snapshot()
            XCTAssertEqual(initial, admitted)
        }
        interleaving.arm {
            _ = try coordinator.importLocal(second.bytes, expectedSelectionGeneration: before.selectionGeneration)
        }
        let observed = try await reader.snapshot()
        XCTAssertEqual(observed, admitted)
        XCTAssertEqual(try coordinator.state().activation, admitted)
        let current = await reader.isCurrent(admitted: admitted)
        XCTAssertTrue(current, "Reading across initialization must not stop unchanged live hooks")
    }
}

/// Publishes a real transaction after the first read has captured its bytes, before marker observation.
private final class InitializationReadInterleaving: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?

    func arm(_ action: @escaping @Sendable () throws -> Void) { lock.withLock { self.action = action } }

    func read(_ file: CatalogFile) throws -> Data? {
        let bytes = try file.read(maximumBytes: PluginActivationStore.maxBytes)
        let pending = lock.withLock {
            let pending = action
            action = nil
            return pending
        }
        try pending?()
        return bytes
    }
}
