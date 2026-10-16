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
            let editor = app.scrollViews["plugin.source"].textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["script.save"].isEnabled, "no edit yet")
            editor.tap()
            // A fresh simulator can show the system keyboard's first-use introduction.
            let keyboardIntroduction = app.otherElements["UIContinuousPathIntroductionView"]
            if keyboardIntroduction.waitForExistence(timeout: 2) {
                keyboardIntroduction.buttons.firstMatch.tap()
                XCTAssertTrue(keyboardIntroduction.waitForNonExistence(timeout: 3))
                editor.tap()
            }
            editor.doubleTap()
            let selectAll = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", japanese ? "すべてを選択" : "Select All")).firstMatch
            if japanese && !selectAll.waitForExistence(timeout: 1) {
                // The Japanese edit menu paginates on a narrow iPhone.
                for _ in 0..<4 {
                    if selectAll.exists { break }
                    let previous = app.buttons["戻る"]
                    guard previous.exists && previous.isEnabled else { break }
                    previous.tap()
                }
                for _ in 0..<4 {
                    if selectAll.exists { break }
                    let next = app.buttons["進む"]
                    guard next.exists && next.isEnabled else { break }
                    next.tap()
                }
            }
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
            selectAll.tap()
            let replacement = "// local edit\nfunction onRequest(event, config) { return {actions: []}; }\n"
            editor.typeText(replacement)
            XCTAssertEqual(editor.value as? String, replacement)
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
        app.buttons["repo.preview"].tap()
        XCTAssertTrue(app.staticTexts["repo.error"].waitForExistence(timeout: 5))
        attach(app, "Add repository invalid URL")
        app.buttons["repo.cancel"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'insecure'")).count == 0)
    }


    @MainActor
    func testUnsignedRepositoryWarningAndVerifiedPackageImport() async throws {
        var ready = URLRequest(url: URL(string: "https://localhost:39443/__interceptor_fixture")!)
        ready.timeoutInterval = 2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 2
        let probe = URLSession(configuration: configuration)
        defer { probe.invalidateAndCancel() }
        guard let (body, _) = try? await probe.data(for: ready),
              String(data: body, encoding: .utf8) == "Interceptor Plugin Repository Fixture 1" else {
            throw XCTSkip("Requires the disposable localhost HTTPS repository fixture")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: false)
        app.buttons["plugins.add"].tap()
        app.buttons["plugins.addRepository"].tap()
        let url = app.textFields["repo.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://localhost:39443/repository.json")
        app.buttons["repo.preview"].tap()
        let add = app.buttons["repo.addUnverified"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        reach(add, in: app.collectionViews["repo.addForm"])
        attach(app, "Unsigned repository preview")
        add.tap()
        let confirmation = app.buttons.matching(identifier: "repo.confirmUnverified").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        attach(app, "Unverified publisher warning")
        confirmation.tap()
        let repository = app.buttons["plugins.repo.Local repository fixture"]
        XCTAssertTrue(repository.waitForExistence(timeout: 10))
        repository.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "repo.entry.")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let importButton = app.buttons["repo.import"]
        reach(importButton, in: app.collectionViews["repository.detail"])
        XCTAssertTrue(importButton.exists)
        attach(app, "Verified package review before import")
        importButton.tap()
        XCTAssertTrue(app.otherElements["repo.imported"].waitForExistence(timeout: 5)
                      || app.staticTexts["Imported (disabled)"].waitForExistence(timeout: 3))
        attach(app, "Repository package imported disabled")
    }

    @MainActor
    private func openPlugins(_ app: XCUIApplication, japanese: Bool) {
        let agree = app.buttons[japanese ? "同意する" : "Agree"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", japanese ? "設定" : "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let link = app.buttons["settings.plugins"]
        for _ in 0 ..< 10 where !(link.exists && link.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.buttons["plugins.add"].waitForExistence(timeout: 5))
    }

    @MainActor
    @discardableResult
    private func reach(_ element: XCUIElement, in form: XCUIElement) -> XCUIElement {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return element }
            form.swipeUp()
        }
        attach(XCUIApplication(), "Unreachable plugin control")
        XCTFail("Expected a reachable plugin control")
        return element
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
