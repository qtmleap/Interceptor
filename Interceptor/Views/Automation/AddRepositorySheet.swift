import AutomationCore
import SwiftUI

struct AddRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddRepositoryModel
    @State private var confirmUnverified = false

    init(controller: AutomationController) { _model = State(initialValue: AddRepositoryModel(controller: controller)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/repository.json", text: $model.urlText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.phase == .fetching || model.phase == .adding)
                        .accessibilityIdentifier("repo.url")
                    Button("AUTO_PREVIEW") { model.preview() }
                        .disabled(!model.canPreview).frame(minHeight: 44)
                        .accessibilityIdentifier("repo.preview")
                    if model.phase == .fetching { ProgressView() }
                } header: { Text("AUTO_REPOSITORY_URL") } footer: { Text("AUTO_PREVIEW_FOOTER") }
                if let error = model.error {
                    Section { Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(.red) }
                        .accessibilityIdentifier("repo.error")
                }
                if let snapshot = model.snapshot { review(snapshot) }
            }
            .accessibilityIdentifier("repo.addForm")
            .navigationTitle(Text("AUTO_ADD_REPOSITORY"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }.disabled(model.phase == .adding).accessibilityIdentifier("repo.cancel")
                }
            }
            .onChange(of: model.phase) { if model.phase == .added { close() } }
            .confirmationDialog("AUTO_UNVERIFIED_TITLE", isPresented: $confirmUnverified, titleVisibility: .visible) {
                Button("AUTO_ADD_UNVERIFIED", role: .destructive) { model.addUnverified() }
                    .accessibilityIdentifier("repo.confirmUnverified")
            } message: { Text("AUTO_UNVERIFIED_WARNING") }
        }
        .interactiveDismissDisabled(model.phase == .adding)
        .onDisappear { model.cancel() }
        .tint(Color("PluginAccent"))
    }

    private func close() { model.cancel(); dismiss() }

    @ViewBuilder private func review(_ s: VerifiedSnapshot) -> some View {
        Section("AUTO_REPOSITORY_DETAILS") {
            LabeledContent("AUTO_NAME") { Text(verbatim: s.index.name) }
            LabeledContent("AUTO_URL") { Text(verbatim: s.url.canonical).textSelection(.enabled) }
            LabeledContent("AUTO_SCRIPT_COUNT") { Text(verbatim: "\(s.index.plugins.count)") }
            VStack(alignment: .leading, spacing: 4) {
                Text("AUTO_PAYLOAD_HASH").font(.footnote).foregroundStyle(.secondary)
                HashText(value: s.payloadDigest)
            }
            TrustBadgeLabel(badge: badge(s))
        }
        if let key = model.offeredFingerprint {
            Section {
                HashText(value: key)
                TextField("AUTO_FINGERPRINT_PLACEHOLDER", text: $model.fingerprintText, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("repo.fingerprint")
                Button("AUTO_VERIFY_KEY") { model.verifyAndAdd() }
                    .disabled(!model.canVerifyAndAdd).frame(minHeight: 44)
                    .accessibilityIdentifier("repo.verifyAdd")
            } header: { Text("AUTO_KEY_FINGERPRINT") } footer: { Text("AUTO_KEY_FOOTER") }
        }
        Section {
            if model.acceptance?.requiresAcknowledgment == false {
                Button("AUTO_ADD") { model.addContinuing() }.frame(minHeight: 44).accessibilityIdentifier("repo.add")
            } else {
                Button("AUTO_ADD_UNVERIFIED", role: .destructive) { confirmUnverified = true }
                    .frame(minHeight: 44).accessibilityIdentifier("repo.addUnverified")
            }
        } footer: { Text("AUTO_ADD_FOOTER") }
            .disabled(model.phase == .adding)
    }

    private func badge(_ s: VerifiedSnapshot) -> AutomationTrustBadge {
        if let trust = model.acceptance?.resultingTrust { return AutomationTrustBadge(trust) }
        if case .signed = s.signature { return .signedKeyUnverified }
        return .unsigned
    }
}
