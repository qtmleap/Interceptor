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
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        else {
            tab(app, named: "Settings").tap()
            app.buttons["Data Use and Consent"].tap()
            if app.buttons["Withdraw Consent"].exists { app.buttons["Withdraw Consent"].tap() }
            returnToSettings(app)
        }
        XCTAssertTrue(tab(app, named: "Home").waitForExistence(timeout: 5))
        tab(app, named: "Settings").tap()
        let connection = app.switches["Connection Status"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertFalse(connection.isEnabled)
        app.buttons["Data Use and Consent"].tap()
        XCTAssertTrue(app.buttons["Agree and Continue"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Data Use and Consent")
        app.buttons["Agree and Continue"].tap()
        XCTAssertTrue(app.buttons["Withdraw Consent"].waitForExistence(timeout: 5))
        app.buttons["Withdraw Consent"].tap()
        attachScreenshot(app, named: "Consent Withdrawn")
        returnToSettings(app)
        XCTAssertFalse(connection.isEnabled)
        app.terminate()
        app.launch()
        tab(app, named: "Settings").tap()
        XCTAssertFalse(app.switches["Connection Status"].isEnabled)
    }

    @MainActor
    func testPhysicalVPNLifecycle() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("VPN tunnel validation requires a physical device with the certificate and VPN installed.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        app.buttons["Data Use and Consent"].tap()
        if app.buttons["Agree and Continue"].exists { app.buttons["Agree and Continue"].tap() }
        returnToSettings(app)
        let connection = app.switches["Connection Status"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(connection.isEnabled)
        let control = connection.switches.firstMatch
        defer {
            app.activate()
            tab(app, named: "Settings").tap()
            if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
            app.buttons["Data Use and Consent"].tap()
            if app.buttons["Withdraw Consent"].exists { app.buttons["Withdraw Consent"].tap() }
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
        app.buttons["Data Use and Consent"].tap()
        app.buttons["Withdraw Consent"].tap()
        returnToSettings(app)
        let revoked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0' AND enabled == false"), object: connection)
        XCTAssertEqual(XCTWaiter.wait(for: [revoked], timeout: 15), .completed)
        attachScreenshot(app, named: "Physical VPN stopped after withdrawal")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.general"].tap()
        let vpnSettings = settings.cells["ManagedConfigurationList"]
        if !vpnSettings.isHittable { settings.swipeUp() }
        XCTAssertTrue(vpnSettings.waitForExistence(timeout: 5))
        vpnSettings.tap()
        XCTAssertTrue(settings.staticTexts["Not Connected"].waitForExistence(timeout: 15), "iPadOS must report that the VPN stopped after consent withdrawal.")
        attachScreenshot(settings, named: "Physical system VPN disconnected")
        #endif
    }

    @MainActor
    func testSimulatorOnboardingAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "Tracking permission") { alert in
            let decline = alert.buttons["Ask App Not to Track"]
            guard decline.exists else { return false }
            decline.tap()
            return true
        }
        app.launch()

        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        tab(app, named: "Settings").tap()
        app.buttons["Data Use and Consent"].tap()
        if app.buttons["Agree and Continue"].exists { app.buttons["Agree and Continue"].tap() }
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Set Up Capture"].tap()

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

        app.buttons["SSL Proxying List"].tap()
        XCTAssertTrue(app.navigationBars["SSL Proxying List"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["api.lp1.av5ja.srv.nintendo.net"].exists)
        XCTAssertTrue(app.staticTexts["app.splatoon2.nintendo.net"].exists)
        attachScreenshot(app, named: "Proxy Hosts")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Token List"].tap()
        XCTAssertTrue(app.navigationBars["Token List"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "Token List")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Certificate"].tap()
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
    private func tab(_ app: XCUIApplication, named name: String) -> XCUIElement {
        // iPadOS exposes its top tabs as ordinary buttons, rather than a TabBar.
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    private func returnToSettings(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Settings"].firstMatch
        // iPad keeps the Settings form beside the detail view, so there is no back button.
        if back.exists { back.tap() }
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
