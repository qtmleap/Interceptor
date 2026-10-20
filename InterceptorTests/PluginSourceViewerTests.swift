@testable import Interceptor
import Runestone
import SwiftUI
import XCTest

@MainActor
final class PluginSourceViewerTests: XCTestCase {
    func testCanonicalEquivalentSourceUpdatesViewerBytes() throws {
        let composed = "// caf\u{00e9}\nconst value = 1;\n"
        let decomposed = "// cafe\u{0301}\nconst value = 1;\n"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let host = UIHostingController(rootView: PluginSourceViewer(source: composed, identifier: "plugin.source"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: host.view)?.text.utf8.elementsEqual(composed.utf8) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed)
        let viewer = try XCTUnwrap(findViewer(in: host.view))
        XCTAssertFalse(viewer.isEditable)
        XCTAssertEqual(viewer.accessibilityIdentifier, "plugin.source")
        for (index, source) in [decomposed, composed].enumerated() {
            host.rootView = PluginSourceViewer(source: source, identifier: "plugin.source")
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.findViewer(in: host.view)?.text.utf8.elementsEqual(source.utf8) == true
            }, object: nil)
            let result = XCTWaiter.wait(for: [updated], timeout: 5)
            let diagnostic = "update=\(index), actualUTF8=\(Array(viewer.text.utf8))"
            XCTAssertEqual(result, .completed, diagnostic)
            XCTAssertTrue(findViewer(in: host.view) === viewer, diagnostic)
            XCTAssertEqual(Array(viewer.text.utf8), Array(source.utf8), diagnostic)
        }
    }

    func testFullScreenViewerKeepsExactBytesSoftWrapsAndStaysReadOnly() throws {
        let original = "// " + String(repeating: "long ", count: 200) + "\r\nconst é = 1;\r\n"
        let host = UIHostingController(rootView: PluginSourceViewer(source: original, identifier: "plugin.source", fillsAvailableSpace: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: host.view)?.text.utf8.elementsEqual(original.utf8) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed)
        let viewer = try XCTUnwrap(findViewer(in: host.view))
        XCTAssertFalse(viewer.isEditable)
        XCTAssertTrue(viewer.isSelectable)
        XCTAssertTrue(viewer.showLineNumbers)
        XCTAssertTrue(viewer.isLineWrappingEnabled, "soft wrapping keeps long lines readable without changing source bytes")
        XCTAssertGreaterThan(viewer.bounds.height, 320, "the full-screen viewer fills the offered space")
        XCTAssertEqual(viewer.accessibilityIdentifier, "plugin.source")
    }

    private func findViewer(in view: UIView) -> TextView? {
        if let viewer = view as? TextView {
            return viewer
        }
        return view.subviews.lazy.compactMap { self.findViewer(in: $0) }.first
    }

    func testVerifiedSourceIsReadOnlyAndUpdatesWithoutNormalizingText() throws {
        let original = "// 日本語 😀\r\n\tconst path = \"/api/\";\r\nfunction onRequest() { return { actions: [] }; }\r\n"
        let host = UIHostingController(rootView: PluginSourceViewer(source: original))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: host.view)?.text == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed)
        let viewer = try XCTUnwrap(findViewer(in: host.view))
        XCTAssertFalse(viewer.isEditable)
        XCTAssertFalse(viewer.canBecomeFirstResponder)
        XCTAssertTrue(viewer.isSelectable)
        XCTAssertTrue(viewer.showLineNumbers)
        XCTAssertEqual(viewer.accessibilityIdentifier, "repo.script.source")
        XCTAssertEqual(Array(viewer.text.utf8), Array(original.utf8))

        let alternate = "// different verified revision\nconst status = 503;\n"
        host.rootView = PluginSourceViewer(source: alternate)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: host.view)?.text == alternate
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        XCTAssertTrue(findViewer(in: host.view) === viewer, "the existing viewer must refresh on entry/source changes")
        XCTAssertEqual(Array(viewer.text.utf8), Array(alternate.utf8))

        host.rootView = PluginSourceViewer(source: "")
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: host.view)?.text == ""
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [emptied], timeout: 5), .completed)
    }
}
