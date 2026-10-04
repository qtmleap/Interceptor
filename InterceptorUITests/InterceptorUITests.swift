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
            app.tabBars.buttons["Settings"].tap()
            app.buttons["Data Use and Consent"].tap()
            if app.buttons["Withdraw Consent"].exists { app.buttons["Withdraw Consent"].tap() }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let connection = app.switches["Connection Status"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertFalse(connection.isEnabled)
        app.buttons["Data Use and Consent"].tap()
        XCTAssertTrue(app.buttons["Agree and Continue"].waitForExistence(timeout: 5))
        app.buttons["Agree and Continue"].tap()
        XCTAssertTrue(app.buttons["Withdraw Consent"].waitForExistence(timeout: 5))
        app.buttons["Withdraw Consent"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(connection.isEnabled)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.switches["Connection Status"].isEnabled)
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
        app.tabBars.buttons["Settings"].tap()
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
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        attachScreenshot(app, named: "Home")

        app.tabBars.buttons["Settings"].tap()
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
        app.tabBars.buttons["Home"].tap()

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        XCTAssertTrue(app.navigationBars["Home"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Next"].exists, "Completed onboarding must remain dismissed after relaunch")
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
