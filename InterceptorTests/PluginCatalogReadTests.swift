import AutomationCore
import AutomationRepository
import Foundation
@testable import Interceptor
import XCTest

@MainActor
final class PluginCatalogReadTests: XCTestCase {
    private var directory: URL!
    private var catalogURL: URL { directory.appendingPathComponent("catalog.json") }
    private var activationURL: URL { directory.appendingPathComponent("activation.json") }
    private var databaseURL: URL { directory.appendingPathComponent("PackageCatalog") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginCatalogReads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var coordinator: InstallationCoordinator {
        InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL)
    }

    private func described(_ package: PluginPackage, name: String? = nil, version: String? = nil,
                           author: String? = nil, summary: String? = nil, category: String? = nil) throws -> PluginPackage
    {
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        if let name { manifest["name"] = .string(name) }
        if let version { manifest["version"] = .string(version) }
        if let author { manifest["author"] = .string(author) }
        if let summary { manifest["summary"] = .string(summary) }
        if let category { manifest["category"] = .string(category) }
        root["manifest"] = .object(manifest)
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    private func snapshot(_ packages: [PluginPackage], url: RepositoryURL = AutomationFixtures.url,
                          sequence: Int64 = 1) throws -> VerifiedSnapshot
    {
        let entries = packages.map { package -> JSONValue in
            var entry = AutomationFixtures.entry(for: package).objectValue!
            for key in ["author", "summary", "category"] {
                if let value = package.manifest.json.objectValue?[key] { entry[key] = value }
            }
            return .object(entry)
        }
        let index: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string("11111111-1111-4111-8111-111111111111"),
            "name": .string("Persisted catalog"), "sequence": .integer(sequence),
            "issuedAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(-60))),
            "expiresAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(86_400))),
            "plugins": .array(entries),
        ])
        let envelope: JSONValue = .object(["schemaVersion": .integer(1), "payload": .string(try index.data().base64EncodedString())])
        return try RepositoryEnvelope.verify(envelope: envelope.data(), url: url, now: AutomationFixtures.now)
    }

    private func withIcon(_ package: PluginPackage, path: String) throws -> PluginPackage {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        manifest["icon"] = .string(path)
        root["manifest"] = .object(manifest)
        root["assets"] = .object([path: .string(encoded)])
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    private func install(_ package: PluginPackage, from record: RepositoryRecord) throws {
        let state = try coordinator.state()
        _ = try coordinator.batch([InstallationRequest(package: package, snapshot: XCTUnwrap(record.snapshot),
            expectedSourceGeneration: record.generation, operation: .add)],
            expectedSelectionGeneration: state.selectionGeneration, now: AutomationFixtures.now)
    }

    /// This database instance leaves scope before the controller opens the same persistent store.
    private func stageAndAccept(_ packages: [PluginPackage], url: RepositoryURL = AutomationFixtures.url,
                                sequence: Int64 = 1, receipt: UInt64 = 1) async throws -> RepositoryRecord
    {
        let database = try PackageCatalogDatabase(url: databaseURL)
        let acceptedSnapshot = try snapshot(packages, url: url, sequence: sequence)
        let lease = UUID()
        try await database.stage(acceptedSnapshot, packages: packages, leaseID: lease)
        let store = AutomationStore(fileURL: catalogURL)
        let record = try await store.accept(acceptedSnapshot, acknowledgeUnverified: true, now: AutomationFixtures.now)
        let catalog = try await store.load()
        let installed = try coordinator.state().installed
        try await database.synchronize(visible: catalog.visibleRepositories, installed: installed, receipt: receipt)
        try await database.finish(leaseID: lease, visible: catalog.visibleRepositories)
        return record
    }

    private func offlineController(packages: [PluginPackage], snapshot: VerifiedSnapshot) async throws
        -> (AutomationController, PluginBrowserModel, FakeRepositoryClient)
    {
        let client = FakeRepositoryClient(snapshot: snapshot, packages: packages)
        client.packageError = URLError(.notConnectedToInternet)
        client.previewError = URLError(.notConnectedToInternet)
        let database = try PackageCatalogDatabase(url: databaseURL)
        let controller = AutomationController(store: AutomationStore(fileURL: catalogURL), client: client,
                                              executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                              packageCatalog: database,
                                              activationStore: PluginActivationStore(fileURL: activationURL),
                                              installationCoordinator: coordinator,
                                              hasCaptureConsent: { true }, stopCapture: {})
        await controller.load()
        let backfillFinished = await waitUntil { !controller.isBackfillingPackages }
        XCTAssertTrue(backfillFinished)
        return (controller, PluginBrowserModel(controller: controller), client)
    }

    private func assertNoNetwork(_ client: FakeRepositoryClient, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(client.packageCount, 0, "Presentation/Get must use persisted content", file: file, line: line)
        XCTAssertEqual(client.previewCount, 0, "Reading the catalog must not refresh its source", file: file, line: line)
    }

    func testRecreatedDatabaseAndControllerReadDetailsAndSearchOffline() async throws {
        let package = try described(AutomationFixtures.multiFilePackage(name: "日本語 Package2"),
                                    author: "Mixed Case Author", summary: "100%_literal 説明", category: "通信")
        let other = try AutomationFixtures.package(name: "Unrelated")
        let record = try await stageAndAccept([package, other])
        let (controller, browser, client) = try await offlineController(packages: [package, other], snapshot: XCTUnwrap(record.snapshot))
        let current = try XCTUnwrap(controller.repositories.first)
        let family = PluginBrowserFamilyID(repository: current.url, manifestID: package.manifest.id)
        let detail = try XCTUnwrap(browser.packagePresentation(for: family, record: current))
        XCTAssertTrue(detail.isComplete)
        XCTAssertEqual(detail, PluginPackagePresentation(package))
        XCTAssertEqual(detail.sourceFiles, package.sourceFiles)
        XCTAssertEqual(detail.sourceFileNames, package.sourceFiles.keys.sorted())
        XCTAssertFalse(detail.manifestJSON.isEmpty)
        XCTAssertTrue(detail.manifestJSON.contains("Mixed Case Author"))
        XCTAssertFalse(detail.rulesByFile.isEmpty)
        for query in ["日本語", "mixed case author", "説明", "%_literal", "  PACKAGE2\n"] {
            XCTAssertEqual(browser.catalogPackages(query: query).map(\.id), [family], "query=\(query)")
        }
        XCTAssertTrue(browser.catalogPackages(query: "does not exist").isEmpty)
        let category = try XCTUnwrap(browser.categories(in: current).first { $0.name == "通信" })
        XCTAssertEqual(browser.catalogPackages(in: current, category: category, query: "mixed case").map(\.id), [family])
        XCTAssertNil(browser.catalogReadError)
        XCTAssertTrue(controller.scripts.isEmpty, "Persisting source content does not install packages")
        assertNoNetwork(client)
    }

    func testRepeatedDetailReadsReuseDTOUntilPublishedDatabaseRevisionChanges() async throws {
        let package = try AutomationFixtures.multiFilePackage(name: "Cached detail")
        let record = try await stageAndAccept([package])
        let client = FakeRepositoryClient(snapshot: try XCTUnwrap(record.snapshot), packages: [package])
        client.packageError = URLError(.notConnectedToInternet)
        let database = try CountingReadCatalog(base: PackageCatalogDatabase(url: databaseURL))
        let controller = AutomationController(store: AutomationStore(fileURL: catalogURL), client: client,
            executor: FakeScriptRunner(), clock: { AutomationFixtures.now }, packageCatalog: database,
            installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
        await controller.load()
        let browser = PluginBrowserModel(controller: controller)
        let family = PluginBrowserFamilyID(repository: record.url, manifestID: package.manifest.id)
        for _ in 0..<5 {
            let detail = try XCTUnwrap(browser.packagePresentation(for: family, record: record))
            XCTAssertEqual(detail.sourceFiles, package.sourceFiles)
            XCTAssertEqual(detail.manifest.name, "Cached detail")
        }
        XCTAssertEqual(database.detailReads, 1, "Tab changes and body reevaluations must not decode the same persisted DTO repeatedly")
        let before = controller.packageCatalogRevision
        await controller.refreshCatalog()
        XCTAssertGreaterThan(controller.packageCatalogRevision, before)
        XCTAssertEqual(try browser.packagePresentation(for: family, record: record), PluginPackagePresentation(package))
        XCTAssertEqual(database.detailReads, 2)
        assertNoNetwork(client)
    }

    func testInstalledManagementSurvivesMissingUnreadableOrStaleDisplayDatabase() async throws {
        let package = try AutomationFixtures.package(name: "Still manageable")
        let record = try await stageAndAccept([package])
        let state = try coordinator.state()
        _ = try coordinator.batch([InstallationRequest(package: package, snapshot: XCTUnwrap(record.snapshot),
            expectedSourceGeneration: record.generation, operation: .add)],
            expectedSelectionGeneration: state.selectionGeneration, now: AutomationFixtures.now)
        for failure in 0..<3 {
            let client = FakeRepositoryClient(snapshot: try XCTUnwrap(record.snapshot), packages: [package])
            let database = try CountingReadCatalog(base: PackageCatalogDatabase(url: databaseURL))
            if failure == 2 {
                try await database.base.synchronize(visible: [record], installed: [], receipt: 0)
            }
            database.failReads = failure == 1
            database.failSynchronization = failure == 2
            let controller = AutomationController(store: AutomationStore(fileURL: catalogURL), client: client,
                executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                packageCatalog: failure == 0 ? nil : database, packageCatalogError: failure == 0 ? CatalogReadFailure.read : nil,
                installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
            await controller.load()
            let browser = PluginBrowserModel(controller: controller)
            let family = PluginBrowserFamilyID(repository: record.url, manifestID: package.manifest.id)
            XCTAssertEqual(browser.catalogPackages().map(\.id), [family], "failure=\(failure)")
            XCTAssertEqual(browser.catalogPackages(query: " \n").map(\.id), [family])
            let detail = try browser.packagePresentation(for: family, record: record)
            XCTAssertEqual(detail, PluginPackagePresentation(package))
            XCTAssertNotNil(browser.selectedRevision(for: family), "existing detail actions must retain authoritative selection")
            if failure != 2 {
                XCTAssertTrue(browser.catalogPackages(query: package.manifest.name).isEmpty, "failed DB reads must not become in-memory catalog searches")
                XCTAssertNotNil(browser.catalogReadError)
            } else {
                XCTAssertNotNil(controller.packageCatalogError)
            }
            assertNoNetwork(client)
        }
    }

    func testExplicitGetRevalidatesExactPersistedBytesWithoutNetwork() async throws {
        let package = try AutomationFixtures.multiFilePackage(name: "Local Get")
        let record = try await stageAndAccept([package])
        let (controller, browser, client) = try await offlineController(packages: [package], snapshot: XCTUnwrap(record.snapshot))
        let current = try XCTUnwrap(controller.repositories.first)
        let entry = try XCTUnwrap(current.snapshot?.index.plugins.first)
        let fetched = try await browser.fetchPackage(entry: entry, record: current)
        XCTAssertEqual(fetched.bytes, package.bytes)
        XCTAssertEqual(fetched.revision, entry.sha256)
        XCTAssertEqual(fetched.manifest.id, entry.id)
        XCTAssertTrue(controller.scripts.isEmpty)
        assertNoNetwork(client)
    }

    func testInstalledNilMetadataDoesNotFallBackToNewPublishedMetadata() async throws {
        let local = try described(AutomationFixtures.package(name: "Selected local"), category: "Tools")
        let original = try await stageAndAccept([local])
        let state = try coordinator.state()
        _ = try coordinator.batch([InstallationRequest(package: local, snapshot: XCTUnwrap(original.snapshot),
                                                         expectedSourceGeneration: original.generation, operation: .add)],
                                  expectedSelectionGeneration: state.selectionGeneration, now: AutomationFixtures.now)
        let published = try described(local, name: "Published replacement", version: "2.0.0",
                                      author: "Published author", summary: "Published summary", category: "Tools")
        let refreshed = try await stageAndAccept([published], sequence: 2, receipt: 2)
        let (controller, browser, client) = try await offlineController(packages: [published], snapshot: XCTUnwrap(refreshed.snapshot))
        let row = try XCTUnwrap(browser.catalogPackages().first)
        XCTAssertEqual(row.name, "Selected local")
        XCTAssertEqual(row.version, "1.0.0")
        XCTAssertNil(row.author)
        XCTAssertNil(row.summary)
        XCTAssertEqual(row.entry?.name, "Published replacement")
        XCTAssertEqual(row.entry?.author, "Published author")
        XCTAssertEqual(browser.catalogPackages(query: "selected local").map(\.id), [row.id])
        XCTAssertTrue(browser.catalogPackages(query: "published author").isEmpty)
        XCTAssertTrue(browser.catalogPackages(query: "published summary").isEmpty)
        let detail = try XCTUnwrap(browser.packagePresentation(for: row.id, record: controller.repositories.first))
        XCTAssertEqual(detail, PluginPackagePresentation(local))
        XCTAssertNil(detail.manifest.author)
        XCTAssertNil(detail.manifest.summary)
        assertNoNetwork(client)
    }

    func testInstalledIconTakesPrecedenceOverPublishedUpdate() async throws {
        let local = try withIcon(AutomationFixtures.multiFilePackage(name: "Selected icon"), path: "selected.png")
        let original = try await stageAndAccept([local])
        try install(local, from: original)
        let published = try withIcon(described(local, version: "2.0.0"), path: "published.png")
        let refreshed = try await stageAndAccept([published], sequence: 2, receipt: 2)
        let (controller, browser, client) = try await offlineController(packages: [published], snapshot: XCTUnwrap(refreshed.snapshot))
        let current = try XCTUnwrap(controller.repositories.first)
        let entry = try XCTUnwrap(current.snapshot?.index.plugins.first)
        let family = PluginBrowserFamilyID(repository: current.url, manifestID: local.manifest.id)
        let source = try XCTUnwrap(browser.iconSource(for: family, entry: entry, record: current))
        let icon = try await source.load()
        XCTAssertEqual(icon, try XCTUnwrap(local.icon))
        XCTAssertNotEqual(icon, try XCTUnwrap(published.icon), "The selected package owns its displayed icon, including its asset path")
        assertNoNetwork(client)
    }

    func testInstalledPackageWithoutIconDoesNotBorrowPublishedIcon() async throws {
        let local = try AutomationFixtures.multiFilePackage(name: "Selected without icon")
        let original = try await stageAndAccept([local])
        try install(local, from: original)
        let published = try withIcon(described(local, version: "2.0.0"), path: "published.png")
        let refreshed = try await stageAndAccept([published], sequence: 2, receipt: 2)
        let (controller, browser, client) = try await offlineController(packages: [published], snapshot: XCTUnwrap(refreshed.snapshot))
        let current = try XCTUnwrap(controller.repositories.first)
        let entry = try XCTUnwrap(current.snapshot?.index.plugins.first)
        let family = PluginBrowserFamilyID(repository: current.url, manifestID: local.manifest.id)
        XCTAssertNotNil(published.icon)
        XCTAssertNil(local.icon)
        XCTAssertNil(browser.iconSource(for: family, entry: entry, record: current))
        assertNoNetwork(client)
    }

    func testCatalogIconRequiresCurrentEntryAndMatchingFamily() async throws {
        let originalPackage = try withIcon(AutomationFixtures.multiFilePackage(name: "Catalog icon"), path: "original.png")
        let original = try await stageAndAccept([originalPackage])
        let staleEntry = try XCTUnwrap(original.snapshot?.index.plugins.first)
        let published = try withIcon(described(originalPackage, version: "2.0.0"), path: "published.png")
        let other = try AutomationFixtures.multiFilePackage(name: "Other accepted package")
        let refreshed = try await stageAndAccept([published, other], sequence: 2, receipt: 2)
        let (controller, browser, client) = try await offlineController(packages: [published, other], snapshot: XCTUnwrap(refreshed.snapshot))
        let current = try XCTUnwrap(controller.repositories.first)
        let entry = try XCTUnwrap(current.snapshot?.index.plugins.first { $0.id == published.manifest.id })
        let otherEntry = try XCTUnwrap(current.snapshot?.index.plugins.first { $0.id == other.manifest.id })
        let family = PluginBrowserFamilyID(repository: current.url, manifestID: published.manifest.id)
        let source = try XCTUnwrap(browser.iconSource(for: family, entry: entry, record: current))
        let icon = try await source.load()
        XCTAssertEqual(icon, try XCTUnwrap(published.icon), "An uninstalled package uses the currently accepted local content")
        XCTAssertNil(browser.iconSource(for: family, entry: staleEntry, record: original))
        XCTAssertNil(browser.iconSource(for: family, entry: otherEntry, record: current))
        let otherSource = PluginBrowserFamilyID(repository: try RepositoryURL(parsing: "https://other.example.com/repository.json"),
                                               manifestID: published.manifest.id)
        XCTAssertNil(browser.iconSource(for: otherSource, entry: entry, record: current))
        XCTAssertNil(browser.iconSource(for: family, entry: nil, record: current))
        XCTAssertNil(browser.iconSource(for: family, entry: entry, record: nil))
        assertNoNetwork(client)
    }

    func testCatalogIconIsUnavailableWithoutDisplayDatabase() async throws {
        let package = try withIcon(AutomationFixtures.multiFilePackage(name: "Catalog unavailable"), path: "icon.png")
        let record = try await stageAndAccept([package])
        let client = FakeRepositoryClient(snapshot: try XCTUnwrap(record.snapshot), packages: [package])
        let controller = AutomationController(store: AutomationStore(fileURL: catalogURL), client: client,
            executor: FakeScriptRunner(), clock: { AutomationFixtures.now }, packageCatalog: nil,
            installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
        await controller.load()
        let browser = PluginBrowserModel(controller: controller)
        let current = try XCTUnwrap(controller.repositories.first)
        let entry = try XCTUnwrap(current.snapshot?.index.plugins.first)
        let family = PluginBrowserFamilyID(repository: current.url, manifestID: package.manifest.id)
        XCTAssertNil(browser.iconSource(for: family, entry: entry, record: current))
        assertNoNetwork(client)
    }

    func testSameManifestFromTwoSourcesStaysDistinctAndInstalledOrphanRemainsOffline() async throws {
        let first = try described(AutomationFixtures.package(name: "Same identity"), author: "First source", category: "Tools")
        let second = try described(first, author: "Second source")
        let firstRecord = try await stageAndAccept([first])
        let otherURL = try RepositoryURL(parsing: "https://other.example.com/repository.json")
        let secondRecord = try await stageAndAccept([second], url: otherURL, receipt: 2)
        let state = try coordinator.state()
        _ = try coordinator.batch([InstallationRequest(package: first, snapshot: XCTUnwrap(firstRecord.snapshot),
                                                         expectedSourceGeneration: firstRecord.generation, operation: .add)],
                                  expectedSelectionGeneration: state.selectionGeneration, now: AutomationFixtures.now)
        try await AutomationStore(fileURL: catalogURL).remove(firstRecord.url)
        let (controller, browser, client) = try await offlineController(packages: [second], snapshot: XCTUnwrap(secondRecord.snapshot))
        let rows = browser.catalogPackages()
        XCTAssertEqual(Set(rows.map(\.id)), [PluginBrowserFamilyID(repository: firstRecord.url, manifestID: first.manifest.id),
                                              PluginBrowserFamilyID(repository: secondRecord.url, manifestID: second.manifest.id)])
        let orphan = try XCTUnwrap(rows.first { $0.id.source == firstRecord.url.canonical })
        XCTAssertNil(orphan.record)
        XCTAssertNil(orphan.entry)
        XCTAssertNotNil(orphan.installed)
        XCTAssertEqual(orphan.author, "First source")
        let current = try XCTUnwrap(controller.repositories.first)
        let tools = try XCTUnwrap(browser.categories(in: current).first { $0.name == "Tools" })
        XCTAssertEqual(browser.catalogPackages(in: current, category: tools).map(\.id),
                       [PluginBrowserFamilyID(repository: secondRecord.url, manifestID: second.manifest.id)])
        XCTAssertEqual(try browser.packagePresentation(for: orphan.id, record: nil), PluginPackagePresentation(first))
        assertNoNetwork(client)
    }
}

@MainActor
private final class CountingReadCatalog: PackageCatalogStoring {
    let base: any PackageCatalogStoring
    private(set) var detailReads = 0
    var failReads = false
    var failSynchronization = false
    init(base: any PackageCatalogStoring) { self.base = base }
    func stage(_ snapshot: VerifiedSnapshot, packages: [PluginPackage], leaseID: UUID) async throws {
        try await base.stage(snapshot, packages: packages, leaseID: leaseID)
    }
    func synchronize(visible: [RepositoryRecord], installed: [InstalledRevision], receipt: UInt64) async throws {
        if failSynchronization { throw CatalogReadFailure.write }
        try await base.synchronize(visible: visible, installed: installed, receipt: receipt)
    }
    func finish(leaseID: UUID, visible: [RepositoryRecord]) async throws {
        try await base.finish(leaseID: leaseID, visible: visible)
    }
    func rows(visible: [RepositoryRecord], installed: [InstalledRevision], query: String, source: String?, category: PackageCatalogCategoryFilter) throws -> [PackageCatalogRow] {
        if failReads { throw CatalogReadFailure.read }
        return try base.rows(visible: visible, installed: installed, query: query, source: source, category: category)
    }
    func categories(in record: RepositoryRecord) throws -> [PackageCatalogCategory] { try base.categories(in: record) }
    func detail(in record: RepositoryRecord, entryID: UUID) throws -> PluginPackagePresentation? {
        detailReads += 1
        return try base.detail(in: record, entryID: entryID)
    }
    func packageBytes(in record: RepositoryRecord, entry: IndexEntry) throws -> Data? {
        try base.packageBytes(in: record, entry: entry)
    }
    func reusableBytes(sha256: String) throws -> Data? { try base.reusableBytes(sha256: sha256) }
    func icon(sha256: String) async throws -> PluginIcon? { try await base.icon(sha256: sha256) }
    func isComplete(_ snapshot: VerifiedSnapshot) throws -> Bool { try base.isComplete(snapshot) }
}

private enum CatalogReadFailure: Error { case read, write }
