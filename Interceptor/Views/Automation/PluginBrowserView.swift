import AutomationCore
import SwiftUI
import UniformTypeIdentifiers

enum PluginBrowserDestination: String, CaseIterable, Identifiable, Hashable {
    case sources, packages, scripts, search
    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
            case .sources: "AUTO_BROWSER_SOURCES"
            case .packages: "AUTO_BROWSER_PACKAGES"
            case .scripts: "AUTO_BROWSER_SCRIPTS"
            case .search: "AUTO_BROWSER_SEARCH_TAB"
        }
    }

    var symbol: String {
        switch self {
            case .sources: "folder"
            case .packages: "shippingbox"
            case .scripts: "doc.text"
            case .search: "magnifyingglass"
        }
    }
}

/// One model and queue survive navigation between all four browser destinations.
struct PluginBrowserView: View {
    @State var model: PluginBrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var destination: PluginBrowserDestination? = .sources
    @State private var packagesQuery = ""
    @State private var searchQuery = ""
    @State private var localQuery = ""

    var body: some View {
        let queueCount = model.queue.count
        let busy = model.isProcessing
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(PluginBrowserDestination.allCases, selection: $destination) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                            .accessibilityIdentifier("plugins.tab." + item.rawValue)
                    }
                    .navigationTitle("AUTO_PLUGINS")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            sidebarCloseButton
                                .disabled(model.isProcessing)
                                .accessibilityIdentifier("plugins.close")
                        }
                    }
                } detail: {
                    browserStack(destination ?? .sources, includesQueueBar: false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PluginInstallQueueBar(count: queueCount, isBusy: busy) { model.openQueue() }
                }
            } else {
                TabView(selection: Binding(get: { destination ?? .sources }, set: { destination = $0 })) {
                    ForEach(PluginBrowserDestination.allCases) { item in
                        browserStack(item)
                            .tabItem { Label(item.title, systemImage: item.symbol) }
                            .tag(item)
                    }
                }
            }
        }
        .tint(PluginBrowserColor.accent)
        .interactiveDismissDisabled(model.isProcessing)
        .sheet(isPresented: Binding(get: { model.isQueuePresented }, set: {
            if !$0 {
                _ = model.dismissQueue()
            }
        })) {
            PluginInstallSheetContent(
                entries: model.queue.map { entry in
                    PluginInstallQueueDisplayEntry(
                        id: queueID(entry.id), name: entry.package.manifest.name, version: entry.package.manifest.version,
                        detail: queueEntryIsValid(entry) ? queueDetail(entry) : "AUTO_BROWSER_QUEUE_ITEM_CHANGED",
                        isValid: queueEntryIsValid(entry), systemImage: "shippingbox",
                    )
                },
                isBusy: model.isProcessing, canConfirm: !model.queue.isEmpty && model.queue.allSatisfy(queueEntryIsValid),
                status: model.queueCompletionCount != nil ? "AUTO_BROWSER_INSTALL_COMPLETE" : nil,
                errorMessage: model.queueError.map { NSLocalizedString(PluginBrowserMessage.key(for: $0), comment: "") },
                onRemove: {
                    id in if let entry = model.queue.first(where: { queueID($0.id) == id }) {
                        model.removeQueued(id: entry.id)
                    }
                },
                onClear: { model.clearQueue() },
                onConfirm: { Task { _ = await model.confirmQueue() } },
                onClose: { _ = model.dismissQueue() },
            )
            .presentationDetents([.large])
        }
    }

    @ViewBuilder private var sidebarCloseButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) { dismiss() }
        } else {
            Button("AUTO_BROWSER_CLOSE", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
        }
    }

    private func browserStack(_ item: PluginBrowserDestination, includesQueueBar: Bool = true) -> some View {
        let ownsSearch = sizeClass == .regular && (item == .packages || item == .search)
        return NavigationStack {
            Group {
                switch item {
                    case .sources: PluginSourcesView(model: model, localQuery: $localQuery)
                    case .packages: PluginInstalledPackagesView(model: model, query: $packagesQuery, includesSearchField: !ownsSearch)
                    case .scripts: PluginScriptFilesView(model: model)
                    case .search: PluginPackageSearchView(model: model, query: $searchQuery, includesSearchField: !ownsSearch)
                }
            }
            .modifier(PluginStableSearch(isEnabled: ownsSearch, text: stableSearchBinding(item)))
            .toolbar {
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("AUTO_BROWSER_CLOSE") { dismiss() }
                            .disabled(model.isProcessing)
                            .accessibilityIdentifier("plugins.close")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if includesQueueBar {
                PluginInstallQueueBar(count: model.queue.count, isBusy: model.isProcessing) { model.openQueue() }
            }
        }
    }

    /// Selects the independent parent query so the regular stack keeps one native search field across tab switches.
    private func stableSearchBinding(_ item: PluginBrowserDestination) -> Binding<String> {
        item == .search ? $searchQuery : $packagesQuery
    }

    private func queueID(_ id: PluginBrowserFamilyID) -> String {
        id.source + "|" + id.manifestID.uuidString
    }

    private func queueDetail(_ entry: PluginQueuedPackage) -> LocalizedStringKey {
        switch entry.operation {
            case .get: "AUTO_BROWSER_QUEUE_WAITING"
            case .reinstall: "AUTO_BROWSER_REINSTALL"
        }
    }

    private func queueEntryIsValid(_ item: PluginQueuedPackage) -> Bool {
        switch item.operation {
            case .get:
                guard model.selectedRevision(for: item.id) == nil,
                      let record = model.controller.repositories.first(where: { $0.url.canonical == item.id.source }),
                      record.generation == item.sourceGeneration,
                      let snapshot = record.snapshot,
                      snapshot.index.expiresAt > model.controller.now,
                      let entry = snapshot.index.plugins.first(where: { $0.id == item.id.manifestID }) else { return false }
                return entry.sha256 == item.package.revision && entry.version == item.package.manifest.version
            case let .reinstall(selectedID):
                guard let selected = model.selectedRevision(for: item.id) else { return false }
                return selected.id == selectedID && selected.package.bytes == item.package.bytes
        }
    }
}

