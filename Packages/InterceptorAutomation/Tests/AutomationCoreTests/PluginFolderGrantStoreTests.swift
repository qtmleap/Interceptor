import Foundation
import XCTest
@testable import AutomationCore

final class PluginFolderGrantStoreTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("grants.json") }
    private let family = "local|AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testBookmarkAndRootIdentitySurviveFreshInstance() throws {
        let grant = PluginFolderGrant(bookmark: Data([0, 255, 1]), rootIdentity: String(repeating: "a", count: 64))
        try PluginFolderGrantStore(url: url).set(grant, for: family)
        XCTAssertEqual(try PluginFolderGrantStore(url: url).grant(for: family), grant)
        XCTAssertNil(try PluginFolderGrantStore(url: url).grant(for: "local|BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    }

    func testInvalidGrantCannotReplacePreviouslyPersistedGrant() throws {
        let store = PluginFolderGrantStore(url: url)
        let grant = PluginFolderGrant(bookmark: Data([42]), rootIdentity: String(repeating: "a", count: 64))
        try store.set(grant, for: family)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.set(.init(bookmark: Data(), rootIdentity: "bad"), for: family))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try store.grant(for: family), grant)
    }

    func testSymlinkCannotReadOrOverwriteAnotherGrantRegistry() throws {
        let outside = folder.appendingPathComponent("outside.json")
        try Data("private user data".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        let store = PluginFolderGrantStore(url: url)
        XCTAssertThrowsError(try store.grant(for: family))
        XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64)), for: family))
        XCTAssertEqual(try Data(contentsOf: outside), Data("private user data".utf8))
    }

    func testCorruptRegistryFailsClosedAndIsNotReset() throws {
        let bytes = Data("{\"version\":1,\"version\":1,\"grants\":{}}".utf8)
        try bytes.write(to: url)
        let store = PluginFolderGrantStore(url: url)
        XCTAssertThrowsError(try store.grant(for: family))
        XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64)), for: family))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testScopedPrefixGrantsAreIndependentAfterRelaunch() throws {
        let first = PluginFolderGrant(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: "Salmon Run")
        let second = PluginFolderGrant(bookmark: Data([2]), rootIdentity: String(repeating: "b", count: 64), pathPrefix: "Other")
        try PluginFolderGrantStore(url: url).set(first, for: family)
        try PluginFolderGrantStore(url: url).set(second, for: family)
        let fresh = PluginFolderGrantStore(url: url)
        XCTAssertEqual(try fresh.grant(for: family, prefix: "Salmon Run"), first)
        XCTAssertEqual(try fresh.grant(for: family, prefix: "Other"), second)
        XCTAssertNil(try fresh.grant(for: family, prefix: "Salmon Run2"))
        XCTAssertNil(try fresh.grant(for: family))
    }

    func testRootAndPrefixGrantsCannotOverlapAndCaseAliasesFailClosed() throws {
        let store = PluginFolderGrantStore(url: url)
        let scoped = PluginFolderGrant(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: "Salmon Run")
        try store.set(scoped, for: family)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64)), for: family))
        XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: "salmon run"), for: family))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testThirtyTwoScopedGrantsAreBoundedWithoutEviction() throws {
        let store = PluginFolderGrantStore(url: url)
        for i in 0..<32 {
            try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: "Folder\(i)"), for: family)
        }
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: "Overflow"), for: family))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotNil(try store.grant(for: family, prefix: "Folder0"))
    }
    func testScalarSlashAndHiddenPrefixCannotGrantMultipleFolders() throws {
        let store = PluginFolderGrantStore(url: url)
        for prefix in ["a/\u{0301}b", ".\u{0301}hidden"] {
            XCTAssertThrowsError(try store.set(.init(bookmark: Data([1]), rootIdentity: String(repeating: "a", count: 64), pathPrefix: prefix), for: family))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

}
