import AutomationCore
import Foundation

/// Marks database failures separately from repository transport and validation failures.
struct PackageCatalogStorageFailure: Error {
    let underlying: Error
}

/// App-lifetime source ingestion. It never installs, selects, approves or activates a package.
/// Preparations are serialized across sources, with at most three package fetches in one preparation.
@MainActor
final class PackageCatalogSynchronization {
    private let database: any PackageCatalogStoring
    private let client: any RepositoryFetching
    private var preparing = false
    private struct PreparationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [PreparationWaiter] = []

    init(database: any PackageCatalogStoring, client: any RepositoryFetching) {
        self.database = database
        self.client = client
    }

    func stage(_ snapshot: VerifiedSnapshot, installed: [InstalledRevision], leaseID: UUID,
               admit: @MainActor () throws -> Bool = { true }) async throws {
        try await acquirePreparation()
        defer { releasePreparation() }
        try Task.checkCancellation()
        guard try admit() else { return }
        let inputs: [(IndexEntry, Data?)]
        do {
            inputs = try snapshot.index.plugins.map { entry in
                let stored = try database.reusableBytes(sha256: entry.sha256)
                let selected = installed.first { $0.package.revision == entry.sha256 }?.package.bytes
                return (entry, stored ?? selected)
            }
        } catch { throw PackageCatalogStorageFailure(underlying: error) }
        let packages = try await Self.prepare(inputs, from: snapshot, client: client)
        try Task.checkCancellation()
        do { try await database.stage(snapshot, packages: packages, leaseID: leaseID) }
        catch { throw PackageCatalogStorageFailure(underlying: error) }
    }

    private func acquirePreparation() async throws {
        try Task.checkCancellation()
        if !preparing {
            preparing = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(PreparationWaiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPreparation(id) }
        }
        // A successful resume transfers ownership. stage installs its defer before checking cancellation.
    }

    private func cancelPreparation(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releasePreparation() {
        if waiters.isEmpty { preparing = false }
        else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    nonisolated private static func prepare(_ inputs: [(IndexEntry, Data?)], from snapshot: VerifiedSnapshot,
                                           client: any RepositoryFetching) async throws -> [PluginPackage] {
        try await withThrowingTaskGroup(of: (Int, PluginPackage).self) { group in
            var next = 0
            var prepared: [Int: PluginPackage] = [:]
            func enqueue(_ index: Int) {
                let (entry, reused) = inputs[index]
                group.addTask {
                    try Task.checkCancellation()
                    let bytes: Data
                    if let reused { bytes = reused }
                    else { bytes = try await client.fetchPackage(entry: entry, from: snapshot).bytes }
                    try Task.checkCancellation()
                    return (index, try PluginPackage.validate(bytes, against: entry))
                }
            }
            while next < min(3, inputs.count) { enqueue(next); next += 1 }
            while let (index, package) = try await group.next() {
                prepared[index] = package
                if next < inputs.count { enqueue(next); next += 1 }
            }
            return inputs.indices.compactMap { prepared[$0] }
        }
    }
}
