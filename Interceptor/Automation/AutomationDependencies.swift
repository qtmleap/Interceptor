import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation

/// Narrow seams over the real Core/Repository/Runtime types so the controller can be tested with the same
/// production types (or recording doubles for the network and the JavaScript engine).
protocol AutomationStoring: Sendable {
    func load() async throws -> Catalog
    func catalog() async -> Catalog
    func seedIfAbsent(_ snapshot: VerifiedSnapshot, expectedURL: RepositoryURL, expectedRepositoryID: UUID,
                      expectedFingerprint: String, now: Date) async throws -> RepositoryRecord
    func preview(_ snapshot: VerifiedSnapshot, now: Date) async throws -> AcceptancePreview
    func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord
    func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date) async throws -> RepositoryRecord
    func pin(_ url: RepositoryURL, fingerprint: String) async throws -> RepositoryRecord
    func remove(_ url: RepositoryURL) async throws
    func install(_ package: PluginPackage, from snapshot: VerifiedSnapshot, expectedGeneration: UUID, now: Date) async throws -> InstalledRevision
    func importLocal(_ bytes: Data) async throws -> InstalledRevision
    func editSource(of revisionID: String, to source: String) async throws -> InstalledRevision
    func deleteRevision(_ revisionID: String) async throws
}

protocol RepositoryFetching: Sendable {
    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot
    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage
}

protocol ScriptRunning: AnyObject, Sendable {
    func run(source: String, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data
    func cancel()
}

extension AutomationStore: AutomationStoring {}
extension RepositoryClient: RepositoryFetching {}
extension JavaScriptExecutor: ScriptRunning {}
