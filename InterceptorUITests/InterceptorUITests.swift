//
//  InterceptorUITests.swift
//  InterceptorUITests
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import XCTest

final class InterceptorUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testHowToUseCanCloseAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        XCTAssertFalse(app.buttons["Capture Setup"].exists, "Setup must share the How to Use entry")
        for _ in 0 ..< 2 {
            settingsButton(app, named: "How to Use").tap()
            XCTAssertTrue(app.navigationBars["How to Use"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Review Requests"].exists)
            XCTAssertFalse(app.buttons["Next"].exists, "The guide must not start certificate or VPN setup")
            XCTAssertFalse(app.buttons["Allow Notifications"].exists)
            XCTAssertTrue(app.buttons["Close"].isHittable)
            attachScreenshot(app, named: "Read-only How to Use")
            app.buttons["Close"].tap()
            XCTAssertTrue(app.navigationBars["How to Use"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Agree"].exists)
        }
        XCTAssertFalse(app.buttons["Allow Notifications"].exists, "Notification permission belongs inside Capture Setup")
        startCaptureSetup(app)
        // Next is not guaranteed on the first page: it only appears once permission is decided.
        _ = waitForNotificationStage(app)
        XCTAssertTrue(app.staticTexts["Notification Settings"].exists)
        XCTAssertFalse(app.staticTexts["About This App"].exists)
        XCTAssertFalse(app.buttons["Back"].exists, "The first setup page has Close, not Back")
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        settingsButton(app, named: "How to Use").tap()
        XCTAssertTrue(app.navigationBars["How to Use"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.collectionViews["guide.overview"].exists, "Reopening after setup must return to the overview")
        XCTAssertFalse(app.staticTexts["Notification Settings"].exists)
        app.buttons["Close"].tap()
    }

    @MainActor
    func testCaptureSetupLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        agreeIfNeeded(app)
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertGreaterThan(app.frame.width, app.frame.height, "iPad must actually display a landscape viewport")
        } else {
            XCTAssertGreaterThan(app.frame.height, app.frame.width, "iPhone supports a portrait viewport")
        }
        tab(app, named: "Settings").tap()
        startCaptureSetup(app)
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        let scroll = app.scrollViews.containing(.staticText, identifier: "Notification Settings").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "Setup instructions and controls must remain scrollable in a short window")
        let stage = waitForNotificationStage(app)
        for _ in 0 ..< 6 {
            if notificationControlsHittable(app, stage) {
                break
            }
            scroll.swipeUp()
        }
        XCTAssertTrue(notificationControlsHittable(app, stage), "Notification controls must be reachable at large text in the supported orientation")
        XCTAssertTrue(app.buttons["Close"].isHittable)
        attachDeviceScreenshot(named: UIDevice.current.userInterfaceIdiom == .pad ? "Capture Setup large text landscape" : "Capture Setup large text portrait")
        // Continue without requesting notification permission.
        advancePastNotifications(app)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCaptureSetupCanFinishAndReopen() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        startCaptureSetup(app)
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        let instructions = app.scrollViews.containing(.staticText, identifier: "Notification Settings").firstMatch
        if app.frame.width >= 700 && app.frame.height > 1000 {
            XCTAssertLessThanOrEqual(instructions.frame.width, 621,
                                     "A regular-width iPad should use a bounded setup sheet")
            XCTAssertGreaterThan(instructions.frame.minX, 0,
                                 "The setup sheet should retain a margin on iPad")
        }
        let stage = waitForNotificationStage(app)
        XCTAssertTrue(app.staticTexts["Step 1 of 6"].exists)
        let setupButtons = stage == .undecided ? ["Allow Notifications", "Skip for Now"] : ["Next"]
        for title in setupButtons {
            let frame = app.buttons[title].frame
            XCTAssertLessThanOrEqual(frame.width, 321,
                                     "Standard-size setup buttons should not stretch across the iPad sheet")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(title) must keep a 44 pt hit region")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(title) must keep a 44 pt hit region")
        }
        attachScreenshot(app, named: "Capture Setup portrait")
        advancePastNotifications(app)
        XCTAssertTrue(app.staticTexts["Step 2 of 6"].exists)
        XCTAssertTrue(app.buttons["Back"].isHittable, "Back replaces Close at the leading edge after the first page")
        XCTAssertTrue(app.buttons["Close"].isHittable)
        for title in ["VPN Configuration Profile", "Install Profile", "Trust Certificate",
                      "Install VPN Configuration", "Enable VPN Configuration"]
        {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            if title == "Enable VPN Configuration" {
                // The final Done exists only in the toolbar (gated by the real VPN state).
                XCTAssertFalse(app.buttons["Next"].exists)
                XCTAssertTrue(app.navigationBars.buttons["Done"].isHittable)
                app.navigationBars.buttons["Done"].tap()
            } else {
                XCTAssertTrue(app.buttons["Next"].isHittable)
                XCTAssertFalse(app.navigationBars.buttons["Done"].exists)
                app.buttons["Next"].tap()
            }
        }
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForNonExistence(timeout: 5))
        startCaptureSetup(app)
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let closeAfterRotation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["Close"],
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closeAfterRotation], timeout: 5), .completed,
                       "Close must become usable after the sheet's rotation animation")
        let rotatedInstructions = app.scrollViews.containing(.staticText, identifier: "Notification Settings").firstMatch
        let rotatedStage = waitForNotificationStage(app)
        for _ in 0 ..< 6 {
            if notificationControlsHittable(app, rotatedStage) {
                break
            }
            rotatedInstructions.swipeUp()
        }
        XCTAssertTrue(notificationControlsHittable(app, rotatedStage), "Rotating an open setup sheet must keep its controls reachable")
        XCTAssertTrue(app.buttons["Close"].isHittable)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
        } else {
            XCTAssertGreaterThan(app.frame.height, app.frame.width)
        }
        attachDeviceScreenshot(named: UIDevice.current.userInterfaceIdiom == .pad ? "Capture Setup after iPad rotation" : "Capture Setup iPhone portrait after device rotation")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.switches["Status"].exists)
        XCTAssertFalse(app.buttons["Allow Notifications"].exists)
    }

    @MainActor
    func testCaptureConsentLifecycle() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        // Establish revoked authorization through the UI, regardless of previous test state.
        agreeIfNeeded(app)
        revokeForStartupTest(app)
        assertStartupConsent(app)
        app.swipeDown()
        assertStartupConsent(app)
        attachScreenshot(app, named: "Mandatory launch consent")

        app.terminate()
        // A legacy decision flag must not bypass revoked shared authorization (version 0).
        app.launchArguments += ["-CaptureConsentDecided", "YES"]
        app.launch()
        assertStartupConsent(app)
        app.terminate()
        app.launch()
        assertStartupConsent(app)
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        XCTAssertTrue(app.switches["Status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Status"].isEnabled)
        XCTAssertFalse(app.staticTexts["Consent Status"].exists)
        XCTAssertFalse(app.buttons["Read Details"].exists)
        XCTAssertFalse(app.buttons["Review and Agree"].exists)
        XCTAssertFalse(app.buttons["Withdraw Consent"].exists)
        settingsButton(app, named: "Data Use & Consent").tap()
        XCTAssertTrue(app.navigationBars["Data Use & Consent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Purpose"].exists)
        XCTAssertFalse(app.buttons["Agree"].exists)
        let withdrawal = settingsButton(app, named: "Withdraw Consent")
        XCTAssertGreaterThanOrEqual(withdrawal.frame.height, 44)
        attachDeviceScreenshot(named: "Consent withdrawal button")
        withdrawal.tap()
        XCTAssertTrue(app.alerts.buttons["Cancel"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Agree"].exists)
        XCTAssertTrue(app.navigationBars["Data Use & Consent"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(tab(app, named: "Settings").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agree"].exists)
        openPrivacy(app)
        withdrawConsent(app)
        assertStartupConsent(app)
        app.terminate()
        app.launch()
        assertStartupConsent(app)
        // Leave consent granted so other navigation tests do not depend on ordering.
        agreeIfNeeded(app)
        // Accept both accessibility roles used by SwiftUI Link across OS versions.
        let policy = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)",
            "Privacy Policy", Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.link.rawValue),
        )).firstMatch
        XCTAssertTrue(scrollTo(app, policy).isHittable)
        app.terminate()
    }

    @MainActor
    func testConsentDetailsLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        agreeIfNeeded(app)
        revokeForStartupTest(app)
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        assertStartupConsent(app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertGreaterThan(app.frame.width, app.frame.height, "iPad must actually display a landscape viewport")
        } else {
            XCTAssertGreaterThan(app.frame.height, app.frame.width, "iPhone supports a portrait viewport")
        }
        XCTAssertTrue(app.navigationBars.buttons["Agree"].isHittable)
        attachDeviceScreenshot(named: UIDevice.current.userInterfaceIdiom == .pad ? "Mandatory consent large text landscape" : "Mandatory consent large text portrait")
        agreeIfNeeded(app)
        openPrivacy(app)
        XCTAssertTrue(app.staticTexts["Purpose"].exists)
        XCTAssertFalse(app.buttons["Agree"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        attachDeviceScreenshot(named: UIDevice.current.userInterfaceIdiom == .pad ? "Privacy large text landscape" : "Privacy large text portrait")
    }

    private struct DisclaimerLocale {
        let args: [String]
        let isJapanese: Bool
        let title: String
        let settingsTab: String
        let privacy: String
        let agree: String
        let withdraw: String

        static let english = DisclaimerLocale(
            args: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"], isJapanese: false,
            title: "Apple Policy Disclaimer", settingsTab: "Settings", privacy: "Data Use & Consent",
            agree: "Agree", withdraw: "Withdraw Consent",
        )
        static let japanese = DisclaimerLocale(
            args: ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"], isJapanese: true,
            title: "Appleポリシーに基づく注意事項", settingsTab: "設定", privacy: "データ利用と同意",
            agree: "同意する", withdraw: "同意を取り消す",
        )
    }

    /// Verifies the Apple policy disclaimer card before consent and in Settings > Data Use & Consent, per locale.
    @MainActor
    func testAppleDisclaimerShownBeforeConsentAndInPrivacy() {
        XCUIDevice.shared.orientation = .portrait
        for loc in [DisclaimerLocale.english, .japanese] {
            let app = XCUIApplication()
            app.launchArguments = loc.args
            app.launch()
            addTeardownBlock { @MainActor in app.terminate() }

            // Precondition: revoke consent through the UI (agree first if the gate is showing).
            let agree = app.buttons[loc.agree]
            let settings = tab(app, named: loc.settingsTab)
            XCTAssertTrue(agree.waitForExistence(timeout: 5) || settings.waitForExistence(timeout: 5),
                          "app must show the gate or the main UI (\(loc.title))")
            if agree.exists {
                agree.tap()
            }
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            scrollTo(app, app.buttons[loc.privacy]).tap()
            XCTAssertTrue(app.navigationBars[loc.privacy].waitForExistence(timeout: 5))
            scrollTo(app, app.buttons[loc.withdraw]).tap()
            let confirm = app.alerts.buttons[loc.withdraw]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()

            // Before consent: gate blocks main UI, and the disclaimer is visible without scrolling.
            XCTAssertTrue(agree.waitForExistence(timeout: 5), "Agree gate must appear (\(loc.title))")
            XCTAssertTrue(app.navigationBars[loc.privacy].exists, "Initial and Settings consent must share the same title")
            XCTAssertFalse(tab(app, named: loc.settingsTab).exists, "main UI must be blocked before Agree")
            let title = app.staticTexts[loc.title]
            XCTAssertTrue(title.waitForExistence(timeout: 5), "disclaimer title must render before consent")
            XCTAssertTrue(title.isHittable, "title must be visible without scrolling")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(title.frame))
            let initialBody = assertDisclaimerBody(app, title: title, loc: loc)
            attachScreenshot(app, named: "Apple disclaimer before consent \(loc.isJapanese ? "ja" : "en")")

            agree.tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))

            // Persistent: still available in Settings > Data Use & Consent after consent.
            settings.tap()
            scrollTo(app, app.buttons[loc.privacy]).tap()
            XCTAssertTrue(app.navigationBars[loc.privacy].waitForExistence(timeout: 5))
            let privacyTitle = scrollTo(app, app.staticTexts[loc.title])
            XCTAssertFalse(app.buttons[loc.agree].exists)
            XCTAssertEqual(assertDisclaimerBody(app, title: privacyTitle, loc: loc), initialBody,
                           "Initial and Settings consent must display the same disclosure")
            attachScreenshot(app, named: "Apple disclaimer in Data Use \(loc.isJapanese ? "ja" : "en")")
            let withdrawal = scrollTo(app, app.buttons[loc.withdraw])
            XCTAssertTrue(withdrawal.isHittable)
            XCTAssertGreaterThanOrEqual(withdrawal.frame.height, 44)
            attachDeviceScreenshot(named: "Consent withdrawal \(loc.isJapanese ? "ja" : "en")")
            app.terminate()
        }
    }

    /// The rendered body below the title must be real localized text, not empty or a raw key.
    @MainActor
    @discardableResult
    private func assertDisclaimerBody(_ app: XCUIApplication, title: XCUIElement, loc: DisclaimerLocale) -> String {
        let titleFrame = title.frame
        let body = app.scrollViews["consent.disclosure"].staticTexts.allElementsBoundByIndex
            .filter { $0.frame.minY >= titleFrame.maxY - 1 && !$0.label.isEmpty && $0.label != loc.title }
            .min { $0.frame.minY < $1.frame.minY }
        guard let text = body?.label else {
            XCTFail("disclaimer must render a body below its title (\(loc.title))")
            return ""
        }
        XCTAssertGreaterThanOrEqual(text.count, 20, "body must be substantive: \(text)")
        XCTAssertNil(text.range(of: "^[A-Z0-9_.]+$", options: .regularExpression), "raw key shown: \(text)")
        let hasJapanese = text.range(of: "[\\u3040-\\u30FF\\u4E00-\\u9FFF]", options: .regularExpression) != nil
        XCTAssertEqual(hasJapanese, loc.isJapanese, "body must be in the launch locale: \(text)")
        return text
    }

    @MainActor
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        for _ in 0 ..< 10 {
            if element.exists && element.isHittable {
                return element
            }
            let isPrivacy = app.navigationBars["Data Use & Consent"].exists || app.navigationBars["データ利用と同意"].exists
            let form = isPrivacy && app.scrollViews.firstMatch.exists
                ? app.scrollViews.firstMatch
                : (app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch)
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2)))
        }
        XCTFail("Must be able to scroll to \(element)")
        return element
    }

    @MainActor
    private func assertStartupConsent(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Not Now"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        XCTAssertFalse(tab(app, named: "Settings").exists)
        XCTAssertFalse(app.switches["Status"].exists)
    }

    @MainActor
    private func agreeIfNeeded(_ app: XCUIApplication) {
        if app.buttons["Agree"].waitForExistence(timeout: 3) {
            app.buttons["Agree"].tap()
        }
        XCTAssertTrue(tab(app, named: "Settings").waitForExistence(timeout: 5))
        // Existing installations may have dismissed the old optional consent screen.
        // Grant through its old settings action before establishing a revoked baseline.
        tab(app, named: "Settings").tap()
        if app.buttons["Review and Agree"].exists {
            settingsButton(app, named: "Review and Agree").tap()
            XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5))
            app.buttons["Agree"].tap()
        }
    }

    @MainActor
    private func revokeForStartupTest(_ app: XCUIApplication) {
        tab(app, named: "Settings").tap()
        // Normalize consent using either the old settings section or its replacement.
        // This also lets the regression fail on the mandatory gate before the UI changes.
        if !app.buttons["Read Details"].exists {
            settingsButton(app, named: "Data Use & Consent").tap()
        }
        withdrawConsent(app)
    }

    @MainActor
    private func openPrivacy(_ app: XCUIApplication) {
        tab(app, named: "Settings").tap()
        settingsButton(app, named: "Data Use & Consent").tap()
        XCTAssertTrue(app.navigationBars["Data Use & Consent"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func startCaptureSetup(_ app: XCUIApplication) {
        settingsButton(app, named: "How to Use").tap()
        XCTAssertTrue(app.navigationBars["How to Use"].waitForExistence(timeout: 5))
        let begin = app.buttons["guide.beginSetup"]
        let guide = app.collectionViews["guide.overview"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        for _ in 0 ..< 6 {
            if begin.exists && begin.isHittable { break }
            guide.swipeUp()
        }
        XCTAssertTrue(begin.exists)
        XCTAssertTrue(begin.isHittable)
        attachDeviceScreenshot(named: "Unified guide before setup")
        begin.tap()
    }

    @MainActor
    private func settingsButton(_ app: XCUIApplication, named name: String) -> XCUIElement {
        let button = app.buttons[name]
        let form: XCUIElement = if app.navigationBars["Data Use & Consent"].exists && app.scrollViews.firstMatch.exists {
            app.scrollViews.firstMatch
        } else {
            app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        }
        for _ in 0 ..< 10 {
            if button.exists && button.isHittable {
                return button
            }
            // Keep the gesture in the visible part of iPad's displaced sidebar.
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Settings must allow scrolling to \(name)")
        return button
    }

    @MainActor
    private func withdrawConsent(_ app: XCUIApplication) {
        settingsButton(app, named: "Withdraw Consent").tap()
        let confirm = app.alerts.buttons["Withdraw Consent"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    // MARK: - Notification permission (real SpringBoard alert)

    //
    // Each branch needs a notDetermined permission, so run each test on its own freshly erased
    // simulator; otherwise the test reports XCTSkip.

    @MainActor
    func testNotificationPermissionGranted() throws {
        try exerciseNotificationPermission(allow: true)
    }

    @MainActor
    func testNotificationPermissionDenied() throws {
        try exerciseNotificationPermission(allow: false)
    }

    @MainActor
    private func exerciseNotificationPermission(allow: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        startCaptureSetup(app)
        guard waitForNotificationStage(app) == .undecided else {
            throw XCTSkip("Notification permission is already decided; run on a fresh simulator to exercise this branch.")
        }
        XCTAssertFalse(app.buttons["Next"].exists)
        app.buttons["Allow Notifications"].tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The system notification permission alert must appear")
        // Accept both the curly and straight apostrophe in "Don't Allow".
        let predicate = allow
            ? NSPredicate(format: "label == 'Allow'")
            : NSPredicate(format: "label IN {'Don\u{2019}t Allow', 'Don\\'t Allow'}")
        let choice = alert.buttons.matching(predicate).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The system alert must offer \(allow ? "Allow" : "Don't Allow")")
        choice.tap()

        // Granted or denied, the choice advances exactly one page.
        XCTAssertTrue(app.staticTexts["VPN Configuration Profile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Step 2 of 6"].exists)

        // The page now reflects the decided state and offers Next.
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Allow Notifications"].exists)
        XCTAssertFalse(app.buttons["Skip for Now"].exists)
        if allow {
            XCTAssertTrue(app.staticTexts["Notifications are on."].exists)
            XCTAssertFalse(app.buttons["Open Settings"].exists)
        } else {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Notifications are off'")).firstMatch.exists)
            // Optional action: check it is offered, but never tap it (that would leave the app).
            XCTAssertTrue(app.buttons["Open Settings"].exists)
        }
        attachScreenshot(app, named: allow ? "Notification permission granted" : "Notification permission denied")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForNonExistence(timeout: 5))
    }

    private enum NotificationStage { case undecided, decided }

    /// Waits for the first setup page to resolve its permission state (Allow vs Next).
    @MainActor
    private func waitForNotificationStage(_ app: XCUIApplication) -> NotificationStage {
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        let allow = app.buttons["Allow Notifications"]
        let next = app.buttons["Next"]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if allow.waitForExistence(timeout: 0.25) {
                return .undecided
            }
            if next.waitForExistence(timeout: 0.25) {
                return .decided
            }
        } while Date() < deadline
        XCTFail("Notification state never resolved")
        return .undecided
    }

    @MainActor
    private func notificationControlsHittable(_ app: XCUIApplication, _ stage: NotificationStage) -> Bool {
        switch stage {
            case .undecided: app.buttons["Allow Notifications"].isHittable && app.buttons["Skip for Now"].isHittable
            case .decided: app.buttons["Next"].isHittable
        }
    }

    /// Leaves the notification page without changing permission: Skip (no confirmation) or Next.
    @MainActor
    private func advancePastNotifications(_ app: XCUIApplication) {
        switch waitForNotificationStage(app) {
            case .undecided:
                XCTAssertFalse(app.buttons["Next"].exists, "Next must not appear before permission is decided")
                let skip = app.buttons["Skip for Now"]
                XCTAssertTrue(skip.isHittable)
                skip.tap()
            case .decided:
                app.buttons["Next"].tap()
        }
        XCTAssertTrue(app.staticTexts["VPN Configuration Profile"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPhysicalNintendoCapture() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Nintendo capture requires a logged-in Nintendo Switch App on a physical device.")
        #else
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        let connection = app.switches["Status"]
        addTeardownBlock { @MainActor in
            app.activate()
            if app.alerts.buttons["OK"].exists {
                app.alerts.buttons["OK"].tap()
            }
            if !app.buttons["Agree"].exists {
                self.openPrivacy(app)
                self.withdrawConsent(app)
            }
        }
        if connection.value as? String != "1" {
            try switchControl(app, row: connection).tap()
        }
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: connection)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 20), .completed)
        let nintendo = XCUIApplication(bundleIdentifier: "com.nintendo.znca")
        nintendo.launch()
        XCTAssertTrue(nintendo.wait(for: .runningForeground, timeout: 10))
        let game = nintendo.cells["SplatNet 3"]
        guard game.waitForExistence(timeout: 10) else {
            attachScreenshot(nintendo, named: "Private Nintendo navigation inspection")
            XCTFail("The SplatNet 3 entry was not found; inspect the private Nintendo UI attachment.")
            return
        }
        game.tap()
        _ = nintendo.webViews.firstMatch.waitForExistence(timeout: 20)
        app.activate()
        tab(app, named: "Home").tap()
        let capturedHost = app.staticTexts["api.lp1.av5ja.srv.nintendo.net"]
        XCTAssertTrue(capturedHost.waitForExistence(timeout: 10))
        capturedHost.tap()
        XCTAssertTrue(app.staticTexts["/api/bullet_tokens"].waitForExistence(timeout: 10), "The Nintendo token request must appear in captured history.")
        tab(app, named: "Settings").tap()
        settingsButton(app, named: "Token List").tap()
        XCTAssertTrue(app.navigationBars["Token List"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["api.lp1.av5ja.srv.nintendo.net"].waitForExistence(timeout: 15), "The app must extract the Splatoon 3 token from captured Nintendo traffic.")
        // Stay on the token host list: opening token details would expose live credentials.
        #endif
    }

    @MainActor
    func testPhysicalVPNLifecycle() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("VPN tunnel validation requires a physical device with the certificate and VPN installed.")
        #else
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        let connection = app.switches["Status"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(connection.isEnabled)
        let control = try switchControl(app, row: connection)
        addTeardownBlock { @MainActor in
            app.activate()
            if app.alerts.buttons["OK"].exists {
                app.alerts.buttons["OK"].tap()
            }
            if !app.buttons["Agree"].exists {
                self.openPrivacy(app)
                self.withdrawConsent(app)
            }
        }
        if connection.value as? String == "1" {
            control.tap()
            let initiallyStopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: connection)
            XCTAssertEqual(XCTWaiter.wait(for: [initiallyStopped], timeout: 15), .completed)
        }
        control.tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: connection)
        let result = XCTWaiter.wait(for: [connected], timeout: 20)
        attachScreenshot(app, named: "Physical VPN start result")
        if result != .completed {
            let diagnostic = XCTAttachment(string: app.debugDescription)
            diagnostic.name = "Physical VPN start accessibility"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertEqual(result, .completed, "Install the Interceptor VPN configuration before running this test; inspect the attached start result for errors.")
        guard result == .completed else { return }
        let probePath = "/__interceptor_review_probe_" + UUID().uuidString
        let probeURL = try XCTUnwrap(URL(string: "https://api.lp1.av5ja.srv.nintendo.net" + probePath))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: probeURL)
        XCTAssertNotNil(response as? HTTPURLResponse, "A public probe must complete TLS and receive an HTTP response.")
        app.activate()
        tab(app, named: "Home").tap()
        let host = app.staticTexts["api.lp1.av5ja.srv.nintendo.net"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        XCTAssertTrue(app.staticTexts[probePath].waitForExistence(timeout: 10), "The unique public probe must appear in captured history.")
        attachScreenshot(app, named: "Physical VPN captured public HTTPS probe")
        tab(app, named: "Settings").tap()
        control.tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: connection)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)
        control.tap()
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: connection)
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 20), .completed)
        openPrivacy(app)
        withdrawConsent(app)
        assertStartupConsent(app)
        attachScreenshot(app, named: "Physical mandatory consent after withdrawal")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let vpnSettings = settings.buttons["com.apple.settings.vpn"]
        XCTAssertTrue(vpnSettings.waitForExistence(timeout: 5))
        vpnSettings.tap()
        let systemStatus = settings.switches.matching(NSPredicate(format: "label BEGINSWITH 'VPN Status'")).firstMatch
        XCTAssertTrue(systemStatus.waitForExistence(timeout: 5))
        let systemStopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: systemStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [systemStopped], timeout: 15), .completed, "iPadOS must report that the VPN stopped after consent withdrawal.")
        attachScreenshot(settings, named: "Physical system VPN disconnected")
        #endif
    }

    @MainActor
    func testSimulatorOnboardingAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        addUIInterruptionMonitor(withDescription: "Tracking permission") { alert in
            let decline = alert.buttons["Ask App Not to Track"]
            guard decline.exists else { return false }
            decline.tap()
            return true
        }
        app.launch()

        agreeIfNeeded(app)
        tab(app, named: "Settings").tap()
        startCaptureSetup(app)

        // The simulator permits advancing through the device-only setup steps.
        XCTAssertTrue(app.staticTexts["Step 1 of 6"].waitForExistence(timeout: 5))
        advancePastNotifications(app)
        XCTAssertTrue(app.staticTexts["Step 2 of 6"].exists)
        // Back returns to the notification page.
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Notification Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Step 1 of 6"].exists)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        advancePastNotifications(app)
        // Closing mid-flow dismisses setup; reopening starts again from the first page.
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Step 3 of 6"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Step 3 of 6"].waitForNonExistence(timeout: 5))
        startCaptureSetup(app)
        XCTAssertTrue(app.staticTexts["Step 1 of 6"].waitForExistence(timeout: 5))
        advancePastNotifications(app)
        for _ in 0 ..< 4 {
            XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
            app.buttons["Next"].tap()
        }
        XCTAssertTrue(app.staticTexts["Step 6 of 6"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Step 6 of 6"].waitForNonExistence(timeout: 5))
        tab(app, named: "Home").tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(tab(app, named: "Home").waitForExistence(timeout: 10))
        attachScreenshot(app, named: "Home")

        tab(app, named: "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let autoConnect = app.switches["Auto Connect"]
        XCTAssertTrue(autoConnect.waitForExistence(timeout: 5))
        let control = try switchControl(app, row: autoConnect)
        let initialValue = try XCTUnwrap(control.value as? String)
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", initialValue), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        control.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", initialValue), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        attachScreenshot(app, named: "Settings")

        settingsButton(app, named: "SSL Proxying List").tap()
        XCTAssertTrue(app.navigationBars["SSL Proxying List"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["api.lp1.av5ja.srv.nintendo.net"].exists)
        XCTAssertTrue(app.staticTexts["app.splatoon2.nintendo.net"].exists)
        attachScreenshot(app, named: "Proxy Hosts")
        returnFromSettingsDetail(app)

        settingsButton(app, named: "Token List").tap()
        XCTAssertTrue(app.navigationBars["Token List"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Token List")
        returnFromSettingsDetail(app)

        settingsButton(app, named: "Certificate").tap()
        XCTAssertTrue(app.navigationBars["Certificate"].waitForExistence(timeout: 5))
        returnFromSettingsDetail(app)
        settingsButton(app, named: "Licenses").tap()
        XCTAssertTrue(app.navigationBars["Licenses"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Licenses detail title")
        let license = app.staticTexts["BetterSafariView"].firstMatch
        XCTAssertTrue(license.waitForExistence(timeout: 5))
        license.tap()
        XCTAssertTrue(app.navigationBars["BetterSafariView"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Individual license inline title")
        app.navigationBars.buttons["Licenses"].firstMatch.tap()
        returnFromSettingsDetail(app)
        tab(app, named: "Home").tap()

        let clear = app.navigationBars.buttons["Clear History"]
        XCTAssertTrue(clear.exists)
        if clear.isEnabled {
            clear.tap()
            XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
            app.buttons["Clear"].tap()
        } else {
            XCTAssertTrue(app.staticTexts["No Captured Requests"].exists)
        }
        XCTAssertTrue(app.navigationBars["Home"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(tab(app, named: "Home").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Notification Settings"].exists, "Completed onboarding must remain dismissed after relaunch")
    }

    @MainActor
    private func returnFromSettingsDetail(_ app: XCUIApplication) {
        // iPad replaces the secondary root while keeping Settings visible in the sidebar.
        // iPhone pushes the destination and exposes Settings as its back button.
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists {
            back.tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func switchControl(_ app: XCUIApplication, row: XCUIElement) throws -> XCUIElement {
        // iPadOS 18 exposes the UISwitch beside its labeled row; newer versions nest it.
        let frame = row.frame
        return try XCTUnwrap(app.switches.allElementsBoundByIndex.first { candidate in
            let controlFrame = candidate.frame
            return controlFrame.width < frame.width
                && frame.contains(CGPoint(x: controlFrame.midX, y: controlFrame.midY))
        }, "The labeled row must expose its actual switch control.")
    }

    @MainActor
    private func tab(_ app: XCUIApplication, named name: String) -> XCUIElement {
        // iPadOS exposes its top tabs as ordinary buttons, rather than a TabBar.
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachDeviceScreenshot(named name: String) {
        // Application screenshots can retain portrait bounds after a landscape launch.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
