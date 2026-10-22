import AutomationCore
import SwiftUI

struct PluginPackageDetailView: View {
    let model: PluginBrowserModel
    let family: PluginBrowserFamilyID
    var sourceURL: RepositoryURL?
    private enum PackageTab { case details, version }
    @State private var tab = PackageTab.details
    @State private var isPreparingGet = false
    @State private var getError: Error?
    @State private var showDelete = false
    @State private var showJSON = false
    @State private var approval: PluginPackageApprovalRequest?
    @State private var isChangingActivation = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var selected: InstalledRevision? {
        model.selectedRevision(for: family)
    }

    private var record: RepositoryRecord? {
        model.controller.repositories.first { $0.url.canonical == (sourceURL?.canonical ?? family.source) }
    }

    private var entry: IndexEntry? {
        record?.snapshot?.index.plugins.first { $0.id == family.manifestID }
    }

    private var presentation: Result<PluginPackagePresentation?, Error> {
        Result { try model.packagePresentation(for: family, record: record) }
    }

    private var package: PluginPackagePresentation? { try? presentation.get() }

    private var busy: Bool {
        model.isProcessing || isChangingActivation || isPreparingGet
    }

    private var queued: Bool {
        model.queue.contains { $0.id == family }
    }

    var body: some View {
        Group {
            switch presentation {
                case .success(let package?): ready(package)
                case .failure(let error):
                    ContentUnavailableView {
                        Label("AUTO_BROWSER_PACKAGE_UNAVAILABLE", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(LocalizedStringKey(PluginBrowserMessage.key(for: error)))
                    }
                case .success(nil):
                    ContentUnavailableView("AUTO_BROWSER_PACKAGE_UNAVAILABLE", systemImage: "shippingbox")
            }
        }
        .navigationTitle(Text(verbatim: selected?.package.manifest.name ?? entry?.name ?? String(localized: "AUTO_BROWSER_PACKAGES")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $approval) { request in
            PluginPackageApprovalView(package: request.package,
                                      confirmTitle: request.isUpdate ? "AUTO_BROWSER_UPDATE" : "AUTO_ACTIVATE_CONFIRM",
                                      isBusy: busy, onCancel: { approval = nil })
            {
                approve(request)
            }
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showJSON) {
            if let package {
                PluginManifestJSONView(package: package) { showJSON = false }
            }
        }
        .alert("AUTO_BROWSER_DELETE_QUESTION \(selected?.package.manifest.name ?? "")", isPresented: $showDelete) {
            Button("AUTO_BROWSER_CANCEL", role: .cancel) {}
            Button("AUTO_BROWSER_DELETE", role: .destructive) {
                guard let selected else { return }
                Task {
                    await model.controller.deleteScript(id: selected.id)
                    if model.selectedRevision(for: family) == nil {
                        dismiss()
                    }
                }
            }
        }
        .tint(PluginBrowserColor.accent)
    }

    private func ready(_ package: PluginPackagePresentation) -> some View {
        List {
            PluginPackageHero(name: package.manifest.name, targetHosts: package.manifest.targetHosts,
                              actionTitle: selected != nil ? "AUTO_BROWSER_MODIFY" : queued ? "AUTO_BROWSER_QUEUED" : "AUTO_BROWSER_GET",
                              isActionEnabled: !busy && package.isComplete && (selected != nil || record != nil), isWorking: busy,
                              modifyActions: selected.map { _ in
                                  PluginPackageModifyActions(onReinstall: {
                                      guard !busy, let selected else { return }
                                      _ = model.enqueueReinstall(selected)
                                      model.openQueue()
                                  }, onDelete: {
                                      guard !busy, selected != nil else { return }
                                      showDelete = true
                                  })
                              })
            {
                if queued {
                    model.openQueue()
                } else if let record, let entry {
                    isPreparingGet = true
                    getError = nil
                    Task {
                        defer { isPreparingGet = false }
                        if !(await model.enqueueGet(entry: entry, record: record)) { getError = model.queueError }
                    }
                }
            }
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            HStack(spacing: 0) {
                tabButton(.details, title: "AUTO_BROWSER_DETAILS", id: "plugins.package.tab.details")
                tabButton(.version, title: "AUTO_VERSION", id: "plugins.package.tab.version")
            }
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            switch tab {
                case .details: details(package)
                case .version: version(package)
            }
            if !package.isComplete {
                Section {
                    Button("AUTO_BROWSER_REFRESH") { Task { await model.refreshSources() } }
                        .disabled(model.isRefreshing)
                        .accessibilityIdentifier("plugins.package.refresh")
                } footer: { Text("AUTO_BROWSER_REFRESH_DETAILS") }
            }
            if let error = getError {
                Section { Text(LocalizedStringKey(PluginBrowserMessage.key(for: error))).foregroundStyle(AutomationStatusColor.error) }
                    .accessibilityIdentifier("plugins.package.getError")
            }
            if let key = model.controller.activationErrorKey {
                Section { Text(LocalizedStringKey(key)).foregroundStyle(AutomationStatusColor.error) }
            }
            if let error = model.updateError {
                Section { Text(LocalizedStringKey(PluginBrowserMessage.key(for: error))).foregroundStyle(AutomationStatusColor.error) }
                    .accessibilityIdentifier("plugins.package.updateError")
            }
            PluginBrowserErrors(controller: model.controller)
        }
        .listStyle(.plain)
        .accessibilityIdentifier("plugins.package.detail")
    }

    private func tabButton(_ value: PackageTab, title: LocalizedStringKey, id: String) -> some View {
        let isSelected = tab == value
        return Button { tab = value } label: {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isSelected ? PluginBrowserColor.accent : .secondary)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? PluginBrowserColor.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func details(_ package: PluginPackagePresentation) -> some View {
        if package.manifest.summary != nil || package.manifest.author != nil {
            Section {
                if let summary = package.manifest.summary {
                    Text(verbatim: summary).textSelection(.enabled)
                }
                if let author = package.manifest.author {
                    LabeledContent("AUTO_AUTHOR") { Text(verbatim: author).textSelection(.enabled) }
                }
            }
        }
        if let selected, package.manifest.schemaVersion == 2 {
            Section {
                Toggle("AUTO_BROWSER_ENABLED", isOn: Binding(
                    get: { model.controller.isActive(selected.id) },
                    set: { enabled in changeActivation(enabled, revision: selected) },
                ))
                .disabled(busy || model.controller.installationState == nil)
                .accessibilityIdentifier("plugins.package.enabled")
            }
        }
        if let record {
            Section {
                NavigationLink {
                    PluginRepositoryCategoriesView(model: model, sourceURL: record.url)
                } label: { Text(verbatim: record.displayName) }
                TrustBadgeLabel(badge: AutomationTrustBadge(record.trust)).font(.body)
            } header: { Text("AUTO_BROWSER_REPOSITORY") }
        } else if family.source != "local" {
            Section {
                Text(verbatim: family.source).font(.footnote).textSelection(.enabled)
            } header: { Text("AUTO_BROWSER_REPOSITORY") }
        }
        if package.isComplete {
            Section {
                if !package.sourceFileNames.isEmpty {
                    NavigationLink("AUTO_BROWSER_SCRIPTS") { PluginScriptFilesView(model: model, package: package) }
                        .accessibilityIdentifier("plugins.package.scripts")
                }
                Button { showJSON = true } label: {
                    HStack {
                        Text("AUTO_BROWSER_MANIFEST_JSON").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("plugins.package.manifestJSON")
                if let selected {
                    NavigationLink("AUTO_BROWSER_TEST") {
                        ScriptDetailView(session: ScriptSession(controller: model.controller, revision: selected), testOnly: true)
                    }
                    .accessibilityIdentifier("plugins.package.test")
                }
            } header: { Text("AUTO_BROWSER_CONTENTS") }
        }
    }

    @ViewBuilder private func version(_ package: PluginPackagePresentation) -> some View {
        Section {
            if let published = package.manifest.publishedAt {
                LabeledContent {
                    Text(verbatim: PluginPublicationDate.string(published, locale: locale))
                        .accessibilityIdentifier("plugins.package.publishedAt")
                } label: {
                    Text(verbatim: package.manifest.version).accessibilityIdentifier("plugins.package.version")
                }
            } else {
                Text(verbatim: package.manifest.version).accessibilityIdentifier("plugins.package.version")
            }
            if let selected, let record, case .available = model.updateComparison(for: selected, record: record) {
                Button("AUTO_BROWSER_UPDATE") { prepareUpdate(selected, record: record) }
                    .disabled(busy).accessibilityIdentifier("plugins.package.update")
            }
        }
    }

    private func changeActivation(_ enabled: Bool, revision: InstalledRevision) {
        guard !busy else { return }
        isChangingActivation = true
        Task {
            defer { isChangingActivation = false }
            if enabled {
                await model.controller.refreshActivation()
                guard let current = model.selectedRevision(for: family), current.id == revision.id,
                      current.package.bytes == revision.package.bytes,
                      let generation = model.controller.activationSnapshot?.generation else { return }
                approval = PluginPackageApprovalRequest(operation: .activate(current, generation))
            } else {
                _ = await model.controller.revokeActivation(id: revision.id)
            }
        }
    }

    private func prepareUpdate(_ revision: InstalledRevision, record: RepositoryRecord) {
        guard !busy else { return }
        Task {
            guard let candidate = await model.prepareUpdate(revision, record: record) else { return }
            if candidate.requiresApproval {
                approval = PluginPackageApprovalRequest(operation: .update(candidate))
            } else {
                _ = await model.commitUpdate(candidate)
            }
        }
    }

    private func approve(_ request: PluginPackageApprovalRequest) {
        guard approval?.id == request.id, !busy else { return }
        approval = nil
        Task {
            switch request.operation {
                case let .activate(revision, generation):
                    isChangingActivation = true
                    await model.controller.activate(revision, expectedGeneration: generation)
                    isChangingActivation = false
                case let .update(candidate):
                    _ = await model.commitUpdate(candidate, approval: InstallationApproval(
                        packageBytes: candidate.package.bytes, expectedGrantGeneration: candidate.expectedGrantGeneration,
                    ))
            }
        }
    }
}

/// Short localized UTC calendar day for a manifest's publisher-declared `publishedAt`.
enum PluginPublicationDate {
    static func string(_ date: Date, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = locale
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style)
    }
}

private struct PluginPackageApprovalRequest: Identifiable {
    enum Operation { case activate(InstalledRevision, UUID), update(PluginBrowserUpdate) }
    let id = UUID()
    let operation: Operation
    var package: PluginPackage {
        switch operation {
            case let .activate(revision, _): revision.package
            case let .update(candidate): candidate.package
        }
    }

    var isUpdate: Bool {
        if case .update = operation {
            return true
        }; return false
    }
}
