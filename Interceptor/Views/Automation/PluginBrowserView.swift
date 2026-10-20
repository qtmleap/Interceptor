import AutomationCore
import SwiftUI
import UniformTypeIdentifiers

enum PluginBrowserDestination: String, CaseIterable, Identifiable, Hashable {
    case sources, packages, scripts
    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
            case .sources: "AUTO_BROWSER_SOURCES"
            case .packages: "AUTO_BROWSER_PACKAGES"
            case .scripts: "AUTO_BROWSER_SCRIPTS"
        }
    }

    var symbol: String {
        switch self {
            case .sources: "folder"
            case .packages: "shippingbox"
            case .scripts: "doc.text"
        }
    }
}

/// One model and queue survive navigation between all three browser destinations.
struct PluginBrowserView: View {
    @State var model: PluginBrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var destination: PluginBrowserDestination? = .sources

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
        .task { await model.controller.load() }
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

    private func browserStack(_ item: PluginBrowserDestination, includesQueueBar: Bool = true) -> some View {
        NavigationStack {
            Group {
                switch item {
                    case .sources: PluginSourcesView(model: model)
                    case .packages: PluginInstalledPackagesView(model: model)
                    case .scripts: PluginScriptFilesView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("AUTO_BROWSER_CLOSE") { dismiss() }
                        .disabled(model.isProcessing)
                        .accessibilityIdentifier("plugins.close")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if includesQueueBar {
                PluginInstallQueueBar(count: model.queue.count, isBusy: model.isProcessing) { model.openQueue() }
            }
        }
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

struct PluginSourcesView: View {
    let model: PluginBrowserModel
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var addedURL: RepositoryURL?
    @State private var pendingAddedURL: RepositoryURL?
    @State private var pendingRemoval: RepositoryRecord?
    @State private var showsRefreshResult = false

    var body: some View {
        List {
            PluginBrowserErrors(controller: model.controller)
            if !model.controller.isLoaded {
                ProgressView("AUTO_BROWSER_LOADING").accessibilityIdentifier("plugins.loading")
            }
            if model.isRefreshing {
                ProgressView("AUTO_BROWSER_REFRESHING").accessibilityIdentifier("plugins.refreshing")
            } else if !model.refreshErrors.isEmpty {
                Section {
                    Text("AUTO_BROWSER_REFRESH_FAILED").foregroundStyle(AutomationStatusColor.error)
                    Button("AUTO_BROWSER_RETRY") { Task { await model.refreshSources() } }
                        .accessibilityIdentifier("plugins.refreshRetry")
                }
            } else if model.didRefresh && showsRefreshResult {
                Text("AUTO_BROWSER_REFRESHED").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugins.refreshed")
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
                    PluginInstalledPackagesView(model: model, localOnly: true)
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
        .task(id: model.didRefresh) {
            showsRefreshResult = model.didRefresh
            guard model.didRefresh else { return }
            do { try await Task.sleep(for: .seconds(2.5)) }
            catch { return }
            showsRefreshResult = false
        }
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
        List {
            if let current {
                Section {
                    ForEach(model.categories(in: current)) { category in
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
                    if model.categories(in: current).isEmpty {
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
        List {
            if let current {
                let entries = model.catalogEntries(in: current, category: category, query: query)
                ForEach(entries, id: \.id) { entry in
                    PluginCatalogLink(model: model, entry: entry, record: current)
                }
                if entries.isEmpty {
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

struct PluginCatalogLink: View {
    let model: PluginBrowserModel
    let entry: IndexEntry
    let record: RepositoryRecord
    private var family: PluginBrowserFamilyID {
        PluginBrowserFamilyID(repository: record.url, manifestID: entry.id)
    }

    var body: some View {
        NavigationLink {
            PluginPackageDetailView(model: model, family: family, sourceURL: record.url)
        } label: {
            PluginPackageRow(name: entry.name, author: entry.author, version: entry.version, summary: entry.summary ?? "",
                             isInstalled: model.selectedRevision(for: family) != nil)
        }
        .accessibilityIdentifier("plugins.catalog.package." + entry.id.uuidString)
    }
}

struct PluginInstalledPackagesView: View {
    let model: PluginBrowserModel
    var localOnly = false
    @State private var query = ""
    @State private var ascending = true
    @State private var pendingDelete: InstalledRevision?
    private var packages: [InstalledRevision] {
        let values = model.installedPackages(query: query).filter {
            guard localOnly else { return true }
            if case .repository = $0.provenance.origin {
                return false
            }; return true
        }
        return ascending ? values : Array(values.reversed())
    }

    var body: some View {
        List {
            PluginBrowserErrors(controller: model.controller)
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
            ForEach(packages, id: \.id) { revision in
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
            if packages.isEmpty {
                PluginPackagesEmpty(query: query, installed: true)
            }
        }
        .listStyle(.plain)
        .navigationTitle(localOnly ? Text("AUTO_BROWSER_LOCAL") : Text("AUTO_BROWSER_PACKAGES"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("AUTO_BROWSER_SEARCH"))
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
    var package: PluginPackage?
    var body: some View {
        List {
            if let package {
                files(package)
            } else {
                ForEach(model.installedPackages(), id: \.id) { revision in
                    Section(revision.package.manifest.name) { files(revision.package) }
                }
                if model.installedPackages().isEmpty {
                    ContentUnavailableView("AUTO_BROWSER_NO_SCRIPTS", systemImage: "doc.text", description: Text("AUTO_BROWSER_ADD_TO_SEE_SCRIPTS"))
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("AUTO_BROWSER_SCRIPTS")
        .navigationBarTitleDisplayMode(package == nil ? .large : .inline)
        .accessibilityIdentifier("plugins.scripts")
    }

    private func files(_ package: PluginPackage) -> some View {
        ForEach(PluginBrowserModel.sourceFiles(in: package), id: \.self) { file in
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
                    .frame(minHeight: 44)
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
    }
}

struct PluginBrowserErrors: View {
    let controller: AutomationController
    var body: some View {
        if let error = controller.storeError ?? controller.installationError ?? controller.actionError {
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
