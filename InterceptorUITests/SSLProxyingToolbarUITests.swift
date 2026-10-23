import XCTest

public final class SSLProxyingToolbarUITests: XCTestCase {
    @MainActor
    func testEditingKeepsEditControlAtTrailingEdge() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        openList(app)
        let edit = app.buttons["ssl.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let initialFrame = edit.frame
        let appFrame = app.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: initialFrame.midX - appFrame.minX, dy: initialFrame.midY - appFrame.minY))
        defer {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "SSL edit control after repeated toggles"
            image.lifetime = .keepAlways
            add(image)
        }
        for _ in 0 ..< 3 {
            XCTAssertEqual(edit.label, "Edit")
            tapPoint.tap()
            let addHost = app.buttons["ssl.add"]
            XCTAssertTrue(addHost.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "ssl.edit").count, 1)
            XCTAssertEqual(edit.label, "Done")
            XCTAssertTrue(edit.isHittable)
            XCTAssertTrue(addHost.isHittable)
            XCTAssertEqual(edit.frame.maxX, initialFrame.maxX, accuracy: 1, "Adding an action must not move Edit/Done away from the trailing edge")
            XCTAssertTrue(edit.frame.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)), "The original Edit target must still activate Done")
            XCTAssertLessThanOrEqual(addHost.frame.maxX, edit.frame.minX, "Add must precede Edit/Done without overlapping")
            tapPoint.tap()
            XCTAssertTrue(addHost.waitForNonExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "ssl.edit").count, 1)
            XCTAssertEqual(edit.label, "Edit")
            XCTAssertEqual(edit.frame.maxX, initialFrame.maxX, accuracy: 1)
        }
    }

    @MainActor
    func testJapaneseEditLabels() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_PROXY_SUITE"] = "Interceptor.UITests.\(UUID().uuidString)"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        defer {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "Japanese SSL edit labels"
            image.lifetime = .keepAlways
            add(image)
            app.terminate()
        }
        openList(app, japanese: true)
        let edit = app.buttons["ssl.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "編集")
        edit.tap()
        let addHost = app.buttons["ssl.add"]
        XCTAssertTrue(addHost.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "完了")
        edit.tap()
        XCTAssertTrue(addHost.waitForNonExistence(timeout: 5))
        XCTAssertEqual(edit.label, "編集")
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
        for _ in 0 ..< 10 {
            if link.exists && link.isHittable {
                break
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }
}
