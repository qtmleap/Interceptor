import Foundation
import XCTest
@testable import AutomationCore

final class UpdateApprovalInvalidationTests: AutomationTestCase {
    private func package(_ source: String) throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(pluginID.uuidString)","name":"P","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"a.js"}}}],
        "read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},"sourceFiles":{"a.js":"\(source)"}}
        """.utf8))
    }
    private func request(_ p: PluginPackage, file: URL, sequence: Int) async throws -> InstallationRequest {
        let snapshot = try snap(indexJSON(sequence: sequence, pkg: p.bytes))
        let repository = try await AutomationStore(fileURL: file).accept(snapshot, acknowledgeUnverified: true, now: now)
        return .init(package: p, snapshot: snapshot, expectedSourceGeneration: repository.generation, operation: .add)
    }

    func testSuppliedApprovalAfterExplicitRevocationRejectedIncludingSameRevision() async throws {
        for sameRevision in [false, true] {
            for revokeAll in [false, true] {
                let f = tempFile(), activation = f.appendingPathExtension("activation")
                let c = InstallationCoordinator(catalogURL: f, activationURL: activation), p = try package("// old")
                let initial = try await request(p, file: f, sequence: 1)
                var state = try c.batch([initial], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
                let base = state.installed[0].id
                state = try c.activate(revisionID: base, expectedSelectionGeneration: state.selectionGeneration,
                    approval: .init(packageBytes: p.bytes, expectedGrantGeneration: state.activation.generation), captureConsent: { true })
                let target = try (sameRevision ? p : package("// updated"))
                let update = try await request(target, file: f, sequence: 2)
                let approval = InstallationApproval(packageBytes: target.bytes, expectedGrantGeneration: state.activation.generation)
                let grantStore = PluginActivationStore(fileURL: activation, catalogURL: f)
                if revokeAll { _ = try await grantStore.revokeAll() }
                else { _ = try await grantStore.revoke(revisionID: base) }
                let revoked = try c.state(), catalogBytes = try Data(contentsOf: f), sharedBytes = try Data(contentsOf: activation)
                XCTAssertEqual(revoked.selectionGeneration, state.selectionGeneration)
                XCTAssertNotEqual(revoked.activation.generation, approval.expectedGrantGeneration)
                XCTAssertTrue(revoked.activation.revisions.isEmpty)
                XCTAssertThrowsError(try c.update(update, baseRevisionID: base, expectedSelectionGeneration: revoked.selectionGeneration,
                    approval: approval, now: now, captureConsent: { XCTFail("Reject stale approval before consent"); return true })) {
                    XCTAssertEqual($0 as? AutomationError, .staleSnapshot)
                }
                XCTAssertEqual(try Data(contentsOf: f), catalogBytes, "Rejected review must not stage bytes")
                XCTAssertEqual(try Data(contentsOf: activation), sharedBytes, "Rejected review must not publish or change either generation")
                XCTAssertEqual(try c.state(), revoked)
            }
        }
    }

    func testDisabledUpdateRejectsWrongSuppliedBytesIncludingSameRevisionButAllowsNoApproval() async throws {
        for sameRevision in [false, true] {
            let f = tempFile(), activation = f.appendingPathExtension("activation")
            let c = InstallationCoordinator(catalogURL: f, activationURL: activation), p = try package("// old")
            let initial = try await request(p, file: f, sequence: 1)
            let state = try c.batch([initial], expectedSelectionGeneration: c.state().selectionGeneration, now: now)
            let target = try (sameRevision ? p : package("// updated"))
            let update = try await request(target, file: f, sequence: 2)
            let invalid = InstallationApproval(packageBytes: Data("not the reviewed package".utf8), expectedGrantGeneration: state.activation.generation)
            let catalogBytes = try Data(contentsOf: f), sharedBytes = try Data(contentsOf: activation)
            XCTAssertThrowsError(try c.update(update, baseRevisionID: state.installed[0].id,
                expectedSelectionGeneration: state.selectionGeneration, approval: invalid, now: now, captureConsent: { false })) {
                XCTAssertEqual($0 as? InstallationError, .approvalRequired)
            }
            XCTAssertEqual(try Data(contentsOf: f), catalogBytes)
            XCTAssertEqual(try Data(contentsOf: activation), sharedBytes)
            let result = try c.update(update, baseRevisionID: state.installed[0].id,
                expectedSelectionGeneration: state.selectionGeneration, approval: nil, now: now, captureConsent: { false })
            XCTAssertEqual(result.installed.map(\.package.bytes), [target.bytes])
            XCTAssertEqual(result.activation, state.activation)
        }
    }
}
