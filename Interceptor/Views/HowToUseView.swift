import Mudmouth
import SwiftUI

struct HowToUseView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0
    @State private var isSettingUp = false

    private var hasConsent: Bool {
        consentVersion == CaptureAuthorization.version
    }

    /// The container stays stable so the sheet sizing anchor never moves between branches.
    var body: some View {
        ZStack {
            if isSettingUp {
                FirstLaunchView(flow: .captureSetup)
            } else {
                overview
            }
        }
        .tint(Color(uiColor: .systemBlue))
    }

    private var overview: some View {
        NavigationStack {
            Form {
                Section {
                    Text("HOW_TO_USE_PREPARE_DESCRIPTION")
                    Button {
                        guard hasConsent else { return }
                        isSettingUp = true
                    } label: {
                        Text("Begin Capture Setup")
                            .font(.headline)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasConsent)
                    .accessibilityIdentifier("guide.beginSetup")
                } header: {
                    Label("HOW_TO_USE_PREPARE_TITLE", systemImage: "checkmark.shield")
                }
                Section {
                    Text("HOW_TO_USE_CAPTURE_DESCRIPTION")
                } header: {
                    Label("HOW_TO_USE_CAPTURE_TITLE", systemImage: "network")
                }
                Section {
                    Text("HOW_TO_USE_REVIEW_DESCRIPTION")
                } header: {
                    Label("HOW_TO_USE_REVIEW_TITLE", systemImage: "list.bullet.rectangle")
                }
                Section {
                    Text("HOW_TO_USE_HOSTS_DESCRIPTION")
                } header: {
                    Label("HOW_TO_USE_HOSTS_TITLE", systemImage: "info.circle")
                }
            }
            .accessibilityIdentifier("guide.overview")
            .textCase(nil)
            .navigationTitle("TITLE_HOW_TO_USE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
