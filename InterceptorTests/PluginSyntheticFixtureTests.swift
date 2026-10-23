import AutomationCore
import AutomationRuntime
@testable import Interceptor
import XCTest

final class PluginSyntheticFixtureTests: XCTestCase {
    func testPackageSampleMatchesDeclaredHostMethodAndPath() throws {
        let package = try AutomationFixtures.package(name: "Sample")
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        var matches = try XCTUnwrap(manifest["matches"]?.arrayValue)
        var match = try XCTUnwrap(matches.first?.objectValue)
        match["hosts"] = .array([.string("api.example.com")])
        match["methods"] = .array([.string("PATCH")])
        match["path"] = .object(["kind": .string("exact"), "value": .string("/search")])
        matches[0] = .object(match)
        manifest["matches"] = .array(matches)
        root["manifest"] = .object(manifest)
        let changed = try PluginPackage.validate(JSONValue.object(root).data())
        let json = SyntheticFixture.eventJSON(for: .responseEnter, manifest: changed.manifest)
        let event = try XCTUnwrap(JSONValue(parsing: Data(json.utf8)).objectValue)
        let request = try XCTUnwrap(event["request"]?.objectValue)
        XCTAssertEqual(request["host"], .string("api.example.com"))
        XCTAssertEqual(request["method"], .string("PATCH"))
        XCTAssertEqual(request["path"], .string("/search"))
        XCTAssertEqual(event["response"]?.objectValue?["status"], .integer(200))
    }

    func testDefaultPackageKeepsTheExistingSyntheticSample() throws {
        let package = try AutomationFixtures.package(name: "Sample")
        XCTAssertEqual(SyntheticFixture.eventJSON(for: .requestEnter, manifest: package.manifest),
                       SyntheticFixture.eventJSON(for: .requestEnter))
    }
}
