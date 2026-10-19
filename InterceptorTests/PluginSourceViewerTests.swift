@testable import Interceptor
import Runestone
import SwiftUI
import XCTest

@MainActor
final class PluginSourceViewerTests: XCTestCase {
    func testCanonicalEquivalentSourceUpdatesViewerAndEditorBytes() throws {
        let composed = "// caf\u{00e9}\nconst value = 1;\n"
        let decomposed = "// cafe\u{0301}\nconst value = 1;\n"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        for editable in [false, true] {
            func sourceView(_ source: String) -> AnyView {
                if editable {
                    return AnyView(PluginSourceEditor(text: .constant(source)))
                }
                return AnyView(PluginSourceViewer(source: source))
            }
            let host = UIHostingController(rootView: sourceView(composed))
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
            let editor = try XCTUnwrap(findViewer(in: host.view))
            XCTAssertEqual(editor.isEditable, editable)
            for (index, source) in [decomposed, composed].enumerated() {
                host.rootView = sourceView(source)
                let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    self.findViewer(in: host.view)?.text.utf8.elementsEqual(source.utf8) == true
                }, object: nil)
                let result = XCTWaiter.wait(for: [updated], timeout: 5)
                let bindingBytes = (editor.editorDelegate as? PluginSourceEditor.Coordinator).map { Array($0.text.wrappedValue.utf8) }
                let diagnostic = "editable=\(editable), update=\(index), bindingUTF8=\(String(describing: bindingBytes)), actualUTF8=\(Array(editor.text.utf8))"
                XCTAssertEqual(result, .completed, diagnostic)
                XCTAssertTrue(findViewer(in: host.view) === editor, diagnostic)
                XCTAssertEqual(Array(editor.text.utf8), Array(source.utf8), diagnostic)
            }
        }
    }

    /// Separates iOS Runestone setter behavior from SwiftUI representable updates.
    func testDirectMountedEditorStateReplacementPreservesCanonicalEquivalentSourceBytes() throws {
        let composed = "// caf\u{00e9}\nconst value = 1;\n"
        let decomposed = "// cafe\u{0301}\nconst value = 1;\n"
        let controller = UIHostingController(rootView: PluginSourceEditor(text: .constant(composed)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.layoutIfNeeded()
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.findViewer(in: controller.view)?.text.utf8.elementsEqual(composed.utf8) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed)
        let editor = try XCTUnwrap(findViewer(in: controller.view))
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(Array(editor.text.utf8), Array(composed.utf8))

        editor.text = decomposed
        let setterDecomposed = Array(editor.text.utf8)
        editor.setState(TextViewState(text: decomposed))
        let stateDecomposed = Array(editor.text.utf8)
        editor.text = composed
        let setterComposed = Array(editor.text.utf8)
        editor.setState(TextViewState(text: composed))
        let stateComposed = Array(editor.text.utf8)
        let nsEqual = (composed as NSString) == (decomposed as NSString)
        let setterGuard = decomposed as NSString != NSMutableString(string: composed)
        let diagnostic = """
        iOS \(UIDevice.current.systemVersion); NSString equality=\(nsEqual); Runestone NSString guard=\(setterGuard)
        direct setter NFD: \(setterDecomposed)
        direct plain-text setState NFD: \(stateDecomposed)
        direct setter NFC: \(setterComposed)
        direct plain-text setState NFC: \(stateComposed)
        """
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "Mounted Runestone canonical source diagnostic"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(diagnostic)
        XCTAssertEqual(stateDecomposed, Array(decomposed.utf8), diagnostic)
        XCTAssertEqual(stateComposed, Array(composed.utf8), diagnostic)
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
