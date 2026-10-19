import XCTest

final class AutomationUITests: XCTestCase {
    @MainActor
    private func launch(japanese: Bool, suite: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_AUTOMATION_STORE"] = suite
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch()
        return app
    }

    @MainActor
    func testCreateEditRunAndReopenPersistsInEnglishAndJapanese() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            let suite = "Interceptor.UITests.\(UUID().uuidString)"
            let app = launch(japanese: japanese, suite: suite)
            defer { app.terminate() }
            openPlugins(app, japanese: japanese)
            attach(app, "Plugins empty \(japanese ? "ja" : "en")")

            app.buttons["plugins.add"].tap()
            app.buttons["plugins.createExample"].tap()
            let script = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script.")).firstMatch
            XCTAssertTrue(script.waitForExistence(timeout: 5))
            attach(app, "Plugins with example \(japanese ? "ja" : "en")")

            script.tap()
            let approve = reach(app.buttons["script.activate"], in: app.collectionViews["script.form"])
            XCTAssertTrue(approve.exists, "v2 live approval is separate from importing")
            attach(app, "Live approval section \(japanese ? "ja" : "en")")
            let editor = sourceEditor(app)
            reach(editor, in: app.collectionViews["script.form"])
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["script.save"].isEnabled, "no edit yet")
            let replacement = """
            // local edit
            Interceptor.attach({
              request:{onEnter(request, config){request.body.limit = 7;},onLeave(){}},
              response:{onEnter(response, config){response.body.maintenance = true;},onLeave(){}}
            });

            """
            replaceSource(editor, with: replacement, app: app, japanese: japanese)
            XCTAssertTrue(app.buttons["script.save"].isEnabled)
            app.buttons["script.save"].tap()
            let run = reach(app.buttons["script.run"], in: app.collectionViews["script.form"])
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            attach(app, "Script detail after local edit \(japanese ? "ja" : "en")")

            run.tap()
            reach(app.staticTexts["script.validated"], in: app.collectionViews["script.form"])
            XCTAssertTrue(app.staticTexts["script.validated"].exists)
            XCTAssertFalse(app.staticTexts["script.error"].exists)
            let preview = reach(app.staticTexts["script.bodyPreview"], in: app.collectionViews["script.form"])
            XCTAssertEqual(preview.label, #"{"limit":7}"#)
            attach(app, "Synthetic test result \(japanese ? "ja" : "en")")

            app.terminate()
            let reopened = launch(japanese: japanese, suite: suite)
            openPlugins(reopened, japanese: japanese)
            let rows = reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script."))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, 2, "original and local-edit revisions persist")
            attach(reopened, "Plugins after relaunch \(japanese ? "ja" : "en")")
            reopened.terminate()
        }
    }

    /// Captures the affected live-approval and four-phase dry-run flow without connecting VPN.
    @MainActor
    func testFourHookDryRunAndExplicitApproval() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for japanese in [false, true] {
            let app = launch(japanese: japanese, suite: "Interceptor.UITests.\(UUID().uuidString)")
            defer { app.terminate() }
            openPlugins(app, japanese: japanese)
            let locale = japanese ? "ja" : "en"
            attach(app, "Hooks plugins empty \(locale)")
            app.buttons["plugins.add"].tap()
            app.buttons["plugins.createExample"].tap()
            let script = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script.")).firstMatch
            XCTAssertTrue(script.waitForExistence(timeout: 5))
            attach(app, "Hooks imported disabled \(locale)")
            script.tap()
            let form = app.collectionViews["script.form"]
            let approve = reach(app.buttons["script.activate"], in: form)
            XCTAssertTrue(approve.isEnabled)
            attach(app, "Hooks live approval scope \(locale)")
            approve.tap()
            let confirm = app.buttons[japanese ? "このリビジョンを承認" : "Approve Revision"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            attach(app, "Hooks exact revision confirmation \(locale)")
            confirm.tap()
            let revoke = app.buttons["script.revoke"]
            XCTAssertTrue(revoke.waitForExistence(timeout: 5))
            attach(app, "Hooks approved revision \(locale)")
            revoke.tap()
            XCTAssertTrue(approve.waitForExistence(timeout: 5))
            attach(app, "Hooks revoked revision \(locale)")
            for phase in ["request.onEnter", "request.onLeave", "response.onEnter", "response.onLeave"] {
                let picker = reach(app.buttons["script.hook"], in: form)
                picker.tap()
                let choice = app.buttons[phase]
                XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
                choice.tap()
                let run = reach(app.buttons["script.run"], in: form)
                XCTAssertTrue(run.isEnabled)
                run.tap()
                let result = reach(app.staticTexts["script.validated"], in: form)
                XCTAssertTrue(result.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["script.error"].exists)
                if phase.hasSuffix("onEnter") {
                    let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
                    XCTAssertEqual(preview.label, phase.hasPrefix("request") ? #"{"limit":5}"# : #"{"maintenance":true}"#)
                } else {
                    XCTAssertFalse(app.staticTexts["script.bodyPreview"].exists)
                }
                attach(app, "Hooks \(phase) result \(locale)")
                // A picker covered by the navigation bar may still report isHittable.
                reachAbove(app.buttons["script.hook"], in: form)
            }
            app.terminate()
        }
    }

    /// The tracked CI fixture wrapper supplies an owned HTTPS URL, nonce and simulator UUID.
    /// Fixture-dependent tests fail when setup is missing or belongs to another run/device.
    @MainActor
    func testMultiFileEditingSwitchesSavesAndReopensInEnglishAndJapanese() async {
        continueAfterFailure = false
        guard let repositoryURL = await repositoryFixtureURLIfReady() else {
            XCTFail("Run scripts/ci-plugin-repository-fixture.py around this test command on its selected disposable simulator")
            return
        }
        XCUIDevice.shared.orientation = .portrait
        for japanese in [false, true] {
            let suite = "Interceptor.UITests.\(UUID().uuidString)"
            let locale = japanese ? "ja" : "en"
            let app = launch(japanese: japanese, suite: suite)
            defer { app.terminate() }
            openFixturePackage("Multi-file hooks", repositoryURL: repositoryURL, app: app, japanese: japanese)
            let review = app.collectionViews["repo.script.list"]
            for (file, marker) in [(Self.secondaryFile, "SECONDARY HOOK FILE"), (Self.primaryFile, "PRIMARY HOOK FILE")] {
                let source = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
                reach(source, in: review)
                XCTAssertTrue(source.exists, "every package source file must be reviewable: \(file)")
                source.tap()
                XCTAssertFalse(app.keyboards.firstMatch.exists, "repository sources remain read-only")
                attach(app, "Multi-file source review \(marker) \(locale)")
            }
            reach(app.buttons["repo.import"], in: review).tap()
            XCTAssertTrue(app.otherElements["repo.imported"].waitForExistence(timeout: 5)
                || app.staticTexts[japanese ? "取り込みました（無効）" : "Imported (disabled)"].waitForExistence(timeout: 3))
            app.navigationBars["Multi-file hooks"].buttons.element(boundBy: 0).tap()
            app.navigationBars["Local repository fixture"].buttons.element(boundBy: 0).tap()
            let script = app.buttons["plugins.script.Multi-file hooks"]
            XCTAssertTrue(script.waitForExistence(timeout: 5))
            script.tap()
            attach(app, "Multi-file installed editor before selection \(locale)")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Multi-file installed editor hierarchy \(locale)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let firstEdit = Self.primarySource.replacingOccurrences(of: "limit = 5", with: "limit = 7")
            let secondEdit = Self.secondarySource.replacingOccurrences(of: "limit = 15", with: "limit = 17")
            let editor = sourceEditor(app)
            selectSourceFile(Self.primaryFile, app: app, fromTop: true)
            assertSource(editor, equals: Self.primarySource)
            replaceSource(editor, with: firstEdit, app: app, japanese: japanese)
            let form = app.collectionViews["script.form"]
            let approve = reachAbove(app.buttons["script.activate"], in: form)
            XCTAssertFalse(approve.isEnabled, "an unsaved file must block live approval")
            selectSourceFile(Self.secondaryFile, app: app, fromTop: true)
            assertSource(editor, equals: Self.secondarySource)
            replaceSource(editor, with: secondEdit, app: app, japanese: japanese)
            selectSourceFile(Self.primaryFile, app: app)
            assertSource(editor, equals: firstEdit)
            selectSourceFile(Self.secondaryFile, app: app)
            assertSource(editor, equals: secondEdit)
            attach(app, "Multi-file drafts retained \(locale)")
            XCTAssertTrue(app.buttons["script.save"].isEnabled)
            app.buttons["script.save"].tap()
            let run = reach(app.buttons["script.run"], in: form)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            run.tap()
            let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertEqual(preview.label, #"{"limit":7}"#, "the event selects the primary file while the editor shows the secondary file")
            attach(app, "Multi-file saved package dispatch \(locale)")
            app.terminate()
            let reopened = launch(japanese: japanese, suite: suite)
            defer { reopened.terminate() }
            openPlugins(reopened, japanese: japanese)
            let rows = reopened.buttons.matching(identifier: "plugins.script.Multi-file hooks")
            XCTAssertEqual(rows.count, 2, "one save creates one child revision and retains its parent")
            var foundEditedChild = false
            for index in 0 ..< 2 {
                rows.element(boundBy: index).tap()
                selectSourceFile(Self.primaryFile, app: reopened, fromTop: true)
                let reopenedEditor = sourceEditor(reopened)
                reach(reopenedEditor, in: reopened.collectionViews["script.form"])
                if (reopenedEditor.value as? String)?.utf8.elementsEqual(firstEdit.utf8) == true {
                    selectSourceFile(Self.secondaryFile, app: reopened)
                    assertSource(reopenedEditor, equals: secondEdit)
                    XCTAssertFalse(reopened.buttons["script.save"].isEnabled)
                    attach(reopened, "Multi-file edited revision after relaunch \(locale)")
                    foundEditedChild = true
                    break
                }
                reopened.navigationBars["Multi-file hooks"].buttons.element(boundBy: 0).tap()
            }
            XCTAssertTrue(foundEditedChild, "both edited source files must persist in the same child revision")
        }
    }

    @MainActor
    func testAddRepositorySheetRequiresExplicitPreviewAndCancelsCleanly() {
        continueAfterFailure = false
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: false)
        app.buttons["plugins.add"].tap()
        app.buttons["plugins.addRepository"].tap()
        let url = app.textFields["repo.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["repo.preview"].isEnabled)
        XCTAssertFalse(app.buttons["repo.addUnverified"].exists, "nothing can be added before a preview")
        url.tap()
        url.typeText("http://insecure.example.com/")
        tapAfterLayoutSettles(app.buttons["repo.preview"])
        XCTAssertTrue(app.staticTexts["repo.error"].waitForExistence(timeout: 5))
        attach(app, "Add repository invalid URL")
        app.buttons["repo.cancel"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'insecure'")).count, 0)
    }

    @MainActor
    func testUnsignedRepositoryWarningAndVerifiedPackageImport() async throws {
        for japanese in [false, true] {
            try await verifyRepositoryScriptDetails(japanese: japanese)
        }
    }
}

private extension AutomationUITests {
    @MainActor
    func verifyRepositoryScriptDetails(japanese: Bool) async throws {
        guard let repositoryURL = await repositoryFixtureURLIfReady() else {
            XCTFail("Run scripts/ci-plugin-repository-fixture.py around this test command on its selected disposable simulator")
            return
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(japanese: japanese, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: japanese)
        app.buttons["plugins.add"].tap()
        app.buttons["plugins.addRepository"].tap()
        let url = app.textFields["repo.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(repositoryURL.absoluteString)
        tapAfterLayoutSettles(app.buttons["repo.preview"])
        let add = app.buttons["repo.addUnverified"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        reach(add, in: app.collectionViews["repo.addForm"])
        attach(app, "Unsigned repository preview \(japanese ? "ja" : "en")")
        add.tap()
        let confirmation = app.buttons.matching(identifier: "repo.confirmUnverified").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        attach(app, "Unverified publisher warning \(japanese ? "ja" : "en")")
        confirmation.tap()
        let repository = app.buttons["plugins.repo.Local repository fixture"]
        XCTAssertTrue(repository.waitForExistence(timeout: 10))
        repository.tap()
        let entry = app.buttons["repo.entry.Request summary"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.collectionViews["repo.script.list"].waitForExistence(timeout: 10))
        let author = app.descendants(matching: .any).matching(identifier: "script.author").firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), "verified package metadata must load")
        attach(app, "Repository script metadata \(japanese ? "ja" : "en")")
        let signature = app.staticTexts[japanese ? "リポジトリは署名されていません" : "Repository is unsigned"]
        reach(signature, in: app.collectionViews["repo.script.list"])
        XCTAssertTrue(signature.exists, "signature state is separate from hash matching")
        attach(app, "Repository script integrity \(japanese ? "ja" : "en")")
        XCTAssertFalse(app.buttons["repo.imported"].exists, "navigation must not import")
        attach(app, "Repository script detail \(japanese ? "ja" : "en")")
        let source = app.scrollViews["repo.script.source"].textViews.firstMatch
        reach(source, in: app.collectionViews["repo.script.list"])
        XCTAssertTrue(source.waitForExistence(timeout: 5), "JavaScript is a selectable native code viewer")
        XCTAssertTrue((source.value as? String)?.contains("function onRequest") == true)
        source.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "reviewing verified source must never open an editing keyboard")
        attach(app, "Highlighted repository JavaScript \(japanese ? "ja" : "en")")
        if (source.value as? String)?.contains("END OF VERIFIED SOURCE") == true {
            app.scrollViews["repo.script.source"].swipeUp()
            app.scrollViews["repo.script.source"].swipeUp()
            attach(app, "Repository JavaScript scrolled to final line \(japanese ? "ja" : "en")")
        }
        app.navigationBars["Request summary"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let alternate = app.buttons["repo.entry.Response details"]
        if alternate.exists {
            alternate.tap()
            XCTAssertTrue(app.navigationBars["Response details"].waitForExistence(timeout: 5))
            let alternateSource = app.scrollViews["repo.script.source"].textViews.firstMatch
            reach(alternateSource, in: app.collectionViews["repo.script.list"])
            XCTAssertEqual(alternateSource.value as? String, "function onRequest(event, config) { return { actions: [] }; }\n")
            attach(app, "Different repository script source \(japanese ? "ja" : "en")")
            app.navigationBars["Response details"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
        }
        entry.tap()
        XCTAssertTrue(app.collectionViews["repo.script.list"].waitForExistence(timeout: 10))
        let importButton = app.buttons["repo.import"]
        reach(importButton, in: app.collectionViews["repo.script.list"])
        XCTAssertTrue(importButton.exists)
        attach(app, "Verified package review before import \(japanese ? "ja" : "en")")
        importButton.tap()
        XCTAssertTrue(app.otherElements["repo.imported"].waitForExistence(timeout: 5)
            || app.staticTexts[japanese ? "取り込みました（無効）" : "Imported (disabled)"].waitForExistence(timeout: 3))
        attach(app, "Repository package imported disabled \(japanese ? "ja" : "en")")
    }

    static let primaryFile = PluginRepositorySources.primaryFile
    static let secondaryFile = PluginRepositorySources.secondaryFile
    static let primarySource = PluginRepositorySources.primarySource
    static let secondarySource = PluginRepositorySources.secondarySource

    func repositoryFixtureURLIfReady() async -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["INTERCEPTOR_REPOSITORY_FIXTURE_URL"],
              let url = URL(string: rawURL), url.scheme == "https", url.host == "localhost",
              url.path == "/repository.json", url.port != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let token = environment["INTERCEPTOR_REPOSITORY_FIXTURE_TOKEN"], UUID(uuidString: token) != nil,
              let device = environment["INTERCEPTOR_REPOSITORY_FIXTURE_DEVICE"],
              environment["SIMULATOR_UDID"]?.lowercased() == device.lowercased(),
              let digest = environment["INTERCEPTOR_REPOSITORY_FIXTURE_DIGEST"]
        else { return nil }
        let readyURL = url.deletingLastPathComponent().appendingPathComponent("__interceptor_fixture")
        var request = URLRequest(url: readyURL)
        request.timeoutInterval = 2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["fixture"] as? String == "Interceptor Plugin Repository Fixture",
              marker["version"] as? Int == 1, marker["runToken"] as? String == token,
              marker["device"] as? String == device, marker["packageDigest"] as? String == digest
        else { return nil }
        return url
    }

    @MainActor
    func openFixturePackage(_ name: String, repositoryURL: URL, app: XCUIApplication, japanese: Bool) {
        openPlugins(app, japanese: japanese)
        app.buttons["plugins.add"].tap()
        app.buttons["plugins.addRepository"].tap()
        let url = app.textFields["repo.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(repositoryURL.absoluteString)
        tapAfterLayoutSettles(app.buttons["repo.preview"])
        let add = app.buttons["repo.addUnverified"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        reach(add, in: app.collectionViews["repo.addForm"])
        add.tap()
        let confirm = app.buttons.matching(identifier: "repo.confirmUnverified").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let repository = app.buttons["plugins.repo.Local repository fixture"]
        XCTAssertTrue(repository.waitForExistence(timeout: 10))
        repository.tap()
        let entry = app.buttons["repo.entry." + name]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the repository fixture must include " + name)
        entry.tap()
        XCTAssertTrue(app.collectionViews["repo.script.list"].waitForExistence(timeout: 10))
    }

    @MainActor
    func selectSourceFile(_ file: String, app: XCUIApplication, fromTop: Bool = false) {
        let form = app.collectionViews["script.form"]
        let picker = fromTop ? reach(app.buttons["script.sourceFile"], in: form) : reachAbove(app.buttons["script.sourceFile"], in: form)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let item = app.buttons[file]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let editor = sourceEditor(app)
        reach(editor, in: form)
        XCTAssertTrue(editor.exists)
    }

    @MainActor
    func sourceEditor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "plugin.source").firstMatch.textViews.firstMatch
    }

    @MainActor
    @discardableResult
    func assertSource(_ editor: XCUIElement, equals text: String) -> String? {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard editor.exists else { return false }
            return (editor.value as? String)?.utf8.elementsEqual(text.utf8) == true
        }, object: nil)
        let result = XCTWaiter.wait(for: [changed], timeout: 5)
        guard result == .completed else {
            captureSourceFailure(XCUIApplication(), name: "Source update did not become visible")
            XCTFail("Expected exact source bytes in the visible editor")
            return nil
        }
        guard editor.exists else { return nil }
        return editor.value as? String
    }

    @MainActor
    func captureSourceFailure(_ app: XCUIApplication, name: String) {
        attach(app, name)
        // A system modal can stall a full application hierarchy query for a minute.
        let diagnostic = XCTAttachment(string: "Screenshot retained; full hierarchy omitted while a system modal may be present.")
        diagnostic.name = name + " diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
    }

    @MainActor
    func replaceSource(_ editor: XCUIElement, with replacement: String, app: XCUIApplication, japanese: Bool) {
        let pasteboard = UIPasteboard.general
        pasteboard.string = replacement
        let ownedPasteboardChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == ownedPasteboardChange {
                pasteboard.items = []
            }
        }
        editor.tap()
        let introduction = app.otherElements["UIContinuousPathIntroductionView"]
        if introduction.waitForExistence(timeout: 2) {
            introduction.buttons.firstMatch.tap()
            XCTAssertTrue(introduction.waitForNonExistence(timeout: 3))
            editor.tap()
        }
        editor.doubleTap()
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", japanese ? "すべてを選択" : "Select All")).firstMatch
        if japanese && !selectAll.waitForExistence(timeout: 1) {
            for label in ["戻る", "進む"] {
                for _ in 0 ..< 4 {
                    if selectAll.exists {
                        break
                    }
                    let button = app.buttons[label]
                    guard button.exists && button.isEnabled else { break }
                    button.tap()
                }
            }
        }
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
        selectAll.tap()
        // Select All dismisses the menu on iOS18. Command-V invokes the same UIKit paste action.
        let runner = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        guard !runner.isEmpty else { return XCTFail("The UI runner must expose its actual paste source name") }
        let title = app.navigationBars.firstMatch.staticTexts.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let titleFrame = title.frame
        let appOrigin = app.frame.origin
        let titlePoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: titleFrame.midX - appOrigin.x, dy: titleFrame.midY - appOrigin.y,
        ))
        let identity = XCTAttachment(string: "Runner bundle name: \(runner); inert title: \(title.label); frame: \(titleFrame)")
        identity.name = "Paste source identity and inert trigger"
        identity.lifetime = .keepAlways
        add(identity)
        var pastePermissionWasHandled = false
        let monitor = addUIInterruptionMonitor(withDescription: "Paste from the UI test runner") { alert in
            let alertLabel = alert.label
            let text = alert.staticTexts.allElementsBoundByIndex.map(\.label)
            let diagnostic = "Expected runner: \(runner)\nAlert label: \(alertLabel)\nStatic text: \(text)"
            let received = XCTAttachment(string: diagnostic)
            received.name = "Received paste interruption"
            received.lifetime = .keepAlways
            self.add(received)
            print(diagnostic)
            guard alertLabel.contains(runner) || text.contains(where: { $0.contains(runner) }) else { return false }
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Paste", "ペーストを許可"])).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            pastePermissionWasHandled = true
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        editor.typeKey("v", modifierFlags: .command)
        // Remote paste permission may appear just after the key event. Only the inert title
        // receives retry taps; no source/selection or app-control interaction is replayed.
        for _ in 0 ..< 4 {
            titlePoint.tap()
            if pastePermissionWasHandled {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let permission = XCTAttachment(string: "Expected paste prompt handled: \(pastePermissionWasHandled)")
        permission.name = "Paste interruption monitor outcome"
        permission.lifetime = .keepAlways
        add(permission)
        let pasted = assertSource(editor, equals: replacement)
        XCTAssertEqual(pasted.map { Array($0.utf8) }, Array(replacement.utf8))
        let done = app.buttons[japanese ? "完了" : "Done"]
        if done.exists && done.isHittable {
            done.tap()
        }
    }

    @MainActor
    @discardableResult
    func reachAbove(_ element: XCUIElement, in form: XCUIElement) -> XCUIElement {
        for _ in 0 ..< 14 {
            if isVisibleForTap(element, in: form) {
                return element
            }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8)))
        }
        attach(XCUIApplication(), "Unreachable earlier plugin control")
        XCTFail("Expected a reachable earlier plugin control")
        return element
    }

    /// iPad keyboard presentation can move the form sheet after UIKit reports the app idle.
    /// Use current geometry rather than a cached accessibility activation point.
    @MainActor
    func tapAfterLayoutSettles(_ button: XCUIElement) {
        var previous = CGRect.null
        var unchangedSince = Date()
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = button.frame
            if frame != previous {
                previous = frame
                unchangedSince = Date()
                return false
            }
            return button.isHittable && button.isEnabled && Date().timeIntervalSince(unchangedSince) >= 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 8), .completed)
        let geometry = XCTAttachment(string: "Stable button frame: \(button.frame)")
        geometry.name = "Preview tap geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    func openPlugins(_ app: XCUIApplication, japanese: Bool) {
        let agree = app.buttons[japanese ? "同意する" : "Agree"]
        if agree.waitForExistence(timeout: 3) {
            agree.tap()
        }
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", japanese ? "設定" : "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let link = app.buttons["settings.plugins"]
        for _ in 0 ..< 10 where !(link.exists && link.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.buttons["plugins.add"].waitForExistence(timeout: 5))
    }

    @MainActor
    @discardableResult
    func reach(_ element: XCUIElement, in form: XCUIElement) -> XCUIElement {
        for _ in 0 ..< 14 {
            if isVisibleForTap(element, in: form) {
                return element
            }
            let above = element.exists && element.frame.midY < visibleFormFrame(form).minY
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: above ? 0.25 : 0.8))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: above ? 0.8 : 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let geometry = "target=\(element.exists ? String(describing: element.frame) : "absent"), visible=\(visibleFormFrame(form))"
        captureSourceFailure(XCUIApplication(), name: "Unreachable plugin control " + geometry)
        XCTFail("Expected a reachable plugin control: " + geometry)
        return element
    }

    @MainActor
    func visibleFormFrame(_ form: XCUIElement) -> CGRect {
        let app = XCUIApplication()
        var frame = form.frame.intersection(app.frame)
        for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && bar.frame.intersects(frame) {
            let top = max(frame.minY, bar.frame.maxY)
            frame = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
        }
        for bar in app.tabBars.allElementsBoundByIndex where bar.exists && bar.frame.intersects(frame) {
            frame.size.height = max(0, min(frame.maxY, bar.frame.minY) - frame.minY)
        }
        return frame.insetBy(dx: 2, dy: 4)
    }

    @MainActor
    func isVisibleForTap(_ element: XCUIElement, in form: XCUIElement) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let visible = visibleFormFrame(form)
        if element.elementType == .textView {
            // Runestone exposes the whole text content frame, which can exceed its scroll viewport.
            let intersection = element.frame.intersection(visible)
            return intersection.width >= 44 && intersection.height >= 44
        }
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        return visible.contains(center)
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
