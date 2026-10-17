import XCTest

final class SSLProxyingListUITests: XCTestCase {
    @MainActor
    func testHostMutationsRequireEditMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        openList(app)
        XCTAssertFalse(app.buttons["ssl.add"].exists, "Add belongs to edit mode")
        XCTAssertFalse(app.buttons["ssl.sort"].exists, "Sort belongs to edit mode")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ssl.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertFalse(app.textFields["ssl.host"].waitForExistence(timeout: 1), "Normal rows must be read-only")
        row.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].exists, "Normal rows must not offer deletion")

        app.buttons["ssl.edit"].tap()
        XCTAssertTrue(app.buttons["ssl.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ssl.sort"].exists)
        row.tap()
        XCTAssertTrue(app.textFields["ssl.host"].waitForExistence(timeout: 5))
        app.buttons["ssl.cancel"].tap()
        app.buttons["ssl.edit"].tap()
        XCTAssertFalse(app.buttons["ssl.add"].exists)
        XCTAssertFalse(app.buttons["ssl.sort"].exists)
        row.tap()
        XCTAssertFalse(app.textFields["ssl.host"].waitForExistence(timeout: 1))

        app.terminate()
        app.launch()
        openList(app)
        XCTAssertFalse(app.buttons["ssl.add"].exists, "Relaunch must begin in viewing mode")
        XCTAssertFalse(app.buttons["ssl.sort"].exists)
        attach(app, "SSL list read-only after relaunch")
    }

    @MainActor
    func testHostListCanAddEditSortDeleteAndPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        openList(app)
        app.buttons["ssl.edit"].tap()
        XCTAssertTrue(app.buttons["ssl.add"].waitForExistence(timeout: 5), "Edit mode must provide a + action")

        app.buttons["ssl.add"].tap()
        XCTAssertTrue(app.textFields["ssl.host"].waitForExistence(timeout: 5))
        app.textFields["ssl.host"].tap()
        app.textFields["ssl.host"].typeText("https://invalid.example/path")
        XCTAssertFalse(app.buttons["ssl.save"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(sslRow(app, "invalid.example").exists)

        addHost("ZEBRA.EXAMPLE.COM.", app: app)
        renameHost("zebra.example.com", to: "alpha.example.com", app: app)
        addHost("zulu.example.com", app: app)

        app.buttons["ssl.sort"].tap()
        app.buttons["Host Name (Z–A)"].tap()
        let zulu = sslRow(app, "zulu.example.com")
        let alpha = sslRow(app, "alpha.example.com")
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

        app.buttons["ssl.edit"].tap()
        for host in ["zulu.example.com", "alpha.example.com"] {
            let row = sslRow(app, host)
            scrollTo(row, app: app)
            deleteRow(row, app: app)
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
            app.buttons["ssl.edit"].tap()
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
    func testEmptyListStillAllowsEditThenAdd() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        openList(app)
        app.buttons["ssl.edit"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "ssl.row."))
        while rows.count > 0 {
            deleteRow(rows.firstMatch, app: app)
        }
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No hosts")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        app.buttons["ssl.edit"].tap()
        XCTAssertFalse(app.buttons["ssl.add"].exists)
        app.buttons["ssl.edit"].tap()
        XCTAssertTrue(app.buttons["ssl.add"].waitForExistence(timeout: 5), "An empty list must still allow Edit, then +")
        addHost("recovered.example.com", app: app)
        XCTAssertTrue(sslRow(app, "recovered.example.com").waitForExistence(timeout: 5))
    }

    /// Rows are Text outside editing and Buttons while editing, so query by identifier only.
    @MainActor
    private func sslRow(_ app: XCUIApplication, _ host: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ssl.row." + host).firstMatch
    }

    @MainActor
    private func deleteRow(_ row: XCUIElement, app: XCUIApplication) {
        let identifier = row.identifier
        // UIKit combines the minus control with the row in the accessibility tree.
        // Tap its leading control rather than the host label, which opens the editor.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).tap()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier)
            .firstMatch.waitForNonExistence(timeout: 5))
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
        let original = sslRow(app, oldHost)
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
        XCTAssertTrue(sslRow(app, newHost).waitForExistence(timeout: 5))
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
