import AutomationCore
import SwiftUI

/// One repository script. Owns an independent model (so leaving the parent list never cancels it); opening
/// only downloads and verifies the package for review. Import stays a separate explicit button.
struct RepositoryScriptDetailView: View {
    @State private var model: RepositoryDetailModel
    private let entry: IndexEntry
    @State private var isSourcePresented = false
    @State private var selectedFile: String?

    init(parent: RepositoryDetailModel, entry: IndexEntry) {
        _model = State(initialValue: parent.makeEntryModel())
        self.entry = entry
    }

    var body: some View {
        List {
            if model.package == nil {
                Section {
                    LabeledContent("AUTO_NAME") { Text(verbatim: entry.name) }
                    LabeledContent("AUTO_VERSION") { Text(verbatim: entry.version) }
                }
            }
            if let error = model.error {
                Section {
                    Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(AutomationStatusColor.error)
                        .accessibilityIdentifier("repo.script.error")
                    if model.package == nil {
                        Button("AUTO_RETRY") { model.select(entry) }.frame(minHeight: 44)
                            .accessibilityIdentifier("repo.script.retry")
                    }
                }
            }
            if model.phase == .fetching {
                Section { ProgressView().accessibilityIdentifier("repo.script.loading") }
            }
            if let package = model.package {
                review(package)
            }
        }
        .accessibilityIdentifier("repo.script.list")
        .navigationTitle(Text(verbatim: entry.name))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.package == nil, model.phase == .idle, model.error == nil {
                model.select(entry)
            }
        }
        .fullScreenCover(isPresented: $isSourcePresented) {
            if let package = model.package {
                PluginSourceReader(fileNames: package.sourceFiles.keys.sorted(), selection: $selectedFile,
                                   source: { _ in source(of: package) }, sourceIdentifier: "repo.script.source",
                                   pickerIdentifier: "repo.script.sourceFile", closeIdentifier: "repo.script.closeSource") {
                    isSourcePresented = false
                }
            }
        }
        // Presenting the reader may report this view as disappearing; only a real pop closes the model.
        .onDisappear { if !isSourcePresented { model.close() } }
        .tint(Color("PluginAccent"))
    }

    @ViewBuilder private func review(_ package: PluginPackage) -> some View {
        ScriptMetadataSection(manifest: package.manifest)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("AUTO_REVISION_HASH").font(.footnote).foregroundStyle(.secondary)
                HashText(value: package.revision)
            }
            .padding(.vertical, 8)
            Label("AUTO_HASH_MATCHES", systemImage: "checkmark.circle")
                .foregroundStyle(AutomationStatusColor.ok)
            signatureLabel
            if let key = model.record.keyFingerprint {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUTO_KEY_FINGERPRINT").font(.footnote).foregroundStyle(.secondary)
                    HashText(value: key.hex)
                }
                .padding(.vertical, 8)
            }
        } header: { Text("AUTO_SIGNATURE") } footer: { Text("AUTO_SIGNATURE_FOOTER") }
            .accessibilityIdentifier("repo.script.signature")
        ScriptTargetsSection(manifest: package.manifest)
        Section {
            PluginSourceRow(fileName: package.source == nil ? repositoryFile(in: package) : nil, identifier: "repo.script.openSource") {
                selectedFile = repositoryFile(in: package)
                isSourcePresented = true
            }
        } header: { Text("AUTO_SOURCE") }
        Section {
            DisclosureGroup("AUTO_DECLARED_MANIFEST") {
                Text(verbatim: (try? package.manifest.json.jsonString()) ?? "")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        Section {
            if model.phase == .imported {
                Label("AUTO_IMPORTED", systemImage: "checkmark.circle")
                    .foregroundStyle(AutomationStatusColor.ok).accessibilityIdentifier("repo.imported")
            } else {
                Button("AUTO_IMPORT_DISABLED") { model.importDisabled() }
                    .disabled(model.phase != .reviewing).frame(minHeight: 44)
                    .accessibilityIdentifier("repo.import")
            }
        } footer: { Text("AUTO_IMPORT_FOOTER") }
    }

    @ViewBuilder private var signatureLabel: some View {
        switch model.record.trust {
            case .pinned:
                Label("AUTO_SIG_PINNED", systemImage: "checkmark.seal").foregroundStyle(AutomationStatusColor.ok)
            case .signedUnverified:
                Label("AUTO_SIG_UNVERIFIED_KEY", systemImage: "questionmark.seal").foregroundStyle(AutomationStatusColor.warning)
            case .unsignedAcknowledged:
                Label("AUTO_SIG_UNSIGNED", systemImage: "exclamationmark.triangle").foregroundStyle(AutomationStatusColor.warning)
        }
    }
}

private extension RepositoryScriptDetailView {
    /// The chosen file, or the first one when nothing (or a file of another package) is selected.
    func repositoryFile(in package: PluginPackage) -> String? {
        let names = package.sourceFiles.keys.sorted()
        return selectedFile.flatMap { names.contains($0) ? $0 : nil } ?? names.first
    }

    func source(of package: PluginPackage) -> String {
        if let single = package.source {
            return single
        }
        return repositoryFile(in: package).flatMap { package.sourceFiles[$0] } ?? ""
    }
}
