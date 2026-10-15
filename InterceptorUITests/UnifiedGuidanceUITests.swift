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
        app.terminate()

        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["データ利用と同意"].waitForExistence(timeout: 5))
        XCTAssertTrue(agree.isHittable)
        attach("Shared Japanese consent at accessibility text")
        agree.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        openGuide(app)
        attach("Japanese guide portrait at accessibility text")

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            let close = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["閉じる"],
            )
            XCTAssertEqual(XCTWaiter.wait(for: [close], timeout: 5), .completed)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            XCTAssertTrue(app.buttons["閉じる"].isHittable)
            attach("Japanese guide after iPad rotation")
        }

        let begin = app.buttons["guide.beginSetup"]
        let form = app.collectionViews["guide.overview"]
        reach(begin, in: form).tap()
        XCTAssertTrue(app.staticTexts["通知設定"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["アプリの使い方"].exists)
        XCTAssertTrue(app.buttons["閉じる"].isHittable)
        attach("Japanese setup from unified guide")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.staticTexts["通知設定"].waitForNonExistence(timeout: 5))
        openGuide(app)
        XCTAssertFalse(app.staticTexts["通知設定"].exists, "Reopening starts with the overview")
        app.buttons["閉じる"].tap()
    }

    @MainActor
    private func withdrawConsent(_ app: XCUIApplication) {
        reach(app.buttons["データ利用と同意"], in: app.collectionViews.firstMatch).tap()
        reach(app.buttons["同意を取り消す"], in: app.scrollViews.firstMatch).tap()
        let confirm = app.alerts.buttons["同意を取り消す"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    @MainActor
    private func openGuide(_ app: XCUIApplication) {
        let row = app.buttons["アプリの使い方"]
        reach(row, in: app.collectionViews.firstMatch).tap()
        XCTAssertTrue(
            app.navigationBars["アプリの使い方"].waitForExistence(timeout: 5),
            "Japanese entry and screen must use the same title",
        )
        XCTAssertTrue(app.collectionViews["guide.overview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["次へ"].exists)
        XCTAssertFalse(app.staticTexts["通知設定"].exists)
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
