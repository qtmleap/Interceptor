import AutomationCore
import AutomationRuntime
@testable import Interceptor
import Observation
import XCTest

@MainActor
final class HTTPHookPresentationTests: XCTestCase {
    func testAllFourFixturesAreStrictObjectsWithSeparatePhases() throws {
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .responseLeave] {
            let root = try JSONValue(parsing: Data(SyntheticFixture.eventJSON(for: hook).utf8))
            XCTAssertEqual(root.objectValue?["phase"], .string(hook.rawValue))
            XCTAssertNotNil(root.objectValue?["request"]?.objectValue?["body"])
        }
    }

    func testAppLinkedTemplateUsesFourSeparateRuntimePhases() async throws {
        let package = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Runtime"))
        let executor = JavaScriptExecutor()
        for hook in [JavaScriptHook.requestEnter, .requestLeave, .responseEnter, .responseLeave] {
            let bytes = try await executor.runV2(packageJSON: package.bytes, hook: hook,
                                                 eventJSON: Data(SyntheticFixture.eventJSON(for: hook).utf8),
                                                 configJSON: Data("{}".utf8))
            let result = try SyntheticResult.parse(bytes, hook: hook, manifest: package.manifest)
            XCTAssertTrue(result.actions.isEmpty)
            switch hook {
                case .requestEnter: XCTAssertEqual(result.bodyPreview, #"{"limit":5}"#)
                case .responseEnter: XCTAssertEqual(result.bodyPreview, #"{"maintenance":true}"#)
                default: XCTAssertNil(result.bodyPreview)
            }
        }
    }

    func testPreviewOnlyAllowsDeclaredEnterBodyMutation() throws {
        let manifest = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "JSON")).manifest
        let result = Data(#"{"actions":[],"mutation":{"body":{"limit":5}}}"#.utf8)
        let preview = try SyntheticResult.parse(result, hook: .requestEnter, manifest: manifest)
        XCTAssertEqual(preview.bodyPreview, #"{"limit":5}"#)
        XCTAssertTrue(preview.actions.isEmpty)
        XCTAssertThrowsError(try SyntheticResult.parse(result, hook: .requestLeave, manifest: manifest))
        XCTAssertThrowsError(try SyntheticResult.parse(result, hook: .responseLeave, manifest: manifest))
        XCTAssertThrowsError(try SyntheticResult.parse(Data(#"{"actions":[],"mutation":{"body":{},"headers":{}}}"#.utf8), hook: .requestEnter, manifest: manifest))
        XCTAssertThrowsError(try SyntheticResult.parse(result, hook: .requestEnter, manifest: PluginPackage.template().manifest))
    }

    func testCoordinatorDeletionRevokesExactApprovalAndKeepsHistoryDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let store = AutomationStore(fileURL: catalogURL)
        let activation = PluginActivationStore(fileURL: directory.appendingPathComponent("active.json"), catalogURL: catalogURL)
        let coordinator = InstallationCoordinator(catalogURL: catalogURL, activationURL: directory.appendingPathComponent("active.json"))
        let package = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Original"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let revision = try await store.importLocal(package.bytes)
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), activationStore: activation,
                                              installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
        await controller.load()
        let initial = try coordinator.state()
        await controller.activate(revision, expectedGeneration: initial.activation.generation)
        XCTAssertTrue(controller.isActive(revision.id))
        await controller.deleteScript(id: revision.id)
        let afterDelete = try coordinator.state()
        XCTAssertTrue(afterDelete.activation.revisions.isEmpty)
        XCTAssertTrue(afterDelete.installed.isEmpty)
        XCTAssertEqual(afterDelete.catalog.revision(id: revision.id)?.package.bytes, package.bytes)
        XCTAssertTrue(afterDelete.catalog.revisions.allSatisfy { !$0.enabled })
        XCTAssertFalse(controller.scripts.contains { $0.id == revision.id })
        XCTAssertNil(controller.actionError)
    }

    func testFileDraftsSurviveSelectionAndSaveTogetherInOneChildRevision() async throws {
        let (session, controller, _) = try await multiFileSession()
        let parent = session.revision
        let files = session.sourceFileNames
        XCTAssertEqual(files.count, 2)
        session.selectedSourceFile = files[0]
        let first = session.source + "\n// first edit"
        session.source = first
        session.selectedSourceFile = files[1]
        let second = session.source + "\n// second edit"
        session.source = second
        session.selectedSourceFile = files[0]
        XCTAssertEqual(session.source, first)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.canRun)
        await session.saveAsLocalEdit()
        XCTAssertNil(session.saveError)
        XCTAssertEqual(session.revision.package.sourceFiles, [files[0]: first, files[1]: second])
        XCTAssertEqual(session.revision.package.manifest, parent.package.manifest)
        XCTAssertEqual(session.revision.provenance.origin, .localEdit(parent: parent.package.revision))
        XCTAssertEqual(controller.scripts.count, 2, "one atomic save creates one child, preserving the parent")
        XCTAssertEqual(controller.scripts.first { $0.id == parent.id }?.package, parent.package)
        XCTAssertFalse(session.isDirty)
        session.selectedSourceFile = files[1]
        XCTAssertEqual(session.source, second)
    }

    func testEditorSelectionDoesNotChooseRuntimeSourceAndAnyFileEditDropsResults() async throws {
        let (session, _, runner) = try await multiFileSession()
        session.selectedSourceFile = session.sourceFileNames.last
        runner.setCancellationIgnored(true)
        session.run()
        let started = await waitUntil { runner.isWaiting }
        XCTAssertTrue(started)
        XCTAssertEqual(runner.runs.first?.packageJSON, session.revision.package.bytes)
        XCTAssertNil(runner.runs.first?.source)
        session.source += "\n// invalidates result"
        XCTAssertEqual(session.runState, .idle)
        XCTAssertEqual(runner.cancelCount, 1)
        session.selectedSourceFile = session.sourceFileNames.first
        XCTAssertTrue(session.isDirty, "an edit in another file still blocks run and activation")
        XCTAssertFalse(session.canRun)
        runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        await Task.yield()
        XCTAssertEqual(session.runState, .idle)
    }

    func testCombinedFileSourceLimitIsCheckedBeforeSaveOrRun() async throws {
        let (session, _, _) = try await multiFileSession()
        for file in session.sourceFileNames {
            session.selectedSourceFile = file
            session.source = String(repeating: " ", count: Limits.source / 2 + 1)
        }
        XCTAssertFalse(session.sourceFitsLimit)
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.canRun)
    }

    func testUnicodeEquivalentSourceEditStillCreatesByteDistinctRevision() async throws {
        let (session, _, _) = try await multiFileSession()
        session.source += "\n// caf\u{00e9}"
        await session.saveAsLocalEdit()
        XCTAssertNil(session.saveError)
        let parent = session.revision
        session.source = session.source.replacingOccurrences(of: "\u{00e9}", with: "e\u{0301}")
        XCTAssertTrue(session.isDirty, "source editing tracks exact UTF-8 bytes")
        await session.saveAsLocalEdit()
        XCTAssertNil(session.saveError)
        XCTAssertNotEqual(session.revision.package.revision, parent.package.revision)
        XCTAssertFalse(session.isDirty)
    }

    func testEmptyResultNoticeIsPerRunAndOnlyForNoEffect() async throws {
        let (session, runner) = try await templateSession()
        let empty = Data(#"{"actions":[]}"#.utf8)
        try await finishRun(session, runner, Data(#"{"actions":[],"mutation":{"body":{"limit":5}}}"#.utf8))
        XCTAssertEqual(session.bodyPreview, #"{"limit":5}"#)
        XCTAssertNil(session.emptyResultNotice, "a body mutation is a real result")
        try await finishRun(session, runner, empty)
        let first = try XCTUnwrap(session.emptyResultNotice)
        session.dismissEmptyResultNotice()
        XCTAssertNil(session.emptyResultNotice)
        XCTAssertEqual(session.runState, .finished([]), "dismissing keeps the result")
        try await finishRun(session, runner, empty)
        XCTAssertNotEqual(session.emptyResultNotice, first, "a repeated empty result is a new notice")
    }

    func testCancelLeaveAndStaleCompletionNeverShowEmptyResultNotice() async throws {
        let (session, runner) = try await templateSession()
        let empty = Data(#"{"actions":[]}"#.utf8)
        session.run()
        _ = await waitUntil { runner.isWaiting }
        session.cancelRun()
        await Task.yield()
        XCTAssertNil(session.emptyResultNotice)
        runner.setCancellationIgnored(true)
        session.run()
        _ = await waitUntil { runner.isWaiting }
        session.leave()
        let unexpectedNotice = expectation(description: "a late completion must not present an empty-result alert")
        unexpectedNotice.isInverted = true
        withObservationTracking { _ = session.emptyResultNotice } onChange: { unexpectedNotice.fulfill() }
        runner.finish(.success(empty))
        let lateResult = await XCTWaiter.fulfillment(of: [unexpectedNotice], timeout: 0.2)
        XCTAssertEqual(lateResult, .completed)
        XCTAssertNil(session.emptyResultNotice)
        XCTAssertEqual(session.runState, .idle)
    }

    func testInitialInputsAreFormattedAndFormattingThemKeepsTheResult() async throws {
        let (session, runner) = try await templateSession()
        XCTAssertEqual(session.eventText, JSONPrettyPrinter.format(session.eventText, maxBytes: JavaScriptLimits.maxEventBytes))
        XCTAssertEqual(session.configText, JSONPrettyPrinter.format(session.configText, maxBytes: JavaScriptLimits.maxConfigBytes))
        try await finishRun(session, runner, Data(#"{"actions":[],"mutation":{"body":{"limit":5}}}"#.utf8))
        let finished = session.runState
        session.formatInputs()
        XCTAssertEqual(session.runState, finished, "already formatted inputs must not clear the result")
        XCTAssertEqual(session.bodyPreview, #"{"limit":5}"#, "stored preview bytes stay compact")
    }

    func testFormattingRunsOnEditEndAndBeforeRunButNeverOnInvalidText() async throws {
        let (session, runner) = try await templateSession()
        session.eventText = #"{"id":"x","request":{"body":{"limit":20}}}"#
        session.formatInputs()
        XCTAssertEqual(session.eventText, "{\n  \"id\": \"x\",\n  \"request\": {\n    \"body\": {\n      \"limit\": 20\n    }\n  }\n}")
        let invalid = #"{"id":"#
        session.eventText = invalid
        session.formatInputs()
        XCTAssertEqual(session.eventText, invalid)
        session.eventText = SyntheticFixture.eventJSON(for: session.hook)
        session.configText = "{ \"endpoints\" : { } }"
        session.run()
        XCTAssertEqual(session.configText, "{\n  \"endpoints\": {}\n}", "run formats first")
        _ = await waitUntil { runner.isWaiting }
        XCTAssertTrue(session.isRunning)
        runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        _ = await waitUntil { !session.isRunning }
    }

    func testFormattingNeverMutatesInputsWhileRunning() async throws {
        let (session, runner) = try await templateSession()
        session.run()
        _ = await waitUntil { runner.isWaiting }
        XCTAssertTrue(session.isRunning)
        let before = (session.eventText, session.configText)
        session.formatInputs()
        XCTAssertEqual(session.eventText, before.0)
        XCTAssertEqual(session.configText, before.1)
        XCTAssertTrue(session.isRunning, "formatting must not cancel a pending run")
        session.formatInput(.event)
        session.formatInput(.config)
        XCTAssertTrue(session.isRunning)
        runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        _ = await waitUntil { !session.isRunning }
    }

    func testFormattingOneEditorLeavesTheFocusedEditorUntouched() async throws {
        let (session, _) = try await templateSession()
        session.eventText = #"{"id":"x"}"#
        session.configText = #"{"settings":{"x":1}}"#
        let config = session.configText
        session.formatInput(.event)
        XCTAssertEqual(session.eventText, "{\n  \"id\": \"x\"\n}")
        XCTAssertEqual(session.configText, config)
        session.formatInput(.config)
        XCTAssertTrue(session.configText.contains("\n  "))
    }

    func testSelectedSourceFileSurvivesWithoutChoosingRuntimeSourceOrCancellingRun() async throws {
        let (session, _, runner) = try await multiFileSession()
        session.run()
        _ = await waitUntil { runner.isWaiting }
        let bytes = session.revision.package.bytes
        session.selectedSourceFile = session.sourceFileNames.last
        XCTAssertTrue(session.isRunning, "browsing source never cancels a pending dry run")
        XCTAssertEqual(runner.runs.first?.packageJSON, bytes)
        XCTAssertEqual(runner.cancelCount, 0)
        runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        _ = await waitUntil { !session.isRunning }
        XCTAssertEqual(session.selectedSourceFile, session.sourceFileNames.last)
        XCTAssertFalse(session.isDirty)
    }

    private func finishRun(_ session: ScriptSession, _ runner: FakeScriptRunner, _ data: Data) async throws {
        session.run()
        let started = await waitUntil { runner.isWaiting }
        XCTAssertTrue(started)
        runner.finish(.success(data))
        let done = await waitUntil { session.runState != .running }
        XCTAssertTrue(done)
    }

    private func templateSession() async throws -> (ScriptSession, FakeScriptRunner) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notice-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let package = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Notice"))
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let runner = FakeScriptRunner()
        let controller = AutomationController(store: store, client: client, executor: runner)
        await controller.load()
        let revision = try await store.importLocal(package.bytes)
        return (ScriptSession(controller: controller, revision: revision), runner)
    }

    private func multiFileSession() async throws -> (ScriptSession, AutomationController, FakeScriptRunner) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("files-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let package = try AutomationFixtures.multiFilePackage(name: "Files")
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let runner = FakeScriptRunner()
        let controller = AutomationController(store: store, client: client, executor: runner)
        await controller.load()
        let revision = try await store.importLocal(package.bytes)
        await controller.refreshCatalog()
        return (ScriptSession(controller: controller, revision: revision), controller, runner)
    }

    func testLegacyRevisionKeepsLegacyDryRunHooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try PluginPackage.template()
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner())
        await controller.load()
        let revision = try await store.importLocal(package.bytes)
        let session = ScriptSession(controller: controller, revision: revision)
        XCTAssertEqual(session.hooks, [.request, .response])
        XCTAssertEqual(session.hook, .request)
    }
}
