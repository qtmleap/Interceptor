import AutomationCore
import AutomationRuntime
@testable import Interceptor
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

    func testSourceEditAndDeletionRevokeExactOldApprovalWithoutAutoEnabling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(fileURL: directory.appendingPathComponent("catalog.json"))
        let activation = PluginActivationStore(fileURL: directory.appendingPathComponent("active.json"))
        let package = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "Original"))
        let client = try FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let controller = AutomationController(store: store, client: client, executor: FakeScriptRunner(), activationStore: activation)
        await controller.load()
        let revision = try await store.importLocal(package.bytes)
        await controller.refreshCatalog()
        let initial = try await activation.snapshot()
        _ = try await activation.activate(package, revisionID: revision.id, expectedGeneration: initial.generation)
        let session = ScriptSession(controller: controller, revision: revision)
        session.source += "\n// edited"
        await session.saveAsLocalEdit()
        XCTAssertNotEqual(session.revision.id, revision.id)
        let afterEdit = try await activation.snapshot()
        XCTAssertTrue(afterEdit.revisions.isEmpty)
        XCTAssertTrue(controller.scripts.allSatisfy { !$0.enabled })
        _ = try await activation.activate(package, revisionID: revision.id, expectedGeneration: afterEdit.generation)
        await controller.deleteScript(id: revision.id)
        let afterDelete = try await activation.snapshot()
        XCTAssertTrue(afterDelete.revisions.isEmpty)
        XCTAssertFalse(controller.scripts.contains { $0.id == revision.id })
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
