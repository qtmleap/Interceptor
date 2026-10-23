import XCTest
@testable import AutomationCore

final class PluginUpdateComparisonTests: XCTestCase {
    private let repo = try! RepositoryURL(parsing: "https://example.com/r/")
    private let other = try! RepositoryURL(parsing: "https://other.example.com/r/")

    private func package(_ version: String = "1.0.0", source: String = "function onRequest(){return {actions:[]}}") throws -> PluginPackage {
        try PluginPackage.validate(packageBytes(version: version, source: source))
    }

    private func installed(_ p: PluginPackage, origin: Provenance.Origin? = nil) -> InstalledRevision {
        InstalledRevision(package: p, provenance: Provenance(origin: origin ?? .repository(url: repo, sequence: 1), trustAtImport: .unsignedAcknowledged), enabled: false)
    }

    private func published(_ p: PluginPackage) -> IndexEntry {
        entry(for: p.bytes, name: p.manifest.name, version: p.manifest.version)
    }

    private func compare(_ i: InstalledRevision, _ e: IndexEntry?, in url: RepositoryURL? = nil) -> PluginUpdateComparison {
        PluginUpdateComparison.compare(installed: i, published: e, repository: url ?? repo)
    }

    func testSameDigestIsCurrent() throws {
        let p = try package()
        XCTAssertEqual(compare(installed(p), published(p)), .current)
    }

    func testHigherVersionDifferentDigestIsAvailable() throws {
        let old = try package("1.0.0"), new = try package("1.1.0")
        XCTAssertEqual(compare(installed(old), published(new)), .available(version: "1.1.0"))
        let pre = try package("1.0.0-rc.1")
        XCTAssertEqual(compare(installed(pre), published(old)), .available(version: "1.0.0"))
    }

    func testLowerPrecedenceIsOlder() throws {
        let cur = try package("2.0.0"), old = try package("1.9.0"), pre = try package("2.0.0-rc.1")
        XCTAssertEqual(compare(installed(cur), published(old)), .older(version: "1.9.0"))
        XCTAssertEqual(compare(installed(cur), published(pre)), .older(version: "2.0.0-rc.1"))
    }

    func testRepublishedSameVersionIsChangedContent() throws {
        let a = try package("1.0.0"), b = try package("1.0.0", source: "function onRequest(){return {actions:[]};}")
        XCTAssertNotEqual(a.revision, b.revision)
        XCTAssertEqual(compare(installed(a), published(b)), .changedContent(version: "1.0.0"))
    }

    func testBuildMetadataOnlyDeltaIsChangedContentNeverAvailable() throws {
        let a = try package("1.0.0+1"), b = try package("1.0.0+2")
        XCTAssertEqual(compare(installed(a), published(b)), .changedContent(version: "1.0.0+2"))
    }

    func testNotListedWhenVerifiedRepositoryHasNoEntry() throws {
        XCTAssertEqual(compare(installed(try package()), nil), .notListed)
    }

    func testProvenanceMismatchIsUnrelated() throws {
        let p = try package(), e = published(try package("2.0.0"))
        XCTAssertEqual(compare(installed(p, origin: .localImport), e), .unrelated)
        XCTAssertEqual(compare(installed(p, origin: .localEdit(parent: "x")), e), .unrelated)
        XCTAssertEqual(compare(installed(p, origin: .localImport), nil), .unrelated)
        XCTAssertEqual(compare(installed(p), e, in: other), .unrelated)
        XCTAssertEqual(compare(installed(p), nil, in: other), .unrelated)
    }

    func testDifferentEntryIDIsUnrelated() throws {
        let p = try package(), n = try package("2.0.0")
        let e = published(n)
        let foreign = IndexEntry(id: UUID(), name: e.name, version: e.version, packagePath: e.packagePath, sha256: e.sha256, size: e.size)
        XCTAssertEqual(compare(installed(p), foreign), .unrelated)
    }

