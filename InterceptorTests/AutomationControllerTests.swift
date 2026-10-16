import AutomationCore
import AutomationRepository
import AutomationRuntime
import CryptoKit
import XCTest
@testable import Interceptor

@MainActor
final class AutomationControllerTests: XCTestCase {
    private var storeURL = AutomationFixtures.tempStoreURL()
    private var runner = FakeScriptRunner()

    override func setUp() { storeURL = AutomationFixtures.tempStoreURL(); runner = FakeScriptRunner() }
    override func tearDown() { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

    private func controller(client: FakeRepositoryClient? = nil) throws -> (AutomationController, FakeRepositoryClient) {
        let package = try AutomationFixtures.package(name: "Zeta")
        let fake = try client ?? FakeRepositoryClient(snapshot: AutomationFixtures.snapshot(packages: [package]), packages: [package])
        let c = AutomationController(store: AutomationStore(fileURL: storeURL), client: fake, executor: runner, clock: { AutomationFixtures.now })
        return (c, fake)
    }

    // MARK: Lists and local scripts

    func testCreateExampleIsDisabledSyntheticAndSortedByName() async throws {
        let (c, _) = try controller()
        await c.load()
        let beta = await c.createExample(name: "beta")
        await c.createExample(name: "Alpha")
        XCTAssertEqual(c.scripts.map(\.package.manifest.name), ["Alpha", "beta"])
        let r = try XCTUnwrap(beta)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.package.manifest.read.body, .none)
        XCTAssertEqual(r.package.manifest.subscriptions.flatMap(\.hosts), ["example.com", "example.com"])
        XCTAssertEqual(AutomationTrustBadge(r.provenance), .localFile)
        XCTAssertTrue(runner.runs.isEmpty, "creating a script must not execute it")
    }

