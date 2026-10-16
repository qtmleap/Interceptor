import XCTest

internal final class UnifiedGuidanceUITests: XCTestCase {
    @MainActor
    func testJapaneseGuidanceAndConsentAtLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let agree = app.buttons["同意する"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "設定")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        withdrawConsent(app)
        XCTAssertTrue(agree.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["閉じる"].waitForNonExistence(timeout: 5), "The mandatory gate has no Close")
        app.terminate()

        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["データ利用と同意"].waitForExistence(timeout: 5))
        XCTAssertTrue(agree.isHittable)
        attach("Shared Japanese consent at accessibility text")
        agree.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        openSetup(app)
        attach("Japanese direct setup portrait")

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            let close = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["閉じる"],
            )
            XCTAssertEqual(XCTWaiter.wait(for: [close], timeout: 5), .completed)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(app.buttons["閉じる"].isHittable)
            attach("Japanese direct setup after iPad rotation")
        }

        XCTAssertTrue(app.staticTexts["通知設定"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["アプリの使い方"].exists)
        XCTAssertTrue(app.buttons["閉じる"].isHittable)
        attach("Japanese setup from unified guide")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.staticTexts["通知設定"].waitForNonExistence(timeout: 5))
        openSetup(app)
        XCTAssertTrue(app.staticTexts["通知設定"].exists, "Reopening starts with the first setup step")
        app.buttons["閉じる"].tap()
    }

    @MainActor
    private func withdrawConsent(_ app: XCUIApplication) {
        reach(app.buttons["データ利用と同意"], in: app.collectionViews.firstMatch).tap()
        XCTAssertTrue(app.buttons["閉じる"].waitForExistence(timeout: 5), "Settings disclosure must be a closable sheet")
        reach(app.buttons["同意を取り消す"], in: app.scrollViews["consent.disclosure"]).tap()
        let confirm = app.alerts.buttons["同意を取り消す"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    @MainActor
    private func openSetup(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["アプリの使い方"].exists)
        let row = app.buttons["キャプチャ設定"]
        reach(row, in: app.collectionViews.firstMatch).tap()
        XCTAssertTrue(
            app.staticTexts["通知設定"].waitForExistence(timeout: 5),
            "The Japanese setup entry must open the first setup step directly",
        )
        XCTAssertFalse(app.collectionViews["guide.overview"].exists)
        XCTAssertFalse(app.buttons["guide.beginSetup"].exists)
        XCTAssertTrue(app.buttons["閉じる"].isHittable)
    }

    @MainActor
    @discardableResult
    private func reach(_ element: XCUIElement, in scroll: XCUIElement) -> XCUIElement {
        for _ in 0 ..< 20 {
            if element.exists && element.isHittable {
                return element
            }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2)),
            )
        }
        XCTFail("The control must remain reachable: \(element)")
        return element
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