    func testUnparseableVersionsAreInvalidMetadata() throws {
        let p = try package(), n = try package("2.0.0")
        let e = published(n)
        let bad = IndexEntry(id: e.id, name: e.name, version: "2.0", packagePath: e.packagePath, sha256: e.sha256, size: e.size)
        XCTAssertEqual(compare(installed(p), bad), .invalidMetadata)
    }

    private func family(_ list: [InstalledRevision], _ e: IndexEntry?, id: UUID = pluginID, in url: RepositoryURL? = nil) -> PluginUpdateComparison {
        PluginUpdateComparison.compare(installed: list, manifestID: id, published: e, repository: url ?? repo)
    }

    func testFamilyWithOlderAndPublishedRevisionImportedIsCurrent() throws {
        let v1 = try package("1.0.0"), v2 = try package("2.0.0")
        XCTAssertEqual(family([installed(v1), installed(v2)], published(v2)), .current)
        XCTAssertEqual(family([installed(v2), installed(v1)], published(v2)), .current)
    }

    func testFamilyExcludesLocalAndOtherRepositoryRevisions() throws {
        let v1 = try package("1.0.0"), v2 = try package("2.0.0")
        let list = [installed(v2, origin: .localImport), installed(v2, origin: .localEdit(parent: "x")),
                    installed(v2, origin: .repository(url: other, sequence: 1)), installed(v1)]
        XCTAssertEqual(family(list, published(v2)), .available(version: "2.0.0"))
    }

    func testFamilyWithNoRelatedInstalledIsNotInstalled() throws {
        let v2 = try package("2.0.0")
        XCTAssertEqual(family([], published(v2)), .notInstalled)
        XCTAssertEqual(family([installed(v2, origin: .localImport), installed(v2, origin: .repository(url: other, sequence: 1))], published(v2)), .notInstalled)
    }

    func testFamilyMissingEntryAndIDMismatch() throws {
        let v1 = try package("1.0.0"), v2 = try package("2.0.0")
        XCTAssertEqual(family([installed(v1)], nil), .notListed)
        XCTAssertEqual(family([installed(v1)], published(v2), id: UUID()), .unrelated)
    }

    func testFamilyComparesHighestInstalledVersion() throws {
        let v1 = try package("1.0.0"), v2 = try package("2.0.0"), v3 = try package("3.0.0")
        XCTAssertEqual(family([installed(v1), installed(v2)], published(v3)), .available(version: "3.0.0"))
        XCTAssertEqual(family([installed(v3), installed(v1)], published(v2)), .older(version: "2.0.0"))
        let republished = try package("2.0.0", source: "function onRequest(){return {actions:[]};}")
        XCTAssertEqual(family([installed(v1), installed(v2)], published(republished)), .changedContent(version: "2.0.0"))
    }

    func testFamilySameDigestInconsistentMetadataIsInvalid() throws {
        let v1 = try package("1.0.0"), v2 = try package("2.0.0")
        let e = published(v2)
        let bad = IndexEntry(id: e.id, name: e.name, version: "9.0.0", packagePath: e.packagePath, sha256: e.sha256, size: e.size)
        XCTAssertEqual(family([installed(v1), installed(v2)], bad), .invalidMetadata)
    }

    func testSameDigestWithInconsistentMetadataIsInvalid() throws {
        let p = try package(), e = published(p)
        func variant(version: String? = nil, name: String? = nil, size: Int? = nil) -> IndexEntry {
            IndexEntry(id: e.id, name: name ?? e.name, version: version ?? e.version, packagePath: e.packagePath, sha256: e.sha256, size: size ?? e.size)
        }
        XCTAssertEqual(compare(installed(p), variant(version: "9.0.0")), .invalidMetadata)
        XCTAssertEqual(compare(installed(p), variant(version: "1.0.0+x")), .invalidMetadata)
        XCTAssertEqual(compare(installed(p), variant(name: "Other")), .invalidMetadata)
        XCTAssertEqual(compare(installed(p), variant(size: e.size + 1)), .invalidMetadata)
    }
}
