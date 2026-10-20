import XCTest

/// Browser tests use real HTTPS package bytes. The wrapper proves ownership before the app launches.
final class AutomationUITests: XCTestCase {
    private static let multiID = "65153731-6449-4BFC-B2F6-3A3350927DB8"
    private static let summaryID = "57414817-0F72-40BA-A27C-535B784BEE01"
    private static let limitsID = "03447CB7-1DB8-4D4C-9012-00846EB052F3"
    private static let targetsID = "E9472B70-2DB2-4F4C-A291-33F5FEF88519"
    private static let multiRevision = "6f007a8e930949b7e0094b59b17cbfb82128eaf196156edd9901495f543440fa"

    @MainActor
    private func launch(japanese: Bool, suite: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["INTERCEPTOR_TEST_AUTOMATION_STORE"] = suite
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch()
        return app
    }

    /// Retains the CI method name; packages now come from the run-owned repository rather than Create Example.
    @MainActor
    func testCreateViewRunAndReopenPersistsInEnglishAndJapanese() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            let suite = "Interceptor.UITests.\(UUID().uuidString)"
            let app = launch(japanese: japanese, suite: suite)
            openPlugins(app, japanese: japanese)
            if !japanese { attach("Dedicated browser Sources en") }
            addRepository(repositoryURL, app: app)
            goBack(app, from: "Local repository fixture")
            reach(app.buttons.matching(identifier: "plugins.repo.Local repository fixture").firstMatch, in: scrollContainer(app, "plugins.sources")).tap()
            XCTAssertTrue(scrollContainer(app, "plugins.categories").waitForExistence(timeout: 5))
            if !japanese { attach("Repository categories en") }
            openCategory(app)
            openCatalogPackage(Self.multiID, app: app)
            enqueueGet(app)
            goBack(app, from: "Multi-file hooks")
            openCatalogPackage(Self.summaryID, app: app)
            enqueueGet(app)

