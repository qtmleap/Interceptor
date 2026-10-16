import AutomationCore
import AutomationRuntime
import Foundation
import Observation

/// Editing and dry-running one installed revision. Saving creates a new local-edit revision and never runs
/// code. A run is explicit; any edit of source, hook, event or config discards the previous result, and a
/// result that arrives after such an edit or after leaving the screen is dropped.
@MainActor @Observable
final class ScriptSession {
    enum RunState: Equatable { case idle, running, finished([ValidatedAction]), failed(String) }

    private(set) var revision: InstalledRevision
    private(set) var runState = RunState.idle
    private(set) var saveError: Error?
    private(set) var isSaving = false

    var source: String { didSet { if source != oldValue { invalidateResult() } } }
    var hook = JavaScriptHook.request {
        didSet { if hook != oldValue { eventText = SyntheticFixture.eventJSON(for: hook); invalidateResult() } }
    }
    var eventText = SyntheticFixture.eventJSON(for: .request) { didSet { if eventText != oldValue { invalidateResult() } } }
    var configText = SyntheticFixture.configJSON { didSet { if configText != oldValue { invalidateResult() } } }

    private let controller: AutomationController
    private var runTask: Task<Void, Never>?
    private var runToken = UUID()

    init(controller: AutomationController, revision: InstalledRevision) {
        self.controller = controller; self.revision = revision; source = revision.package.source
    }

    var badge: AutomationTrustBadge { AutomationTrustBadge(revision.provenance) }
    var isDirty: Bool { source != revision.package.source }
    var isRunning: Bool { runState == .running }
    var sourceFitsLimit: Bool { source.utf8.count <= Limits.source }
    var canSave: Bool { isDirty && sourceFitsLimit && !isRunning && !isSaving && controller.storeError == nil }
    var canRun: Bool { !isRunning && !isSaving && !isDirty && sourceFitsLimit }

    /// New immutable revision with parent link; the original stays installed. Not executed.
    func saveAsLocalEdit() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let id = revision.id, text = source
        guard let saved = await controller.mutate({ try await controller.store.editSource(of: id, to: text) }) else {
            saveError = controller.actionError ?? controller.storeError ?? AutomationInputError.storeUnavailable; return
        }
        saveError = nil
        revision = saved
        // Preserve any newer typing that arrived while the store was saving the captured text.
        if source == text { source = saved.package.source }
        invalidateResult()
    }

    func run() {
        guard canRun else { return }
        guard let event = Self.boundedJSON(eventText, max: JavaScriptLimits.maxEventBytes) else {
            runState = .failed("AUTO_ERR_EVENT_INVALID"); return
        }
        guard let config = Self.boundedJSON(configText, max: JavaScriptLimits.maxConfigBytes) else {
            runState = .failed("AUTO_ERR_CONFIG_INVALID"); return
        }
        let token = UUID(); runToken = token; runState = .running
        let (executor, code, selected) = (controller.executor, revision.package.source, hook)
        runTask = Task { [weak self] in
            let state: RunState
            do {
                let data = try await executor.run(source: code, hook: selected, eventJSON: event, configJSON: config)
                state = .finished(try ValidatedAction.parse(data))
            } catch { state = .failed(AutomationErrorText.key(for: error)) }
            self?.finishRun(token, state)
        }
    }

    func cancelRun() {
        guard isRunning else { return }
        controller.executor.cancel()
        runTask?.cancel()
        runTask = nil
        runToken = UUID()
        runState = .failed("AUTO_ERR_JS_CANCELLED")
    }

    /// Leaving the screen: cancels the runtime and ensures no late result is applied.
    func leave() {
        if isRunning { controller.executor.cancel() }
        runTask?.cancel(); runTask = nil
        runToken = UUID()
        if isRunning { runState = .idle }
    }

    private func finishRun(_ token: UUID, _ state: RunState) {
        guard token == runToken else { return }
        runState = state
    }

    private func invalidateResult() {
        if isRunning { controller.executor.cancel() }
        runToken = UUID()
        runState = .idle
    }

    /// Strict, size-bounded JSON object text → compact bytes (rejects duplicate keys, non-objects, oversize).
    static func boundedJSON(_ text: String, max: Int) -> Data? {
        let raw = Data(text.utf8)
        guard raw.count <= max, let value = try? JSONValue(parsing: raw), value.objectValue != nil, let data = try? value.data(), data.count <= max else { return nil }
        return data
    }
}