/// One `.searchable` owner for the regular-width Packages/Search roots.
private struct PluginStableSearch: ViewModifier {
    let isEnabled: Bool
    let text: Binding<String>

    func body(content: Content) -> some View {
        if isEnabled {
            let searchableContent = content.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("AUTO_BROWSER_SEARCH"))
            if #available(iOS 17.1, *) {
                searchableContent.searchPresentationToolbarBehavior(.avoidHidingContent)
            } else {
                searchableContent
            }
        } else {
            content
        }
    }
}

struct PluginSourcesView: View {
    let model: PluginBrowserModel
    @Binding var localQuery: String
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var addedURL: RepositoryURL?
    @State private var pendingAddedURL: RepositoryURL?
    @State private var pendingRemoval: RepositoryRecord?

    var body: some View {
        List {
            PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
            if !model.controller.isLoaded {
                ProgressView("AUTO_BROWSER_LOADING").accessibilityIdentifier("plugins.loading")
            }
            if model.isRefreshing || model.controller.isBackfillingPackages {
                ProgressView("AUTO_BROWSER_REFRESHING").accessibilityIdentifier("plugins.refreshing")
            } else if model.hasSourceRefreshFailures {
                Section {
                    Text("AUTO_BROWSER_REFRESH_FAILED").foregroundStyle(AutomationStatusColor.error)
                    Button("AUTO_BROWSER_RETRY") { Task { await model.refreshSources() } }
                        .accessibilityIdentifier("plugins.refreshRetry")
                }
            }
            Section {
                ForEach(model.controller.repositories, id: \.url) { record in
                    NavigationLink {
                        PluginRepositoryCategoriesView(model: model, sourceURL: record.url)
                    } label: {
                        PluginRepositoryRow(name: record.displayName, url: record.url.canonical,
                                            packageCount: record.snapshot?.index.plugins.count ?? 0)
                    }
                    .accessibilityIdentifier("plugins.repo." + record.displayName)
                    .swipeActions {
                        Button("AUTO_BROWSER_DELETE", role: .destructive) { pendingRemoval = record }
                    }
                }
                .onDelete { offsets in
                    if let index = offsets.first, model.controller.repositories.indices.contains(index) {
                        pendingRemoval = model.controller.repositories[index]
                    }
                }
                NavigationLink {
                    PluginInstalledPackagesView(model: model, query: $localQuery, localOnly: true)
                } label: {
                    PluginRepositoryRow(name: String(localized: "AUTO_BROWSER_LOCAL"),
                                        url: String(localized: "AUTO_BROWSER_LOCAL_DESCRIPTION"),
                                        packageCount: localPackages.count, systemImage: "folder", iconColor: .gray)
                }
                .accessibilityIdentifier("plugins.source.local")
            } header: { Text("AUTO_BROWSER_REPOSITORIES") }
        }
        .listStyle(.plain)
        .navigationTitle("AUTO_BROWSER_SOURCES")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("plugins.sources")
        .refreshable { await model.refreshSources() }
        .accessibilityAction(named: Text("AUTO_BROWSER_REFRESH")) { Task { await model.refreshSources() } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton().disabled(model.isProcessing)
                Menu {
                    Button("AUTO_ADD_REPOSITORY") { showAdd = true }.accessibilityIdentifier("plugins.addRepository")
                    Button("AUTO_IMPORT_FILE") { showImporter = true }.accessibilityIdentifier("plugins.importFile")
                } label: { Label("AUTO_BROWSER_ADD", systemImage: "plus") }
                    .disabled(model.isProcessing || model.controller.storeError != nil)
                    .accessibilityIdentifier("plugins.add")
            }
        }
        .sheet(isPresented: $showAdd, onDismiss: {
            addedURL = pendingAddedURL; pendingAddedURL = nil
        }) {
            AddRepositorySheet(controller: model.controller) { pendingAddedURL = $0 }
        }
        .navigationDestination(isPresented: Binding(get: { addedURL != nil }, set: {
            if !$0 {
                addedURL = nil
            }
        })) {
            if let addedURL {
                PluginRepositoryCategoriesView(model: model, sourceURL: addedURL)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            Task {
                _ = await model.controller.importFile(at: url)
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
        .alert("AUTO_BROWSER_REMOVE_SOURCE", isPresented: Binding(get: { pendingRemoval != nil }, set: {
            if !$0 {
                pendingRemoval = nil
            }
        })) {
            Button("AUTO_BROWSER_CANCEL", role: .cancel) { pendingRemoval = nil }
            Button("AUTO_BROWSER_DELETE", role: .destructive) {
                guard let record = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.controller.deleteRepository(record.url) }
            }
        } message: { Text("AUTO_BROWSER_REMOVE_SOURCE_FOOTER") }
    }

    private var localPackages: [InstalledRevision] {
        model.installedPackages().filter {
            if case .repository = $0.provenance.origin {
                return false
            }; return true
        }
    }
}

struct PluginRepositoryCategoriesView: View {
    let model: PluginBrowserModel
    let sourceURL: RepositoryURL
    private var current: RepositoryRecord? {
        model.controller.repositories.first { $0.url == sourceURL }
    }