            selectTab("packages", app: app)
            XCTAssertFalse(app.buttons.matching(identifier: "plugins.package." + Self.multiID).firstMatch.exists, "GET must not install")
            XCTAssertFalse(app.buttons.matching(identifier: "plugins.package." + Self.summaryID).firstMatch.exists)
            openQueue(app)
            XCTAssertEqual(queueRows(app).count, 2, "both immutable candidates share one confirmation")
            if !japanese { attach("Batch queue before installation en") }
            confirmQueue(app)
            selectTab("packages", app: app)
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.package." + Self.multiID).firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.package." + Self.summaryID).firstMatch.exists)
            XCTAssertEqual(app.buttons.matching(identifier: "plugins.package." + Self.multiID).firstMatch.value as? String, japanese ? "インストール済み" : "Installed")
            if !japanese { attach("Installed package list en") }
            openInstalled(Self.multiID, app: app)
            assertEnabled(false, app: app)
            XCTAssertEqual(app.buttons.matching(identifier: "plugins.package.hero.action").firstMatch.label, japanese ? "管理" : "Modify")
            if japanese { attach("Selected package installed disabled ja") }
            app.terminate()

            let reopened = launch(japanese: japanese, suite: suite)
            openPlugins(reopened, japanese: japanese)
            selectTab("packages", app: reopened)
            XCTAssertEqual(reopened.buttons.matching(identifier: "plugins.package." + Self.multiID).count, 1)
            XCTAssertEqual(reopened.buttons.matching(identifier: "plugins.package." + Self.summaryID).count, 1)
            openInstalled(Self.multiID, app: reopened)
            assertEnabled(false, app: reopened)
            let version = reopened.staticTexts["plugins.package.version"].label
            let versionTitle = japanese ? "バージョン" : "Version"
            let combinedVersion = japanese ? "\(versionTitle)、1.0.0" : "\(versionTitle), 1.0.0"
            XCTAssertTrue(["1.0.0", combinedVersion].contains(version), "The selected version must remain exactly 1.0.0: \(version)")
            reopened.terminate()
        }
    }

    @MainActor
    func testFourHookDryRunAndExplicitApproval() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        XCUIDevice.shared.orientation = .portrait
        for japanese in [false, true] {
            let app = launch(japanese: japanese, suite: "Interceptor.UITests.\(UUID().uuidString)")
            defer { app.terminate() }
            installMulti(repositoryURL, app: app, japanese: japanese)
            tapEnabled(app)
            let approval = scrollContainer(app, "plugins.approval.form")
            XCTAssertTrue(approval.waitForExistence(timeout: 5))
            let revision = reach(app.textViews["plugins.approval.revision"], in: approval, attempts: 30)
            XCTAssertEqual(revision.value as? String, Self.multiRevision, "approval binds exact installed bytes")
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.approval.confirm").firstMatch.isHittable)
            app.buttons.matching(identifier: "plugins.approval.cancel").firstMatch.tap()
            XCTAssertTrue(approval.waitForNonExistence(timeout: 5))
            assertEnabled(false, app: app)
            tapEnabled(app)
            XCTAssertTrue(approval.waitForExistence(timeout: 5))
            if japanese { attach("Exact revision grant approval ja") }
            app.buttons.matching(identifier: "plugins.approval.confirm").firstMatch.tap()
            XCTAssertTrue(approval.waitForNonExistence(timeout: 5))
            assertEnabled(true, app: app)
            tapEnabled(app)
            assertEnabled(false, app: app)

            openPackageTest(app)
            XCTAssertFalse(app.buttons.matching(identifier: "script.activate").firstMatch.exists, "Test has its own task, separate from grants")
            XCTAssertFalse(app.buttons.matching(identifier: "script.openSource").firstMatch.exists)
            let form = scrollContainer(app, "script.form")
            for phase in ["request.onEnter", "request.onLeave", "response.onEnter", "response.onLeave"] {
                reach(app.buttons.matching(identifier: "script.hook").firstMatch, in: form).tap()
                let choice = app.buttons.matching(identifier: phase).firstMatch
                XCTAssertTrue(choice.waitForExistence(timeout: 5))
                choice.tap()
                let run = app.buttons.matching(identifier: "script.run").firstMatch
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in run.isHittable && run.isEnabled }, object: nil)
                let settled = XCTWaiter.wait(for: [ready], timeout: 5)
                if settled != .completed { attachDiagnostic("Run after Hook selection", app: app, detail: phase) }
                XCTAssertEqual(settled, .completed, "Run stays at the bottom of the Test screen")
                run.tap()
                let expectsMutation = phase == "request.onEnter"
                if !expectsMutation {
                    let alert = app.alerts.firstMatch
                    XCTAssertTrue(alert.waitForExistence(timeout: 5))
                    XCTAssertEqual(alert.label, japanese ? "テスト完了" : "Test completed")
                    alert.buttons.matching(identifier: "OK").firstMatch.tap()
                    XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
                }
                let validated = app.staticTexts["script.validated"]
                XCTAssertTrue(validated.waitForExistence(timeout: 5))
                reach(validated, in: form)
                XCTAssertFalse(app.staticTexts["script.error"].exists)
                if expectsMutation {
                    let json = openSampleJSON("script.bodyPreview", app: app)
                    // The first declared route is GET /other, which executes the secondary file.
                    assertJSON(json.value as? String ?? "", equals: #"{"limit":15}"#)
                    app.buttons.matching(identifier: "script.closeJSON").firstMatch.tap()
                } else {
                    XCTAssertFalse(app.buttons.matching(identifier: "script.bodyPreview").firstMatch.exists)
                }
                if !japanese && phase == "request.onEnter" { attach("Separate package Test result en") }
            }
        }
    }

    @MainActor
    func testLargeApprovalScopeCanBeReadAndCancelled() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        XCUIDevice.shared.orientation = .portrait
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: false)
        addRepository(repositoryURL, app: app)
        openCategory(app)
        openCatalogPackage(Self.limitsID, app: app)
        enqueueGet(app)
        openQueue(app)
        confirmQueue(app)
        tapEnabled(app)
        let form = scrollContainer(app, "plugins.approval.form")
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        XCTAssertEqual(PluginRepositorySources.approvalPaths.count, 16)
        XCTAssertEqual(PluginRepositorySources.approvalReadFields.count, 64)
        attach("Large grant scope top en")
        verifyLargeApproval(app, form: form)
        XCTAssertTrue(app.buttons.matching(identifier: "plugins.approval.confirm").firstMatch.isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "plugins.approval.cancel").firstMatch.isHittable)
        attach("Large grant scope final revision en")
        app.buttons.matching(identifier: "plugins.approval.cancel").firstMatch.tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        assertEnabled(false, app: app)
    }

    @MainActor
    func testMultiFileViewingSwitchesAndReopensInEnglishAndJapanese() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        XCUIDevice.shared.orientation = .portrait
        for japanese in [false, true] {
            let suite = "Interceptor.UITests.\(UUID().uuidString)"
            let app = launch(japanese: japanese, suite: suite)
            defer { app.terminate() }
            installMulti(repositoryURL, app: app, japanese: japanese)
            selectTab("scripts", app: app)
            if !japanese { attach("Installed script files en") }
            for (file, source, path, excluded) in [
                (PluginRepositorySources.primaryFile, PluginRepositorySources.primarySource, "/synthetic", "/other"),
                (PluginRepositorySources.secondaryFile, PluginRepositorySources.secondarySource, "/other", "/synthetic"),
            ] {
                openFile(file, packageID: Self.multiID, app: app)
                let detail = scrollContainer(app, "plugins.file.detail")
                XCTAssertTrue(text(path, in: detail).exists)
                XCTAssertFalse(text(excluded, in: detail).exists, "file metadata contains only this file's rules")
                XCTAssertFalse(app.scrollViews["plugins.file.source"].exists, "source requires an explicit action")
                if !japanese && file == PluginRepositorySources.primaryFile { attach("File target metadata en") }
                let reader = openFileSource(app)
                assertSource(reader, equals: source)
                assertReadOnly(reader, app: app)
                if japanese && file == PluginRepositorySources.secondaryFile { attach("Full screen exact file source ja") }
                app.buttons.matching(identifier: "plugins.file.closeSource").firstMatch.tap()
                XCTAssertTrue(detail.waitForExistence(timeout: 5))
                XCTAssertTrue(text(path, in: detail).exists, "Done returns to the same file metadata")
                let reopened = openFileSource(app)
                assertSource(reopened, equals: source)
                app.buttons.matching(identifier: "plugins.file.closeSource").firstMatch.tap()
                goBack(app, from: (file as NSString).lastPathComponent)
            }
            app.terminate()
            let reopened = launch(japanese: japanese, suite: suite)
            openPlugins(reopened, japanese: japanese)
            selectTab("scripts", app: reopened)
            openFile(PluginRepositorySources.secondaryFile, packageID: Self.multiID, app: reopened)
            assertSource(openFileSource(reopened), equals: PluginRepositorySources.secondarySource)
            reopened.buttons.matching(identifier: "plugins.file.closeSource").firstMatch.tap()
            reopened.terminate()
        }
    }

    @MainActor
    func testJSONSamplesAreReadOnlyAndFormatted() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        installMulti(repositoryURL, app: app, japanese: false)
        reach(app.buttons.matching(identifier: "plugins.package.manifestJSON").firstMatch, in: scrollContainer(app, "plugins.package.detail")).tap()
        let manifest = app.textViews["plugins.manifest.json"]
        XCTAssertTrue(manifest.waitForExistence(timeout: 5))
        let manifestText = manifest.value as? String ?? ""
        let object = try? JSONSerialization.jsonObject(with: Data(manifestText.utf8)) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, Self.multiID)
        XCTAssertTrue(manifestText.contains("\n  "))
        assertFullScreen(manifest, app: app)
        assertReadOnly(manifest, app: app)
        attach("Full screen manifest JSON en")
        app.buttons.matching(identifier: "plugins.manifest.close").firstMatch.tap()
        XCTAssertTrue(scrollContainer(app, "plugins.package.detail").waitForExistence(timeout: 5))
        openPackageTest(app)
        attach("Sample traffic and plugin configuration en")
        let event = openSampleJSON("script.event", app: app)
        let eventText = event.value as? String ?? ""
        let sample = try? JSONSerialization.jsonObject(with: Data(eventText.utf8)) as? [String: Any]
        let request = sample?["request"] as? [String: Any]
        XCTAssertEqual(request?["host"] as? String, "example.com")
        XCTAssertEqual(request?["method"] as? String, "GET")
        XCTAssertEqual(request?["path"] as? String, "/other")
        XCTAssertTrue(eventText.contains("\n  "))
        assertReadOnly(event, app: app)
        app.buttons.matching(identifier: "script.closeJSON").firstMatch.tap()
        let config = openSampleJSON("script.config", app: app)
        assertJSON(config.value as? String ?? "", equals: #"{"settings":{},"endpoints":{}}"#)
        assertReadOnly(config, app: app)
        app.buttons.matching(identifier: "script.closeJSON").firstMatch.tap()
        app.buttons.matching(identifier: "script.run").firstMatch.tap()
        let validated = app.staticTexts["script.validated"]
        XCTAssertTrue(validated.waitForExistence(timeout: 5))
        reach(validated, in: scrollContainer(app, "script.form"))
        let result = openSampleJSON("script.bodyPreview", app: app)
        assertJSON(result.value as? String ?? "", equals: #"{"limit":15}"#)
        assertReadOnly(result, app: app)
        attach("Full screen formatted Test JSON en")
        app.buttons.matching(identifier: "script.closeJSON").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "script.bodyPreview").firstMatch.exists, "Done preserves the completed result")
        XCTAssertFalse(app.buttons.matching(identifier: "script.save").firstMatch.exists)
    }

    @MainActor
    func testAddRepositorySheetRequiresExplicitPreviewAndCancelsCleanly() async {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        let app = launch(japanese: false, suite: "Interceptor.UITests.\(UUID().uuidString)")
        defer { app.terminate() }
        openPlugins(app, japanese: false)
        openAddRepository(app)
        let url = app.textFields["repo.url"]
        XCTAssertFalse(app.buttons.matching(identifier: "repo.preview").firstMatch.isEnabled)
        XCTAssertFalse(app.buttons.matching(identifier: "repo.addUnverified").firstMatch.exists)
        url.tap()
        url.typeText("http://insecure.example.com/")
        tapWhenStable(app.buttons.matching(identifier: "repo.preview").firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["repo.error"].waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "repo.cancel").firstMatch.tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
        previewRepository(repositoryURL, app: app)
        XCTAssertTrue(app.buttons.matching(identifier: "repo.addUnverified").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "plugins.repo.Local repository fixture").firstMatch.exists, "preview must not persist a source")
        attach("Explicit repository preview before add en")
        app.buttons.matching(identifier: "repo.cancel").firstMatch.tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(identifier: "plugins.repo.Local repository fixture").firstMatch.exists)
        XCTAssertTrue(scrollContainer(app, "plugins.sources").exists)
    }

    @MainActor
    func testUnsignedRepositoryWarningAndVerifiedPackageImport() async throws {
        guard let repositoryURL = await requiredRepositoryURL() else { return }
        let browserURL = repositoryURL.deletingLastPathComponent().appendingPathComponent("browser/repository.json")
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            let app = launch(japanese: japanese, suite: "Interceptor.UITests.\(UUID().uuidString)")
            defer { app.terminate() }
            openPlugins(app, japanese: japanese)
            previewRepository(browserURL, app: app)
            let add = reach(app.buttons.matching(identifier: "repo.addUnverified").firstMatch, in: scrollContainer(app, "repo.addForm"))
            add.tap()
            let confirm = app.buttons.matching(identifier: "repo.confirmUnverified").firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            if japanese { attach("Unsigned source consequence warning ja") }
            app.buttons.matching(identifier: "repo.cancelUnverified").firstMatch.tap()
            XCTAssertTrue(add.isEnabled)
            XCTAssertEqual(app.textFields["repo.url"].value as? String, browserURL.absoluteString)
            add.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(scrollContainer(app, "plugins.categories").waitForExistence(timeout: 10))
            openCategory(app, id: "category:Requests")
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertEqual(search.placeholderValue, japanese ? "パッケージを検索" : "Search for Packages")
            search.tap()
            search.typeText("not in catalog")
            XCTAssertFalse(app.buttons.matching(identifier: "plugins.catalog.package." + Self.targetsID).firstMatch.exists)
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "not in catalog".count))
            search.typeText("Browser fixture author\n")
            let entry = app.buttons.matching(identifier: "plugins.catalog.package." + Self.targetsID).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "catalog search includes author metadata")
            XCTAssertTrue(entry.label.contains("Target hosts example"))
            XCTAssertTrue(entry.label.contains("Browser fixture author"))
            if !japanese { attach("Searchable category package metadata en") }
            entry.tap()
            XCTAssertTrue(scrollContainer(app, "plugins.package.detail").waitForExistence(timeout: 15))
            let hero = app.descendants(matching: .any)["plugins.package.hero"]
            let words = Set(hero.label.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",、"))).filter { !$0.isEmpty })
            if !words.contains("api.example.com") || !words.contains("example.com") {
                attachDiagnostic("Package target host labels", app: app, detail: "hero=\(hero.label.debugDescription), scalars=\(hero.label.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))")
            }
            XCTAssertTrue(words.contains("api.example.com"))
            XCTAssertTrue(words.contains("example.com"), "the package hero aggregates every declared host")
            XCTAssertFalse(app.scrollViews["plugins.file.source"].exists)
            if japanese { attach("Package aggregate target hosts before GET ja") }
            reach(app.buttons.matching(identifier: "plugins.package.scripts").firstMatch, in: scrollContainer(app, "plugins.package.detail")).tap()
            openFile(PluginRepositorySources.primaryFile, packageID: Self.targetsID, app: app)
            let fileDetail = scrollContainer(app, "plugins.file.detail")
            XCTAssertTrue(text("api.example.com", in: fileDetail).exists)
            XCTAssertFalse(text("example.com", in: fileDetail).exists, "a file shows only its matching rules")
            if !japanese { attach("Grouped file target conditions en") }
            goBack(app, from: "POST.js")
            goBack(app, from: "Scripts")
            enqueueGet(app)
            openQueue(app)
            confirmQueue(app)
            assertEnabled(false, app: app)
            if japanese { attach("Installed package detail reviewed ja") }
            openModify(app)
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.modify.cancel").firstMatch.waitForExistence(timeout: 5))
            if !japanese { attach("Installed package actions en") }
            app.buttons.matching(identifier: "plugins.modify.cancel").firstMatch.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.modify.cancel").firstMatch.waitForNonExistence(timeout: 5))
            openModify(app)
            app.buttons.matching(identifier: "plugins.modify.reinstall").firstMatch.tap()
            XCTAssertTrue(scrollContainer(app, "plugins.queue.items").waitForExistence(timeout: 5))
            XCTAssertEqual(queueRows(app).count, 1)
            confirmQueue(app)
            assertEnabled(false, app: app)
            selectTab("packages", app: app)
            XCTAssertEqual(app.buttons.matching(identifier: "plugins.package." + Self.targetsID).count, 1, "reinstall retains one selected family")
            if !japanese { attach("Installed package list without count en") }
            openInstalled(Self.targetsID, app: app)
            openModify(app)
            app.buttons.matching(identifier: "plugins.modify.delete").firstMatch.tap()
            let deletion = app.alerts.firstMatch
            XCTAssertTrue(deletion.waitForExistence(timeout: 5))
            deletion.buttons.matching(identifier: japanese ? "キャンセル" : "Cancel").firstMatch.tap()
            assertEnabled(false, app: app)
            openModify(app)
            app.buttons.matching(identifier: "plugins.modify.delete").firstMatch.tap()
            XCTAssertTrue(deletion.waitForExistence(timeout: 5))
            deletion.buttons.matching(identifier: japanese ? "削除" : "Delete").firstMatch.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "plugins.package." + Self.targetsID).firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(scrollContainer(app, "plugins.packages").exists)
        }
    }
}

