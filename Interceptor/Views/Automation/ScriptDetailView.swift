import AutomationCore
import AutomationRuntime
import SwiftUI
import UIKit

struct ScriptDetailView: View {
    @State var session: ScriptSession

    var body: some View {
        Form {
            Section {
                TrustBadgeLabel(badge: session.badge)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AUTO_REVISION_HASH").font(.footnote).foregroundStyle(.secondary)
                    HashText(value: session.revision.package.revision)
                }
                if case .localEdit(let parent) = session.revision.provenance.origin {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AUTO_PARENT_HASH").font(.footnote).foregroundStyle(.secondary)
                        HashText(value: parent)
                    }
                }
            } header: { Text(verbatim: session.revision.package.manifest.name) } footer: { Text("AUTO_DISABLED_FOOTER") }
            Section {
                PluginSourceEditor(text: $session.source).frame(minHeight: 260)
                if let error = session.saveError {
                    Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(.red)
                }
            } header: { Text("AUTO_SOURCE") } footer: { Text("AUTO_SAVE_FOOTER") }
            Section {
                Picker("AUTO_HOOK", selection: $session.hook) {
                    Text("AUTO_HOOK_REQUEST").tag(JavaScriptHook.request)
                    Text("AUTO_HOOK_RESPONSE").tag(JavaScriptHook.response)
                }
                .pickerStyle(.segmented).accessibilityIdentifier("script.hook")
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
                if session.isDirty { Text("AUTO_SAVE_BEFORE_RUN").font(.footnote).foregroundStyle(.secondary) }
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
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("script.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("AUTO_KEYBOARD_DONE") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onDisappear { session.leave() }
        .tint(Color("PluginAccent"))
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
        case .failed(let key): Text(LocalizedStringKey(key)).foregroundStyle(.red).accessibilityIdentifier("script.error")
        case .finished(let actions):
            Text("AUTO_VALIDATED_ACTIONS").font(.headline).accessibilityIdentifier("script.validated")
            Label("AUTO_NOT_SENT", systemImage: "paperplane.slash")
            if actions.isEmpty { Text("AUTO_NO_ACTIONS").foregroundStyle(.secondary) }
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 4) {
                    HashText(value: action.endpointID.uuidString)
                    Text(verbatim: action.json).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}
