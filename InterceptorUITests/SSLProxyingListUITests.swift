import XCTest

final class SSLProxyingListUITests: XCTestCase {
    @MainActor
    func testHostListCanAddEditSortDeleteAndPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        openList(app)
        XCTAssertTrue(app.buttons["ssl.add"].waitForExistence(timeout: 5), "The list must provide a + action")

        app.buttons["ssl.add"].tap()
        XCTAssertTrue(app.textFields["ssl.host"].waitForExistence(timeout: 5))
        app.textFields["ssl.host"].tap()
        app.textFields["ssl.host"].typeText("https://invalid.example/path")
        XCTAssertFalse(app.buttons["ssl.save"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["ssl.row.invalid.example"].exists)

        addHost("ZEBRA.EXAMPLE.COM.", app: app)
        renameHost("zebra.example.com", to: "alpha.example.com", app: app)
        addHost("zulu.example.com", app: app)

        app.buttons["ssl.sort"].tap()
        app.buttons["Host Name (Z–A)"].tap()
        let zulu = app.buttons["ssl.row.zulu.example.com"]
        let alpha = app.buttons["ssl.row.alpha.example.com"]
        XCTAssertTrue(zulu.waitForExistence(timeout: 5))
        XCTAssertLessThan(zulu.frame.minY, alpha.frame.minY)
        attach(app, "SSL list sorted Z to A")

        app.terminate()
        app.launch()
        openList(app)
        XCTAssertTrue(zulu.waitForExistence(timeout: 5))
        XCTAssertLessThan(zulu.frame.minY, alpha.frame.minY, "Sort order must survive relaunch")
        app.buttons["ssl.edit"].tap()
        XCTAssertTrue(app.buttons["Done"].exists, "Standard editing must expose Done")
        attach(app, "SSL list editing and reorder controls")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "SSL list edit accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        reorderAndVerifyPersistence(app, moving: zulu, after: alpha)

        for host in ["zulu.example.com", "alpha.example.com"] {
            let row = app.buttons["ssl.row." + host]
            scrollTo(row, app: app)
            row.swipeLeft()
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            delete.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        openList(app)
        XCTAssertFalse(zulu.exists)
        XCTAssertFalse(alpha.exists)
        attach(app, "SSL list after deleting custom hosts")
    }

    @MainActor
    func testHostEditorSupportsJapaneseAndAccessibilityText() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
            app.launchArguments = [
                "-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
            app.launch()
            openList(app, japanese: japanese)
            XCTAssertTrue(app.buttons["ssl.sort"].isHittable)
            attach(app, "SSL list accessibility text \(japanese ? "ja" : "en")")
            app.buttons["ssl.add"].tap()
            let field = app.textFields["ssl.host"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["ssl.save"].isEnabled)
            field.tap()
            field.typeText("api.example.com")
            XCTAssertTrue(app.buttons["ssl.save"].isEnabled)
            XCTAssertTrue(app.buttons["ssl.save"].isHittable)
            attach(app, "SSL host editor accessibility text \(japanese ? "ja" : "en")")
            app.buttons[japanese ? "キャンセル" : "Cancel"].tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func reorderAndVerifyPersistence(_ app: XCUIApplication, moving: XCUIElement, after: XCUIElement) {
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
        XCTAssertTrue(handle.exists)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.5,
            thenDragTo: after.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)),
        )
        XCTAssertTrue(moving.waitForExistence(timeout: 5))
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(moving.frame.minY, after.frame.minY)
        app.buttons["ssl.edit"].tap()
        app.terminate()
        app.launch()
        openList(app)
        XCTAssertTrue(moving.waitForExistence(timeout: 5))
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(moving.frame.minY, after.frame.minY, "Manual order must survive relaunch")
        attach(app, "SSL list after manual reorder and relaunch")
    }

    @MainActor
    private func openList(_ app: XCUIApplication, japanese: Bool = false) {
        let agree = app.buttons[japanese ? "同意する" : "Agree"]
        if agree.waitForExistence(timeout: 3) {
            agree.tap()
        }
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", japanese ? "設定" : "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let title = japanese ? "プロキシ対象リスト" : "SSL Proxying List"
        let link = app.buttons[title]
        scrollTo(link, app: app)
        link.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    @MainActor
    private func renameHost(_ oldHost: String, to newHost: String, app: XCUIApplication) {
        let original = app.buttons["ssl.row." + oldHost]
        scrollTo(original, app: app)
        original.tap()
        let field = app.textFields["ssl.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            field.typeText(newHost)
        } else {
            let value = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + newHost)
        }
        app.buttons["ssl.save"].tap()
        XCTAssertFalse(original.exists)
        XCTAssertTrue(app.buttons["ssl.row." + newHost].waitForExistence(timeout: 5))
    }

    @MainActor
    private func addHost(_ host: String, app: XCUIApplication) {
        app.buttons["ssl.add"].tap()
        let field = app.textFields["ssl.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(host)
        XCTAssertTrue(app.buttons["ssl.save"].isEnabled)
        app.buttons["ssl.save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        for _ in 0 ..< 10 {
            if element.exists && element.isHittable {
                return
            }
            list.swipeUp()
        }
        XCTFail("Expected reachable control: \(element)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