private extension AutomationUITests {
    func requiredRepositoryURL() async -> URL? {
        guard let url = await repositoryFixtureURLIfReady() else {
            XCTFail("Run ci-plugin-repository-fixture.py around this test command on its selected disposable simulator")
            return nil
        }
        return url
    }

    /// Nonce, bytes and exact simulator identity must match the run-owned HTTPS server.
    func repositoryFixtureURLIfReady() async -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["INTERCEPTOR_REPOSITORY_FIXTURE_URL"],
              let url = URL(string: rawURL), url.scheme == "https", url.host == "localhost",
              url.path == "/repository.json", url.port != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let token = environment["INTERCEPTOR_REPOSITORY_FIXTURE_TOKEN"], UUID(uuidString: token) != nil,
              let device = environment["INTERCEPTOR_REPOSITORY_FIXTURE_DEVICE"],
              environment["SIMULATOR_UDID"]?.lowercased() == device.lowercased(),
              let digest = environment["INTERCEPTOR_REPOSITORY_FIXTURE_DIGEST"]
        else { return nil }
        let readyURL = url.deletingLastPathComponent().appendingPathComponent("__interceptor_fixture")
        var request = URLRequest(url: readyURL)
        request.timeoutInterval = 10
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["fixture"] as? String == "Interceptor Plugin Repository Fixture",
              marker["version"] as? Int == 1, marker["runToken"] as? String == token,
              marker["device"] as? String == device, marker["packageDigest"] as? String == digest
        else { return nil }
        return url
    }

    @MainActor
    func openPlugins(_ app: XCUIApplication, japanese: Bool) {
        let agree = app.buttons.matching(identifier: japanese ? "同意する" : "Agree").firstMatch
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let settings = settingsTab(app, japanese: japanese)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        reach(app.buttons.matching(identifier: "settings.plugins").firstMatch, in: app.collectionViews.firstMatch).tap()
        XCTAssertTrue(scrollContainer(app, "plugins.sources").waitForExistence(timeout: 5))
        let underlyingSettings = settingsTab(app, japanese: japanese)
        let browserPresented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "plugins.close").firstMatch.isHittable && !underlyingSettings.isHittable
        }, object: nil)
        let presented = XCTWaiter.wait(for: [browserPresented], timeout: 5)
        if presented != .completed { attach("Dedicated browser presentation failure") }
        XCTAssertEqual(presented, .completed, "browser owns its visible navigation")
    }

    @MainActor
    func settingsTab(_ app: XCUIApplication, japanese: Bool) -> XCUIElement {
        let label = japanese ? "設定" : "Settings"
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        if tab.exists { return tab }
        return app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "gearshape.fill", label)).firstMatch
    }

    @MainActor
    func selectTab(_ tab: String, app: XCUIApplication) {
        let sidebar = app.staticTexts["plugins.tab." + tab]
        if sidebar.exists && !sidebar.isHittable {
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sidebar.isHittable }, object: nil)
            _ = XCTWaiter.wait(for: [settled], timeout: 1)
        }
        if !sidebar.exists || !sidebar.isHittable,
           let toggle = app.buttons.matching(identifier: "ToggleSidebar").allElementsBoundByIndex.first(where: { $0.isHittable }) {
            toggle.tap()
        }
        if sidebar.exists {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sidebar.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            sidebar.tap()
        } else {
            let name = tab.prefix(1).uppercased() + tab.dropFirst()
            let tabButton = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            let button = tabButton.exists ? tabButton : app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
        XCTAssertTrue(scrollContainer(app, "plugins." + tab).waitForExistence(timeout: 5))
    }

    @MainActor
    func openAddRepository(_ app: XCUIApplication) {
        app.buttons.matching(identifier: "plugins.add").firstMatch.tap()
        app.buttons.matching(identifier: "plugins.addRepository").firstMatch.tap()
        XCTAssertTrue(app.textFields["repo.url"].waitForExistence(timeout: 5))
    }

    @MainActor
    func previewRepository(_ url: URL, app: XCUIApplication) {
        openAddRepository(app)
        let field = app.textFields["repo.url"]
        field.tap()
        field.typeText(url.absoluteString)
        tapWhenStable(app.buttons.matching(identifier: "repo.preview").firstMatch)
        let form = scrollContainer(app, "repo.addForm")
        let reviewedURL = form.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", url.absoluteString)).firstMatch
        XCTAssertTrue(reviewedURL.waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["repo.error"].exists)
        reach(app.buttons.matching(identifier: "repo.addUnverified").firstMatch, in: form)
    }

    @MainActor
    func addRepository(_ url: URL, app: XCUIApplication) {
        previewRepository(url, app: app)
        reach(app.buttons.matching(identifier: "repo.addUnverified").firstMatch, in: scrollContainer(app, "repo.addForm")).tap()
        let confirm = app.buttons.matching(identifier: "repo.confirmUnverified").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["repo.url"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(scrollContainer(app, "plugins.categories").waitForExistence(timeout: 5), "added source opens Categories")
    }

    @MainActor
    func openCategory(_ app: XCUIApplication, id: String = "uncategorized") {
        reach(app.buttons.matching(identifier: "plugins.category." + id).firstMatch, in: scrollContainer(app, "plugins.categories")).tap()
        XCTAssertTrue(scrollContainer(app, "plugins.catalog").waitForExistence(timeout: 5))
    }

    @MainActor
    func openCatalogPackage(_ id: String, app: XCUIApplication) {
        reach(app.buttons.matching(identifier: "plugins.catalog.package." + id).firstMatch, in: scrollContainer(app, "plugins.catalog")).tap()
        XCTAssertTrue(scrollContainer(app, "plugins.package.detail").waitForExistence(timeout: 15))
    }

    @MainActor
    func enqueueGet(_ app: XCUIApplication) {
        let detail = scrollContainer(app, "plugins.package.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        let action = reach(app.buttons.matching(identifier: "plugins.package.hero.action").firstMatch, in: detail)
        XCTAssertTrue(action.isEnabled)
        action.tap()
        let queueExists = app.buttons.matching(identifier: "plugins.queue.open").firstMatch.waitForExistence(timeout: 5)
        if !queueExists { attachDiagnostic("Missing install queue bar", app: app) }
        XCTAssertTrue(queueExists)
        XCTAssertFalse(app.switches["plugins.package.enabled"].exists, "a queued package is not installed")
    }

    @MainActor
    func openQueue(_ app: XCUIApplication) {
        app.buttons.matching(identifier: "plugins.queue.open").firstMatch.tap()
        XCTAssertTrue(scrollContainer(app, "plugins.queue.items").waitForExistence(timeout: 5))
    }

    @MainActor
    func queueRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "plugins.queue.entry."))
    }

    @MainActor
    func confirmQueue(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(identifier: "plugins.queue.confirm").firstMatch
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plugins.queue.status"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["plugins.queue.error"].exists)
        XCTAssertEqual(queueRows(app).count, 0)
        XCTAssertFalse(confirm.isEnabled, "confirmed success stays visible without a second submission")
        app.buttons.matching(identifier: "plugins.queue.close").firstMatch.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func openInstalled(_ id: String, app: XCUIApplication) {
        reach(app.buttons.matching(identifier: "plugins.package." + id).firstMatch, in: scrollContainer(app, "plugins.packages")).tap()
        XCTAssertTrue(scrollContainer(app, "plugins.package.detail").waitForExistence(timeout: 5))
    }

    @MainActor
    func openModify(_ app: XCUIApplication) {
        reach(app.buttons.matching(identifier: "plugins.package.hero.action").firstMatch, in: scrollContainer(app, "plugins.package.detail")).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "plugins.modify.cancel").firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func text(_ label: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func installMulti(_ url: URL, app: XCUIApplication, japanese: Bool) {
        openPlugins(app, japanese: japanese)
        addRepository(url, app: app)
        openCategory(app)
        openCatalogPackage(Self.multiID, app: app)
        enqueueGet(app)
        openQueue(app)
        confirmQueue(app)
        assertEnabled(false, app: app)
    }

    @MainActor
    func tapEnabled(_ app: XCUIApplication) {
        let row = reach(app.switches["plugins.package.enabled"], in: scrollContainer(app, "plugins.package.detail"))
        // SwiftUI can expose both a full-width labelled row and its native UISwitch.
        let nested = row.switches.firstMatch
        let control = nested.exists ? nested : row
        XCTAssertTrue(control.isEnabled && control.isHittable)
        control.tap()
    }

    @MainActor
    func assertEnabled(_ expected: Bool, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = reach(app.switches["plugins.package.enabled"], in: scrollContainer(app, "plugins.package.detail"))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.value as? String == (expected ? "1" : "0")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    func openPackageTest(_ app: XCUIApplication) {
        reach(app.buttons.matching(identifier: "plugins.package.test").firstMatch, in: scrollContainer(app, "plugins.package.detail")).tap()
        XCTAssertTrue(scrollContainer(app, "script.form").waitForExistence(timeout: 5))
        let run = app.buttons.matching(identifier: "script.run").firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in run.isHittable }, object: nil)
        let visible = XCTWaiter.wait(for: [ready], timeout: 5)
        if visible != .completed { attachDiagnostic("Package Test controls", app: app) }
        XCTAssertEqual(visible, .completed)
    }

    @MainActor
    func openSampleJSON(_ id: String, app: XCUIApplication) -> XCUIElement {
        reach(app.buttons.matching(identifier: id).firstMatch, in: scrollContainer(app, "script.form")).tap()
        let viewer = app.textViews["script.sampleJSON"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "script.closeJSON").firstMatch.isHittable)
        assertFullScreen(viewer, app: app)
        return viewer
    }

    @MainActor
    func openFile(_ file: String, packageID: String, app: XCUIApplication) {
        reach(app.buttons.matching(identifier: "plugins.file." + packageID + "." + file).firstMatch, in: scrollContainer(app, "plugins.scripts")).tap()
        XCTAssertTrue(scrollContainer(app, "plugins.file.detail").waitForExistence(timeout: 5))
    }

    @MainActor
    func openFileSource(_ app: XCUIApplication) -> XCUIElement {
        reach(app.buttons.matching(identifier: "plugins.file.openSource").firstMatch, in: scrollContainer(app, "plugins.file.detail")).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "plugins.file.closeSource").firstMatch.waitForExistence(timeout: 5))
        let sourceScrollView = app.scrollViews["plugins.file.source"]
        XCTAssertTrue(sourceScrollView.waitForExistence(timeout: 5))
        assertFullScreen(sourceScrollView, app: app)
        // Runestone identifies its outer scroll view; the child text view holds the complete source.
        let viewer = sourceScrollView.textViews.firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(identifier: "plugins.file.sourcePicker").firstMatch.exists, "the reader keeps the exact selected file")
        return viewer
    }

    @MainActor
    func assertReadOnly(_ viewer: XCUIElement, app: XCUIApplication) {
        let before = viewer.value as? String
        XCTAssertFalse(before?.isEmpty ?? true)
        viewer.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        XCTAssertEqual(viewer.value as? String, before)
        XCTAssertFalse(app.buttons.matching(identifier: "script.save").firstMatch.exists)
    }

    @MainActor
    func assertFullScreen(_ viewer: XCUIElement, app: XCUIApplication) {
        XCTAssertGreaterThan(viewer.frame.intersection(app.frame).height, app.frame.height * 0.6)
    }

    @MainActor
    func assertSource(_ viewer: XCUIElement, equals source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((viewer.value as? String).map { Array($0.utf8) }, Array(source.utf8), file: file, line: line)
    }

    func assertJSON(_ text: String, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let actual = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? NSObject
        let wanted = try? JSONSerialization.jsonObject(with: Data(expected.utf8), options: [.fragmentsAllowed]) as? NSObject
        XCTAssertNotNil(actual, file: file, line: line)
        XCTAssertEqual(actual, wanted, file: file, line: line)
    }

    @MainActor
    func goBack(_ app: XCUIApplication, from title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func scrollContainer(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        for query in [app.collectionViews, app.tables, app.scrollViews] {
            let container = query.matching(identifier: id).firstMatch
            if container.exists { return container }
        }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Gesture the actual accessibility scroll container; no screen-coordinate or inset-edge drags.
    @MainActor
    @discardableResult
    func reach(_ element: XCUIElement, in container: XCUIElement, attempts: Int = 18) -> XCUIElement {
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        for _ in 0 ..< attempts {
            let visible = viewport(container)
            if fullyVisible(element, in: container, within: visible) { return element }
            if element.exists && element.frame.midY < visible.minY {
                container.swipeDown(velocity: .slow)
            } else {
                container.swipeUp(velocity: .slow)
            }
        }
        let info = "identifier=\(element.identifier), exists=\(element.exists), hittable=\(element.isHittable), target=\(element.frame), container=\(container.frame), viewport=\(viewport(container))"
        let diagnostic = XCTAttachment(string: info)
        diagnostic.name = "Unreachable browser accessibility control"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        attach("Unreachable browser control")
        XCTFail(info)
        return element
    }

    @MainActor
    func viewport(_ container: XCUIElement) -> CGRect {
        let app = XCUIApplication()
        var visible = container.frame.intersection(app.frame)
        for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable && bar.frame.intersects(visible) {
            let top = max(visible.minY, bar.frame.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: max(0, visible.maxY - top))
        }
        for overlay in app.tabBars.allElementsBoundByIndex + app.keyboards.allElementsBoundByIndex where overlay.isHittable && overlay.frame.intersects(visible) {
            visible.size.height = max(0, min(visible.maxY, overlay.frame.minY) - visible.minY)
        }
        // List links can end exactly at a bar boundary; test the actual unobscured bounds.
        return visible
    }

    @MainActor
    func fullyVisible(_ element: XCUIElement, in container: XCUIElement, within visible: CGRect? = nil) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return (visible ?? viewport(container)).contains(element.frame)
    }

    @MainActor
    func verifyLargeApproval(_ app: XCUIApplication, form: XCUIElement) {
        var paths = Set(PluginRepositorySources.approvalPaths)
        var fields = Set(PluginRepositorySources.approvalReadFields)
        var sawRevision = false
        var capturedPath = false
        var capturedField = false
        for _ in 0 ..< 100 {
            let visible = viewport(form)
            for text in form.staticTexts.allElementsBoundByIndex where fullyVisible(text, in: form, within: visible) {
                if paths.contains(text.label) {
                    assertApprovalWrapping(text.label, element: text)
                    if !capturedPath && text.label == PluginRepositorySources.approvalPaths.last {
                        attachApprovalRow(text, name: "Large approval long path render")
                        capturedPath = true
                    }
                }
                paths.remove(text.label)
            }
            for row in form.textViews.allElementsBoundByIndex where fullyVisible(row, in: form, within: visible) {
                let value = row.value as? String ?? ""
                if row.identifier.hasPrefix("plugins.approval.read.") {
                    assertApprovalWrapping(value, element: row)
                    fields = fields.filter { !value.hasSuffix($0) }
                    if !capturedField, let last = PluginRepositorySources.approvalReadFields.last, value.hasSuffix(last) {
                        attachApprovalRow(row, name: "Large approval long field render")
                        capturedField = true
                    }
                } else if row.identifier == "plugins.approval.revision" {
                    XCTAssertEqual(value, PluginRepositorySources.approvalRevision)
                    sawRevision = true
                }
            }
            if paths.isEmpty && fields.isEmpty && sawRevision { break }
            form.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(paths.isEmpty, "all declared paths must be readable; missing \(paths.count)")
        XCTAssertTrue(fields.isEmpty, "all declared headers and query fields must be readable; missing \(fields.count)")
        XCTAssertTrue(sawRevision, "the complete revision must be readable")
        XCTAssertTrue(capturedPath && capturedField, "retain rendered evidence of long permission values")
    }

    @MainActor
    func assertApprovalWrapping(_ value: String, element: XCUIElement) {
        XCTAssertGreaterThan(element.frame.width, 0)
        guard element.frame.width > 0 else { return }
        // Conservative lower bound for the default monospaced footnote values in this fixture.
        let minimumHeight = ceil(Double(value.utf16.count) * 7.5 / Double(element.frame.width)) * 14
        XCTAssertGreaterThanOrEqual(Double(element.frame.height) + 1, minimumHeight, "permission text must wrap without clipping")
    }

    @MainActor
    func attachApprovalRow(_ row: XCUIElement, name: String) {
        let image = XCTAttachment(screenshot: row.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func tapWhenStable(_ button: XCUIElement) {
        var previous = CGRect.null
        var unchangedSince = Date()
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = button.frame
            if frame != previous { previous = frame; unchangedSince = Date(); return false }
            return button.isHittable && button.isEnabled && Date().timeIntervalSince(unchangedSince) >= 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 8), .completed)
        button.tap()
    }

    @MainActor
    func attachDiagnostic(_ name: String, app: XCUIApplication, detail: String = "") {
        attach(name)
        let attachment = XCTAttachment(string: detail + "\n" + app.debugDescription)
        attachment.name = name + " accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
