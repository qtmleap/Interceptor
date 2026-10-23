import Foundation
import XCTest
@testable import AutomationCore

final class RevocationApprovalRaceTests: AutomationTestCase {
    private func routedPackage() throws -> PluginPackage {
        try PluginPackage.validate(Data("""
        {"manifest":{"schemaVersion":2,"id":"\(pluginID)","name":"Race","version":"1.0.0",
        "matches":[{"hosts":["example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/"},"hooks":{"request":{"onEnter":"a.js"}}}],
        "read":{"metadata":[],"headers":[],"queryKeys":[],"body":{"mode":"none"}},
        "write":{"requestBody":false,"responseBody":false},"endpointBindings":[],"settings":{}},
        "sourceFiles":{"a.js":"Interceptor.attach({request:{onEnter(){}}});"}}
        """.utf8))
    }

    func testRevokeBeforeFirstApprovalInvalidatesTheReviewedGeneration() async throws {
        try await assertRevocationInvalidatesApproval(revokeAll: false)
    }

    func testRevokeAllBeforeFirstApprovalInvalidatesTheReviewedGeneration() async throws {
        try await assertRevocationInvalidatesApproval(revokeAll: true)
    }

    func testDisabledDeleteAndIdenticalReinstallInvalidateTheOldApproval() throws {
        let catalogURL = tempFile()
        let coordinator = InstallationCoordinator(catalogURL: catalogURL,
                                                 activationURL: catalogURL.appendingPathExtension("activation"))
        let package = try routedPackage()
        let first = try coordinator.importLocal(package.bytes, expectedSelectionGeneration: coordinator.state().selectionGeneration)
        let reviewed = InstallationApproval(packageBytes: package.bytes, expectedGrantGeneration: first.activation.generation)
        let revisionID = try XCTUnwrap(first.installed.first?.id)
        let deleted = try coordinator.delete(revisionID: revisionID, expectedSelectionGeneration: first.selectionGeneration)
        let replacement = try coordinator.importLocal(package.bytes, expectedSelectionGeneration: deleted.selectionGeneration)
        XCTAssertEqual(replacement.installed.first?.id, revisionID)
        XCTAssertNotEqual(replacement.activation.generation, reviewed.expectedGrantGeneration)
        XCTAssertThrowsError(try coordinator.activate(revisionID: revisionID,
            expectedSelectionGeneration: replacement.selectionGeneration, approval: reviewed, captureConsent: { true })) {
            XCTAssertEqual($0 as? AutomationError, .staleSnapshot)
        }
        XCTAssertTrue(try coordinator.state().activation.revisions.isEmpty)
    }

    private func assertRevocationInvalidatesApproval(revokeAll: Bool) async throws {
        let store = PluginActivationStore(fileURL: tempFile())
        let package = try routedPackage()
        let id = "local|\(package.manifest.id.uuidString)|\(package.revision)"
        let reviewed = try await store.snapshot()
        if revokeAll { _ = try await store.revokeAll() }
        else { _ = try await store.revoke(revisionID: id) }
        let revoked = try await store.snapshot()
        XCTAssertNotEqual(reviewed.generation, revoked.generation)
        do {
            _ = try await store.activate(package, revisionID: id, expectedGeneration: reviewed.generation)
            XCTFail("An explicit revocation must invalidate an already-open approval")
        } catch {
            XCTAssertEqual(error as? AutomationError, .staleSnapshot)
        }
        let final = try await store.snapshot()
        XCTAssertTrue(final.revisions.isEmpty)
    }
}
