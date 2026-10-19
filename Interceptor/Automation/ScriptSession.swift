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
    private(set) var saveErrorKey: String?
    private(set) var isSaving = false
    private(set) var bodyPreview: String?
    var activationGeneration: UUID? {
        controller.activationSnapshot?.generation
    }

    var isActive: Bool {
        controller.isActive(revision.id)
    }

    var activationError: Error? {
        controller.activationError
    }

    var activationErrorKey: String? {
        controller.activationErrorKey
    }

    var activationAvailable: Bool {
        controller.activationStore != nil && controller.activationSnapshot != nil
    }

    var isV2: Bool {
        revision.package.manifest.schemaVersion == 2
    }

    var hooks: [JavaScriptHook] {
        isV2 ? [.requestEnter, .requestLeave, .responseEnter, .responseLeave] : [.request, .response]
    }

    func refreshActivation() async {
        await controller.refreshActivation()
    }

    func activate(expectedGeneration: UUID) async {
        guard !isDirty, !isSaving else { return }
        await controller.activate(revision, expectedGeneration: expectedGeneration)
    }

    func revokeActivation() async {
        await controller.revokeActivation(id: revision.id)
    }

    /// Selection is only an editor concern. Runtime routing always receives the full package.
    var selectedSourceFile: String?
    private(set) var sourceFiles: [String: String]
    private var legacySource: String
    var sourceFileNames: [String] {
        sourceFiles.keys.sorted()
    }

    var source: String {
        get {
            if isV2 {
                return selectedSourceFile.flatMap { sourceFiles[$0] } ?? ""
            }
            return legacySource
        }
        set {
            guard !Self.sameSource(source, newValue) else { return }
            if isV2 {
                guard let file = selectedSourceFile, sourceFiles[file] != nil else { return }
                sourceFiles[file] = newValue
            } else {
                legacySource = newValue
            }
            invalidateResult()
        }
    }

    var hook = JavaScriptHook.request {
        didSet {
            if hook != oldValue {
                eventText = SyntheticFixture.eventJSON(for: hook); invalidateResult()
            }
        }
    }

    var eventText = SyntheticFixture.eventJSON(for: .request) {
        didSet {
            if eventText != oldValue {
                invalidateResult()
            }
        }
    }

    var configText = SyntheticFixture.configJSON {
        didSet {
            if configText != oldValue {
                invalidateResult()
            }
        }
    }

    private let controller: AutomationController
    private var runTask: Task<Void, Never>?
    private var runToken = UUID()

    init(controller: AutomationController, revision: InstalledRevision) {
        self.controller = controller; self.revision = revision
        sourceFiles = revision.package.sourceFiles
        selectedSourceFile = revision.package.sourceFiles.keys.sorted().first
        legacySource = revision.package.source ?? ""
        if revision.package.manifest.schemaVersion == 2 {
            hook = .requestEnter
            eventText = SyntheticFixture.eventJSON(for: .requestEnter)
            configText = (try? JSONValue.object(["settings": revision.package.manifest.settings, "endpoints": .object([:])]).jsonString()) ?? "{}"
        }
    }

    var badge: AutomationTrustBadge {
        AutomationTrustBadge(revision.provenance)
    }

    var isDirty: Bool {
        if isV2 {
            return sourceFiles.count != revision.package.sourceFiles.count || sourceFiles.contains {
                !Self.sameSource($0.value, revision.package.sourceFiles[$0.key])
            }
        }
        return !Self.sameSource(legacySource, revision.package.source)
    }

    var isRunning: Bool {
        runState == .running
    }

    var sourceFitsLimit: Bool {
        (isV2 ? sourceFiles.values.reduce(0) { $0 + $1.utf8.count } : legacySource.utf8.count) <= Limits.source
    }

    var canSave: Bool {
        isDirty && sourceFitsLimit && !isRunning && !isSaving && controller.storeError == nil
    }

    var canRun: Bool {
        !isRunning && !isSaving && !isDirty && sourceFitsLimit
    }

    /// New immutable revision with parent link; the original stays installed. Not executed.
    func saveAsLocalEdit() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let id = revision.id, text = legacySource, files = sourceFiles, savesFiles = isV2
        if isV2, await !(controller.revokeActivation(id: id)) {
            saveError = controller.activationError
            saveErrorKey = controller.activationErrorKey
            return
        }
        guard let saved = await controller.mutate({
            if savesFiles {
                return try await controller.store.editSources(of: id, to: files)
            }
            return try await controller.store.editSource(of: id, to: text)
        }) else {
            saveError = controller.actionError ?? controller.storeError ?? AutomationInputError.storeUnavailable
            saveErrorKey = saveError.map { AutomationErrorText.key(for: $0) }
            return
        }
        saveError = nil
        saveErrorKey = nil
        revision = saved
        // Keep newer typing in any file while this immutable snapshot is being saved.
        if savesFiles {
            for (file, captured) in files where Self.sameSource(sourceFiles[file], captured) {
                sourceFiles[file] = saved.package.sourceFiles[file]
            }
        } else if Self.sameSource(legacySource, text) {
            legacySource = saved.package.source ?? ""
        }
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
        let (executor, package, selected) = (controller.executor, revision.package, hook)
        let manifest = package.manifest
        bodyPreview = nil
        runTask = Task { [weak self] in
            let state: RunState
            do {
                let data: Data
                if manifest.schemaVersion == 2 {
                    data = try await executor.runV2(packageJSON: package.bytes, hook: selected, eventJSON: event, configJSON: config)
                } else {
                    guard let code = package.source else { throw JavaScriptExecutionError.invalidInput }
                    data = try await executor.run(source: code, hook: selected, eventJSON: event, configJSON: config)
                }
                let result = try SyntheticResult.parse(data, hook: selected, manifest: manifest)
                guard self?.runToken == token else { return }
                self?.bodyPreview = result.bodyPreview
                state = .finished(result.actions)
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
        if isRunning {
            controller.executor.cancel()
        }
        runTask?.cancel(); runTask = nil
        runToken = UUID()
        if isRunning {
            runState = .idle
        }
    }

    private func finishRun(_ token: UUID, _ state: RunState) {
        guard token == runToken else { return }
        runState = state
    }

    private func invalidateResult() {
        if isRunning {
            controller.executor.cancel()
        }
        runToken = UUID()
        runState = .idle
        bodyPreview = nil
    }

    private static func sameSource(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
            case (.none, .none): true
            case let (.some(left), .some(right)): left.utf8.elementsEqual(right.utf8)
            default: false
        }
    }

    /// Strict, size-bounded JSON object text → compact bytes (rejects duplicate keys, non-objects, oversize).
    static func boundedJSON(_ text: String, max: Int) -> Data? {
        let raw = Data(text.utf8)
        guard raw.count <= max, let value = try? JSONValue(parsing: raw), value.objectValue != nil, let data = try? value.data(), data.count <= max else { return nil }
        return data
    }
}