    var body: some View {
        let categories = current.map { model.categories(in: $0) } ?? []
        List {
            PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
            if let current {
                Section {
                    ForEach(categories) { category in
                        NavigationLink {
                            PluginCatalogPackagesView(model: model, sourceURL: sourceURL, category: category)
                        } label: {
                            HStack {
                                Label { categoryName(category) } icon: { Image(systemName: "square.grid.2x2").foregroundStyle(PluginBrowserColor.accent) }
                                Spacer()
                                Text(category.count, format: .number).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("plugins.category." + category.id)
                    }
                    if categories.isEmpty {
                        Text("AUTO_BROWSER_CATALOG_EMPTY").foregroundStyle(.secondary)
                    }
                } header: { Text("AUTO_BROWSER_CATEGORIES") }
            } else {
                Text("AUTO_BROWSER_SOURCE_UNAVAILABLE").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(verbatim: current?.displayName ?? sourceURL.canonical))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("plugins.categories")
    }
}

struct PluginCatalogPackagesView: View {
    let model: PluginBrowserModel
    let sourceURL: RepositoryURL
    let category: PluginBrowserCategory
    @State private var query = ""
    private var current: RepositoryRecord? {
        model.controller.repositories.first { $0.url == sourceURL }
    }

    var body: some View {
        let rows = current.map { model.catalogPackages(in: $0, category: category, query: query) } ?? []
        List {
            PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
            if current != nil {
                ForEach(rows, id: \.id) { item in
                    PluginCatalogPackageLink(model: model, item: item, identifier: "plugins.catalog.package." + item.id.manifestID.uuidString)
                }
                if rows.isEmpty {
                    PluginPackagesEmpty(query: query, installed: false)
                }
            } else {
                Text("AUTO_BROWSER_SOURCE_UNAVAILABLE")
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("AUTO_BROWSER_SEARCH"))
        .navigationTitle(category.name.map { Text(verbatim: $0) } ?? Text("AUTO_BROWSER_UNCATEGORIZED"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("plugins.catalog")
    }
}

/// One cached catalog row: source-qualified identity, detail navigation, installed check and source hint.
struct PluginCatalogPackageLink: View {
    let model: PluginBrowserModel
    let item: PluginBrowserCatalogPackage
    let identifier: String

    var body: some View {
        NavigationLink {
            PluginPackageDetailView(model: model, family: item.id, sourceURL: item.record?.url)
        } label: {
            PluginPackageRow(name: item.name, author: item.author, version: item.version,
                             summary: item.summary ?? "", isInstalled: item.installed != nil)
                .accessibilityHint(Text(verbatim: item.record?.displayName ?? item.id.source))
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Global search over the cached catalogs. Never fetches, queues, installs or enables.
struct PluginPackageSearchView: View {
    let model: PluginBrowserModel
    @Binding var query: String
    var includesSearchField = true

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = trimmed.isEmpty ? [] : model.catalogPackages(query: trimmed)
        let loaded = model.controller.isLoaded
        List {
            PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
            if !loaded {
                ProgressView("AUTO_BROWSER_LOADING").accessibilityIdentifier("plugins.loading")
            }
            if model.isRefreshing {
                ProgressView("AUTO_BROWSER_REFRESHING").accessibilityIdentifier("plugins.refreshing")
            } else if !model.refreshErrors.isEmpty {
                Text("AUTO_BROWSER_REFRESH_FAILED").foregroundStyle(AutomationStatusColor.error)
            }
            ForEach(results) { item in
                PluginCatalogPackageLink(model: model, item: item, identifier: "plugins.search.package." + item.id.source + "|" + item.id.manifestID.uuidString)
            }
        }
        .listStyle(.plain)
        .navigationTitle("AUTO_BROWSER_SEARCH_TAB")
        .navigationBarTitleDisplayMode(.large)
        .modifier(PluginStableSearch(isEnabled: includesSearchField, text: $query))
        .accessibilityIdentifier("plugins.search")
    }
}

struct PluginInstalledPackagesView: View {
    let model: PluginBrowserModel
    @Binding var query: String
    var localOnly = false
    var includesSearchField = true
    @State private var ascending = true
    @State private var pendingDelete: InstalledRevision?
    private var packages: [InstalledRevision] {
        let values = model.installedPackages(query: query).filter {
            if case .repository = $0.provenance.origin {
                return false
            }; return true
        }
        return ascending ? values : Array(values.reversed())
    }

    private var catalog: [PluginBrowserCatalogPackage] {
        let values = model.catalogPackages(query: query)
        return ascending ? values : Array(values.reversed())
    }

    var body: some View {
        let catalogRows = localOnly ? [] : catalog
        List {
            PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
            HStack {
                Spacer()
                Picker("AUTO_BROWSER_SORT", selection: $ascending) {
                    Text("AUTO_BROWSER_NAME_ASCENDING").tag(true)
                    Text("AUTO_BROWSER_NAME_DESCENDING").tag(false)
                }
                .pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
                .accessibilityIdentifier("plugins.sort")
            }
            .listRowSeparator(.hidden)
            if !localOnly {
                if !model.controller.isLoaded {
                    ProgressView("AUTO_BROWSER_LOADING").accessibilityIdentifier("plugins.loading")
                }
                ForEach(catalogRows) { item in
                    PluginCatalogPackageLink(model: model, item: item, identifier: "plugins.package." + item.id.source + "|" + item.id.manifestID.uuidString)
                        .swipeActions {
                            if let installed = item.installed {
                                Button("AUTO_BROWSER_DELETE", role: .destructive) { pendingDelete = installed }
                                    .disabled(model.isProcessing)
                            }
                        }
                }
                if catalog.isEmpty && model.controller.isLoaded {
                    PluginPackagesEmpty(query: query, installed: true)
                }
            }
            ForEach(localOnly ? packages : [], id: \.id) { revision in
                NavigationLink {
                    PluginPackageDetailView(model: model, family: PluginBrowserFamilyID(revision))
                } label: {
                    let manifest = revision.package.manifest
                    PluginPackageRow(name: manifest.name, author: manifest.author, version: manifest.version,
                                     summary: manifest.summary ?? "", isInstalled: true)
                }
                .accessibilityIdentifier("plugins.package." + revision.package.manifest.id.uuidString)
                .swipeActions {
                    Button("AUTO_BROWSER_DELETE", role: .destructive) { pendingDelete = revision }
                        .disabled(model.isProcessing)
                }
            }
            if localOnly && packages.isEmpty {
                PluginPackagesEmpty(query: query, installed: true)
            }
        }
        .listStyle(.plain)
        .navigationTitle(localOnly ? Text("AUTO_BROWSER_LOCAL") : Text("AUTO_BROWSER_PACKAGES"))
        .navigationBarTitleDisplayMode(.large)
        .modifier(PluginStableSearch(isEnabled: includesSearchField, text: $query))
        .accessibilityIdentifier("plugins.packages")
        .alert("AUTO_BROWSER_DELETE_QUESTION \(pendingDelete?.package.manifest.name ?? "")",
               isPresented: Binding(get: { pendingDelete != nil }, set: {
                   if !$0 {
                       pendingDelete = nil
                   }
               })) {
            Button("AUTO_BROWSER_CANCEL", role: .cancel) { pendingDelete = nil }
            Button("AUTO_BROWSER_DELETE", role: .destructive) {
                guard let revision = pendingDelete else { return }
                pendingDelete = nil
                Task { await model.controller.deleteScript(id: revision.id) }
            }
        }
    }
}

struct PluginScriptFilesView: View {
    let model: PluginBrowserModel
    var package: PluginPackagePresentation?
    var body: some View {
        List {
            if let package {
                files(package)
            } else {
                PluginBrowserErrors(controller: model.controller, queryError: model.catalogReadError)
                if !model.controller.isLoaded {
                    ProgressView("AUTO_BROWSER_LOADING").accessibilityIdentifier("plugins.loading")
                }
                ForEach(model.installedPackages(), id: \.id) { revision in
                    Section(revision.package.manifest.name) { files(model.presentation(of: revision)) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("AUTO_BROWSER_SCRIPTS")
        .navigationBarTitleDisplayMode(package == nil ? .large : .inline)
        .accessibilityIdentifier("plugins.scripts")
    }

    private func files(_ package: PluginPackagePresentation) -> some View {
        ForEach(package.sourceFileNames, id: \.self) { file in
            NavigationLink {
                PluginFileDetailView(package: package, file: file)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: (file as NSString).lastPathComponent)
                        if file.contains("/") {
                            Text(verbatim: file).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: "doc.text").foregroundStyle(PluginBrowserColor.accent) }
            }
            .accessibilityIdentifier("plugins.file." + package.manifest.id.uuidString + "." + file)
        }
    }
}

struct PluginPackagesEmpty: View {
    let query: String
    let installed: Bool
    var body: some View {
        ContentUnavailableView {
            Label(query.isEmpty ? LocalizedStringKey("AUTO_BROWSER_NO_PACKAGES") : LocalizedStringKey("AUTO_BROWSER_NO_MATCHES"), systemImage: "shippingbox")
        } description: {
            if query.isEmpty && installed {
                Text("AUTO_BROWSER_ADD_FROM_SOURCES")
            }
        }
        .listRowSeparator(.hidden)
    }
}

struct PluginBrowserErrors: View {
    let controller: AutomationController
    var queryError: Error?
    var body: some View {
        if let error = controller.storeError ?? controller.installationError ?? controller.packageCatalogError ?? controller.actionError ?? queryError {
            Section { Text(LocalizedStringKey(PluginBrowserMessage.key(for: error))).foregroundStyle(AutomationStatusColor.error) }
                .accessibilityIdentifier("plugins.error")
        }
    }
}

enum PluginBrowserMessage {
    static func key(for error: Error) -> String {
        if let error = error as? PluginBrowserError {
            switch error {
                case .busy: return "AUTO_BROWSER_BUSY"
                case .emptyQueue: return "AUTO_BROWSER_QUEUE_EMPTY"
                case .queueLimit: return "AUTO_BROWSER_QUEUE_LIMIT"
                case .staleQueue: return "AUTO_BROWSER_QUEUE_CHANGED"
                case .updateUnavailable: return "AUTO_BROWSER_UPDATE_UNAVAILABLE"
                case .catalogUnavailable: return "AUTO_BROWSER_REFRESH_DETAILS"
            }
        }
        if let error = error as? InstallationError {
            switch error {
                case .activationUnavailable: return "AUTO_BROWSER_UNAVAILABLE"
                case .familyAlreadyInstalled, .duplicateFamily: return "AUTO_BROWSER_QUEUE_CHANGED"
                case .approvalRequired: return "AUTO_ACTIVATION_STALE"
                case .consentRequired: return "AUTO_ACTIVATION_CONSENT"
            }
        }
        return AutomationErrorText.key(for: error)
    }
}

@ViewBuilder private func categoryName(_ category: PluginBrowserCategory) -> some View {
    if let name = category.name {
        Text(verbatim: name)
    } else {
        Text("AUTO_BROWSER_UNCATEGORIZED")
    }
}
