import AutomationCore
import AutomationRepository
import CryptoKit
import Foundation
@testable import Interceptor
import XCTest

@MainActor
final class PluginBrowserModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginBrowser-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func revised(_ package: PluginPackage, version: String? = nil, marker: String = "") throws -> PluginPackage {
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        if let version { manifest["version"] = .string(version) }
        root["manifest"] = .object(manifest)
        root["sourceFiles"] = .object(package.sourceFiles.mapValues { .string($0 + marker) })
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    private func catalogSnapshot(_ packages: [PluginPackage], url: RepositoryURL = AutomationFixtures.url,
                                 sequence: Int64 = 1) throws -> VerifiedSnapshot {
        let entries = packages.map { package -> JSONValue in
            var entry = AutomationFixtures.entry(for: package).objectValue!
            for key in ["author", "summary", "category"] {
                if let value = package.manifest.json.objectValue?[key] { entry[key] = value }
            }
            return .object(entry)
        }
        let index: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string("11111111-1111-4111-8111-111111111111"),
            "name": .string("Metadata catalog"), "sequence": .integer(sequence),
            "issuedAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(-60))),
            "expiresAt": .string(AutomationFixtures.iso(AutomationFixtures.now.addingTimeInterval(86_400))),
            "plugins": .array(entries),
        ])
        let envelope: JSONValue = .object(["schemaVersion": .integer(1), "payload": .string(try index.data().base64EncodedString())])
        return try RepositoryEnvelope.verify(envelope: envelope.data(), url: url, now: AutomationFixtures.now)
    }

    private func fixture(packages: [PluginPackage], repositorySnapshot: VerifiedSnapshot? = nil,
                         publishedSnapshot: VerifiedSnapshot? = nil, publishedPackages: [PluginPackage]? = nil,
                         namespace: String? = nil, clientWrapper: ((FakeRepositoryClient) -> any RepositoryFetching)? = nil,
                         coordinatorWrapper: ((InstallationCoordinator) -> any InstallationCoordinating)? = nil,
                         stopCapture: @escaping @MainActor () -> Void = {}) async throws
        -> (AutomationController, PluginBrowserModel, AutomationStore, InstallationCoordinator, RepositoryRecord, FakeRepositoryClient)
    {
        let fixtureDirectory = namespace.map { directory.appendingPathComponent($0) } ?? directory!
        let catalogURL = fixtureDirectory.appendingPathComponent("catalog.json")
        let activationURL = fixtureDirectory.appendingPathComponent("activation.json")
        let store = AutomationStore(fileURL: catalogURL)
        let snapshot = try repositorySnapshot ?? AutomationFixtures.snapshot(packages: packages)
        let record = try await store.accept(snapshot, acknowledgeUnverified: true, now: AutomationFixtures.now)
        let coordinator = InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL)
        let client = FakeRepositoryClient(snapshot: publishedSnapshot ?? snapshot, packages: publishedPackages ?? packages)
        let controller = AutomationController(store: store, client: clientWrapper?(client) ?? client, executor: FakeScriptRunner(),
                                              clock: { AutomationFixtures.now },
                                              activationStore: PluginActivationStore(fileURL: activationURL),
                                              installationCoordinator: coordinatorWrapper?(coordinator) ?? coordinator,
                                              hasCaptureConsent: { true }, stopCapture: stopCapture)
        await controller.load()
        return (controller, PluginBrowserModel(controller: controller), store, coordinator, record, client)
    }

    private func described(_ package: PluginPackage, version: String? = nil,
                           author: String? = nil, summary: String? = nil) throws -> PluginPackage {
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        if let version { manifest["version"] = .string(version) }
        if let author { manifest["author"] = .string(author) }
        if let summary { manifest["summary"] = .string(summary) }
        root["manifest"] = .object(manifest)
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    private let otherSource = "https://other.example.com/repository.json"

    func testCatalogPackagesListsEveryVisibleEntryWithNothingInstalledAndNoFetch() async throws {
        let a = try described(AutomationFixtures.package(name: "Zeta"), author: "Ann", summary: "Rewrites headers")
        let b = try AutomationFixtures.package(name: "Alpha")
        let c = try AutomationFixtures.package(name: "Middle")
        let (controller, model, store, _, record, client) = try await fixture(packages: [a, b], repositorySnapshot: catalogSnapshot([a, b]))
        let otherURL = try RepositoryURL(parsing: otherSource)
        let other = try await store.accept(catalogSnapshot([c], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let rows = model.catalogPackages()
        XCTAssertEqual(rows.map(\.name), ["Alpha", "Middle", "Zeta"])
        XCTAssertEqual(rows.map(\.id), [
            PluginBrowserFamilyID(repository: record.url, manifestID: b.manifest.id),
            PluginBrowserFamilyID(repository: other.url, manifestID: c.manifest.id),
            PluginBrowserFamilyID(repository: record.url, manifestID: a.manifest.id),
        ])
        XCTAssertTrue(rows.allSatisfy { $0.installed == nil && $0.entry != nil && $0.record != nil })
        XCTAssertEqual(rows.last?.author, "Ann")
        XCTAssertEqual(rows.last?.summary, "Rewrites headers")
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(client.packageCount, 0)
    }

    func testCatalogPackagesKeepsTheSameUUIDFromTwoSourcesDistinctAndChecksOnlyTheInstalledOne() async throws {
        let package = try AutomationFixtures.package(name: "Shared")
        let (controller, model, store, _, record, _) = try await fixture(packages: [package], repositorySnapshot: catalogSnapshot([package]))
        let otherURL = try RepositoryURL(parsing: otherSource)
        let other = try await store.accept(catalogSnapshot([package], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertEqual(Set(model.catalogPackages().map(\.id)).count, 2)
        XCTAssertTrue(model.enqueueGet(package: package, record: other))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let rows = model.catalogPackages()
        XCTAssertEqual(rows.count, 2, "The installed package must not add a duplicate row")
        XCTAssertEqual(rows.filter { $0.installed != nil }.map(\.id),
                       [PluginBrowserFamilyID(repository: other.url, manifestID: package.manifest.id)])
        let untouched = try XCTUnwrap(rows.first { $0.id == PluginBrowserFamilyID(repository: record.url, manifestID: package.manifest.id) })
        XCTAssertNil(untouched.installed)
        XCTAssertNotNil(untouched.entry)
    }

    func testCatalogPackagesSortTiesByNameThenSourceThenUUID() async throws {
        let low = try AutomationFixtures.package(name: "Same", id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let high = try AutomationFixtures.package(name: "Same", id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        let (controller, model, store, _, record, _) = try await fixture(packages: [high, low], repositorySnapshot: catalogSnapshot([high, low]))
        let otherURL = try RepositoryURL(parsing: otherSource)
        let other = try await store.accept(catalogSnapshot([high, low], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let sources = [record.url.canonical, other.url.canonical].sorted()
        let expected = sources.flatMap { source in [low, high].map { source + "|" + $0.manifest.id.uuidString } }
        XCTAssertEqual(model.catalogPackages().map { $0.id.source + "|" + $0.id.manifestID.uuidString }, expected)
    }

    func testCatalogPackagesSearchNameAuthorSummaryAndDisplayInstalledLocalMetadata() async throws {
        let first = try described(AutomationFixtures.package(name: "Headers"), author: "Local Author", summary: "Local summary")
        let plain = try described(AutomationFixtures.package(name: "Plain"), author: "Someone", summary: "Other text")
        let (controller, model, _, _, record, client) = try await fixture(packages: [first, plain], repositorySnapshot: catalogSnapshot([first, plain]))
        XCTAssertEqual(model.catalogPackages(query: "local author").map(\.name), ["Headers"])
        XCTAssertEqual(model.catalogPackages(query: "other text").map(\.name), ["Plain"])
        XCTAssertEqual(model.catalogPackages(query: "plain").map(\.name), ["Plain"])
        XCTAssertTrue(model.catalogPackages(query: "absent").isEmpty)
        XCTAssertTrue(model.enqueueGet(package: first, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let published = try described(first, version: "2.0.0", author: "New Author", summary: "New summary")
        _ = try await controller.store.refresh(catalogSnapshot([published, plain], sequence: 2), expectedGeneration: XCTUnwrap(controller.catalog.record(for: record.url)).generation,
                                               acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let row = try XCTUnwrap(model.catalogPackages().first { $0.id.manifestID == first.manifest.id })
        XCTAssertEqual(row.version, first.manifest.version)
        XCTAssertEqual(row.author, "Local Author")
        XCTAssertEqual(row.entry?.version, "2.0.0")
        XCTAssertEqual(model.catalogPackages(query: "local summary").map(\.name), ["Headers"])
        XCTAssertTrue(model.catalogPackages(query: "new author").isEmpty, "Search follows the displayed local metadata")
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(client.packageCount, 0)
    }

    private func categorized(_ package: PluginPackage, category: String, version: String? = nil, name: String? = nil,
                             author: String? = nil, summary: String? = nil) throws -> PluginPackage
    {
        var root = try XCTUnwrap(JSONValue(parsing: package.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        manifest["category"] = .string(category)
        if let version {
            manifest["version"] = .string(version)
        }
        if let name {
            manifest["name"] = .string(name)
        }
        if let author {
            manifest["author"] = .string(author)
        }
        if let summary {
            manifest["summary"] = .string(summary)
        }
        root["manifest"] = .object(manifest)
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    func testCategoryPackagesUseLatestEntryMembershipAndInstalledManifestDisplay() async throws {
        let v1 = try categorized(AutomationFixtures.package(name: "Moving"), category: "Old", author: "Old Author", summary: "Old summary")
        let (controller, model, _, _, record, client) = try await fixture(packages: [v1], repositorySnapshot: catalogSnapshot([v1]))
        XCTAssertTrue(model.enqueueGet(package: v1, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let v2 = try categorized(v1, category: "New", version: "2.0.0", name: "Published variant", author: "New Author", summary: "New summary")
        _ = try await controller.store.refresh(catalogSnapshot([v2], sequence: 2), expectedGeneration: XCTUnwrap(controller.catalog.record(for: record.url)).generation,
                                               acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let categories = model.categories(in: record)
        XCTAssertEqual(categories.map(\.name), ["New"])
        let new = try XCTUnwrap(categories.first)
        let rows = model.catalogPackages(in: record, category: new)
        XCTAssertEqual(rows.map(\.id), [PluginBrowserFamilyID(repository: record.url, manifestID: v1.manifest.id)])
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotNil(row.installed)
        XCTAssertEqual(row.name, "Moving")
        XCTAssertEqual(row.version, "1.0.0")
        XCTAssertEqual(row.author, "Old Author")
        XCTAssertEqual(row.summary, "Old summary")
        XCTAssertEqual(row.entry?.version, "2.0.0")
        XCTAssertEqual(row.entry?.name, "Published variant")
        XCTAssertEqual(model.catalogPackages(in: record, category: new, query: "moving").count, 1)
        XCTAssertTrue(model.catalogPackages(in: record, category: new, query: "published variant").isEmpty)
        XCTAssertEqual(model.catalogPackages(in: record, category: new, query: "old summary").count, 1)
        XCTAssertTrue(model.catalogPackages(in: record, category: new, query: "new author").isEmpty, "Search follows the displayed manifest")
        XCTAssertTrue(model.catalogPackages(in: record, category: PluginBrowserCategory(name: "Old", count: 1)).isEmpty)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(client.packageCount, 0)
    }

    func testCategoryPackagesDoNotFallBackToIndexMetadataForInstalledNilFields() async throws {
        let bare = try categorized(AutomationFixtures.package(name: "Bare"), category: "Tools")
        let (controller, model, _, _, record, _) = try await fixture(packages: [bare], repositorySnapshot: catalogSnapshot([bare]))
        XCTAssertTrue(model.enqueueGet(package: bare, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let published = try categorized(bare, category: "Tools", version: "2.0.0", author: "Index Author", summary: "Index summary")
        _ = try await controller.store.refresh(catalogSnapshot([published], sequence: 2), expectedGeneration: XCTUnwrap(controller.catalog.record(for: record.url)).generation,
                                               acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let tools = try XCTUnwrap(model.categories(in: record).first)
        let row = try XCTUnwrap(model.catalogPackages(in: record, category: tools).first)
        XCTAssertNil(row.author)
        XCTAssertNil(row.summary)
        XCTAssertEqual(row.entry?.author, "Index Author")
        XCTAssertTrue(model.catalogPackages(in: record, category: tools, query: "index").isEmpty)
    }

    func testCategoryPackagesKeepSourcesSeparateAndExcludeScopedOrphans() async throws {
        let first = try categorized(AutomationFixtures.package(name: "Shared"), category: "Tools", author: "First Author")
        let second = try categorized(first, category: "Tools", author: "Second Author")
        let sibling = try categorized(AutomationFixtures.package(name: "Sibling"), category: "Tools")
        let (controller, model, store, _, record, _) = try await fixture(packages: [first], repositorySnapshot: catalogSnapshot([first]))
        let otherURL = try RepositoryURL(parsing: otherSource)
        let other = try await store.accept(catalogSnapshot([second], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertTrue(model.enqueueGet(package: first, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let tools = PluginBrowserCategory(name: "Tools", count: 1)
        let otherRow = try XCTUnwrap(model.catalogPackages(in: other, category: tools).first)
        XCTAssertNil(otherRow.installed)
        XCTAssertEqual(otherRow.author, "Second Author", "An uninstalled source row uses its Index")
        XCTAssertEqual(try XCTUnwrap(model.catalogPackages(in: record, category: tools).first).author, "First Author")
        let globalCount = model.catalogPackages().count
        _ = try await controller.store.refresh(catalogSnapshot([sibling], sequence: 2), expectedGeneration: XCTUnwrap(controller.catalog.record(for: record.url)).generation,
                                               acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertEqual(model.catalogPackages(in: record, category: tools).map(\.name), ["Sibling"], "Entry removal drops the orphan from the category")
        let orphan = PluginBrowserFamilyID(repository: record.url, manifestID: first.manifest.id)
        XCTAssertTrue(model.catalogPackages().contains { $0.id == orphan && $0.entry == nil })
        XCTAssertEqual(model.catalogPackages(in: other, category: tools).count, 1)
        try await store.remove(record.url)
        await controller.refreshCatalog()
        XCTAssertTrue(model.catalogPackages(in: record, category: tools).isEmpty)
        XCTAssertTrue(model.catalogPackages().contains { $0.id == orphan && $0.entry == nil }, "Global fallback persists")
        XCTAssertEqual(globalCount, 2)
    }

    func testCatalogPackagesShowInstalledOrphansOnceAfterEntryOrSourceRemoval() async throws {
        let kept = try AutomationFixtures.package(name: "Kept")
        let dropped = try AutomationFixtures.package(name: "Dropped")
        let gone = try AutomationFixtures.package(name: "Gone")
        let (controller, model, store, _, record, _) = try await fixture(packages: [kept, dropped], repositorySnapshot: catalogSnapshot([kept, dropped]))
        let otherURL = try RepositoryURL(parsing: otherSource)
        let other = try await store.accept(catalogSnapshot([gone], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertTrue(model.enqueueGet(package: dropped, record: record))
        XCTAssertTrue(model.enqueueGet(package: gone, record: other))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        XCTAssertEqual(model.catalogPackages().count, 3, "Installed packages with a catalog entry appear once")
        _ = try await controller.store.refresh(catalogSnapshot([kept], sequence: 2), expectedGeneration: XCTUnwrap(controller.catalog.record(for: record.url)).generation,
                                               acknowledgeUnverified: false, now: AutomationFixtures.now)
        try await store.remove(other.url)
        await controller.refreshCatalog()
        let rows = model.catalogPackages()
        XCTAssertEqual(rows.map(\.name), ["Dropped", "Gone", "Kept"])
        let entryOrphan = try XCTUnwrap(rows.first { $0.name == "Dropped" })
        XCTAssertNil(entryOrphan.entry)
        XCTAssertNotNil(entryOrphan.installed)
        XCTAssertNotNil(entryOrphan.record)
        let sourceOrphan = try XCTUnwrap(rows.first { $0.name == "Gone" })
        XCTAssertNil(sourceOrphan.entry)
        XCTAssertNil(sourceOrphan.record)
        XCTAssertEqual(sourceOrphan.id, PluginBrowserFamilyID(repository: other.url, manifestID: gone.manifest.id))
        XCTAssertNil(try XCTUnwrap(rows.first { $0.name == "Kept" }).installed)
    }

    func testCatalogPackagesExcludeLocalImportsAndRemovedSourcesWithoutInstalls() async throws {
        let remote = try AutomationFixtures.package(name: "Remote")
        let local = try AutomationFixtures.package(name: "Local only")
        let (controller, model, store, coordinator, record, client) = try await fixture(packages: [remote], repositorySnapshot: catalogSnapshot([remote]))
        let initial = try await Task.detached { try coordinator.state() }.value
        _ = try await Task.detached { try coordinator.importLocal(local.bytes, expectedSelectionGeneration: initial.selectionGeneration) }.value
        await controller.refreshCatalog()
        XCTAssertEqual(model.installedPackages().map(\.package.manifest.name), ["Local only"])
        XCTAssertEqual(model.catalogPackages().map(\.name), ["Remote"])
        XCTAssertTrue(model.catalogPackages(query: "local only").isEmpty, "Local imports stay under Sources > Local")
        try await store.remove(record.url)
        await controller.refreshCatalog()
        XCTAssertTrue(model.catalogPackages().isEmpty)
        XCTAssertEqual(model.installedPackages().count, 1)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(client.packageCount, 0)
    }

    func testGetOnlyQueuesAndRetainsFirstVersionAcrossMetadataRefresh() async throws {
        let old = try AutomationFixtures.package(name: "Queued")
        let (controller, model, store, _, record, _) = try await fixture(packages: [old])
        XCTAssertTrue(model.enqueueGet(package: old, record: record))
        XCTAssertFalse(model.enqueueGet(package: old, record: record))
        XCTAssertTrue(controller.scripts.isEmpty)
        let queuedCatalog = try await store.load()
        XCTAssertTrue(queuedCatalog.revisions.isEmpty)
        let newer = try revised(old, version: "2.0.0", marker: "\n// new")
        let snapshot = try AutomationFixtures.snapshot(packages: [newer], sequence: 2)
        let refreshed = try await controller.store.refresh(snapshot, expectedGeneration: record.generation,
                                                acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertFalse(model.enqueueGet(package: newer, record: refreshed))
        XCTAssertEqual(model.queue.first?.package.bytes, old.bytes)
        XCTAssertEqual(model.queue.first?.sourceGeneration, record.generation)
        let committed = await model.confirmQueue()
        XCTAssertFalse(committed, "A refresh cannot silently retarget the frozen queue")
        XCTAssertEqual(model.queue.count, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testConfirmInstallsEntireQueueDisabledAndClearsOnlyAfterSuccess() async throws {
        let a = try AutomationFixtures.package(name: "A"), b = try AutomationFixtures.package(name: "B")
        let (controller, model, _, coordinator, record, _) = try await fixture(packages: [a, b])
        XCTAssertTrue(model.enqueueGet(package: a, record: record))
        XCTAssertTrue(model.enqueueGet(package: b, record: record))
        let committed = await model.confirmQueue()
        XCTAssertTrue(committed)
        XCTAssertEqual(controller.scripts.map(\.package.manifest.name), ["A", "B"])
        XCTAssertTrue(model.queue.isEmpty)
        let state = try await Task.detached { try coordinator.state() }.value
        XCTAssertEqual(state.installed.count, 2)
        XCTAssertTrue(state.activation.revisions.isEmpty)
    }

    func testQueueIdentitySeparatesTheSameManifestUUIDFromTwoSources() async throws {
        let package = try AutomationFixtures.package(name: "Shared UUID")
        let (controller, model, store, _, record, _) = try await fixture(packages: [package])
        let otherURL = try RepositoryURL(parsing: "https://other.example.com/repository.json")
        let other = try await store.accept(catalogSnapshot([package], url: otherURL), acknowledgeUnverified: true, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        XCTAssertTrue(model.enqueueGet(package: package, record: other))
        XCTAssertEqual(Set(model.queue.map(\.id)).count, 2)
        let committed = await model.confirmQueue()
        XCTAssertTrue(committed)
        XCTAssertEqual(controller.scripts.count, 2)
    }

    func testCategoriesAndSearchUseCurrentMetadataWithoutNetworkSideEffects() async throws {
        let original = try AutomationFixtures.package(name: "Search limit")
        var root = try XCTUnwrap(JSONValue(parsing: original.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        manifest["author"] = .string("Example Team")
        manifest["summary"] = .string("Changes search results")
        manifest["category"] = .string("Requests")
        root["manifest"] = .object(manifest)
        let categorized = try PluginPackage.validate(JSONValue.object(root).data())
        let unclassified = try AutomationFixtures.package(name: "Unclassified")
        let (controller, model, _, _, record, client) = try await fixture(packages: [categorized, unclassified])
        _ = try await controller.store.refresh(catalogSnapshot([categorized, unclassified], sequence: 2), expectedGeneration: record.generation,
                                    acknowledgeUnverified: false, now: AutomationFixtures.now)
        await controller.refreshCatalog()
        let categories = model.categories(in: record)
        XCTAssertEqual(categories.map(\.name), ["Requests", nil])
        XCTAssertEqual(categories.map(\.count), [1, 1])
        let requests = try XCTUnwrap(categories.first)
        XCTAssertEqual(model.catalogEntries(in: record, category: requests, query: "example team").map(\.name), ["Search limit"])
        XCTAssertEqual(model.catalogEntries(in: record, category: categories.last).map(\.name), ["Unclassified"])
        XCTAssertTrue(model.catalogEntries(in: record, category: requests, query: "no match").isEmpty)
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertEqual(client.packageCount, 0)
    }

    func testRemovedRepositoryExactReinstallPreservesGrantAndWritesNothing() async throws {
        let package = try AutomationFixtures.package(name: "Retained")
        let (controller, model, store, coordinator, record, client) = try await fixture(packages: [package])
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let revision = try XCTUnwrap(controller.scripts.first)
        let generation = try XCTUnwrap(controller.activationSnapshot?.generation)
        await controller.activate(revision, expectedGeneration: generation)
        XCTAssertTrue(controller.isActive(revision.id))
        XCTAssertTrue(model.enqueueReinstall(revision))
        try await store.remove(record.url)
        await controller.refreshCatalog()
        let before = try Data(contentsOf: directory.appendingPathComponent("activation.json"))
        let committed = await model.confirmQueue()
        XCTAssertTrue(committed)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("activation.json")), before)
        XCTAssertTrue(controller.isActive(revision.id))
        XCTAssertEqual(client.packageCount, 0)
        let state = try await Task.detached { try coordinator.state() }.value
        XCTAssertEqual(state.installed.map(\.id), [revision.id])
    }

    func testStaleSameVersionDifferentBytesReinstallRejectsMixedBatch() async throws {
        let remote = try AutomationFixtures.package(name: "Remote")
        let local = try AutomationFixtures.package(name: "Local")
        let (controller, model, _, coordinator, record, _) = try await fixture(packages: [remote])
        let initial = try await Task.detached { try coordinator.state() }.value
        _ = try await Task.detached { try coordinator.importLocal(local.bytes, expectedSelectionGeneration: initial.selectionGeneration) }.value
        await controller.refreshCatalog()
        let old = try XCTUnwrap(controller.scripts.first)
        XCTAssertTrue(model.enqueueReinstall(old))
        XCTAssertTrue(model.enqueueGet(package: remote, record: record))
        let changed = try revised(local, marker: "\n// same version, other exact bytes")
        let current = try await Task.detached { try coordinator.state() }.value
        let removed = try await Task.detached { try coordinator.delete(revisionID: old.id, expectedSelectionGeneration: current.selectionGeneration) }.value
        _ = try await Task.detached { try coordinator.importLocal(changed.bytes, expectedSelectionGeneration: removed.selectionGeneration) }.value
        let committed = await model.confirmQueue()
        XCTAssertFalse(committed)
        XCTAssertEqual(model.queue.count, 2)
        let state = try await Task.detached { try coordinator.state() }.value
        XCTAssertEqual(state.installed.map(\.package.bytes), [changed.bytes])
    }

    func testBusyQueueRefusesEditsDismissalAndDuplicateConfirm() async throws {
        let package = try AutomationFixtures.package(name: "Busy")
        var gate: BrowserCoordinatorGate!
        let (_, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorGate($0)
            return gate
        })
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        model.openQueue()
        let first = Task { await model.confirmQueue() }
        let entered = await waitUntil { gate.enteredBatch }
        XCTAssertTrue(entered)
        XCTAssertTrue(model.isProcessing)
        model.removeQueued(id: model.queue[0].id)
        model.clearQueue()
        XCTAssertFalse(model.dismissQueue())
        let duplicate = await model.confirmQueue()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.queue.count, 1)
        gate.release()
        let committed = await first.value
        XCTAssertTrue(committed)
        XCTAssertEqual(gate.batchCount, 1)
        XCTAssertFalse(gate.batchOnMainThread)
    }

    func testCancellationBeforeBatchPublicationRetainsQueueAndSelection() async throws {
        let package = try AutomationFixtures.package(name: "Cancelled")
        var gate: BrowserCoordinatorGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorGate($0)
            return gate
        })
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let confirmation = Task { await model.confirmQueue() }
        let entered = await waitUntil { gate.enteredBatch }
        XCTAssertTrue(entered)
        confirmation.cancel()
        gate.release()
        let committed = await confirmation.value
        XCTAssertFalse(committed)
        XCTAssertEqual(model.queue.count, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testCancellationAfterConfirmedBatchDoesNotReportUncommittedOrLoseProjection() async throws {
        let package = try AutomationFixtures.package(name: "Committed")
        var gate: BrowserCoordinatorGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorGate($0, blocksAfterCommit: true)
            return gate
        })
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let confirmation = Task { await model.confirmQueue() }
        let entered = await waitUntil { gate.enteredBatch }
        XCTAssertTrue(entered)
        confirmation.cancel()
        gate.release()
        let committed = await confirmation.value
        XCTAssertTrue(committed)
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertEqual(controller.scripts.map(\.package.bytes), [package.bytes])
    }

    func testEnabledUpdateUsesSelectedRevisionAndRequiresReviewOfNewBytes() async throws {
        let old = try AutomationFixtures.package(name: "Update")
        let (original, model, store, coordinator, record, _) = try await fixture(packages: [old])
        XCTAssertTrue(model.enqueueGet(package: old, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(original.scripts.first)
        await original.activate(selected, expectedGeneration: try XCTUnwrap(original.activationSnapshot?.generation))
        let newer = try revised(old, version: "2.0.0", marker: "\n// reviewed new bytes")
        let snapshot = try AutomationFixtures.snapshot(packages: [newer], sequence: 2)
        let refreshed = try await original.store.refresh(snapshot, expectedGeneration: record.generation,
                                                acknowledgeUnverified: false, now: AutomationFixtures.now)
        // Historical bytes must not make the selected old installation look current.
        _ = try await store.install(newer, from: snapshot, expectedGeneration: refreshed.generation, now: AutomationFixtures.now)
        let controller = AutomationController(store: store, client: FakeRepositoryClient(snapshot: snapshot, packages: [newer]),
                                              executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                              activationStore: PluginActivationStore(fileURL: directory.appendingPathComponent("activation.json")),
                                              installationCoordinator: coordinator, hasCaptureConsent: { true }, stopCapture: {})
        await controller.load()
        let browser = PluginBrowserModel(controller: controller)
        XCTAssertEqual(controller.scripts.map(\.id), [selected.id])
        XCTAssertEqual(browser.updateComparison(for: selected, record: refreshed), .available(version: "2.0.0"))
        let prepared = await browser.prepareUpdate(selected, record: refreshed)
        let candidate = try XCTUnwrap(prepared)
        XCTAssertTrue(candidate.requiresApproval)
        let denied = await browser.commitUpdate(candidate)
        XCTAssertFalse(denied)
        XCTAssertEqual(controller.scripts.map(\.id), [selected.id])
        let committed = await browser.commitUpdate(candidate, approval: InstallationApproval(
            packageBytes: candidate.package.bytes, expectedGrantGeneration: candidate.expectedGrantGeneration))
        XCTAssertTrue(committed)
        XCTAssertEqual(controller.scripts.map(\.package.bytes), [newer.bytes])
        XCTAssertTrue(controller.isActive(try XCTUnwrap(controller.scripts.first?.id)))
        XCTAssertFalse(controller.isActive(selected.id))
    }

    func testRefreshCoalescesAndErrorKeepsCachedCatalog() async throws {
        let package = try AutomationFixtures.package(name: "Cache")
        let (controller, model, _, _, record, client) = try await fixture(packages: [package])
        client.delayNanoseconds = 100_000_000
        let first = Task { await model.refreshSources() }
        let entered = await waitUntil { client.previewCount == 1 }
        XCTAssertTrue(entered)
        let second = Task { await model.refreshSources() }
        await first.value
        await second.value
        XCTAssertEqual(client.previewCount, 1)
        XCTAssertTrue(controller.scripts.isEmpty)
        client.previewError = AutomationError.expired
        await model.refreshSources()
        XCTAssertFalse(model.refreshErrors.isEmpty)
        XCTAssertEqual(controller.catalog.record(for: record.url), record)
    }

    func testPackageRecoveryRefreshesOnlyMetadataAndKeepsQueueFrozen() async throws {
        let old = try AutomationFixtures.package(name: "Published package")
        let newer = try revised(old, version: "1.0.1", marker: "\n// published new bytes")
        let fresh = try AutomationFixtures.snapshot(packages: [newer], sequence: 2)
        var stops = 0
        let (controller, model, _, coordinator, record, client) = try await fixture(
            packages: [old], publishedSnapshot: fresh, publishedPackages: [newer], stopCapture: { stops += 1 })
        XCTAssertTrue(model.enqueueGet(package: old, record: record))
        let before = try await Task.detached { try coordinator.state() }.value
        let recovered = try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record)
        XCTAssertTrue(recovered, "A stale index must be replaced by accepted current metadata")
        let refreshed = try XCTUnwrap(controller.catalog.record(for: record.url))
        XCTAssertNotEqual(refreshed.generation, record.generation)
        XCTAssertEqual(refreshed.snapshot, fresh)
        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(client.packageCount, 0, "Recovery only refreshes metadata; the new view identity owns the next download")
        let entry = try XCTUnwrap(refreshed.snapshot?.index.plugins.first)
        let downloaded = try await model.fetchPackage(entry: entry, record: refreshed)
        XCTAssertEqual(downloaded.bytes, newer.bytes)
        let after = try await Task.detached { try coordinator.state() }.value
        XCTAssertEqual(after.installed, before.installed)
        XCTAssertEqual(after.activation, before.activation)
        XCTAssertEqual(after.selectionGeneration, before.selectionGeneration)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(model.queue.first?.package.bytes, old.bytes)
        XCTAssertEqual(model.queue.first?.sourceGeneration, record.generation)
        let committed = await model.confirmQueue()
        XCTAssertFalse(committed, "Recovery must not retarget a previously queued package")
        XCTAssertEqual(model.queue.first?.package.bytes, old.bytes)
        XCTAssertTrue(controller.scripts.isEmpty)
        model.clearQueue()
        XCTAssertTrue(model.enqueueGet(package: downloaded, record: refreshed))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        XCTAssertEqual(controller.scripts.map(\.package.bytes), [newer.bytes])
        XCTAssertFalse(controller.isActive(try XCTUnwrap(controller.scripts.first?.id)))
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryDoesNotPreviewForUnrelatedFailures() async throws {
        let package = try AutomationFixtures.package(name: "No refresh")
        let (_, model, _, _, record, client) = try await fixture(packages: [package])
        let failures: [Error] = [RepositoryClientError.transport, RepositoryClientError.timedOut,
                                 RepositoryClientError.unexpectedStatus(404), AutomationError.metadataMismatch,
                                 AutomationError.limitExceeded, AutomationError.invalidSignature]
        for failure in failures {
            let recovered = try await model.recoverPackageSource(after: failure, record: record)
            XCTAssertFalse(recovered)
        }
        XCTAssertEqual(client.previewCount, 0)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryLeavesUnchangedMetadataAndCorruptBytesAlone() async throws {
        let package = try AutomationFixtures.package(name: "Same metadata")
        let (controller, model, _, _, record, client) = try await fixture(packages: [package])
        let file = directory.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: file)
        for failure: Error in [AutomationError.sizeMismatch, AutomationError.hashMismatch] {
            let recovered = try await model.recoverPackageSource(after: failure, record: record)
            XCTAssertFalse(recovered, "Unchanged metadata cannot authorize different package bytes")
        }
        XCTAssertEqual(client.previewCount, 2)
        XCTAssertEqual(client.packageCount, 0)
        XCTAssertEqual(controller.catalog.record(for: record.url), record)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryRejectsTrustAndContinuityChanges() async throws {
        let package = try AutomationFixtures.package(name: "Trust continuity")
        let newer = try revised(package, version: "1.0.1", marker: "\n// changed")
        let key = Curve25519.Signing.PrivateKey()
        let anotherKey = Curve25519.Signing.PrivateKey()
        let unsigned = try AutomationFixtures.snapshot(packages: [package], sequence: 2)
        let signed = try AutomationFixtures.snapshot(packages: [package], sequence: 2, key: key)
        let cases: [(VerifiedSnapshot, VerifiedSnapshot, AutomationError)] = [
            (unsigned, try AutomationFixtures.snapshot(packages: [newer], sequence: 1), .rollback),
            (unsigned, try AutomationFixtures.snapshot(packages: [newer], sequence: 2), .sameSequenceDifferentPayload),
            (unsigned, try AutomationFixtures.snapshot(packages: [newer], sequence: 3, key: key), .acknowledgmentRequired),
            (signed, try AutomationFixtures.snapshot(packages: [newer], sequence: 3, key: anotherKey), .keyChanged),
            (signed, try AutomationFixtures.snapshot(packages: [newer], sequence: 3), .signatureRemoved),
            (unsigned, try AutomationFixtures.snapshot(packages: [newer], sequence: 3, repositoryID: UUID()), .repositoryIdentityChanged),
        ]
        for (i, testCase) in cases.enumerated() {
            let (controller, model, _, _, record, client) = try await fixture(
                packages: [package], repositorySnapshot: testCase.0, publishedSnapshot: testCase.1, namespace: "trust-\(i)")
            XCTAssertTrue(model.enqueueGet(package: package, record: record))
            let file = directory.appendingPathComponent("trust-\(i)/catalog.json")
            let before = try Data(contentsOf: file)
            do {
                _ = try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record)
                XCTFail("Trust or continuity change must be refused: \(testCase.2)")
            } catch { XCTAssertEqual(error as? AutomationError, testCase.2) }
            XCTAssertEqual(client.previewCount, 1)
            XCTAssertEqual(controller.catalog.record(for: record.url), record)
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(model.queue.first?.package.bytes, package.bytes)
            XCTAssertTrue(controller.scripts.isEmpty)
            XCTAssertFalse(model.isProcessing)
        }
    }

    func testPackageRecoveryUsesConcurrentAcceptedRefreshWithoutOverwritingIt() async throws {
        let old = try AutomationFixtures.package(name: "Concurrent source")
        let newer = try revised(old, version: "1.0.1", marker: "\n// new")
        let newest = try revised(old, version: "1.0.2", marker: "\n// newest")
        let fresh = try AutomationFixtures.snapshot(packages: [newer], sequence: 2)
        let latest = try AutomationFixtures.snapshot(packages: [newest], sequence: 3)
        let gate = BrowserAsyncMutationGate()
        let (controller, model, _, _, record, _) = try await fixture(packages: [old], publishedSnapshot: fresh, clientWrapper: {
            BrowserRecoveryPreviewGate(base: $0, gate: gate)
        })
        defer { gate.release() }
        let recovery = Task { try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record) }
        let entered = await waitUntil { gate.isHeld }
        XCTAssertTrue(entered)
        let beforeConcurrent = try await controller.store.load()
        XCTAssertEqual(beforeConcurrent.record(for: record.url), record)
        // Use Sources' existential seam; a concrete actor call can select the fail-closed async default.
        let concurrent = try await controller.store.refresh(latest, expectedGeneration: record.generation,
                                                           acknowledgeUnverified: false, now: AutomationFixtures.now)
        gate.release()
        let recovered = try await recovery.value
        XCTAssertTrue(recovered)
        XCTAssertEqual(controller.catalog.record(for: record.url), concurrent)
        XCTAssertEqual(controller.catalog.record(for: record.url)?.snapshot, latest)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryCannotRestoreARemovedSource() async throws {
        let old = try AutomationFixtures.package(name: "Removed source")
        let fresh = try AutomationFixtures.snapshot(packages: [old], sequence: 2)
        let gate = BrowserAsyncMutationGate()
        let (controller, model, store, _, record, _) = try await fixture(packages: [old], publishedSnapshot: fresh, clientWrapper: {
            BrowserRecoveryPreviewGate(base: $0, gate: gate)
        })
        defer { gate.release() }
        let recovery = Task { try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record) }
        let entered = await waitUntil { gate.isHeld }
        XCTAssertTrue(entered)
        try await store.remove(record.url)
        gate.release()
        do { _ = try await recovery.value; XCTFail("Recovery must not restore a removed repository") }
        catch { XCTAssertEqual(error as? AutomationError, .staleSnapshot) }
        XCTAssertTrue(controller.repositories.isEmpty)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryAcceptsManifestRemovalWithoutFetchingAnotherPackage() async throws {
        let old = try AutomationFixtures.package(name: "Removed package")
        let fresh = try AutomationFixtures.snapshot(packages: [], sequence: 2)
        let (controller, model, _, _, record, client) = try await fixture(packages: [old], publishedSnapshot: fresh)
        let recovered = try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record)
        XCTAssertTrue(recovered)
        let current = try XCTUnwrap(controller.catalog.record(for: record.url))
        XCTAssertTrue(model.catalogEntries(in: current).isEmpty)
        XCTAssertNotEqual(current.generation, record.generation)
        XCTAssertEqual(client.packageCount, 0)
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testPackageRecoveryCancellationBeforeCommitKeepsCatalog() async throws {
        let old = try AutomationFixtures.package(name: "Cancelled recovery")
        let fresh = try AutomationFixtures.snapshot(packages: [old], sequence: 2)
        let (controller, model, _, _, record, client) = try await fixture(packages: [old], publishedSnapshot: fresh)
        client.delayNanoseconds = 5_000_000_000
        let before = try Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        let recovery = Task { try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record) }
        let entered = await waitUntil { client.previewCount == 1 }
        XCTAssertTrue(entered)
        recovery.cancel()
        do { _ = try await recovery.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(controller.catalog.record(for: record.url), record)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.json")), before)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryPublishesCommittedMetadataAfterCancellation() async throws {
        let old = try AutomationFixtures.package(name: "Committed recovery")
        let fresh = try AutomationFixtures.snapshot(packages: [old], sequence: 2)
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [old], publishedSnapshot: fresh, coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        gate.holdNextRead()
        defer { gate.releaseRead() }
        let recovery = Task { try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record) }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        recovery.cancel()
        gate.releaseRead()
        let recovered = try await recovery.value
        XCTAssertTrue(recovered)
        XCTAssertEqual(controller.catalog.record(for: record.url)?.snapshot, fresh)
        XCTAssertNotEqual(controller.catalog.record(for: record.url)?.generation, record.generation)
        XCTAssertFalse(model.isProcessing)
    }

    func testPackageRecoveryBlocksQueueChangesAndDuplicateRecoveryWhileBusy() async throws {
        let package = try AutomationFixtures.package(name: "Busy recovery")
        let fresh = try AutomationFixtures.snapshot(packages: [package], sequence: 2)
        let gate = BrowserAsyncMutationGate()
        let (_, model, _, _, record, client) = try await fixture(packages: [package], publishedSnapshot: fresh, clientWrapper: {
            BrowserRecoveryPreviewGate(base: $0, gate: gate)
        })
        defer { gate.release() }
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let recovery = Task { try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record) }
        let entered = await waitUntil { gate.isHeld }
        XCTAssertTrue(entered)
        XCTAssertTrue(model.isProcessing)
        model.clearQueue()
        let confirmed = await model.confirmQueue()
        XCTAssertFalse(confirmed)
        do { _ = try await model.recoverPackageSource(after: RepositoryClientError.responseTooLarge, record: record); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? PluginBrowserError, .busy) }
        gate.release()
        _ = try await recovery.value
        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(model.queue.count, 1)
        XCTAssertFalse(model.isProcessing)
    }

    func testControllerReloadReadsCoordinatorChangesInsteadOfActorCache() async throws {
        let package = try AutomationFixtures.package(name: "External")
        let (controller, _, _, coordinator, _, _) = try await fixture(packages: [package])
        let initial = try await Task.detached { try coordinator.state() }.value
        _ = try await Task.detached { try coordinator.importLocal(package.bytes, expectedSelectionGeneration: initial.selectionGeneration) }.value
        await controller.refreshCatalog()
        XCTAssertEqual(controller.scripts.map(\.package.bytes), [package.bytes])
        XCTAssertEqual(controller.catalog.revisions.count, 1)
    }

    func testLateInstallationReadCannotRedisplayADeletedSelection() async throws {
        let package = try AutomationFixtures.package(name: "Read before deletion")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        gate.holdNextRead()
        defer { gate.releaseRead() }
        let earlier = Task { try await controller.readInstallation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        await controller.deleteScript(id: selected.id)
        XCTAssertTrue(controller.scripts.isEmpty)
        let currentGeneration = controller.selectionGeneration
        gate.releaseRead()
        let earlierReceipt = try await earlier.value
        XCTAssertEqual(earlierReceipt.installed.map(\.id), [selected.id], "a completed read retains its real linearization receipt")
        XCTAssertTrue(controller.scripts.isEmpty, "late presentation must not resurrect deleted selection")
        XCTAssertEqual(controller.selectionGeneration, currentGeneration)
    }

    func testLateInstallationReadCannotRedisplayARevokedGrant() async throws {
        let package = try AutomationFixtures.package(name: "Read before revocation")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let installed = await model.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        XCTAssertTrue(controller.isActive(selected.id))
        gate.holdNextRead()
        defer { gate.releaseRead() }
        let earlier = Task { try await controller.readInstallation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        let revoked = await controller.revokeActivation(id: selected.id)
        XCTAssertTrue(revoked)
        let currentGrantGeneration = controller.activationSnapshot?.generation
        gate.releaseRead()
        _ = try await earlier.value
        XCTAssertFalse(controller.isActive(selected.id))
        XCTAssertEqual(controller.activationSnapshot?.generation, currentGrantGeneration)
        XCTAssertEqual(controller.scripts.map(\.id), [selected.id])
    }

    func testLateCommittedMutationRefreshesAuthorityWithoutRedisplayingItsOldReceipt() async throws {
        let package = try AutomationFixtures.package(name: "Delayed committed batch")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, _, _, coordinator, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        let before = try await controller.readInstallation()
        let request = InstallationRequest(package: package, snapshot: try XCTUnwrap(record.snapshot),
                                          expectedSourceGeneration: record.generation, operation: .add)
        gate.holdNextBatchReceipt()
        defer { gate.releaseBatch(); gate.releaseRead() }
        let earlier = Task { try await controller.commitInstallationBatch([request], expectedSelectionGeneration: before.selectionGeneration) }
        let committed = await waitUntil { gate.batchReceiptIsHeld }
        XCTAssertTrue(committed)
        // Another coordinator publishes B while the successful receipt A is delayed in delivery.
        let external = try await Task.detached { try coordinator.state() }.value
        let selected = try XCTUnwrap(external.installed.first)
        _ = try await Task.detached { try coordinator.delete(revisionID: selected.id, expectedSelectionGeneration: external.selectionGeneration) }.value
        _ = try await controller.readInstallation()
        XCTAssertTrue(controller.scripts.isEmpty)
        let currentGeneration = controller.selectionGeneration
        gate.holdNextRead()
        gate.releaseBatch()
        let refreshing = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(refreshing)
        XCTAssertTrue(controller.scripts.isEmpty, "old committed receipt A must not display while authoritative refresh B is pending")
        XCTAssertEqual(controller.selectionGeneration, currentGeneration)
        gate.releaseRead()
        let receipt = try await earlier.value
        XCTAssertEqual(receipt.installed.map(\.id), [selected.id], "the first write really committed; it must not be reported as uncommitted")
        XCTAssertTrue(controller.scripts.isEmpty)
    }

    func testLateReadFailureCannotClearANewerAuthoritativeSelection() async throws {
        let package = try AutomationFixtures.package(name: "Delayed failed read")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, model, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        gate.holdNextRead(error: .saveFailed)
        defer { gate.releaseRead() }
        let earlier = Task { try await controller.readInstallation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        XCTAssertTrue(model.enqueueGet(package: package, record: record))
        let committed = await model.confirmQueue()
        XCTAssertTrue(committed)
        let selected = controller.scripts.map(\.id)
        gate.releaseRead()
        do { _ = try await earlier.value; XCTFail("the earlier read must keep its own failure") }
        catch { XCTAssertEqual(error as? AutomationError, .saveFailed) }
        XCTAssertEqual(controller.scripts.map(\.id), selected)
        XCTAssertNil(controller.installationError)
    }

    func testDisabledDeleteAndExactReinstallInAnotherControllerInvalidatesTheOldApproval() async throws {
        let package = try AutomationFixtures.package(name: "Reinstalled approval")
        let (reviewing, browser, _, _, record, _) = try await fixture(packages: [package])
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let reviewed = try XCTUnwrap(reviewing.scripts.first)
        let reviewedGrantGeneration = try XCTUnwrap(reviewing.activationSnapshot?.generation)
        let reviewedSelectionGeneration = reviewing.selectionGeneration
        XCTAssertFalse(reviewing.isActive(reviewed.id))

        let catalogURL = directory.appendingPathComponent("catalog.json")
        let activationURL = directory.appendingPathComponent("activation.json")
        let other = AutomationController(store: AutomationStore(fileURL: catalogURL), client: reviewing.client,
                                         executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                         activationStore: PluginActivationStore(fileURL: activationURL, catalogURL: catalogURL),
                                         installationCoordinator: InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL),
                                         hasCaptureConsent: { true }, stopCapture: {})
        await other.load()
        await other.deleteScript(id: reviewed.id)
        XCTAssertTrue(other.scripts.isEmpty)
        let otherBrowser = PluginBrowserModel(controller: other)
        XCTAssertTrue(otherBrowser.enqueueGet(package: package, record: record))
        let reinstalled = await otherBrowser.confirmQueue()
        XCTAssertTrue(reinstalled)
        XCTAssertEqual(other.scripts.map(\.id), [reviewed.id], "the exact same family and bytes are selected again")
        XCTAssertNotEqual(other.selectionGeneration, reviewedSelectionGeneration)

        await reviewing.activate(reviewed, expectedGeneration: reviewedGrantGeneration)
        XCTAssertFalse(reviewing.isActive(reviewed.id), "an approval opened before deletion must not authorize a later installation")
        XCTAssertEqual(reviewing.activationErrorKey, "AUTO_ACTIVATION_STALE")
        let freshGeneration = try XCTUnwrap(reviewing.activationSnapshot?.generation)
        XCTAssertNotEqual(freshGeneration, reviewedGrantGeneration)
        await reviewing.activate(reviewed, expectedGeneration: freshGeneration)
        XCTAssertTrue(reviewing.isActive(reviewed.id), "a new review of the current installation may approve it")
    }

    func testFailedMutationRefreshesAuthorityAfterInvalidatingAnOlderRead() async throws {
        let remote = try AutomationFixtures.package(name: "Rejected stale batch")
        let local = try AutomationFixtures.package(name: "External current selection")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, _, _, coordinator, record, _) = try await fixture(packages: [remote], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        let before = try await controller.readInstallation()
        gate.holdNextRead()
        defer { gate.releaseRead() }
        let earlier = Task { try await controller.readInstallation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        let external = try await Task.detached {
            try coordinator.importLocal(local.bytes, expectedSelectionGeneration: before.selectionGeneration)
        }.value
        let request = InstallationRequest(package: remote, snapshot: try XCTUnwrap(record.snapshot),
                                          expectedSourceGeneration: record.generation, operation: .add)
        do {
            _ = try await controller.commitInstallationBatch([request], expectedSelectionGeneration: before.selectionGeneration)
            XCTFail("the stale selection token must remain rejected")
        } catch { XCTAssertEqual(error as? AutomationError, .staleGeneration) }
        XCTAssertEqual(controller.scripts.map(\.id), external.installed.map(\.id), "failure refreshes authority without retrying the batch")
        gate.releaseRead()
        _ = try await earlier.value
        XCTAssertEqual(controller.scripts.map(\.id), external.installed.map(\.id))
    }

    func testDelayedMetadataCorruptionErrorCannotClearANewerValidProjection() async throws {
        let package = try AutomationFixtures.package(name: "Current durable selection")
        let (controller, _, _, coordinator, _, _) = try await fixture(packages: [package])
        let gate = BrowserAsyncMutationGate()
        let earlier = Task { () -> Void? in
            await controller.mutate {
                await gate.hold()
                throw AutomationError.corruptStore
            }
        }
        let entered = await waitUntil { gate.isHeld }
        XCTAssertTrue(entered)
        let before = try await Task.detached { try coordinator.state() }.value
        let external = try await Task.detached {
            try coordinator.importLocal(package.bytes, expectedSelectionGeneration: before.selectionGeneration)
        }.value
        _ = try await controller.readInstallation()
        gate.release()
        _ = await earlier.value
        XCTAssertEqual(controller.scripts.map(\.id), external.installed.map(\.id))
        XCTAssertNil(controller.storeError, "only a current authoritative load can declare corruption")
        XCTAssertNotNil(controller.actionError, "the failed metadata action still reports its actual result")
    }

    func testSupersededRefreshDoesNotConsumePendingRevocationFromAnotherProjection() async throws {
        let package = try AutomationFixtures.package(name: "Pending revocation")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, browser, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        gate.failNextRevocation(with: .saveFailed)
        let revoked = await controller.revokeActivation(id: selected.id)
        XCTAssertFalse(revoked)
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id))
        gate.holdNextRead()
        defer { gate.releaseRead() }
        let reconciliation = Task { await controller.refreshActivation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        _ = try await controller.readInstallation() // A newer successful observation supersedes the held refresh.
        let revocationCount = gate.revocationCount
        gate.releaseRead()
        await reconciliation.value
        XCTAssertEqual(gate.revocationCount, revocationCount, "a superseded refresh must not consume an unrelated shared projection")
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id))
        await controller.refreshActivation()
        XCTAssertFalse(controller.pendingRevocations.contains(selected.id))
        XCTAssertFalse(controller.isActive(selected.id))
    }

    func testOlderSuccessfulRevocationCannotClearANewerFailedRevocationIntent() async throws {
        let package = try AutomationFixtures.package(name: "Revocation delivery order")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, browser, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        gate.holdNextRevocationReceipt()
        defer { gate.releaseRevocation() }
        let earlier = Task { await controller.revokeActivation(id: selected.id) }
        let entered = await waitUntil { gate.revocationReceiptIsHeld }
        XCTAssertTrue(entered)
        gate.failNextRevocation(with: .saveFailed)
        let newer = await controller.revokeActivation(id: selected.id)
        XCTAssertFalse(newer)
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id))
        gate.releaseRevocation()
        let older = await earlier.value
        XCTAssertTrue(older, "the earlier revocation really committed")
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id), "later explicit failure remains pending until a successful retry")
        await controller.refreshActivation()
        XCTAssertFalse(controller.pendingRevocations.contains(selected.id))
        XCTAssertFalse(controller.isActive(selected.id))
    }

    func testOlderFailedRevocationCannotRependOrStopCaptureAfterNewerSuccess() async throws {
        let package = try AutomationFixtures.package(name: "Older failed revocation")
        var gate: BrowserCoordinatorReceiptGate!
        var stops = 0
        let (controller, browser, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        }, stopCapture: { stops += 1 })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        gate.holdNextRevocationReceipt()
        gate.failNextRevocation(with: .saveFailed)
        defer { gate.releaseRevocation() }
        let earlier = Task { await controller.revokeActivation(id: selected.id) }
        let entered = await waitUntil { gate.revocationReceiptIsHeld }
        XCTAssertTrue(entered)
        let newer = await controller.revokeActivation(id: selected.id)
        XCTAssertTrue(newer)
        gate.releaseRevocation()
        let older = await earlier.value
        XCTAssertFalse(older)
        XCTAssertTrue(controller.pendingRevocations.isEmpty)
        XCTAssertEqual(stops, 0)
        XCTAssertNil(controller.activationErrorKey)
        XCTAssertFalse(controller.isActive(selected.id))
    }

    func testDelayedDeleteCannotClearANewerFailedRevocationAfterExactReinstall() async throws {
        let package = try AutomationFixtures.package(name: "Delete versus new revocation")
        var gate: BrowserCoordinatorReceiptGate!
        var stops = 0
        let (controller, browser, _, coordinator, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        }, stopCapture: { stops += 1 })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        gate.holdNextDeleteReceipt()
        defer { gate.releaseDelete() }
        let deletion = Task { await controller.deleteScript(id: selected.id) }
        let entered = await waitUntil { gate.deleteReceiptIsHeld }
        XCTAssertTrue(entered)

        let catalogURL = directory.appendingPathComponent("catalog.json")
        let activationURL = directory.appendingPathComponent("activation.json")
        let other = AutomationController(store: AutomationStore(fileURL: catalogURL), client: controller.client,
                                         executor: FakeScriptRunner(), clock: { AutomationFixtures.now },
                                         activationStore: PluginActivationStore(fileURL: activationURL, catalogURL: catalogURL),
                                         installationCoordinator: InstallationCoordinator(catalogURL: catalogURL, activationURL: activationURL),
                                         hasCaptureConsent: { true }, stopCapture: {})
        await other.load()
        XCTAssertTrue(other.scripts.isEmpty)
        let reinstaller = PluginBrowserModel(controller: other)
        XCTAssertTrue(reinstaller.enqueueGet(package: package, record: record))
        let reinstalled = await reinstaller.confirmQueue()
        XCTAssertTrue(reinstalled)
        let current = try XCTUnwrap(other.scripts.first)
        XCTAssertEqual(current.id, selected.id)
        XCTAssertEqual(current.package.bytes, selected.package.bytes)
        await other.activate(current, expectedGeneration: try XCTUnwrap(other.activationSnapshot?.generation))
        XCTAssertTrue(other.isActive(current.id))

        gate.failNextRevocation(with: .saveFailed)
        let revoked = await controller.revokeActivation(id: current.id)
        XCTAssertFalse(revoked)
        XCTAssertTrue(controller.pendingRevocations.contains(current.id))
        XCTAssertEqual(stops, 1)
        gate.releaseDelete()
        await deletion.value
        XCTAssertTrue(controller.pendingRevocations.contains(current.id), "a historical delete must not consume the newer failed revocation")
        XCTAssertTrue(controller.isActive(current.id), "the failed revocation has not yet changed the durable grant")
        let granted = try await Task.detached { try coordinator.state() }.value
        XCTAssertTrue(granted.activation.contains(revisionID: current.id))

        await controller.refreshActivation()
        XCTAssertTrue(controller.pendingRevocations.isEmpty)
        XCTAssertFalse(controller.isActive(current.id))
        XCTAssertNil(controller.activationErrorKey)
        XCTAssertEqual(stops, 1)
        let reconciled = try await Task.detached { try coordinator.state() }.value
        XCTAssertFalse(reconciled.activation.contains(revisionID: current.id), "retry must persist the new revocation")
        XCTAssertEqual(reconciled.installed.map(\.id), [current.id])
    }

    func testDelayedDeleteMayClearItsOlderPendingRevocationDespiteUnrelatedReads() async throws {
        let package = try AutomationFixtures.package(name: "Delete owns earlier pending intent")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, browser, _, coordinator, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        await controller.activate(selected, expectedGeneration: try XCTUnwrap(controller.activationSnapshot?.generation))
        gate.failNextRevocation(with: .saveFailed)
        let revoked = await controller.revokeActivation(id: selected.id)
        XCTAssertFalse(revoked)
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id))
        gate.holdNextDeleteReceipt()
        defer { gate.releaseDelete() }
        let deletion = Task { await controller.deleteScript(id: selected.id) }
        let entered = await waitUntil { gate.deleteReceiptIsHeld }
        XCTAssertTrue(entered)
        _ = try await controller.readInstallation()
        await controller.refreshCatalog()
        XCTAssertTrue(controller.pendingRevocations.contains(selected.id))
        gate.releaseDelete()
        await deletion.value
        XCTAssertTrue(controller.pendingRevocations.isEmpty, "presentation reads do not transfer ownership of a per-revision intent")
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertNil(controller.actionError)
        let current = try await Task.detached { try coordinator.state() }.value
        XCTAssertTrue(current.installed.isEmpty)
        XCTAssertTrue(current.activation.revisions.isEmpty)
    }

    func testOlderFailedDeleteCannotReplaceANewerSuccessfulDeleteResult() async throws {
        let package = try AutomationFixtures.package(name: "Delete failure delivery order")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, browser, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = try XCTUnwrap(controller.scripts.first)
        gate.holdNextDeleteReceipt()
        gate.failNextDelete(with: .saveFailed)
        defer { gate.releaseDelete() }
        let earlier = Task { await controller.deleteScript(id: selected.id) }
        let entered = await waitUntil { gate.deleteReceiptIsHeld }
        XCTAssertTrue(entered)
        await controller.deleteScript(id: selected.id)
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertNil(controller.actionError)
        gate.releaseDelete()
        await earlier.value
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertNil(controller.actionError, "a stale delete failure must not replace the newer success")
    }

    func testCurrentFailedActivationRefreshReportsPreservedStoreError() async throws {
        let package = try AutomationFixtures.package(name: "Unreadable authority")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, _, _, _, _, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        gate.holdNextRead(error: .corruptStore)
        defer { gate.releaseRead() }
        let refresh = Task { await controller.refreshActivation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        gate.releaseRead()
        await refresh.value
        XCTAssertNil(controller.installationState)
        XCTAssertEqual(controller.activationErrorKey, "AUTO_ACTIVATION_STORE_PRESERVED")
        XCTAssertEqual(controller.installationError as? AutomationError, .corruptStore)
    }

    func testCancelledInstallationReadPreservesTheAuthoritativeSelection() async throws {
        let package = try AutomationFixtures.package(name: "Cancelled read")
        var gate: BrowserCoordinatorReceiptGate!
        let (controller, browser, _, _, record, _) = try await fixture(packages: [package], coordinatorWrapper: {
            gate = BrowserCoordinatorReceiptGate($0); return gate
        })
        XCTAssertTrue(browser.enqueueGet(package: package, record: record))
        let installed = await browser.confirmQueue()
        XCTAssertTrue(installed)
        let selected = controller.scripts.map(\.id)
        gate.holdNextCancelledRead()
        defer { gate.releaseRead() }
        let reading = Task { try await controller.readInstallation() }
        let entered = await waitUntil { gate.readIsHeld }
        XCTAssertTrue(entered)
        reading.cancel()
        gate.releaseRead()
        do { _ = try await reading.value; XCTFail("read cancellation must remain observable") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(controller.scripts.map(\.id), selected)
        XCTAssertNil(controller.installationError)
    }

    func testLegacyInstallAndEditRoutesCannotChangeCoordinatorSelection() async throws {
        let package = try AutomationFixtures.package(name: "Legacy route")
        let (controller, _, _, _, record, _) = try await fixture(packages: [package])
        do {
            _ = try await controller.store.install(package, from: try XCTUnwrap(record.snapshot),
                                                    expectedGeneration: record.generation, now: AutomationFixtures.now)
            XCTFail("Legacy installation must require the coordinator route")
        } catch { XCTAssertEqual(error as? AutomationInstallationRoutingError, .coordinatorRequired) }
        XCTAssertTrue(controller.scripts.isEmpty)
        let createdValue = await controller.createExample(name: "Selected")
        let created = try XCTUnwrap(createdValue)
        do {
            _ = try await controller.store.editSources(of: created.id, to: created.package.sourceFiles)
            XCTFail("Legacy editing must not stage a future selected revision")
        } catch { XCTAssertEqual(error as? AutomationInstallationRoutingError, .coordinatorRequired) }
        await controller.refreshCatalog()
        XCTAssertEqual(controller.scripts.map(\.id), [created.id])
    }

    func testControllerLocalCreationUsesSelectedCoordinatorAndMissingSharedURLFailsClosed() async throws {
        let package = try AutomationFixtures.package(name: "Catalog")
        let (controller, _, _, coordinator, _, _) = try await fixture(packages: [package])
        let created = await controller.createExample(name: "Selected local")
        XCTAssertNotNil(created)
        let state = try await Task.detached { try coordinator.state() }.value
        XCTAssertEqual(state.installed.map(\.id), created.map { [$0.id] } ?? [])
        let unavailable = AutomationController(store: controller.store, client: controller.client, executor: FakeScriptRunner(),
                                               installationCoordinator: InstallationCoordinator(catalogURL: directory.appendingPathComponent("catalog.json"), activationURL: nil),
                                               installationAvailable: false)
        await unavailable.load()
        let rejected = await unavailable.createExample(name: "Cannot stage")
        XCTAssertNil(rejected)
        XCTAssertTrue(unavailable.scripts.isEmpty)
        let after = try await controller.store.load()
        XCTAssertEqual(after.revisions.count, 1)
    }

    func testPackageHostsAggregateAllRulesAndFileConditionsOnlyReferenceThatFile() throws {
        let original = try AutomationFixtures.multiFilePackage(name: "Multiple")
        var root = try XCTUnwrap(JSONValue(parsing: original.bytes).objectValue)
        var manifest = try XCTUnwrap(root["manifest"]?.objectValue)
        var matches = try XCTUnwrap(manifest["matches"]?.arrayValue)
        var other = try XCTUnwrap(matches[1].objectValue)
        other["hosts"] = .array([.string("api.example.com")])
        matches[1] = .object(other)
        manifest["matches"] = .array(matches)
        root["manifest"] = .object(manifest)
        let package = try PluginPackage.validate(JSONValue.object(root).data())
        XCTAssertEqual(PluginBrowserModel.targetHosts(package.manifest), ["api.example.com", "example.com"])
        let rules = PluginBrowserModel.matchingRules(in: package.manifest, file: AutomationTemplate.sourceFile)
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.allSatisfy { $0.hosts == ["example.com"] })
        let otherRules = PluginBrowserModel.matchingRules(in: package.manifest, file: "hooks/example.com/other/GET.js")
        XCTAssertEqual(otherRules.count, 4)
        XCTAssertTrue(otherRules.allSatisfy { $0.hosts == ["api.example.com"] && $0.methods == ["GET"] })
        XCTAssertTrue(PluginBrowserModel.matchingRules(in: package.manifest, file: "missing.js").isEmpty)
    }
}

/// Blocks only the real batch boundary, leaving the coordinator's validation and durable writes intact.
private final class BrowserCoordinatorGate: InstallationCoordinating, @unchecked Sendable {
    let base: InstallationCoordinator
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blocksAfterCommit: Bool
    private var calls = 0, entered = false, onMain = false
    var enteredBatch: Bool { lock.withLock { entered } }
    var batchCount: Int { lock.withLock { calls } }
    var batchOnMainThread: Bool { lock.withLock { onMain } }
    init(_ base: InstallationCoordinator, blocksAfterCommit: Bool = false) {
        self.base = base
        self.blocksAfterCommit = blocksAfterCommit
    }
    func release() { semaphore.signal() }
    func state() throws -> InstallationState { try base.state() }
    func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState {
        let committed = blocksAfterCommit ? try base.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: now) : nil
        lock.withLock { calls += 1; entered = true; onMain = Thread.isMainThread }
        semaphore.wait()
        if let committed { return committed }
        try Task.checkCancellation()
        return try base.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: now)
    }
    func importLocal(_ bytes: Data, operation: InstallationOperation, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.importLocal(bytes, operation: operation, expectedSelectionGeneration: expectedSelectionGeneration)
    }
    func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.activate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, captureConsent: captureConsent)
    }
    func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.deactivate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
    }
    func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.delete(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
    }
    func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.update(request, baseRevisionID: baseRevisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, now: now, captureConsent: captureConsent)
    }
}

/// Delays operation delivery outside durable locks; rejected operations do not alter persisted bytes.
private final class BrowserCoordinatorReceiptGate: InstallationCoordinating, @unchecked Sendable {
    private let base: InstallationCoordinator
    private let lock = NSLock()
    private let readRelease = DispatchSemaphore(value: 0), batchRelease = DispatchSemaphore(value: 0)
    private let revocationRelease = DispatchSemaphore(value: 0)
    private let deleteRelease = DispatchSemaphore(value: 0)
    private var nextRead = false, nextBatch = false, heldRead = false, heldBatch = false
    private var nextRevocation = false, heldRevocation = false, revocations = 0
    private var readError: AutomationError?
    private var cancelRead = false
    private var revocationError: AutomationError?
    private var nextDelete = false, heldDelete = false
    private var deleteError: AutomationError?
    var readIsHeld: Bool { lock.withLock { heldRead } }
    var batchReceiptIsHeld: Bool { lock.withLock { heldBatch } }
    var revocationReceiptIsHeld: Bool { lock.withLock { heldRevocation } }
    var revocationCount: Int { lock.withLock { revocations } }
    var deleteReceiptIsHeld: Bool { lock.withLock { heldDelete } }

    init(_ base: InstallationCoordinator) { self.base = base }
    func holdNextRead(error: AutomationError? = nil) {
        lock.withLock { nextRead = true; heldRead = false; readError = error; cancelRead = false }
    }
    func holdNextCancelledRead() { lock.withLock { nextRead = true; heldRead = false; readError = nil; cancelRead = true } }
    func holdNextBatchReceipt() { lock.withLock { nextBatch = true; heldBatch = false } }
    func holdNextRevocationReceipt() { lock.withLock { nextRevocation = true; heldRevocation = false } }
    func failNextRevocation(with error: AutomationError) { lock.withLock { revocationError = error } }
    func holdNextDeleteReceipt() { lock.withLock { nextDelete = true; heldDelete = false } }
    func failNextDelete(with error: AutomationError) { lock.withLock { deleteError = error } }
    func releaseRead() { readRelease.signal() }
    func releaseBatch() { batchRelease.signal() }
    func releaseRevocation() { revocationRelease.signal() }
    func releaseDelete() { deleteRelease.signal() }
    func state() throws -> InstallationState {
        let gate: (Bool, AutomationError?, Bool) = lock.withLock {
            let result = (nextRead, readError, cancelRead)
            nextRead = false; readError = nil; cancelRead = false
            return result
        }
        let state = try base.state()
        if gate.0 {
            lock.withLock { heldRead = true }
            readRelease.wait()
            if gate.2 { throw CancellationError() }
            if let error = gate.1 { throw error }
        }
        return state
    }
    func batch(_ requests: [InstallationRequest], expectedSelectionGeneration: UUID, now: Date) throws -> InstallationState {
        let shouldHold = lock.withLock { let result = nextBatch; nextBatch = false; return result }
        let state = try base.batch(requests, expectedSelectionGeneration: expectedSelectionGeneration, now: now)
        if shouldHold { lock.withLock { heldBatch = true }; batchRelease.wait() }
        return state
    }
    func importLocal(_ bytes: Data, operation: InstallationOperation, expectedSelectionGeneration: UUID) throws -> InstallationState {
        try base.importLocal(bytes, operation: operation, expectedSelectionGeneration: expectedSelectionGeneration)
    }
    func activate(revisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.activate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, captureConsent: captureConsent)
    }
    func deactivate(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        let gate: (Bool, AutomationError?) = lock.withLock {
            revocations += 1
            let result = (nextRevocation, revocationError)
            nextRevocation = false; revocationError = nil
            return result
        }
        if let error = gate.1 {
            if gate.0 { lock.withLock { heldRevocation = true }; revocationRelease.wait() }
            throw error
        }
        let state = try base.deactivate(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
        if gate.0 { lock.withLock { heldRevocation = true }; revocationRelease.wait() }
        return state
    }
    func delete(revisionID: String, expectedSelectionGeneration: UUID) throws -> InstallationState {
        let gate: (Bool, AutomationError?) = lock.withLock {
            let result = (nextDelete, deleteError)
            nextDelete = false; deleteError = nil
            return result
        }
        if let error = gate.1 {
            if gate.0 { lock.withLock { heldDelete = true }; deleteRelease.wait() }
            throw error
        }
        let state = try base.delete(revisionID: revisionID, expectedSelectionGeneration: expectedSelectionGeneration)
        if gate.0 { lock.withLock { heldDelete = true }; deleteRelease.wait() }
        return state
    }
    func update(_ request: InstallationRequest, baseRevisionID: String, expectedSelectionGeneration: UUID, approval: InstallationApproval?, now: Date, captureConsent: @Sendable () -> Bool) throws -> InstallationState {
        try base.update(request, baseRevisionID: baseRevisionID, expectedSelectionGeneration: expectedSelectionGeneration, approval: approval, now: now, captureConsent: captureConsent)
    }
}

@MainActor
private final class BrowserAsyncMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isHeld = false
    func hold() async {
        await withCheckedContinuation { continuation = $0; isHeld = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class BrowserRecoveryPreviewGate: RepositoryFetching, @unchecked Sendable {
    private let base: FakeRepositoryClient
    private let gate: BrowserAsyncMutationGate

    init(base: FakeRepositoryClient, gate: BrowserAsyncMutationGate) {
        self.base = base; self.gate = gate
    }

    func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot {
        let snapshot = try await base.preview(url: url, now: now)
        await gate.hold()
        return snapshot
    }

    func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage {
        try await base.fetchPackage(entry: entry, from: snapshot)
    }
}
