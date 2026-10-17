import AutomationCore
import AutomationRepository
import Foundation
import Observation

/// Detail of one accepted repository. The index is the snapshot the user accepted; this model never refetches
/// it. Selecting a script downloads and verifies only that package for review; import is a separate step.
@MainActor @Observable
final class RepositoryDetailModel {
    enum Phase: Equatable { case idle, fetching, reviewing, importing, imported }

    private(set) var record: RepositoryRecord
    private(set) var selected: IndexEntry?
    private(set) var package: PluginPackage?
    private(set) var phase = Phase.idle
    private(set) var error: Error?
    var fingerprintText = ""

    private let controller: AutomationController
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(controller: AutomationController, record: RepositoryRecord) {
        self.controller = controller; self.record = record
    }

    var entries: [IndexEntry] {
        (record.snapshot?.index.plugins ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var badge: AutomationTrustBadge { AutomationTrustBadge(record.trust) }
    var canPin: Bool {
        if case .signedUnverified(let k) = record.trust { return FingerprintInput.normalized(fingerprintText) == k.hex }
        return false
    }

    func select(_ entry: IndexEntry) {
        guard let snap = record.snapshot, phase != .importing else { return }
        task?.cancel()
        let run = UUID(); token = run
        selected = entry; package = nil; error = nil; phase = .fetching
        let client = controller.client
        task = Task { [weak self] in
            do {
                let pkg = try await client.fetchPackage(entry: entry, from: snap)
                try Task.checkCancellation()
                self?.finishFetch(run, pkg)
            } catch { self?.fail(run, error) }
        }
    }

    /// Explicit import of the reviewed package as a disabled revision, bound to the accepted generation.
    func importDisabled() {
        guard phase == .reviewing, let snap = record.snapshot, let pkg = package else { return }
        let run = token; phase = .importing; error = nil
        let (controller, generation, clock) = (controller, record.generation, controller.now)
        task = Task { [weak self] in
            let done = await controller.mutate { try await controller.store.install(pkg, from: snap, expectedGeneration: generation, now: clock) }
            if done != nil { self?.finishImport(run) } else { self?.fail(run, controller.actionError ?? AutomationInputError.storeUnavailable) }
        }
    }

    func pin() {
        guard canPin, let typed = FingerprintInput.normalized(fingerprintText) else { return }
        let url = record.url
        Task { [weak self] in
            guard let self else { return }
            let updated = await controller.mutate { try await controller.store.pin(url, fingerprint: typed) }
            if let updated { record = updated; fingerprintText = ""; error = nil } else { error = controller.actionError }
        }
    }

    /// Independent model for one script screen, so leaving the list never cancels the child (and vice versa).
    func makeEntryModel() -> RepositoryDetailModel { RepositoryDetailModel(controller: controller, record: record) }

    func close() {
        task?.cancel(); task = nil; token = UUID()
        if phase == .fetching { phase = .idle }
    }

    private func finishFetch(_ run: UUID, _ pkg: PluginPackage) {
        guard run == token else { return }
        package = pkg; phase = .reviewing
    }

    private func finishImport(_ run: UUID) { guard run == token else { return }; phase = .imported }

    private func fail(_ run: UUID, _ error: Error) {
        guard run == token else { return }
        if error is CancellationError { phase = .idle; return }
        self.error = error
        phase = package == nil ? .idle : .reviewing
    }
}
