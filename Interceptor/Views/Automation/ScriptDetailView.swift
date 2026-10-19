import AutomationCore
import AutomationRuntime
import SwiftUI
import UIKit

struct ScriptDetailView: View {
    @State var session: ScriptSession
    @State private var approvalGeneration: UUID?
    @State private var confirmsActivation = false

    var body: some View {
        Form {
            Section {
                TrustBadgeLabel(badge: session.badge)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AUTO_REVISION_HASH").font(.footnote).foregroundStyle(.secondary)
                    HashText(value: session.revision.package.revision)
                }
                if case let .localEdit(parent) = session.revision.provenance.origin {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AUTO_PARENT_HASH").font(.footnote).foregroundStyle(.secondary)
                        HashText(value: parent)
                    }
                }
            } header: { Text(verbatim: session.revision.package.manifest.name) } footer: { Text("AUTO_DISABLED_FOOTER") }
            ScriptMetadataSection(manifest: session.revision.package.manifest)
            ScriptTargetsSection(manifest: session.revision.package.manifest)
            if session.isV2 {
                activationSection
            }
            Section {
                if session.isV2 {
                    Picker("AUTO_SOURCE_FILE", selection: $session.selectedSourceFile) {
                        ForEach(session.sourceFileNames, id: \.self) { file in
                            Text(verbatim: file).tag(Optional(file))
                        }
                    }
                    .pickerStyle(.menu).accessibilityIdentifier("script.sourceFile")
                }
                PluginSourceEditor(text: $session.source).frame(minHeight: 260)
                if let key = session.saveErrorKey {
                    Text(LocalizedStringKey(key)).foregroundStyle(AutomationStatusColor.error)
                }
            } header: { Text("AUTO_SOURCE") } footer: { Text(LocalizedStringKey(session.isV2 ? "AUTO_SAVE_PACKAGE_FOOTER" : "AUTO_SAVE_FOOTER")) }
            Section {
                if session.isV2 {
                    Picker("AUTO_HOOK", selection: $session.hook) {
                        ForEach(session.hooks, id: \.self) { hook in Text(verbatim: hook.rawValue).tag(hook) }
                    }
                    .pickerStyle(.menu).accessibilityIdentifier("script.hook")
                } else {
                    Picker("AUTO_HOOK", selection: $session.hook) {
                        Text("AUTO_HOOK_REQUEST").tag(JavaScriptHook.request)
                        Text("AUTO_HOOK_RESPONSE").tag(JavaScriptHook.response)
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("script.hook")
                }
                jsonEditor("AUTO_SYNTHETIC_EVENT", text: $session.eventText, id: "script.event")
                jsonEditor("AUTO_SYNTHETIC_CONFIG", text: $session.configText, id: "script.config")
                HStack {
                    Button("AUTO_RUN_TEST") { session.run() }.disabled(!session.canRun).frame(minHeight: 44)
                        .accessibilityIdentifier("script.run")
                    Spacer()
                    if session.isRunning {
                        Button("Cancel", role: .cancel) { session.cancelRun() }.frame(minHeight: 44)
                            .accessibilityIdentifier("script.cancel")
                    }
                }
                if session.isDirty {
                    Text("AUTO_SAVE_BEFORE_RUN").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("AUTO_DRY_RUN") } footer: { Text("AUTO_SYNTHETIC_FOOTER") }
            Section { result }
        }
        .accessibilityIdentifier("script.form")
        .navigationTitle(Text(verbatim: session.revision.package.manifest.name))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("AUTO_SAVE_SHORT") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await session.saveAsLocalEdit() }
                }
                .disabled(!session.canSave)
                .accessibilityIdentifier("script.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("AUTO_KEYBOARD_DONE") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .task { await session.refreshActivation() }
        .confirmationDialog("AUTO_ACTIVATE_CONFIRM_TITLE", isPresented: $confirmsActivation, titleVisibility: .visible) {
            Button("AUTO_ACTIVATE_CONFIRM") {
                if let generation = approvalGeneration {
                    Task { await session.activate(expectedGeneration: generation) }
                }
            }
            .accessibilityIdentifier("script.confirmActivation")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: session.revision.package.manifest.name + "\n")
                + Text("AUTO_TARGET_HOSTS") + Text(verbatim: ": " + declaredHosts + "\n")
                + Text("AUTO_ACTIVATION_DATA") + Text(verbatim: " " + declaredData + "\n")
                + Text(LocalizedStringKey(session.revision.package.manifest.writeRequestBody ? "AUTO_WRITE_REQUEST" : "AUTO_NO_WRITE_REQUEST"))
                + Text(verbatim: "\n")
                + Text(LocalizedStringKey(session.revision.package.manifest.writeResponseBody ? "AUTO_WRITE_RESPONSE" : "AUTO_NO_WRITE_RESPONSE"))
                + Text(verbatim: "\n") + Text("AUTO_WEBHOOK_FOOTER")
                + Text(verbatim: "\n") + Text("AUTO_ACTIVATE_CONFIRM_MESSAGE")
                + Text(verbatim: "\n" + session.revision.package.revision)
        }
        .onDisappear { session.leave() }
        .tint(Color("PluginAccent"))
    }

    private var activationSection: some View {
        Section {
            LabeledContent("AUTO_LIVE_STATUS") {
                Text(LocalizedStringKey(session.isActive ? "AUTO_LIVE_ACTIVE" : "AUTO_LIVE_INACTIVE"))
            }
            if session.isActive {
                Button("AUTO_REVOKE", role: .destructive) { Task { await session.revokeActivation() } }
                    .accessibilityIdentifier("script.revoke")
            } else {
                Button("AUTO_ACTIVATE") {
                    Task {
                        await session.refreshActivation()
                        approvalGeneration = session.activationGeneration
                        confirmsActivation = approvalGeneration != nil
                    }
                }
                .disabled(session.isDirty || !session.activationAvailable)
                .accessibilityIdentifier("script.activate")
            }
        } header: { Text("AUTO_LIVE") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("AUTO_ACTIVATION_SCOPE")
                Text(verbatim: declaredHosts)
                Text("AUTO_ACTIVATION_DATA")
                Text(verbatim: declaredData)
                Text(LocalizedStringKey(session.revision.package.manifest.writeRequestBody ? "AUTO_WRITE_REQUEST" : "AUTO_NO_WRITE_REQUEST"))
                Text(LocalizedStringKey(session.revision.package.manifest.writeResponseBody ? "AUTO_WRITE_RESPONSE" : "AUTO_NO_WRITE_RESPONSE"))
                Text("AUTO_WEBHOOK_FOOTER")
                Text("AUTO_ACTIVATION_CONNECTION")
                if let key = session.activationErrorKey {
                    Text(LocalizedStringKey(key)).foregroundStyle(AutomationStatusColor.error).accessibilityIdentifier("script.activationError")
                }
            }
        }
    }

    private var declaredHosts: String {
        Array(Set(session.revision.package.manifest.matches.flatMap(\.hosts))).sorted().joined(separator: ", ")
    }

    private var declaredData: String {
        let read = session.revision.package.manifest.read
        var fields = read.metadata + read.headers.map { "header: " + $0 } + read.queryKeys.map { "query: " + $0 }
        if read.body == .json {
            fields.append(String(localized: "AUTO_JSON_BODY"))
        }
        return fields.isEmpty ? String(localized: "AUTO_READ_NONE") : fields.joined(separator: ", ")
    }

    private func jsonEditor(_ title: LocalizedStringKey, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(.footnote, design: .monospaced)).frame(minHeight: 120)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(id)
        }
    }

    @ViewBuilder private var result: some View {
        switch session.runState {
            case .idle: Text("AUTO_NO_RESULT").foregroundStyle(.secondary)
            case .running: ProgressView()
            case let .failed(key): Text(LocalizedStringKey(key)).foregroundStyle(AutomationStatusColor.error).accessibilityIdentifier("script.error")
            case let .finished(actions):
                Text(LocalizedStringKey(session.isV2 ? "AUTO_TEST_RESULT" : "AUTO_VALIDATED_ACTIONS")).foregroundStyle(AutomationStatusColor.ok).font(.headline).accessibilityIdentifier("script.validated")
                Label("AUTO_NOT_SENT", systemImage: "paperplane.slash")
                if let preview = session.bodyPreview {
                    Text("AUTO_BODY_PREVIEW").font(.headline)
                    Text(verbatim: preview).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("script.bodyPreview")
                }
                if actions.isEmpty {
                    Text("AUTO_NO_ACTIONS").foregroundStyle(.secondary)
                }
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        HashText(value: action.endpointID.uuidString)
                        Text(verbatim: action.json).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
        }
    }
}
