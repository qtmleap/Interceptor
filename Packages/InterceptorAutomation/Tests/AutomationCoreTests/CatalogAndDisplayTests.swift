import Foundation
import XCTest
@testable import AutomationCore

final class CatalogAndDisplayTests: AutomationTestCase {
    func testUntrustedDisplayNamesRejectBidiControlsAndExcessiveBytes() throws {
        for name in ["\u{202E}source", "\u{0085}source", "a" + String(repeating: "\u{0301}", count: 300)] {
            XCTAssertThrowsError(try PluginPackage.validate(packageBytes(name: name)))
            var payload = try XCTUnwrap(JSONValue(parsing: indexJSON()).objectValue)
            payload["name"] = .string(name)
            XCTAssertThrowsError(try snap(JSONValue.object(payload).data()))
        }
        XCTAssertNoThrow(try PluginPackage.validate(packageBytes(name: "日本語のプラグイン")))
    }

    func testFailedReloadInvalidatesCachedTrustAndPreservesCorruptBytes() async throws {
        let file = tempFile(), store = AutomationStore(fileURL: file)
        _ = try await store.accept(snap(indexJSON()), acknowledgeUnverified: true, now: now)
        let old = await store.catalog()
        XCTAssertEqual(old.repositories.count, 1)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        do { _ = try await store.load(); XCTFail("corrupt load must fail") }
        catch { XCTAssertEqual(error as? AutomationError, .corruptStore) }
        let invalidated = await store.catalog()
        XCTAssertTrue(invalidated.repositories.isEmpty)
        XCTAssertTrue(invalidated.revisions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
