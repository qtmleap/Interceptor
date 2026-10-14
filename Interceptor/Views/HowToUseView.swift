import SwiftUI

struct HowToUseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("HOW_TO_USE_PREPARE_DESCRIPTION")
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
