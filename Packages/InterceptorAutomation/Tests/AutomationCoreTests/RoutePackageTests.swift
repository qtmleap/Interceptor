import Foundation
import XCTest
@testable import AutomationCore

final class RoutePackageTests: XCTestCase {
    private let file = "hooks/api.example.com/search/POST.js"
    private func package(files: [String: String]? = nil, source: Bool = false) throws -> Data {
        let manifest: [String: Any] = [
            "schemaVersion": 2, "id": "00000000-0000-4000-8000-000000000001", "name": "Routes", "version": "2.0.0",
            "matches": [["hosts": ["api.example.com"], "methods": ["POST"], "path": ["kind": "exact", "value": "/search"],
                         "hooks": ["request": ["onEnter": file]]]],
            "read": ["metadata": [], "headers": [], "queryKeys": [], "body": ["mode": "json"]],
            "write": ["requestBody": true, "responseBody": true], "endpointBindings": [], "settings": [:]
        ]
        var object: [String: Any] = ["manifest": manifest, "sourceFiles": files ?? [file: "Interceptor.attach({request:{onEnter(req){req.body.limit=5;}}});"]]
        if source { object["source"] = "" }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testManifestSelectedSourcesPackageIsAcceptedWithoutAJSCondition() throws {
        let bytes = try package()
        let parsed = try PluginPackage.validate(bytes)
        XCTAssertEqual(parsed.manifest.schemaVersion, 2)
        XCTAssertEqual(parsed.bytes, bytes)
    }

    func testEverySourceMustBeReferencedAndEveryReferenceMustExist() throws {
        XCTAssertThrowsError(try PluginPackage.validate(package(files: [:])))
        XCTAssertThrowsError(try PluginPackage.validate(package(files: [file: "", "unused.js": ""])))
        XCTAssertThrowsError(try PluginPackage.validate(package(source: true)))
    }

    func testLegacyPackageRoundTripsUnchanged() throws {
        let legacy = try PluginPackage.template()
        XCTAssertEqual(try PluginPackage.validate(legacy.bytes), legacy)
        XCTAssertEqual(legacy.manifest.schemaVersion, 1)
    }
}

extension RoutePackageTests {
    func testNamedAndBulkSourceReplacementPreserveOtherFilesAndManifest() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: package()) as? [String: Any])
        var manifest = root["manifest"] as! [String: Any]
        var routes = manifest["matches"] as! [[String: Any]]
        routes[0]["hooks"] = ["request": ["onEnter": file, "onLeave": "other.js"]]
        manifest["matches"] = routes; root["manifest"] = manifest
        root["sourceFiles"] = [file: "// é", "other.js": "// other"]
        let parent = try PluginPackage.validate(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(parent.source)
        let named = try parent.replacingSource("// changed", file: file)
        XCTAssertEqual(named.sourceFiles["other.js"], "// other")
        XCTAssertEqual(named.manifest, parent.manifest)
        XCTAssertNotEqual(named.revision, parent.revision)
        XCTAssertThrowsError(try parent.replacingSource("legacy"))
        XCTAssertThrowsError(try parent.replacingSource("x", file: "missing.js"))
        XCTAssertThrowsError(try parent.replacingSources([file: "x"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/catalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AutomationStore(fileURL: url)
        let imported = try await store.importLocal(parent.bytes)
        let edited = try await store.editSources(of: imported.id, to: [file: "// e\u{301}", "other.js": "// other"])
        XCTAssertEqual(edited.package.manifest, parent.manifest)
        XCTAssertTrue(try XCTUnwrap(edited.package.sourceFiles[file]).utf8.elementsEqual("// e\u{301}".utf8))
        XCTAssertEqual(edited.provenance.origin, .localEdit(parent: parent.revision))
        XCTAssertFalse(edited.enabled)
        let catalog = await store.catalog()
        XCTAssertEqual(catalog.revisions.count, 2)
        let namedEdit = try await store.editSource(of: edited.id, file: "other.js", to: "// next")
        XCTAssertEqual(namedEdit.package.sourceFiles[file], edited.package.sourceFiles[file])
        XCTAssertEqual(namedEdit.package.sourceFiles["other.js"], "// next")
    }
}