    func testImportFileRejectsInvalidAndOversizeWithoutSideEffects() async throws {
        let (c, _) = try controller()
        await c.load()
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
        try Data("{}".utf8).write(to: bad)
        let none = await c.importFile(at: bad)
        XCTAssertNil(none)
        XCTAssertEqual(c.actionError as? AutomationError, .invalidManifest)
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID()).json")
        try Data(repeating: 0x20, count: Limits.package + 1).write(to: big)
        _ = await c.importFile(at: big)
        XCTAssertEqual(c.actionError as? AutomationInputError, .fileTooLarge)
        XCTAssertTrue(c.scripts.isEmpty)
        XCTAssertTrue(runner.runs.isEmpty)
    }

    func testImportFileCreatesDisabledLocalRevisionWithoutRunning() async throws {
        let (c, _) = try controller()
        await c.load()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ok-\(UUID()).json")
        try AutomationTemplate.packageBytes(name: "From Files").write(to: file)
        let imported = await c.importFile(at: file)
        XCTAssertEqual(imported?.enabled, false)
        XCTAssertEqual(c.scripts.count, 1)
        XCTAssertTrue(runner.runs.isEmpty)
    }

    func testDeleteScriptPersistsAcrossReload() async throws {
        let (c, _) = try controller()
        await c.load()
        let created = await c.createExample(name: "Temp")
        let r = try XCTUnwrap(created)
        await c.deleteScript(id: r.id)
        XCTAssertTrue(c.scripts.isEmpty)
        let (again, _) = try controller()
        await again.load()
        XCTAssertTrue(again.scripts.isEmpty)
    }

    func testCorruptStoreIsPreservedAndBlocksMutation() async throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("not a catalog".utf8)
        try garbage.write(to: storeURL)
        let (c, _) = try controller()
        await c.load()
        XCTAssertNotNil(c.storeError)
        let created = await c.createExample(name: "Blocked")
        XCTAssertNil(created)
        XCTAssertEqual(c.actionError as? AutomationInputError, .storeUnavailable)
        XCTAssertEqual(try Data(contentsOf: storeURL), garbage, "corrupt data must never be reset")
    }

    func testAppLinkedEngineRejectsOversizeBigIntAndRecovers() async throws {
        let executor = JavaScriptExecutor()
        let start = ContinuousClock.now
        do {
            _ = try await executor.run(source: "function onRequest(){let n=(1n<<1000000n)-1n;return {actions:[]};}",
                                       hook: .request, eventJSON: Data("{}".utf8), configJSON: Data("{}".utf8))
            XCTFail("expected the operand cap")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .memoryOrStack) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let recovered = try await executor.run(source: "function onRequest(){return {actions:[]};}",
                                               hook: .request, eventJSON: Data("{}".utf8), configJSON: Data("{}".utf8))
        XCTAssertTrue(try ValidatedAction.parse(recovered).isEmpty)
    }

    func testAppLinkedEngineInterruptsRepeatedNativeWork() async throws {
        let executor = JavaScriptExecutor()
        let start = ContinuousClock.now
        do {
            _ = try await executor.run(source: "function onRequest(){let n=(1n<<4000n)-1n;while(true){let x=n*n;let s=x.toString(10)+x.toString(36)}}",
                                       hook: .request, eventJSON: Data("{}".utf8), configJSON: Data("{}".utf8))
            XCTFail("expected the deadline")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .timeout) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    // MARK: Add repository

    func testPreviewDoesNotPersistAndCancelDiscardsLateResult() async throws {
        let (c, client) = try controller()
        await c.load()
        client.delayNanoseconds = 200_000_000
        let model = AddRepositoryModel(controller: c)
        model.urlText = "https://plugins.example.com/"
        model.preview()
        XCTAssertEqual(model.phase, .fetching)
        model.cancel()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.phase, .idle)
        let stored = try await c.store.load()
        XCTAssertTrue(stored.repositories.isEmpty)
    }

    func testPreviewShowsUnsignedAndAddUnverifiedPersistsOnlyAfterExplicitAction() async throws {
        let (c, client) = try controller()
        await c.load()
        let model = AddRepositoryModel(controller: c)
        model.urlText = "https://plugins.example.com/"
        model.preview()
        let previewed = await waitUntil { model.phase == .previewed }
        XCTAssertTrue(previewed)
        XCTAssertEqual(model.snapshot?.signature, .unsigned)
        XCTAssertNil(model.offeredFingerprint)
        XCTAssertEqual(client.previewCount, 1)
        let before = try await c.store.load()
        XCTAssertTrue(before.repositories.isEmpty)
        model.addUnverified()
        let added = await waitUntil { model.phase == .added }
        XCTAssertTrue(added)
        XCTAssertEqual(c.repositories.first?.trust, .unsignedAcknowledged)
        XCTAssertTrue(c.scripts.isEmpty, "adding a repository imports nothing")
        XCTAssertEqual(client.packageCount, 0)
    }

    func testAddDoesNotReportSuccessWhenCatalogBecomesCorruptAfterPreview() async throws {
        let (controller, _) = try controller()
        await controller.load()
        let model = AddRepositoryModel(controller: controller)
        model.urlText = "https://plugins.example.com/"
        model.preview()
        let previewed = await waitUntil { model.phase == .previewed }
        XCTAssertTrue(previewed)
        let corrupt = Data("corrupted after preview".utf8)
        try corrupt.write(to: storeURL)
        model.addUnverified()
        let finished = await waitUntil { model.phase != .adding }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.phase, .previewed, "a failed add must remain visible for correction")
        XCTAssertEqual(model.error as? AutomationError, .corruptStore)
        XCTAssertEqual(controller.actionError as? AutomationError, .corruptStore)
        XCTAssertEqual(controller.storeError as? AutomationError, .corruptStore)
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
    }

    func testVerifyAndAddRequiresExactFingerprintAndMismatchPersistsNothing() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let package = try AutomationFixtures.package(name: "Signed")
        let client = FakeRepositoryClient(snapshot: try AutomationFixtures.snapshot(packages: [package], key: key), packages: [package])
        let (c, _) = try controller(client: client)
        await c.load()
        let model = AddRepositoryModel(controller: c)
        model.urlText = "https://plugins.example.com/"
        model.preview()
        _ = await waitUntil { model.phase == .previewed }
        let fingerprint = try XCTUnwrap(model.offeredFingerprint)
        model.fingerprintText = String(fingerprint.dropLast()) + (fingerprint.last == "0" ? "1" : "0")
        XCTAssertFalse(model.canVerifyAndAdd)
        model.verifyAndAdd()
        XCTAssertEqual(model.phase, .previewed)
        let none = try await c.store.load()
        XCTAssertTrue(none.repositories.isEmpty)

        model.fingerprintText = " " + fingerprint.uppercased() + "\n"
        XCTAssertTrue(model.canVerifyAndAdd)
        model.verifyAndAdd()
        _ = await waitUntil { model.phase == .added }
        XCTAssertEqual(c.repositories.first.map { AutomationTrustBadge($0.trust) }, .publisherKeyVerified)
    }

    func testSignedUnverifiedBadgeIsDistinctFromUnsignedAndVerified() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let package = try AutomationFixtures.package(name: "S")
        let client = FakeRepositoryClient(snapshot: try AutomationFixtures.snapshot(packages: [package], key: key), packages: [package])
        let (c, _) = try controller(client: client)
        await c.load()
        let model = AddRepositoryModel(controller: c)
        model.urlText = "https://plugins.example.com/"
        model.preview()
        _ = await waitUntil { model.phase == .previewed }
        model.addUnverified()
        _ = await waitUntil { model.phase == .added }
        XCTAssertEqual(AutomationTrustBadge(try XCTUnwrap(c.repositories.first).trust), .signedKeyUnverified)
        XCTAssertEqual(Set([AutomationTrustBadge.unsigned, .signedKeyUnverified, .publisherKeyVerified]).count, 3)
    }

    // MARK: Repository detail and import

    private func acceptedRecord(_ c: AutomationController, client: FakeRepositoryClient) async throws -> RepositoryRecord {
        _ = await c.mutate { try await c.store.accept(client.snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now) }
        return try XCTUnwrap(c.repositories.first)
    }

    func testSelectFetchesOnlyReviewPackageAndImportIsSeparateAndDisabled() async throws {
        let (c, client) = try controller()
        await c.load()
        let record = try await acceptedRecord(c, client: client)
        let detail = RepositoryDetailModel(controller: c, record: record)
        detail.select(try XCTUnwrap(detail.entries.first))
        _ = await waitUntil { detail.phase == .reviewing }
        XCTAssertEqual(client.packageCount, 1)
        XCTAssertEqual(client.previewCount, 0, "no implicit index refetch")
        XCTAssertTrue(c.scripts.isEmpty, "reviewing must not import")
        detail.importDisabled()
        _ = await waitUntil { detail.phase == .imported }
        XCTAssertEqual(c.scripts.count, 1)
        XCTAssertFalse(c.scripts[0].enabled)
        XCTAssertEqual(AutomationTrustBadge(c.scripts[0].provenance), .unsigned)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertTrue(runner.runs.isEmpty)
    }

    func testImportWithStaleGenerationIsRejected() async throws {
        let (c, client) = try controller()
        await c.load()
        let stale = try await acceptedRecord(c, client: client)
        _ = await c.mutate { try await c.store.accept(client.snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now) }
        let detail = RepositoryDetailModel(controller: c, record: stale)
        detail.select(try XCTUnwrap(detail.entries.first))
        _ = await waitUntil { detail.phase == .reviewing }
        detail.importDisabled()
        _ = await waitUntil { detail.error != nil }
        XCTAssertEqual(detail.error as? AutomationError, .staleGeneration)
        XCTAssertTrue(c.scripts.isEmpty)
    }

    func testClosingDetailDropsLateFetchResult() async throws {
        let (c, client) = try controller()
        await c.load()
        let record = try await acceptedRecord(c, client: client)
        client.delayNanoseconds = 200_000_000
        let detail = RepositoryDetailModel(controller: c, record: record)
        detail.select(try XCTUnwrap(detail.entries.first))
        detail.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(detail.package)
    }

    func testDeletingRepositoryKeepsInstalledScripts() async throws {
        let (c, client) = try controller()
        await c.load()
        let record = try await acceptedRecord(c, client: client)
        let detail = RepositoryDetailModel(controller: c, record: record)
        detail.select(try XCTUnwrap(detail.entries.first))
        _ = await waitUntil { detail.phase == .reviewing }
        detail.importDisabled()
        _ = await waitUntil { detail.phase == .imported }
        await c.deleteRepository(record.url)
        XCTAssertTrue(c.repositories.isEmpty)
        XCTAssertEqual(c.scripts.count, 1)
    }

    // MARK: Script session

    private func session() async throws -> (ScriptSession, AutomationController) {
        let (c, _) = try controller()
        await c.load()
        let created = await c.createExample(name: "Example")
        let r = try XCTUnwrap(created)
        return (ScriptSession(controller: c, revision: r), c)
    }

    func testSaveAsLocalEditCreatesChildRevisionWithoutPublisherTrustOrRunning() async throws {
        let (s, c) = try await session()
        let parent = s.revision
        let original = parent.package.manifest
        s.source += "\n// edited\n"
        XCTAssertTrue(s.canSave)
        XCTAssertFalse(s.canRun, "unsaved edits must be saved before a test")
        await s.saveAsLocalEdit()
        XCTAssertEqual(s.revision.provenance.origin, .localEdit(parent: parent.package.revision))
        XCTAssertEqual(s.badge, .localEdit)
        XCTAssertEqual(s.revision.package.manifest, original, "full manifest preserved")
        XCTAssertEqual(c.scripts.count, 2, "parent revision remains")
        XCTAssertTrue(runner.runs.isEmpty)
    }

    func testRunShowsValidatedActionsAndEditsInvalidateResult() async throws {
        let (s, _) = try await session()
        s.run(); _ = await waitUntil { self.runner.isWaiting }
        XCTAssertTrue(s.isRunning)
        let id = AutomationTemplate.previewEndpointID.uuidString
        runner.finish(.success(Data(#"{"actions":[{"type":"webhook","endpointId":"\#(id)","json":{"a":1}}]}"#.utf8)))
        _ = await waitUntil { !s.isRunning }
        guard case .finished(let actions) = s.runState else { return XCTFail("\(s.runState)") }
        XCTAssertEqual(actions.map(\.endpointID), [AutomationTemplate.previewEndpointID])
        XCTAssertEqual(actions.first?.json, #"{"a":1}"#)
        s.eventText = SyntheticFixture.eventJSON(for: .request) + " "
        XCTAssertEqual(s.runState, .idle)
        s.run(); _ = await waitUntil { self.runner.isWaiting }; runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        _ = await waitUntil { !s.isRunning }
        s.hook = .response
        XCTAssertEqual(s.runState, .idle)
        XCTAssertEqual(s.eventText, SyntheticFixture.eventJSON(for: .response))
    }

    func testInvalidResultAndInvalidInputAreRejected() async throws {
        let (s, _) = try await session()
        s.run(); _ = await waitUntil { self.runner.isWaiting }
        runner.finish(.success(Data(#"{"actions":[{"type":"shell","endpointId":"x","json":1}]}"#.utf8)))
        _ = await waitUntil { !s.isRunning }
        XCTAssertEqual(s.runState, .failed("AUTO_ERR_JS_RESULT"))
        s.eventText = "[]"
        s.run()
        XCTAssertEqual(s.runState, .failed("AUTO_ERR_EVENT_INVALID"))
        XCTAssertEqual(runner.runs.count, 1)
    }

    func testCancelAndLeaveCancelRuntimeAndDropLateResult() async throws {
        let (s, _) = try await session()
        s.run(); _ = await waitUntil { self.runner.isWaiting }
        s.cancelRun()
        _ = await waitUntil { !s.isRunning }
        XCTAssertEqual(s.runState, .failed("AUTO_ERR_JS_CANCELLED"))
        s.run(); _ = await waitUntil { self.runner.isWaiting }
        s.leave()
        XCTAssertEqual(runner.cancelCount, 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.runState, .idle, "no stale task result after leaving")
    }

    func testCancellationDiscardsLateSuccessfulRuntimeResult() async throws {
        let (session, _) = try await session()
        runner.setCancellationIgnored(true)
        session.run()
        let started = await waitUntil { self.runner.isWaiting }
        XCTAssertTrue(started)
        session.cancelRun()
        runner.finish(.success(Data(#"{"actions":[]}"#.utf8)))
        _ = await waitUntil { !session.isRunning }
        XCTAssertEqual(session.runState, .failed("AUTO_ERR_JS_CANCELLED"))
    }

    func testActionParserEnforcesShape() throws {
        let id = UUID().uuidString
        let three = (0..<3).map { _ in #"{"type":"webhook","endpointId":"\#(id)","json":null}"# }.joined(separator: ",")
        XCTAssertThrowsError(try ValidatedAction.parse(Data(#"{"actions":[\#(three)]}"#.utf8)))
        XCTAssertThrowsError(try ValidatedAction.parse(Data(#"{"actions":[],"extra":1}"#.utf8)))
        XCTAssertThrowsError(try ValidatedAction.parse(Data(#"{"actions":[{"type":"webhook","endpointId":"nope","json":1}]}"#.utf8)))
        XCTAssertEqual(try ValidatedAction.parse(Data(#"{"actions":[]}"#.utf8)), [])
    }

    func testTemplateIsMetadataOnlyExampleComAndAtMostOneActionPerHook() throws {
        let p = try PluginPackage.validate(AutomationTemplate.packageBytes(name: "T"))
        XCTAssertEqual(p.manifest.read.body, .none)
        XCTAssertEqual(p.manifest.endpointBindings, ["preview"])
        XCTAssertTrue(p.source.contains("onRequest") && p.source.contains("onResponse"))
        XCTAssertLessThanOrEqual(p.bytes.count, Limits.package)
    }

    func testFingerprintNormalization() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(FingerprintInput.normalized(" \(hex.uppercased())\n"), hex)
        XCTAssertNil(FingerprintInput.normalized(String(hex.dropLast())))
        XCTAssertNil(FingerprintInput.normalized(String(repeating: "g", count: 64)))
    }
}
