import AutomationCore
import SwiftData
import XCTest
@testable import Interceptor

@MainActor
final class PackageCatalogDatabaseTests: XCTestCase {
    private var directories: [URL] = []
    private let now = AutomationFixtures.now

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    // MARK: Fixtures

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("package-catalog-\(UUID().uuidString)")
        directories.append(url)
        return url
    }

    private func authority() -> AutomationStore {
        AutomationStore(fileURL: directory().appendingPathComponent("catalog.json"))
    }

    /// Validated package with optional display metadata added to the manifest.
    private func package(_ name: String, id: UUID = UUID(), author: String? = nil, summary: String? = nil,
                         category: String? = nil) throws -> PluginPackage
    {
        var root = try JSONValue(parsing: AutomationTemplate.packageBytes(name: name, id: id)).objectValue!
        var manifest = root["manifest"]!.objectValue!
        if let author { manifest["author"] = .string(author) }
        if let summary { manifest["summary"] = .string(summary) }
        if let category { manifest["category"] = .string(category) }
        root["manifest"] = .object(manifest)
        return try PluginPackage.validate(JSONValue.object(root).data())
    }

    private func snapshot(_ urlString: String = "https://plugins.example.com/repository.json",
                          repository: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                          sequence: Int64 = 1, packages: [PluginPackage], indexMetadata: Bool = true) throws -> VerifiedSnapshot
    {
        let entries: [JSONValue] = packages.map { p in
            var fields = AutomationFixtures.entry(for: p).objectValue!
            if indexMetadata {
                if let a = p.manifest.author { fields["author"] = .string(a) }
                if let s = p.manifest.summary { fields["summary"] = .string(s) }
                if let c = p.manifest.category { fields["category"] = .string(c) }
            }
            return .object(fields)
        }
        let index: JSONValue = .object([
            "schemaVersion": .integer(1), "id": .string(repository.uuidString), "name": .string("Repo"), "sequence": .integer(sequence),
            "issuedAt": .string(AutomationFixtures.iso(now.addingTimeInterval(-60))),
            "expiresAt": .string(AutomationFixtures.iso(now.addingTimeInterval(86_400))),
            "plugins": .array(entries),
        ])
        let envelope = JSONValue.object(["schemaVersion": .integer(1), "payload": .string(try index.data().base64EncodedString())])
        return try RepositoryEnvelope.verify(envelope: envelope.data(), url: RepositoryURL(parsing: urlString), now: now)
    }

    private func accept(_ snapshot: VerifiedSnapshot, in store: AutomationStore) async throws -> RepositoryRecord {
        try await store.accept(snapshot, acknowledgeUnverified: true, now: now)
    }

    private func staged(_ db: PackageCatalogDatabase, _ snapshot: VerifiedSnapshot, _ packages: [PluginPackage],
                        lease: UUID = UUID()) async throws
    {
        try await db.stage(snapshot, packages: packages, leaseID: lease)
    }

    private func names(_ rows: [PackageCatalogRow]) -> [String] { rows.map(\.name) }

    private func rows(_ db: PackageCatalogDatabase, _ records: [RepositoryRecord], installed: [InstalledRevision] = [],
                      query: String = "", source: String? = nil, category: PackageCatalogCategoryFilter = .all) throws -> [PackageCatalogRow]
    {
        try db.rows(visible: records, installed: installed, query: query, source: source, category: category)
    }

    // MARK: Persistence and offline

    func testCompletedCatalogSurvivesRestartAndServesDetailOffline() async throws {
        let dir = directory().appendingPathComponent("db")
        let a = try package("Alpha", author: "Ann", summary: "First", category: "Tools")
        let multi = try AutomationFixtures.multiFilePackage(name: "Multi")
        let snap = try snapshot(packages: [a, multi])
        let record = try await accept(snap, in: authority())
        let lease = UUID()

        var db: PackageCatalogDatabase? = try PackageCatalogDatabase(url: dir)
        try await db!.stage(snap, packages: [a, multi], leaseID: lease)
        try await db!.synchronize(visible: [record], installed: [], receipt: 1)
        try await db!.finish(leaseID: lease, visible: [record])
        db = nil

        let reopened = try PackageCatalogDatabase(url: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.storeURL.path))
        XCTAssertTrue(try reopened.isComplete(snap))
        XCTAssertEqual(names(try rows(reopened, [record])), ["Alpha", "Multi"])
        XCTAssertTrue(try rows(reopened, [record]).allSatisfy(\.complete))

        let detail = try XCTUnwrap(try reopened.detail(in: record, entryID: a.manifest.id))
        XCTAssertTrue(detail.isComplete)
        XCTAssertEqual(detail, PluginPackagePresentation(a))
        XCTAssertEqual(detail.manifest.author, "Ann")
        XCTAssertEqual(detail.sourceFiles, a.sourceFiles)

        let multiDetail = try XCTUnwrap(try reopened.detail(in: record, entryID: multi.manifest.id))
        XCTAssertEqual(multiDetail, PluginPackagePresentation(multi))
        XCTAssertEqual(multiDetail.sourceFileNames, multi.sourceFiles.keys.sorted())
        XCTAssertEqual(multiDetail.rulesByFile.count, 2)

        let entry = try XCTUnwrap(snap.index.plugins.first { $0.id == a.manifest.id })
        XCTAssertEqual(try reopened.packageBytes(in: record, entry: entry), a.bytes)
        XCTAssertEqual(try reopened.reusableBytes(sha256: a.revision), a.bytes)
    }

    func testIndexOnlySeedIsOfflineFinitePartialAndHasNoBytes() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let p = try package("Seeded", author: "Sam", category: "Tools")
        let snap = try snapshot(packages: [p])
        let record = try await accept(snap, in: authority())

        try await db.synchronize(visible: [record], installed: [], receipt: 1)
        let list = try rows(db, [record])
        XCTAssertEqual(names(list), ["Seeded"])
        XCTAssertFalse(list[0].complete)
        let detail = try XCTUnwrap(try db.detail(in: record, entryID: p.manifest.id))
        XCTAssertFalse(detail.isComplete)
        XCTAssertEqual(detail.manifest.name, "Seeded")
        XCTAssertEqual(detail.manifest.author, "Sam")
        XCTAssertTrue(detail.sourceFiles.isEmpty)
        XCTAssertEqual(detail.manifestJSON, "")
        XCTAssertFalse(try db.isComplete(snap))
        XCTAssertNil(try db.packageBytes(in: record, entry: snap.index.plugins[0]))
    }

    func testSynchronizeCompletesRowsFromInstalledBytesWithoutDownload() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let p = try package("Installed")
        let snap = try snapshot(packages: [p])
        let authority = authority()
        let record = try await accept(snap, in: authority)
        let revision = try await authority.install(p, from: snap, expectedGeneration: record.generation, now: now)

        try await db.synchronize(visible: [record], installed: [revision], receipt: 1)
        XCTAssertTrue(try rows(db, [record], installed: [revision])[0].complete)
        XCTAssertEqual(try db.reusableBytes(sha256: p.revision), p.bytes)
        XCTAssertTrue(try db.isComplete(snap))
    }

    // MARK: Source scope

    func testSameUUIDInTwoSourcesStaysTwoRowsAndIsScoped() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let id = UUID()
        let one = try package("Shared One", id: id), two = try package("Shared Two", id: id)
        let snapA = try snapshot("https://a.example.com/repository.json",
                                 repository: UUID(uuidString: "AAAAAAAA-1111-4111-8111-111111111111")!, packages: [one])
        let snapB = try snapshot("https://b.example.com/repository.json",
                                 repository: UUID(uuidString: "BBBBBBBB-1111-4111-8111-111111111111")!, packages: [two])
        let store = authority()
        let a = try await accept(snapA, in: store), b = try await accept(snapB, in: store)
        try await staged(db, snapA, [one]); try await staged(db, snapB, [two])
        try await db.synchronize(visible: [a, b], installed: [], receipt: 1)

        XCTAssertEqual(names(try rows(db, [a, b])), ["Shared One", "Shared Two"])
        XCTAssertEqual(names(try rows(db, [a, b], source: snapB.url.canonical)), ["Shared Two"])
        XCTAssertEqual(try db.detail(in: a, entryID: id)?.manifest.name, "Shared One")
        XCTAssertEqual(try db.detail(in: b, entryID: id)?.manifest.name, "Shared Two")
        XCTAssertEqual(names(try rows(db, [b])), ["Shared Two"], "A source that is not visible must not leak")
    }

    func testStaleSnapshotIsNotQueryableAfterRefresh() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let old = try package("Old"), new = try package("New")
        let first = try snapshot(sequence: 1, packages: [old])
        let second = try snapshot(sequence: 2, packages: [new])
        let store = authority()
        let r1 = try await accept(first, in: store)
        try await staged(db, first, [old])
        try await db.synchronize(visible: [r1], installed: [], receipt: 1)
        try await staged(db, second, [new])
        // Use the same protocol witness as the controller, rather than the fail-closed default overload.
        let sourceStore: any AutomationStoring = store
        let r2 = try await sourceStore.refresh(second, expectedGeneration: r1.generation, acknowledgeUnverified: true, now: now)
        try await db.synchronize(visible: [r2], installed: [], receipt: 2)

        XCTAssertEqual(names(try rows(db, [r2])), ["New"])
        XCTAssertNil(try db.detail(in: r2, entryID: old.manifest.id))
        XCTAssertEqual(names(try rows(db, [r1])), ["Old"], "The old accepted record still addresses its own snapshot")
        XCTAssertFalse(try rows(db, [r2]).contains { $0.name == "Old" })
    }

    // MARK: Search, order, categories

    func testSearchMatchesCaseDiacriticWidthJapaneseAndLiteralWildcards() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let packages = [try package("Café Tool", author: "Zoë"), try package("ＡＢＣ Wide"), try package("日本語プラグイン", summary: "テスト"),
                        try package("100% Pure"), try package("snake_case"), try package("Plain")]
        let snap = try snapshot(packages: packages)
        let record = try await accept(snap, in: authority())
        try await staged(db, snap, packages)
        try await db.synchronize(visible: [record], installed: [], receipt: 1)

        func found(_ query: String) throws -> [String] { names(try rows(db, [record], query: query)).sorted() }
        XCTAssertEqual(try found("CAFE"), ["Café Tool"])
        XCTAssertEqual(try found("café"), ["Café Tool"])
        XCTAssertEqual(try found("zoe"), ["Café Tool"])
        XCTAssertEqual(try found("abc"), ["ＡＢＣ Wide"])
        XCTAssertEqual(try found("ＰＬＡＩＮ"), ["Plain"])
        XCTAssertEqual(try found("日本語"), ["日本語プラグイン"])
        XCTAssertEqual(try found("テスト"), ["日本語プラグイン"])
        XCTAssertEqual(try found("%"), ["100% Pure"])
        XCTAssertEqual(try found("_"), ["snake_case"])
        XCTAssertEqual(try found("  plain  "), ["Plain"])
        XCTAssertEqual(try found("").count, 6)
        XCTAssertEqual(try found("no such package"), [])
    }

    func testNativeLocalizedStandardParityForFoldedQueries() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let names = ["Café Tool", "ＡＢＣ Wide", "日本語プラグイン", "Plain Résumé", "naïve"]
        let packages = try names.map { try package($0) }
        let snap = try snapshot(packages: packages)
        let record = try await accept(snap, in: authority())
        try await staged(db, snap, packages)
        try await db.synchronize(visible: [record], installed: [], receipt: 1)
        // Width folding is intentionally broader than Foundation localizedStandardContains.
        XCTAssertEqual(try self.names(rows(db, [record], query: "ABC")), ["ＡＢＣ Wide"])
        for query in ["cafe", "日本", "resume", "NAIVE", "tool", "x"] {
            let native = names.filter { $0.localizedStandardContains(query) }.sorted()
            XCTAssertEqual(try self.names(rows(db, [record], query: query)).sorted(), native, "query \(query)")
        }
    }

    func testNaturalNameOrderAndStableTieBreak() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let packages = [try package("Plugin 10"), try package("Plugin 2"), try package("plugin 1"), try package("Beta"), try package("Alpha")]
        let snap = try snapshot(packages: packages)
        let record = try await accept(snap, in: authority())
        try await staged(db, snap, packages)
        try await db.synchronize(visible: [record], installed: [], receipt: 1)
        XCTAssertEqual(names(try rows(db, [record])), ["Alpha", "Beta", "plugin 1", "Plugin 2", "Plugin 10"])
        let native = ["Alpha", "Beta", "plugin 1", "Plugin 2", "Plugin 10"].sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(names(try rows(db, [record])), native)
    }

    func testCategoryMembershipCountsAndFilters() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let packages = [try package("A", category: "Tools"), try package("B", category: "Tools"),
                        try package("C", category: "Games"), try package("D")]
        let snap = try snapshot(packages: packages)
        let record = try await accept(snap, in: authority())
        try await staged(db, snap, packages)
        try await db.synchronize(visible: [record], installed: [], receipt: 1)

        XCTAssertEqual(try db.categories(in: record),
                       [PackageCatalogCategory(name: "Games", count: 1), PackageCatalogCategory(name: "Tools", count: 2),
                        PackageCatalogCategory(name: nil, count: 1)])
        XCTAssertEqual(names(try rows(db, [record], source: snap.url.canonical, category: .category("Tools"))), ["A", "B"])
        XCTAssertEqual(names(try rows(db, [record], category: .category(nil))), ["D"])
        XCTAssertEqual(names(try rows(db, [record], query: "b", category: .category("Tools"))), ["B"])
    }

    // MARK: Installed projection

    func testInstalledMetadataHasPriorityAndOrphansStayGlobalOnly() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        // The index omits author/summary; the installed manifest carries them, so installed wins and matches search.
        let p = try package("Beta Tool", author: "Local Author", summary: "Local summary")
        let plain = try package("Gamma")
        let snap = try snapshot(packages: [p, plain], indexMetadata: false)
        let store = authority()
        let record = try await accept(snap, in: store)
        let revision = try await store.install(p, from: snap, expectedGeneration: record.generation, now: now)
        try await staged(db, snap, [p, plain])

        try await db.synchronize(visible: [record], installed: [], receipt: 1)
        XCTAssertEqual(names(try rows(db, [record], query: "Local Author")), [], "Not installed: index metadata only")

        try await db.synchronize(visible: [record], installed: [revision], receipt: 2)
        let hit = try rows(db, [record], installed: [revision], query: "local author")
        XCTAssertEqual(names(hit), ["Beta Tool"])
        XCTAssertEqual(hit.first?.author, "Local Author")
        XCTAssertEqual(hit.first?.summary, "Local summary")
        XCTAssertNil(try rows(db, [record], installed: [revision], query: "gamma").first?.author)

        // Source removed: the installed repository package survives as a global orphan only.
        try await store.remove(snap.url)
        let catalog = try await store.load()
        let hidden = catalog.repositories
        XCTAssertTrue(hidden.allSatisfy { !$0.visible })
        try await db.synchronize(visible: [], installed: catalog.revisions, receipt: 3)
        let orphans = try rows(db, [], installed: catalog.revisions)
        XCTAssertEqual(names(orphans), ["Beta Tool"])
        XCTAssertEqual(orphans.first?.source, snap.url.canonical)
        XCTAssertEqual(orphans.first?.manifestID, p.manifest.id)
        XCTAssertEqual(names(try rows(db, [], installed: catalog.revisions, source: snap.url.canonical)), [], "Orphans are global only")
    }

    func testStaleProjectionNeverLeaksOldInstalledSelection() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let p = try package("Beta Tool", author: "Local Author")
        let snap = try snapshot(packages: [p], indexMetadata: false)
        let store = authority()
        let record = try await accept(snap, in: store)
        let revision = try await store.install(p, from: snap, expectedGeneration: record.generation, now: now)
        try await staged(db, snap, [p])
        try await db.synchronize(visible: [record], installed: [revision], receipt: 1)

        // A stale projection is hidden. Only synchronize materializes a new selection; reads never repair it.
        let list = try rows(db, [record], installed: [], query: "local author")
        XCTAssertEqual(names(list), [])
        XCTAssertTrue(try rows(db, [record], installed: []).isEmpty)
        try await db.synchronize(visible: [record], installed: [], receipt: 2)
        XCTAssertEqual(names(try rows(db, [record], installed: [])), ["Beta Tool"])
        XCTAssertNil(try rows(db, [record], installed: []).first?.author)
        // A stale orphan row must not surface when its revision is no longer selected.
        XCTAssertEqual(names(try rows(db, [], installed: [])), [])
    }

    func testStaleSynchronizeReceiptIsIgnored() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let p = try package("Receipts"), q = try package("Other")
        let first = try snapshot("https://one.example.com/repository.json", packages: [p])
        let second = try snapshot("https://two.example.com/repository.json", packages: [q])
        let store = authority()
        let a = try await accept(first, in: store), b = try await accept(second, in: store)

        try await db.synchronize(visible: [a, b], installed: [], receipt: 5)
        try await db.synchronize(visible: [a], installed: [], receipt: 4)   // older: ignored
        try await db.synchronize(visible: [a, b], installed: [], receipt: 5) // same receipt is applied
        XCTAssertEqual(names(try rows(db, [a, b])), ["Other", "Receipts"])
        try await db.finish(leaseID: UUID(), visible: [a, b])
        XCTAssertEqual(names(try rows(db, [a, b])), ["Other", "Receipts"])
    }

    // MARK: Staging, rollback and pruning

    func testStageRejectsMismatchAndWritesNothing() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let good = try package("Good"), other = try package("Other")
        let snap = try snapshot(packages: [good, other])
        let record = try await accept(snap, in: authority())
        let replaced = try package("Other", id: other.manifest.id, summary: "changed")   // different bytes, same id/name

        for bad in [[good], [good, replaced], [good, good]] {
            do {
                try await staged(db, snap, bad)
                XCTFail("Expected a rejected stage")
            } catch { XCTAssertTrue(error is PackageCatalogError) }
        }
        XCTAssertFalse(try db.isComplete(snap))
        XCTAssertNil(try db.reusableBytes(sha256: good.revision), "A rejected stage must not leave the valid sibling behind")
        XCTAssertEqual(names(try rows(db, [record])), [])
    }

    func testFinishPrunesUnreferencedSnapshotsButKeepsVisibleAndLeasedStages() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let kept = try package("Kept"), leased = try package("Leased"), gone = try package("Gone")
        let keptSnap = try snapshot("https://kept.example.com/repository.json", packages: [kept])
        let leasedSnap = try snapshot("https://leased.example.com/repository.json", packages: [leased])
        let goneSnap = try snapshot("https://gone.example.com/repository.json", packages: [gone])
        let record = try await accept(keptSnap, in: authority())

        let mine = UUID(), concurrent = UUID()
        try await staged(db, keptSnap, [kept], lease: mine)
        try await staged(db, goneSnap, [gone], lease: mine)
        try await staged(db, leasedSnap, [leased], lease: concurrent)
        try await db.finish(leaseID: mine, visible: [record])

        XCTAssertTrue(try db.isComplete(keptSnap))
        XCTAssertTrue(try db.isComplete(leasedSnap), "Another owner's unexpired stage survives")
        XCTAssertFalse(try db.isComplete(goneSnap))
        XCTAssertNil(try db.reusableBytes(sha256: gone.revision))
        XCTAssertEqual(try db.reusableBytes(sha256: kept.revision), kept.bytes)

        try await db.finish(leaseID: concurrent, visible: [record])
        XCTAssertFalse(try db.isComplete(leasedSnap))
        XCTAssertNil(try db.reusableBytes(sha256: leased.revision))
    }

    func testDelayedCleanupCannotPruneANewerPublishedSnapshot() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let first = try package("Earlier"), latest = try package("Latest")
        let a = try snapshot(sequence: 1, packages: [first])
        let b = try snapshot(sequence: 2, packages: [latest])
        let store = authority(), leaseA = UUID(), leaseB = UUID()
        try await staged(db, a, [first], lease: leaseA)
        let original = try await accept(a, in: store)
        try await db.synchronize(visible: [original], installed: [], receipt: 1)
        try await staged(db, b, [latest], lease: leaseB)
        let sourceStore: any AutomationStoring = store
        let current = try await sourceStore.refresh(b, expectedGeneration: original.generation, acknowledgeUnverified: false, now: now)
        try await db.synchronize(visible: [current], installed: [], receipt: 2)
        try await db.finish(leaseID: leaseB, visible: [current])
        try await db.finish(leaseID: leaseA, visible: [original])
        XCTAssertTrue(try db.isComplete(b))
        XCTAssertEqual(try db.detail(in: current, entryID: latest.manifest.id), PluginPackagePresentation(latest))
        XCTAssertEqual(try db.reusableBytes(sha256: latest.revision), latest.bytes)
    }

    func testLivePublisherKeepsContentAfterLeaseExpiryUntilExplicitFinish() async throws {
        let clock = LockedDate(now)
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true, now: { clock.value }, leaseDuration: 60)
        let p = try package("Suspended publisher")
        let snap = try snapshot(packages: [p])
        let owner = UUID()
        try await staged(db, snap, [p], lease: owner)
        clock.value = now.addingTimeInterval(120)
        try await db.finish(leaseID: UUID(), visible: [])
        XCTAssertTrue(try db.isComplete(snap), "A live publisher may resume after suspension")
        XCTAssertEqual(try db.reusableBytes(sha256: p.revision), p.bytes)
        try await db.finish(leaseID: owner, visible: [])
        XCTAssertFalse(try db.isComplete(snap))
    }

    func testExpiredAbandonedLeaseIsPrunedAfterReopen() async throws {
        let clock = LockedDate(now)
        let dir = directory()
        let p = try package("Abandoned")
        let snap = try snapshot(packages: [p])
        do {
            let db = try PackageCatalogDatabase(url: dir, now: { clock.value }, leaseDuration: 60)
            try await staged(db, snap, [p], lease: UUID())
        }
        let reopened = try PackageCatalogDatabase(url: dir, now: { clock.value }, leaseDuration: 60)
        try await reopened.finish(leaseID: UUID(), visible: [])
        XCTAssertTrue(try reopened.isComplete(snap), "An unexpired persisted lease remains protected")
        clock.value = now.addingTimeInterval(120)
        try await reopened.finish(leaseID: UUID(), visible: [])
        XCTAssertFalse(try reopened.isComplete(snap))
        XCTAssertNil(try reopened.reusableBytes(sha256: p.revision))
    }

    func testContentIsSharedBySHA256AcrossSources() async throws {
        let dir = directory()
        let db = try PackageCatalogDatabase(url: dir, inMemory: true)
        let p = try package("Shared Bytes")
        let a = try snapshot("https://a.example.com/repository.json", packages: [p])
        let b = try snapshot("https://b.example.com/repository.json", packages: [p])
        let store = authority()
        let ra = try await accept(a, in: store), rb = try await accept(b, in: store)
        let leaseA = UUID(), leaseB = UUID()
        try await staged(db, a, [p], lease: leaseA); try await staged(db, b, [p], lease: leaseB)
        try await db.finish(leaseID: leaseA, visible: [ra, rb])
        try await db.finish(leaseID: leaseB, visible: [ra, rb])
        XCTAssertEqual(try db.reusableBytes(sha256: p.revision), p.bytes)

        try await store.remove(a.url)
        try await db.synchronize(visible: [rb], installed: [], receipt: 1)
        try await db.finish(leaseID: UUID(), visible: [rb])
        XCTAssertEqual(try db.reusableBytes(sha256: p.revision), p.bytes, "Still referenced by the other source")
        XCTAssertFalse(try db.isComplete(a))
        XCTAssertTrue(try db.isComplete(b))
    }

    func testStageRejectsMoreThanTheIndexLimit() async throws {
        let db = try PackageCatalogDatabase(url: directory(), inMemory: true)
        let p = try package("Only")
        let snap = try snapshot(packages: [p])
        let extra = try (0..<Limits.plugins).map { try package("Extra \($0)") }
        do {
            try await staged(db, snap, [p] + extra)
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? PackageCatalogError, .invalidSnapshot) }
    }

    // MARK: Incomplete migration

    func testIncompleteUpgradeKeepsKnownMetadataUntilBackfilled() async throws {
        let dir = directory().appendingPathComponent("db")
        let a = try package("Alpha", category: "Tools"), b = try package("Beta")
        let snap = try snapshot(packages: [a, b])
        let record = try await accept(snap, in: authority())

        var db: PackageCatalogDatabase? = try PackageCatalogDatabase(url: dir)
        try await db!.synchronize(visible: [record], installed: [], receipt: 1)
        db = nil

        let reopened = try PackageCatalogDatabase(url: dir)
        XCTAssertEqual(names(try rows(reopened, [record])), ["Alpha", "Beta"])
        XCTAssertTrue(try rows(reopened, [record]).allSatisfy { !$0.complete })
        XCTAssertFalse(try reopened.isComplete(snap))

        // A complete source is backfilled atomically; partial stages are rejected.
        let partial = try snapshot(packages: [a, b])
        XCTAssertEqual(partial.payloadDigest, snap.payloadDigest)
        try await reopened.stage(snap, packages: [a, b], leaseID: UUID())
        try await reopened.synchronize(visible: [record], installed: [], receipt: 2)
        XCTAssertTrue(try reopened.isComplete(snap))
        XCTAssertTrue(try rows(reopened, [record]).allSatisfy(\.complete))
    }

    func testValidatedStageRepairsCorruptBytesAndTypedDetail() async throws {
        try await verifyCorruptionRepair(usingInstalled: false)
    }

    func testSelectedInstalledBytesRepairCorruptProjectionOffline() async throws {
        try await verifyCorruptionRepair(usingInstalled: true)
    }

    private func verifyCorruptionRepair(usingInstalled: Bool) async throws {
        let dir = directory().appendingPathComponent("db")
        let p = try AutomationFixtures.multiFilePackage(name: "Repair")
        let snap = try snapshot(packages: [p])
        let store = authority()
        let record = try await accept(snap, in: store)
        let installed = usingInstalled ? [try await store.install(p, from: snap, expectedGeneration: record.generation, now: now)] : []
        do {
            let db = try PackageCatalogDatabase(url: dir)
            try await staged(db, snap, [p])
        }
        // Simulate on-disk corruption without changing the trusted source or package digest.
        do {
            let schema = Schema(versionedSchema: PackageCatalogSchemaV1.self)
            let config = ModelConfiguration("PackageCatalog", schema: schema,
                url: dir.appendingPathComponent(PackageCatalogDatabase.storeName), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: PackageCatalogMigrationPlan.self, configurations: config)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let raw = try XCTUnwrap(context.fetch(FetchDescriptor<CatalogContentModel>()).first)
            raw.bytes = Data("corrupt".utf8)
            let detail = try XCTUnwrap(context.fetch(FetchDescriptor<CatalogDetailModel>()).first)
            detail.filesData = Data("invalid JSON".utf8)
            detail.rulesData = Data("invalid JSON".utf8)
            try context.save()
        }
        let reopened = try PackageCatalogDatabase(url: dir)
        XCTAssertNil(try reopened.packageBytes(in: record, entry: snap.index.plugins[0]))
        XCTAssertThrowsError(try reopened.detail(in: record, entryID: p.manifest.id))
        if usingInstalled {
            try await reopened.synchronize(visible: [record], installed: installed, receipt: 1)
        } else {
            try await staged(reopened, snap, [p])
        }
        XCTAssertEqual(try reopened.packageBytes(in: record, entry: snap.index.plugins[0]), p.bytes)
        XCTAssertEqual(try reopened.detail(in: record, entryID: p.manifest.id), PluginPackagePresentation(p))
    }

    func testStoreIsSeparateAndNeverResetOnReopen() async throws {
        let dir = directory().appendingPathComponent("db")
        let p = try package("Durable")
        let snap = try snapshot(packages: [p])
        let record = try await accept(snap, in: authority())
        do {
            let db = try PackageCatalogDatabase(url: dir)
            try await db.stage(snap, packages: [p], leaseID: UUID())
            XCTAssertEqual(db.storeURL.lastPathComponent, "packages.store")
        }
        for _ in 0..<2 {
            let db = try PackageCatalogDatabase(url: dir)
            XCTAssertTrue(try db.isComplete(snap))
            _ = try rows(db, [record])
        }
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}
