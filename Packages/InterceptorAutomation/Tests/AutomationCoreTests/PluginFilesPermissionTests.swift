import XCTest
@testable import AutomationCore

/// Optional schema-2 `write.files` permission (Task 1). Intended interface: `PluginManifest.writeFiles: Bool`.
final class PluginFilesPermissionTests: XCTestCase {
    private static let match = #"{"hosts":["api.example.com"],"methods":["GET"],"path":{"kind":"exact","value":"/credentials"},"hooks":{"response":{"onLeave":"selected.js"}}}"#
    private static let read = #"{"metadata":["host"],"headers":[],"queryKeys":[],"body":{"mode":"json"}}"#

    private func package(write: String, schema: String = "2") -> Data {
        Data(#"{"manifest":{"schemaVersion":\#(schema),"id":"\#(pluginID)","name":"Hook","version":"1.0.0","matches":[\#(Self.match)],"read":\#(Self.read),"write":\#(write),"settings":{},"endpointBindings":[]},"sourceFiles":{"selected.js":"Interceptor.attach({response:{onLeave(){}}});"}}"#.utf8)
    }
    private func manifest(_ write: String) throws -> PluginManifest {
        try PluginPackage.validate(package(write: write)).manifest
    }
    private func rejects(_ write: String, line: UInt = #line) {
        assertThrows(.invalidManifest, try PluginPackage.validate(package(write: write)), line: line)
    }

    func testFilesPermissionDefaultsFalseWhenAbsent() throws {
        let m = try manifest(#"{"requestBody":false,"responseBody":false}"#)
        XCTAssertFalse(m.writeFiles)
        XCTAssertFalse(m.writeRequestBody)
        XCTAssertFalse(m.writeResponseBody)
    }

    func testFilesPermissionTrueAndExplicitFalse() throws {
        let granted = try manifest(#"{"requestBody":false,"responseBody":false,"files":true}"#)
        XCTAssertTrue(granted.writeFiles)
        XCTAssertFalse(granted.writeRequestBody)
        XCTAssertFalse(granted.writeResponseBody)
        XCTAssertFalse(try manifest(#"{"requestBody":false,"responseBody":false,"files":false}"#).writeFiles)
        // Independent of the body permissions.
        let all = try manifest(#"{"requestBody":true,"responseBody":true,"files":true}"#)
        XCTAssertTrue(all.writeFiles && all.writeRequestBody && all.writeResponseBody)
    }

    func testFilesPermissionMustBeStrictBoolean() {
        for bad in ["1", "0", "null", #""true""#, "[]", "{}", "2.5"] {
            rejects(#"{"requestBody":false,"responseBody":false,"files":\#(bad)}"#)
        }
    }

    func testWriteStillRejectsUnknownKeysAndRequiresBodyFlags() {
        rejects(#"{"requestBody":false,"responseBody":false,"file":true}"#)
        rejects(#"{"requestBody":false,"responseBody":false,"files":true,"extra":true}"#)
        rejects(#"{"files":true}"#)
        rejects(#"{"requestBody":false,"files":true}"#)
    }

    func testSchemaOneHasNoFilesPermission() {
        let v1 = Data(#"{"manifest":\#(manifestJSON(extra: #","write":{"files":true}"#)),"source":"function onRequest(){return {actions:[]}}"}"#.utf8)
        assertThrows(.invalidManifest, try PluginPackage.validate(v1))
        let v1Write = Data(#"{"manifest":\#(manifestJSON(extra: #","write":{"requestBody":false,"responseBody":false,"files":true}"#)),"source":"function onRequest(){return {actions:[]}}"}"#.utf8)
        assertThrows(.invalidManifest, try PluginPackage.validate(v1Write))
    }

    func testPermissionIsPartOfPreservedManifestJSON() throws {
        let granted = try manifest(#"{"requestBody":false,"responseBody":false,"files":true}"#)
        let absent = try manifest(#"{"requestBody":false,"responseBody":false}"#)
        XCTAssertNotEqual(granted.json, absent.json)
        XCTAssertEqual(try granted.json.data(), try manifest(#"{"requestBody":false,"responseBody":false,"files":true}"#).json.data())
    }
}
