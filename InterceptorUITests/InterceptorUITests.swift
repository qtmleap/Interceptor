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
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testCaptureConsentLifecycle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        XCTAssertTrue(app.buttons["Read Details"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Data use settings")
        if app.buttons["Withdraw Consent"].exists { withdrawConsent(app) }
        let connection = app.switches["Connection Status"]
        XCTAssertFalse(connection.isEnabled)
        app.buttons["Read Details"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agree"].exists)
        XCTAssertFalse(app.buttons["Withdraw Consent"].exists)
        app.buttons["Close"].tap()
        XCTAssertFalse(connection.isEnabled)
        app.buttons["Review and Agree"].tap()
        XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["Agree"].isHittable)
        XCTAssertTrue(app.navigationBars.buttons["Not Now"].isHittable)
        attachScreenshot(app, named: "Consent toolbar actions")
        app.buttons["Agree"].tap()
        XCTAssertTrue(app.buttons["Withdraw Consent"].waitForExistence(timeout: 5))
        XCTAssertTrue(connection.isEnabled)
        app.buttons["Withdraw Consent"].tap()
        XCTAssertTrue(app.alerts.buttons["Cancel"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(connection.isEnabled)
        app.buttons["Read Details"].tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(connection.isEnabled)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["Agree"].exists)
        tab(app, named: "Settings").tap()
        XCTAssertTrue(app.buttons["Withdraw Consent"].waitForExistence(timeout: 5))
        withdrawConsent(app)
        let revoked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: app.switches["Connection Status"])
        XCTAssertEqual(XCTWaiter.wait(for: [revoked], timeout: 5), .completed)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["Agree"].exists)
        tab(app, named: "Settings").tap()
        XCTAssertFalse(app.switches["Connection Status"].isEnabled)
    }

    @MainActor
    func testConsentDetailsLargeTextLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            app.launch()
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        settingsButton(app, named: "Read Details").tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agree"].exists)
        attachScreenshot(app, named: "Consent details large text landscape")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Read Details"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func settingsButton(_ app: XCUIApplication, named name: String) -> XCUIElement {
        let button = app.buttons[name]
        let form = app.collectionViews.firstMatch
        for _ in 0..<6 {
            if button.exists && button.isHittable { return button }
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
        app.buttons["Withdraw Consent"].tap()
        let confirm = app.alerts.buttons["Withdraw Consent"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
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
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        if app.buttons["Review and Agree"].exists {
            app.buttons["Review and Agree"].tap()
            app.buttons["Agree"].tap()
        }
        let connection = app.switches["Connection Status"]
        addTeardownBlock { @MainActor in
            app.activate()
            if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
            self.tab(app, named: "Settings").tap()
            if app.buttons["Withdraw Consent"].exists { self.withdrawConsent(app) }
        }
        if connection.value as? String != "1" { try switchControl(app, row: connection).tap() }
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
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        if app.buttons["Review and Agree"].exists {
            app.buttons["Review and Agree"].tap()
            app.buttons["Agree"].tap()
        }
        let connection = app.switches["Connection Status"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(connection.isEnabled)
        let control = try switchControl(app, row: connection)
        addTeardownBlock { @MainActor in
            app.activate()
            if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
            self.tab(app, named: "Settings").tap()
            if app.buttons["Withdraw Consent"].exists { self.withdrawConsent(app) }
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
        withdrawConsent(app)
        let revoked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0' AND enabled == false"), object: connection)
        XCTAssertEqual(XCTWaiter.wait(for: [revoked], timeout: 15), .completed)
        attachScreenshot(app, named: "Physical VPN stopped after withdrawal")
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

        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        if app.buttons["Review and Agree"].exists {
            app.buttons["Review and Agree"].tap()
            app.buttons["Agree"].tap()
        }
        settingsButton(app, named: "Set Up Capture").tap()

        // The simulator permits advancing through the device-only setup steps.
        if app.buttons["Next"].waitForExistence(timeout: 5) {
            for _ in 0..<8 {
                XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
                app.buttons["Next"].tap()
            }
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
        }
        XCTAssertTrue(tab(app, named: "Home").waitForExistence(timeout: 10))
        attachScreenshot(app, named: "Home")

        tab(app, named: "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let autoConnect = app.switches["Auto Connect"]
        XCTAssertTrue(autoConnect.waitForExistence(timeout: 5))
        let initialValue = try XCTUnwrap(autoConnect.value as? String)
        // SwiftUI exposes the labeled row as the switch's accessibility frame.
        // Tap the trailing control rather than the center of the row's label.
        let control = autoConnect.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", initialValue), object: autoConnect)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        control.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", initialValue), object: autoConnect)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        attachScreenshot(app, named: "Settings")

        settingsButton(app, named: "SSL Proxying List").tap()
        XCTAssertTrue(app.navigationBars["SSL Proxying List"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["api.lp1.av5ja.srv.nintendo.net"].exists)
        XCTAssertTrue(app.staticTexts["app.splatoon2.nintendo.net"].exists)
        attachScreenshot(app, named: "Proxy Hosts")
        app.navigationBars.buttons.firstMatch.tap()

        settingsButton(app, named: "Token List").tap()
        XCTAssertTrue(app.navigationBars["Token List"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Token List")
        app.navigationBars.buttons.firstMatch.tap()

        settingsButton(app, named: "Certificate").tap()
        XCTAssertTrue(app.navigationBars["Certificate"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        tab(app, named: "Home").tap()

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        XCTAssertTrue(app.navigationBars["Home"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(tab(app, named: "Home").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Next"].exists, "Completed onboarding must remain dismissed after relaunch")
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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
