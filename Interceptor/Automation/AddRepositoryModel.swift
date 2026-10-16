import AutomationCore
import AutomationRepository
import Foundation
import Observation

/// Add-repository sheet. Preview only fetches and verifies; nothing is saved until an explicit add. Closing
/// cancels the fetch and any result arriving afterwards is discarded.
@MainActor @Observable
final class AddRepositoryModel {
    enum Phase: Equatable { case idle, fetching, previewed, adding, added }

    var urlText = "" { didSet { if urlText != oldValue { resetPreview() } } }
    var fingerprintText = ""
    private(set) var phase = Phase.idle
    private(set) var snapshot: VerifiedSnapshot?
    private(set) var acceptance: AcceptancePreview?
    private(set) var error: Error?

    private let controller: AutomationController
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(controller: AutomationController) { self.controller = controller }

    var canPreview: Bool { phase == .idle && !urlText.isEmpty && controller.storeError == nil }
    var offeredFingerprint: String? {
        if case .signed(let key)? = snapshot?.signature { return key.hex }
        return nil
    }
    var typedFingerprint: String? { FingerprintInput.normalized(fingerprintText) }
    var canVerifyAndAdd: Bool { phase == .previewed && typedFingerprint != nil && typedFingerprint == offeredFingerprint }

    func preview() {
        guard canPreview else { return }
        let run = UUID(); token = run; phase = .fetching; error = nil
        let (client, store, clock) = (controller.client, controller.store, controller.now)
        let text = urlText
        task = Task { [weak self] in
            do {
                let url = try RepositoryURL(parsing: text)
                let snap = try await client.preview(url: url, now: clock)
                let plan = try await store.preview(snap, now: clock)
                try Task.checkCancellation()
                self?.finishPreview(run, snap, plan)
            } catch { self?.fail(run, error) }
        }
    }

    /// Adds without trusting the publisher key (unsigned, or signed with a key nobody compared).
    func addUnverified() { commit(pinning: nil, acknowledge: true) }

    /// Re-adds a source that needs no acknowledgment (for example an already pinned key).
    func addContinuing() {
        guard acceptance?.requiresAcknowledgment == false else { return }
        commit(pinning: nil, acknowledge: false)
    }

    /// Requires the independently obtained full fingerprint to equal the offered key before anything is saved.
    func verifyAndAdd() {
        guard canVerifyAndAdd, let typed = typedFingerprint else {
            error = AutomationInputError.fingerprintFormat; return
        }
        commit(pinning: typed, acknowledge: true)
    }

    private func commit(pinning fingerprint: String?, acknowledge: Bool) {
        guard phase == .previewed, let snap = snapshot, controller.storeError == nil else { return }
        let run = token; phase = .adding; error = nil
        let (controller, clock) = (controller, controller.now)
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let committed = await controller.mutate {
                    if let fingerprint {
                        _ = try await controller.store.acceptAndPin(snap, fingerprint: fingerprint, now: clock)
                    } else {
                        _ = try await controller.store.accept(snap, acknowledgeUnverified: acknowledge, now: clock)
                    }
                }
                guard committed != nil else {
                    throw controller.actionError ?? controller.storeError ?? AutomationInputError.storeUnavailable
                }
                self?.finishAdd(run)
            } catch { self?.fail(run, error) }
        }
    }

    /// Called when the sheet closes: cancels the fetch/commit and invalidates late results.
    func cancel() {
        task?.cancel(); task = nil
        token = UUID()
        if phase != .added { phase = .idle }
    }

    private func resetPreview() {
        guard phase == .previewed || phase == .idle else { return }
        snapshot = nil; acceptance = nil; error = nil; fingerprintText = ""; phase = .idle
    }

    private func finishPreview(_ run: UUID, _ snap: VerifiedSnapshot, _ plan: AcceptancePreview) {
        guard run == token else { return }
        snapshot = snap; acceptance = plan; phase = .previewed
    }

    private func finishAdd(_ run: UUID) { guard run == token else { return }; phase = .added }

    private func fail(_ run: UUID, _ error: Error) {
        guard run == token else { return }
        if error is CancellationError { phase = .idle; return }
        self.error = error
        phase = snapshot == nil ? .idle : .previewed
    }
}
