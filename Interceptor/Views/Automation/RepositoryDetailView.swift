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
                    NavigationLink {
                        RepositoryScriptDetailView(parent: model, entry: entry)
                    } label: {
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
        }
        .accessibilityIdentifier("repository.detail")
        .navigationTitle(Text(verbatim: model.record.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.close() }
        .tint(Color("PluginAccent"))
    }
}
