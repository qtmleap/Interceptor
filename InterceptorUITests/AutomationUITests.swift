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
    func testCreateViewRunAndReopenPersistsInEnglishAndJapanese() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            let suite = "Interceptor.UITests.\(UUID().uuidString)"
            let locale = japanese ? "ja" : "en"
            let app = launch(japanese: japanese, suite: suite)
            defer { app.terminate() }
            openPlugins(app, japanese: japanese)
            attach(app, "Plugins empty \(locale)")

            app.buttons["plugins.add"].tap()
            app.buttons["plugins.createExample"].tap()
            let script = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script.")).firstMatch
            XCTAssertTrue(script.waitForExistence(timeout: 5))
            attach(app, "Plugins with example \(locale)")

            script.tap()
            let form = app.collectionViews["script.form"]
            let approve = reach(app.buttons["script.activate"], in: form)
            XCTAssertTrue(approve.exists, "v2 live approval is separate from importing")
            attach(app, "Live approval section \(locale)")
            XCTAssertFalse(app.buttons["script.save"].exists, "the app has no source save action")
            XCTAssertFalse(app.descendants(matching: .any)["script.saveGuidance"].exists)
            let footer = reach(app.descendants(matching: .any).matching(identifier: "script.sourceReadOnly").firstMatch, in: form)
            XCTAssertTrue(footer.exists)
            attach(app, "Script detail source row \(locale)")
            let viewer = openSource(app)
            let original = viewer.value as? String
            XCTAssertFalse(original?.isEmpty ?? true, "the imported source must be shown")
            assertSourceIsReadOnly(viewer, app: app)
            attach(app, "Script detail full-screen read-only source \(locale)")
            closeSource(app)

            let picker = reachAbove(app.buttons["script.hook"], in: form)
            picker.tap()
            let choice = app.buttons["request.onEnter"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            let run = reach(app.buttons["script.run"], in: form)
            XCTAssertTrue(run.isEnabled, "an unchanged source is always runnable")
            XCTAssertTrue(app.textViews["script.event"].exists || reach(app.textViews["script.event"], in: form).exists,
                          "dry-run inputs stay editable")
            run.tap()
            reach(app.staticTexts["script.validated"], in: form)
            XCTAssertTrue(app.staticTexts["script.validated"].exists)
            XCTAssertFalse(app.staticTexts["script.error"].exists)
            let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
            assertJSON(preview.label, equals: #"{"limit":5}"#)
            XCTAssertTrue(preview.label.contains("\n  "), "result JSON is formatted for reading")
            attach(app, "Synthetic test result read-only \(locale)")

            app.terminate()
            let reopened = launch(japanese: japanese, suite: suite)
            openPlugins(reopened, japanese: japanese)
            let rows = reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script."))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, 1, "viewing and running create no new revision")
            attach(reopened, "Plugins after relaunch read-only \(locale)")
            rows.element(boundBy: 0).tap()
            let reopenedViewer = openSource(reopened)
            XCTAssertEqual((reopenedViewer.value as? String).map { Array($0.utf8) }, original.map { Array($0.utf8) },
                           "the approved source bytes persist unchanged")
            XCTAssertFalse(reopened.buttons["script.save"].exists)
            attach(reopened, "Source after relaunch read-only \(locale)")
            closeSource(reopened)
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
            let confirm = app.buttons.matching(identifier: "script.confirmActivation").firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            let approvalForm = app.collectionViews["script.approvalForm"]
            XCTAssertTrue(approvalForm.waitForExistence(timeout: 5))
            XCTAssertEqual(confirm.label, "OK")
            let cancelApproval = app.buttons.matching(identifier: "script.cancelActivation").firstMatch
            XCTAssertTrue(cancelApproval.isHittable)
            attach(app, "Hooks exact revision confirmation \(locale)")
            let reviewedRevision = app.textViews["script.approvalRevision"]
            reachApprovalValue(reviewedRevision, in: approvalForm, app: app)
            XCTAssertEqual((reviewedRevision.value as? String)?.utf8.count, 64)
            attach(app, "Hooks approval details \(locale)")
            cancelApproval.tap()
            XCTAssertTrue(approvalForm.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["script.revoke"].exists, "cancelling must not approve the script")
            approve.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(approvalForm.waitForNonExistence(timeout: 5))
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
                let emptyAlert = app.alerts.firstMatch
                if phase.hasSuffix("onLeave") {
                    XCTAssertTrue(emptyAlert.waitForExistence(timeout: 5), "a run that returns nothing explains itself")
                    XCTAssertEqual(emptyAlert.label, japanese ? "テスト完了" : "Test completed")
                    if phase == "request.onLeave" {
                        attach(app, "Hooks empty result alert \(locale)")
                    }
                    emptyAlert.buttons["OK"].tap()
                    XCTAssertTrue(emptyAlert.waitForNonExistence(timeout: 5))
                }
                let result = reach(app.staticTexts["script.validated"], in: form)
                XCTAssertTrue(result.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["script.error"].exists)
                XCTAssertFalse(emptyAlert.exists, "dismissing keeps the result and nothing re-presents it")
                if phase.hasSuffix("onEnter") {
                    let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
                    assertJSON(preview.label, equals: phase.hasPrefix("request") ? #"{"limit":5}"# : #"{"maintenance":true}"#)
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

    /// Exercises the route-count and read-field-count limits with fixed confirmation actions.
    @MainActor
    func testLargeApprovalScopeCanBeReadAndCancelled() async {
        continueAfterFailure = false
        guard let repositoryURL = await repositoryFixtureURLIfReady() else {
            XCTFail("The run-owned HTTPS fixture is required")
            return
        }
        XCUIDevice.shared.orientation = .portrait
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        guard openFixturePackage("Approval limits", repositoryURL: repositoryURL, app: app, japanese: false) else { return }
        reach(app.buttons["repo.import"], in: app.collectionViews["repo.script.list"], attempts: 90).tap()
        XCTAssertTrue(app.otherElements["repo.imported"].waitForExistence(timeout: 5)
            || app.staticTexts["Imported (disabled)"].waitForExistence(timeout: 3))
        app.navigationBars["Approval limits"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Local repository fixture"].buttons.element(boundBy: 0).tap()
        let installed = app.buttons["plugins.script.Approval limits"]
        XCTAssertTrue(installed.waitForExistence(timeout: 5))
        installed.tap()
        let approve = reach(app.buttons["script.activate"], in: app.collectionViews["script.form"], attempts: 90)
        approve.tap()
        let form = app.collectionViews["script.approvalForm"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let confirm = app.buttons.matching(identifier: "script.confirmActivation").firstMatch
        let cancel = app.buttons.matching(identifier: "script.cancelActivation").firstMatch
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertEqual(PluginRepositorySources.approvalPaths.count, 16)
        XCTAssertEqual(PluginRepositorySources.approvalReadFields.count, 64)
        attach(app, "Large approval scope top en")
        verifyVisibleApprovalRows(app, form: form)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        attach(app, "Large approval scope bottom en")
        cancel.tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["script.revoke"].exists)
        XCTAssertTrue(approve.isEnabled, "cancelling must retain the unapproved package")
    }

    /// The tracked CI fixture wrapper supplies an owned HTTPS URL, nonce and simulator UUID.
    /// Fixture-dependent tests fail when setup is missing or belongs to another run/device.
    @MainActor
    func testMultiFileViewingSwitchesAndReopensInEnglishAndJapanese() async {
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
            guard openFixturePackage("Multi-file hooks", repositoryURL: repositoryURL, app: app, japanese: japanese) else { return }
            let review = app.collectionViews["repo.script.list"]
            let repoViewer = openSource(app, repository: true)
            for (file, marker) in [(Self.secondaryFile, "SECONDARY HOOK FILE"), (Self.primaryFile, "PRIMARY HOOK FILE")] {
                selectSourceFile(file, app: app, repository: true)
                let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (repoViewer.value as? String)?.contains(marker) == true
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "every package source file must be reviewable: \(file)")
                repoViewer.tap()
                XCTAssertFalse(app.keyboards.firstMatch.exists, "repository sources remain read-only")
                attach(app, "Multi-file source review \(marker) \(locale)")
            }
            selectSourceFile(Self.secondaryFile, app: app, repository: true)
            closeSource(app, repository: true)
            let repositoryReopened = openSource(app, repository: true)
            assertSource(repositoryReopened, equals: Self.secondarySource)
            closeSource(app, repository: true)
            reach(app.buttons["repo.import"], in: review).tap()
            XCTAssertTrue(app.otherElements["repo.imported"].waitForExistence(timeout: 5)
                || app.staticTexts[japanese ? "取り込みました（無効）" : "Imported (disabled)"].waitForExistence(timeout: 3))
            app.navigationBars["Multi-file hooks"].buttons.element(boundBy: 0).tap()
            app.navigationBars["Local repository fixture"].buttons.element(boundBy: 0).tap()
            let script = app.buttons["plugins.script.Multi-file hooks"]
            XCTAssertTrue(script.waitForExistence(timeout: 5))
            script.tap()
            attach(app, "Multi-file installed read-only source before selection \(locale)")
            let form = app.collectionViews["script.form"]
            let viewer = openSource(app)
            selectSourceFile(Self.primaryFile, app: app)
            assertSource(viewer, equals: Self.primarySource)
            assertSourceIsReadOnly(viewer, app: app)
            XCTAssertFalse(app.buttons["script.save"].exists, "the app has no source save action")
            XCTAssertFalse(app.descendants(matching: .any)["script.saveGuidance"].exists)
            attach(app, "Multi-file primary read-only source \(locale)")
            selectSourceFile(Self.secondaryFile, app: app)
            assertSource(viewer, equals: Self.secondarySource)
            assertSourceIsReadOnly(viewer, app: app)
            attach(app, "Multi-file secondary read-only source \(locale)")
            closeSource(app)
            XCTAssertTrue(app.buttons["script.openSource"].label.contains(Self.secondaryFile), "the row shows the selected file")
            let reopenedSelection = openSource(app)
            assertSource(reopenedSelection, equals: Self.secondarySource)
            closeSource(app)
            let approve = reachAbove(app.buttons["script.activate"], in: form)
            XCTAssertTrue(approve.isEnabled, "viewing a file never makes the package unapproved")
            let run = reach(app.buttons["script.run"], in: form)
            XCTAssertTrue(run.isEnabled)
            run.tap()
            let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            assertJSON(preview.label, equals: #"{"limit":5}"#, "the event selects the primary file while the viewer shows the secondary file")
            attach(app, "Multi-file read-only package dispatch \(locale)")
            app.terminate()
            let reopened = launch(japanese: japanese, suite: suite)
            defer { reopened.terminate() }
            openPlugins(reopened, japanese: japanese)
            let rows = reopened.buttons.matching(identifier: "plugins.script.Multi-file hooks")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, 1, "viewing creates no child revision")
            rows.element(boundBy: 0).tap()
            let reopenedViewer = openSource(reopened)
            selectSourceFile(Self.primaryFile, app: reopened)
            assertSource(reopenedViewer, equals: Self.primarySource)
            selectSourceFile(Self.secondaryFile, app: reopened)
            assertSource(reopenedViewer, equals: Self.secondarySource)
            XCTAssertFalse(reopened.buttons["script.save"].exists)
            attach(reopened, "Multi-file read-only source after relaunch \(locale)")
            closeSource(reopened)
        }
    }

    @MainActor
    func testJSONInputsFormatAfterEditingAndBeforeRunning() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: false)
        app.buttons["plugins.add"].tap()
        app.buttons["plugins.createExample"].tap()
        let script = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.script.")).firstMatch
        XCTAssertTrue(script.waitForExistence(timeout: 5))
        script.tap()
        let form = app.collectionViews["script.form"]
        let event = reach(app.textViews["script.event"], in: form)
        let compact = #"{"id":"00000000-0000-4000-8000-000000000002","phase":"request.onEnter","request":{"method":"POST","host":"example.com","path":"/synthetic","headers":{},"body":{"limit":20}}}"#
        guard replaceJSONInput(event, with: compact, app: app) else { return }
        let config = reach(app.textViews["script.config"], in: form)
        config.tap()
        let eventFormatted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (event.value as? String)?.contains("\n  ") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [eventFormatted], timeout: 5), .completed, "switching editors formats the one that lost focus")
        assertJSON(event.value as? String ?? "", equals: compact)
        let compactConfig = #"{"settings":{"limit":1.0e+2},"endpoints":{}}"#
        guard replaceJSONInput(config, with: compactConfig, app: app) else { return }
        let done = app.buttons["script.inputDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let configFormatted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (config.value as? String)?.contains("\n  ") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [configFormatted], timeout: 5), .completed)
        XCTAssertTrue((config.value as? String)?.contains("1.0e+2") == true)
        let invalid = #"{"request":"#
        reachAbove(event, in: form)
        guard replaceJSONInput(event, with: invalid, app: app) else { return }
        done.tap()
        XCTAssertEqual(event.value as? String, invalid, "incomplete JSON remains exactly as entered")
        guard replaceJSONInput(event, with: compact, app: app) else { return }
        reach(app.buttons["script.run"], in: form).tap()
        let preview = reach(app.staticTexts["script.bodyPreview"], in: form)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        assertJSON(preview.label, equals: #"{"limit":5}"#)
        XCTAssertTrue(preview.label.contains("\n  "))
        XCTAssertFalse(app.staticTexts["script.error"].exists)
        attach(app, "Automatically formatted JSON result en")
        let source = openSource(app)
        assertSourceIsReadOnly(source, app: app)
        closeSource(app)
        reach(preview, in: form)
        assertJSON(preview.label, equals: #"{"limit":5}"#, "opening the source preserves the completed result")
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
    func replaceJSONInput(_ field: XCUIElement, with text: String, app: XCUIApplication) -> Bool {
        field.tap()
        field.press(forDuration: 1.2)
        let menuItem = app.menuItems["Select All"]
        let button = app.buttons["Select All"]
        if menuItem.waitForExistence(timeout: 2) {
            menuItem.tap()
        } else if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            captureSourceFailure(app, name: "JSON select-all action missing")
            XCTFail("The native edit menu must select the complete JSON input")
            return false
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "typing itself must not reformat JSON")
        return true
    }

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
        let cancelConfirmation = app.buttons.matching(identifier: "repo.cancelUnverified").firstMatch
        XCTAssertTrue(cancelConfirmation.isHittable)
        attach(app, "Unverified publisher warning \(japanese ? "ja" : "en")")
        cancelConfirmation.tap()
        XCTAssertTrue(add.isEnabled, "cancelling must retain the preview without adding the repository")
        XCTAssertEqual(url.value as? String, repositoryURL.absoluteString)
        add.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
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
        let source = openSource(app, repository: true)
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
        closeSource(app, repository: true)
        app.navigationBars["Request summary"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let alternate = app.buttons["repo.entry.Response details"]
        if alternate.exists {
            alternate.tap()
            XCTAssertTrue(app.navigationBars["Response details"].waitForExistence(timeout: 5))
            let alternateSource = openSource(app, repository: true)
            XCTAssertEqual(alternateSource.value as? String, "function onRequest(event, config) { return { actions: [] }; }\n")
            attach(app, "Different repository script source \(japanese ? "ja" : "en")")
            closeSource(app, repository: true)
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
    @discardableResult
    func openFixturePackage(_ name: String, repositoryURL: URL, app: XCUIApplication, japanese: Bool) -> Bool {
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
        let author = app.descendants(matching: .any).matching(identifier: "script.author").firstMatch
        let repositoryError = app.staticTexts["repo.script.error"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            author.exists || repositoryError.exists
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [loaded], timeout: 20)
        if repositoryError.exists {
            captureSourceFailure(app, name: "Repository package failed to load")
            XCTFail("Repository package fetch failed: " + name + ": " + repositoryError.label)
            return false
        }
        guard outcome == .completed, author.exists else {
            captureSourceFailure(app, name: "Repository package loading timed out")
            XCTFail("Verified package metadata must load before source review: " + name)
            return false
        }
        return true
    }

    /// Chooses a file in the open full-screen reader. The picker lives in the reader's navigation bar.
    @MainActor
    func selectSourceFile(_ file: String, app: XCUIApplication, repository: Bool = false) {
        let picker = app.buttons[repository ? "repo.script.sourceFile" : "script.sourceFile"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let item = app.buttons[file]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// Compares parsed JSON: the preview is laid out for reading, the value is what matters.
    func assertJSON(_ label: String, equals expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let actual = try? JSONSerialization.jsonObject(with: Data(label.utf8), options: [.fragmentsAllowed]) as? NSObject
        let wanted = try? JSONSerialization.jsonObject(with: Data(expected.utf8), options: [.fragmentsAllowed]) as? NSObject
        XCTAssertNotNil(actual, "the preview must be valid JSON: \(label)", file: file, line: line)
        XCTAssertEqual(actual, wanted, message, file: file, line: line)
    }

    /// Opens the full-screen reader from the installed detail or repository review and returns its viewer.
    @MainActor
    @discardableResult
    func openSource(_ app: XCUIApplication, repository: Bool = false) -> XCUIElement {
        let form = app.collectionViews[repository ? "repo.script.list" : "script.form"]
        let open = reach(app.buttons[repository ? "repo.script.openSource" : "script.openSource"], in: form)
        XCTAssertTrue(open.isEnabled)
        open.tap()
        let close = app.buttons[repository ? "repo.script.closeSource" : "script.closeSource"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the full-screen reader needs an explicit Done")
        let viewer = repository ? app.scrollViews["repo.script.source"].textViews.firstMatch : sourceViewer(app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(viewer.frame.height > app.frame.height * 0.5, "the source fills the screen: \(viewer.frame)")
        return viewer
    }

    @MainActor
    func closeSource(_ app: XCUIApplication, repository: Bool = false) {
        let close = app.buttons[repository ? "repo.script.closeSource" : "script.closeSource"]
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.collectionViews[repository ? "repo.script.list" : "script.form"].waitForExistence(timeout: 5))
    }

    @MainActor
    func sourceViewer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "plugin.source").firstMatch.textViews.firstMatch
    }

    @MainActor
    @discardableResult
    func assertSource(_ viewer: XCUIElement, equals text: String) -> String? {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard viewer.exists else { return false }
            return (viewer.value as? String)?.utf8.elementsEqual(text.utf8) == true
        }, object: nil)
        let result = XCTWaiter.wait(for: [changed], timeout: 5)
        guard result == .completed else {
            captureSourceFailure(XCUIApplication(), name: "Source update did not become visible")
            XCTFail("Expected exact source bytes in the visible viewer")
            return nil
        }
        guard viewer.exists else { return nil }
        return viewer.value as? String
    }

    /// The source must be selectable text only: tapping it never shows the keyboard or changes the bytes.
    @MainActor
    func assertSourceIsReadOnly(_ viewer: XCUIElement, app: XCUIApplication) {
        let before = (viewer.value as? String).map { Array($0.utf8) }
        viewer.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "the source viewer never shows the keyboard")
        XCTAssertEqual((viewer.value as? String).map { Array($0.utf8) }, before, "tapping never changes the source")
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
    @discardableResult
    func reachAbove(_ element: XCUIElement, in form: XCUIElement) -> XCUIElement {
        for _ in 0 ..< 14 {
            guard form.exists else {
                captureSourceFailure(XCUIApplication(), name: "Plugin detail disappeared before scrolling")
                XCTFail("Expected the plugin form to remain on screen")
                return element
            }
            if isVisibleForTap(element, in: form) {
                return element
            }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.8)))
        }
        attach(XCUIApplication(), "Unreachable earlier plugin control")
        XCTFail("Expected a reachable earlier plugin control")
        return element
    }

    /// A full accessibility string is insufficient: every machine-value row must be on screen in full.
    @MainActor
    func reachApprovalValue(_ element: XCUIElement, in form: XCUIElement, app: XCUIApplication) {
        for _ in 0 ..< 14 {
            var viewport = form.frame.intersection(app.frame)
            for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && bar.frame.intersects(viewport) {
                let top = max(viewport.minY, bar.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            if element.exists && element.isHittable && viewport.insetBy(dx: 2, dy: 2).contains(element.frame) {
                return
            }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.35)))
        }
        XCTFail("The complete approval value must be visible: \(element.frame)")
    }

    @MainActor
    func verifyVisibleApprovalRows(_ app: XCUIApplication, form: XCUIElement) {
        var paths = Set(PluginRepositorySources.approvalPaths)
        var fields = Set(PluginRepositorySources.approvalReadFields)
        var inspected = Set<String>()
        var sawRevision = false
        var capturedRule = false
        var capturedField = false
        for _ in 0 ..< 120 {
            var viewport = form.frame.intersection(app.frame)
            for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && bar.frame.intersects(viewport) {
                let top = max(viewport.minY, bar.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            viewport = viewport.insetBy(dx: 2, dy: 2)
            let rows = form.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "script.approval")).allElementsBoundByIndex
            for row in rows {
                let identifier = row.identifier
                guard !inspected.contains(identifier), row.exists, row.isHittable,
                      viewport.contains(row.frame), row.frame.width > 0,
                      let value = row.value as? String else { continue }
                let isRule = identifier.hasPrefix("script.approvalRule.")
                let isField = identifier.hasPrefix("script.approvalRead.")
                let isRevision = identifier == "script.approvalRevision"
                guard isRule || isField || isRevision else { continue }
                // Conservative lower bound for the default-size monospaced UIKit text used by this fixture.
                let minimumHeight = ceil(Double(value.utf16.count) * 7.5 / Double(row.frame.width)) * 14
                XCTAssertGreaterThanOrEqual(Double(row.frame.height) + 1, minimumHeight, "machine values must wrap without clipping")
                if isRule {
                    XCTAssertTrue(value.contains("POST"))
                    XCTAssertTrue(value.contains("limits.example.com"))
                    for path in paths where value.contains(path) {
                        paths.remove(path)
                    }
                    if !capturedRule {
                        let image = XCTAttachment(screenshot: row.screenshot())
                        image.name = "Large approval long rule render"
                        image.lifetime = .keepAlways
                        add(image)
                        capturedRule = true
                    }
                } else if isField {
                    for field in fields where value.hasSuffix(field) {
                        fields.remove(field)
                    }
                    if !capturedField && value.contains(PluginRepositorySources.approvalReadFields.last ?? "") {
                        let image = XCTAttachment(screenshot: row.screenshot())
                        image.name = "Large approval long field render"
                        image.lifetime = .keepAlways
                        add(image)
                        capturedField = true
                    }
                } else {
                    XCTAssertEqual(value, PluginRepositorySources.approvalRevision, "the full exact revision must be visible")
                    sawRevision = true
                }
                inspected.insert(identifier)
            }
            if paths.isEmpty && fields.isEmpty && sawRevision {
                break
            }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.35)))
        }
        XCTAssertTrue(paths.isEmpty, "all16 rule rows must be fully visible; missing: \(paths.count)")
        XCTAssertTrue(fields.isEmpty, "all64 declared header/query rows must be fully visible; missing: \(fields.count)")
        XCTAssertTrue(sawRevision, "the final revision row must be fully visible")
        XCTAssertTrue(capturedRule && capturedField)
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
    func reach(_ element: XCUIElement, in form: XCUIElement, attempts: Int = 14) -> XCUIElement {
        for _ in 0 ..< attempts {
            guard form.exists else {
                captureSourceFailure(XCUIApplication(), name: "Plugin detail disappeared before scrolling")
                XCTFail("Expected the plugin form to remain on screen")
                return element
            }
            if isVisibleForTap(element, in: form) {
                return element
            }
            let above = element.exists && element.frame.midY < visibleFormFrame(form).minY
            // iPadOS 26 can report the full window as the detail form, including the sidebar.
            // The right gutter avoids the sidebar, back gesture and nested source/JSON scrollers.
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.25 : 0.8))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.8 : 0.25))
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
