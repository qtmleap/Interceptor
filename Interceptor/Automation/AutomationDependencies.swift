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
    func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date,
                expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord
    func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date,
                      expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord
    func refresh(_ snapshot: VerifiedSnapshot, expectedGeneration: UUID, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord
    func pin(_ url: RepositoryURL, fingerprint: String) async throws -> RepositoryRecord
    func remove(_ url: RepositoryURL) async throws
    func install(_ package: PluginPackage, from snapshot: VerifiedSnapshot, expectedGeneration: UUID, now: Date) async throws -> InstalledRevision
    func importLocal(_ bytes: Data) async throws -> InstalledRevision
    func editSource(of revisionID: String, to source: String) async throws -> InstalledRevision
    func editSource(of revisionID: String, file: String, to source: String) async throws -> InstalledRevision
    func editSources(of revisionID: String, to sources: [String: String]) async throws -> InstalledRevision
    func deleteRevision(_ revisionID: String) async throws
}

extension AutomationStoring {
    /// Old doubles must not silently bypass the reviewed source's admission condition.
    func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date,
                expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord {
        throw AutomationError.staleSnapshot
    }
    func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date,
                      expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord {
        throw AutomationError.staleSnapshot
    }
    /// Fail closed for doubles that predate refresh.
    func refresh(_ snapshot: VerifiedSnapshot, expectedGeneration: UUID, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord {
        throw AutomationError.staleSnapshot
    }
}

/// Blocking durable installation operations. The controller dispatches these off the main actor.
protocol InstallationCoordinating: Sendable {
    func state() throws -> InstallationState
    func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState
    func importLocal(_ bytes: Data, operation: InstallationOperation, expectedSelectionGeneration: UUID) throws -> InstallationState
    func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval,
                  captureConsent: @Sendable () -> Bool) throws -> InstallationState
    func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState
    func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState
    func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID,
                approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState
}

extension InstallationCoordinator: InstallationCoordinating {}

enum AutomationInstallationRoutingError: Error, Equatable, Sendable { case coordinatorRequired }

/// Old detail/session objects may still exist. They can read and manage metadata, but cannot stage
/// an installation or local edit that a legacy projection would accidentally select on the next read.
struct CoordinatorCatalogStore: AutomationStoring {
    let base: any AutomationStoring
    func load() async throws -> Catalog { try await base.load() }
    func catalog() async -> Catalog { await base.catalog() }
    func seedIfAbsent(_ snapshot: VerifiedSnapshot, expectedURL: RepositoryURL, expectedRepositoryID: UUID,
                      expectedFingerprint: String, now: Date) async throws -> RepositoryRecord {
        try await base.seedIfAbsent(snapshot, expectedURL: expectedURL, expectedRepositoryID: expectedRepositoryID,
                                    expectedFingerprint: expectedFingerprint, now: now)
    }
    func preview(_ snapshot: VerifiedSnapshot, now: Date) async throws -> AcceptancePreview { try await base.preview(snapshot, now: now) }
    func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord {
        try await base.accept(snapshot, acknowledgeUnverified: acknowledgeUnverified, now: now)
    }
    func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date) async throws -> RepositoryRecord {
        try await base.acceptAndPin(snapshot, fingerprint: fingerprint, now: now)
    }
    func accept(_ snapshot: VerifiedSnapshot, acknowledgeUnverified: Bool, now: Date,
                expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord {
        try await base.accept(snapshot, acknowledgeUnverified: acknowledgeUnverified, now: now, expecting: expecting)
    }
    func acceptAndPin(_ snapshot: VerifiedSnapshot, fingerprint: String, now: Date,
                      expecting: RepositoryAcceptanceExpectation) async throws -> RepositoryRecord {
        try await base.acceptAndPin(snapshot, fingerprint: fingerprint, now: now, expecting: expecting)
    }
    func refresh(_ snapshot: VerifiedSnapshot, expectedGeneration: UUID, acknowledgeUnverified: Bool, now: Date) async throws -> RepositoryRecord {
        try await base.refresh(snapshot, expectedGeneration: expectedGeneration, acknowledgeUnverified: acknowledgeUnverified, now: now)
    }
    func pin(_ url: RepositoryURL, fingerprint: String) async throws -> RepositoryRecord { try await base.pin(url, fingerprint: fingerprint) }
    func remove(_ url: RepositoryURL) async throws { try await base.remove(url) }
    func install(_ package: PluginPackage, from snapshot: VerifiedSnapshot, expectedGeneration: UUID, now: Date) async throws -> InstalledRevision {
        throw AutomationInstallationRoutingError.coordinatorRequired
    }
    func importLocal(_ bytes: Data) async throws -> InstalledRevision { throw AutomationInstallationRoutingError.coordinatorRequired }
    func editSource(of revisionID: String, to source: String) async throws -> InstalledRevision { throw AutomationInstallationRoutingError.coordinatorRequired }
    func editSource(of revisionID: String, file: String, to source: String) async throws -> InstalledRevision { throw AutomationInstallationRoutingError.coordinatorRequired }
    func editSources(of revisionID: String, to sources: [String: String]) async throws -> InstalledRevision { throw AutomationInstallationRoutingError.coordinatorRequired }
    func deleteRevision(_ revisionID: String) async throws { throw AutomationInstallationRoutingError.coordinatorRequired }
}

protocol RepositoryFetching: Sendable {
    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot
    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage
}

protocol ScriptRunning: AnyObject, Sendable {
    func run(source: String, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data
    func runV2(packageJSON: Data, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data
    func cancel()
}

extension ScriptRunning {
    func runV2(packageJSON: Data, hook: JavaScriptHook, eventJSON: Data, configJSON: Data) async throws -> Data {
        throw JavaScriptExecutionError.invalidInput
    }
}

extension AutomationStore: AutomationStoring {}
extension RepositoryClient: RepositoryFetching {}
extension JavaScriptExecutor: ScriptRunning {}
