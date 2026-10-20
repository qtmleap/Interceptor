@testable import Interceptor
import SwiftUI
import XCTest

@MainActor
final class PluginJSONViewerTests: XCTestCase {
    func testLargeJSONStaysSelectableReadOnlyAndBounded() throws {
        let json = "{\n  \"value\": \"日本語 😀\",\n  \"items\": [\n" + String(repeating: "    1,\n", count: 100) + "    2\n  ]\n}"
        try withViewer(json: json) { viewer in
            XCTAssertFalse(viewer.isEditable)
            XCTAssertTrue(viewer.isSelectable)
            XCTAssertTrue(viewer.isScrollEnabled)
            XCTAssertEqual(Array(viewer.text.utf8), Array(json.utf8))
            XCTAssertEqual(viewer.accessibilityIdentifier, "plugin.json")
            XCTAssertLessThanOrEqual(viewer.bounds.height, 220)
            XCTAssertGreaterThan(viewer.contentSize.height, viewer.bounds.height)
        }
    }

    func testFullScreenJSONUsesAvailableHeightAndRemainsReadOnly() throws {
        let json = "{\n  \"value\": 1\n}"
        try withViewer(json: json, fillsAvailableSpace: true) { viewer in
            XCTAssertGreaterThan(viewer.bounds.height, 500)
            XCTAssertFalse(viewer.isEditable)
            XCTAssertTrue(viewer.isSelectable)
            XCTAssertTrue(viewer.isScrollEnabled)
            XCTAssertEqual(Array(viewer.text.utf8), Array(json.utf8))
        }
    }

    private func withViewer(json: String, fillsAvailableSpace: Bool = false, check: (UITextView) throws -> Void) throws {
        let host = UIHostingController(rootView: PluginJSONViewer(json: json, identifier: "plugin.json", fillsAvailableSpace: fillsAvailableSpace))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            find(host.view)?.text.utf8.elementsEqual(json.utf8) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed)
        try check(XCTUnwrap(find(host.view)))
    }
}
