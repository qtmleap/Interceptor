@testable import Interceptor
import XCTest

final class PluginScriptTreeTests: XCTestCase {
    private func summary(_ entries: [PluginScriptTree.Entry]) -> [String] {
        entries.map { "\($0.kind == .directory ? "d" : "f"):\($0.name):\($0.path)" }
    }

    func testRootMixedFilesAndFoldersListFoldersFirstSorted() {
        let entries = PluginScriptTree.entries(in: [
            "z.js", "hooks/POST.js", "a.js", "api/GET.js", "hooks/GET.js",
        ])
        XCTAssertEqual(summary(entries), [
            "d:api:api", "d:hooks:hooks", "f:a.js:a.js", "f:z.js:z.js",
        ])
    }

    func testRootFileIsLeafWithFullPath() {
        let entries = PluginScriptTree.entries(in: ["script.js"])
        XCTAssertEqual(summary(entries), ["f:script.js:script.js"])
    }

    func testLegacyRootScriptJS() {
        let entries = PluginScriptTree.entries(in: ["script.js"], at: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .file)
        XCTAssertEqual(entries.first?.path, "script.js")
    }

    func testEmptyInputYieldsNoEntries() {
        XCTAssertTrue(PluginScriptTree.entries(in: []).isEmpty)
        XCTAssertTrue(PluginScriptTree.entries(in: [], at: ["hooks"]).isEmpty)
    }

    func testNestedDuplicatePOSTBasenamesStayInSeparateDirectories() {
        let files = [
            "hooks/a.example.com/v1/POST.js",
            "hooks/b.example.com/v1/POST.js",
            "hooks/a.example.com/v2/POST.js",
        ]
        XCTAssertEqual(summary(PluginScriptTree.entries(in: files)), ["d:hooks:hooks"])
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["hooks"])),
            ["d:a.example.com:hooks/a.example.com", "d:b.example.com:hooks/b.example.com"]
        )
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["hooks", "a.example.com"])),
            ["d:v1:hooks/a.example.com/v1", "d:v2:hooks/a.example.com/v2"]
        )
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["hooks", "a.example.com", "v1"])),
            ["f:POST.js:hooks/a.example.com/v1/POST.js"]
        )
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["hooks", "b.example.com", "v1"])),
            ["f:POST.js:hooks/b.example.com/v1/POST.js"]
        )
    }

    func testPrefixMatchUsesWholeComponentsSoApiAndApi2AreUnrelated() {
        let files = ["api/POST.js", "api2/POST.js", "api2/extra/GET.js"]
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["api"])),
            ["f:POST.js:api/POST.js"]
        )
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["api2"])),
            ["d:extra:api2/extra", "f:POST.js:api2/POST.js"]
        )
        XCTAssertEqual(summary(PluginScriptTree.entries(in: files)), ["d:api:api", "d:api2:api2"])
    }

    func testMissingDirectoryYieldsNoEntries() {
        XCTAssertTrue(PluginScriptTree.entries(in: ["api/POST.js"], at: ["ap"]).isEmpty)
        XCTAssertTrue(PluginScriptTree.entries(in: ["api/POST.js"], at: ["api", "POST.js"]).isEmpty)
    }

    func testFileAndFolderWithSameBasenameRetainedWithDistinctIDs() {
        let entries = PluginScriptTree.entries(in: ["hooks", "hooks/POST.js"])
        XCTAssertEqual(summary(entries), ["d:hooks:hooks", "f:hooks:hooks"])
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(entries[0].id, entries[1].id)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }

    func testIDsAreDistinctForSameBasenameAcrossDirectories() {
        let a = PluginScriptTree.entries(in: ["a/POST.js"], at: ["a"])
        let b = PluginScriptTree.entries(in: ["b/POST.js"], at: ["b"])
        XCTAssertEqual(a.first?.name, "POST.js")
        XCTAssertEqual(b.first?.name, "POST.js")
        XCTAssertNotEqual(a.first?.id, b.first?.id)
    }

    func testIDsAreStableAcrossCalls() {
        let files = ["x/y/POST.js", "x/z.js", "top.js"]
        XCTAssertEqual(
            PluginScriptTree.entries(in: files, at: ["x"]).map(\.id),
            PluginScriptTree.entries(in: files, at: ["x"]).map(\.id)
        )
    }

    func testLeafKeepsExactFullRelativePath() {
        let entries = PluginScriptTree.entries(
            in: ["hooks/api.example.com/v1/users/POST.js"],
            at: ["hooks", "api.example.com", "v1", "users"]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "POST.js")
        XCTAssertEqual(entries[0].path, "hooks/api.example.com/v1/users/POST.js")
        XCTAssertEqual(entries[0].kind, .file)
    }

    func testOutputIsIndependentOfInputOrderAndDeduplicatesFolders() {
        let files = [
            "b/POST.js", "a/GET.js", "b/GET.js", "a/POST.js", "root.js", "a/sub/x.js", "a/sub/y.js",
        ]
        let reversed = Array(files.reversed())
        XCTAssertEqual(PluginScriptTree.entries(in: files), PluginScriptTree.entries(in: reversed))
        XCTAssertEqual(summary(PluginScriptTree.entries(in: files)), ["d:a:a", "d:b:b", "f:root.js:root.js"])
        XCTAssertEqual(
            PluginScriptTree.entries(in: files, at: ["a"]),
            PluginScriptTree.entries(in: reversed, at: ["a"])
        )
        XCTAssertEqual(
            summary(PluginScriptTree.entries(in: files, at: ["a"])),
            ["d:sub:a/sub", "f:GET.js:a/GET.js", "f:POST.js:a/POST.js"]
        )
    }

    func testSortingIsExactLexicalAndCaseSensitive() {
        let entries = PluginScriptTree.entries(in: ["b.js", "B.js", "a.js", "10.js", "2.js", "Z/x.js", "a/x.js"])
        XCTAssertEqual(summary(entries), [
            "d:Z:Z", "d:a:a", "f:10.js:10.js", "f:2.js:2.js", "f:B.js:B.js", "f:a.js:a.js", "f:b.js:b.js",
        ])
    }
}
