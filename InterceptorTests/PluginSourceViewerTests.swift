import Runestone
import SwiftUI
import XCTest
@testable import Interceptor

@MainActor
final class PluginSourceViewerTests: XCTestCase {
    private func findViewer(in view: UIView) -> TextView? {
        if let viewer = view as? TextView { return viewer }
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
