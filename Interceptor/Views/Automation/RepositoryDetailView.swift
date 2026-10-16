import AutomationCore
import SwiftUI

struct RepositoryDetailView: View {
    @State var model: RepositoryDetailModel

    var body: some View {
        List {
            Section {
                TrustBadgeLabel(badge: model.badge)
                Text(verbatim: model.record.url.canonical).font(.footnote).textSelection(.enabled)
                if let key = model.record.keyFingerprint { HashText(value: key.hex) }
            } header: { Text(verbatim: model.record.displayName) } footer: { Text("AUTO_ACCEPTED_FOOTER") }
            if case .signedUnverified = model.record.trust {
                Section {
                    TextField("AUTO_FINGERPRINT_PLACEHOLDER", text: $model.fingerprintText, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("repo.detail.fingerprint")
                    Button("AUTO_VERIFY_KEY_ONLY") { model.pin() }.disabled(!model.canPin).frame(minHeight: 44)
                        .accessibilityIdentifier("repo.detail.pin")
                } footer: { Text("AUTO_KEY_FOOTER") }
            }
            Section("AUTO_SCRIPTS") {
                if model.entries.isEmpty { Text("AUTO_SCRIPTS_EMPTY").foregroundStyle(.secondary) }
                ForEach(model.entries, id: \.id) { entry in
                    Button { model.select(entry) } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: entry.name).foregroundStyle(.primary)
                            Text(verbatim: entry.version).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("repo.entry.\(entry.name)")
                }
            }
            if let error = model.error {
                Section { Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(.red) }
            }
            if model.phase == .fetching { Section { ProgressView() } }
            if let entry = model.selected, let package = model.package { review(entry, package) }
        }
        .accessibilityIdentifier("repository.detail")
        .navigationTitle(Text(verbatim: model.record.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.close() }
        .tint(Color("PluginAccent"))
    }

    @ViewBuilder private func review(_ entry: IndexEntry, _ package: PluginPackage) -> some View {
        Section {
            LabeledContent("AUTO_NAME") { Text(verbatim: package.manifest.name) }
            LabeledContent("AUTO_VERSION") { Text(verbatim: package.manifest.version) }
            VStack(alignment: .leading, spacing: 4) {
                Text("AUTO_REVISION_HASH").font(.footnote).foregroundStyle(.secondary)
                HashText(value: package.revision)
            }
            TrustBadgeLabel(badge: model.badge)
            Text(verbatim: "\(package.manifest.subscriptions.count) · \(package.manifest.read.metadata.joined(separator: ", "))").font(.footnote)
        } header: { Text("AUTO_REVIEW_PACKAGE") } footer: { Text("AUTO_MANIFEST_FOOTER") }
        Section("AUTO_DECLARED_MANIFEST") {
            Text(verbatim: (try? package.manifest.json.jsonString()) ?? "").font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Section("AUTO_SOURCE") {
            Text(verbatim: package.source).font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Section {
            if model.phase == .imported {
                Label("AUTO_IMPORTED", systemImage: "checkmark.circle").accessibilityIdentifier("repo.imported")
            } else {
                Button("AUTO_IMPORT_DISABLED") { model.importDisabled() }
                    .disabled(model.phase != .reviewing).frame(minHeight: 44)
                    .accessibilityIdentifier("repo.import")
            }
        } footer: { Text("AUTO_IMPORT_FOOTER") }
    }
}
