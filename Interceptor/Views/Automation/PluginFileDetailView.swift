import AutomationCore
import SwiftUI

struct PluginManifestJSONView: View {
    let package: PluginPackagePresentation
    let done: () -> Void
    private var json: String { package.manifestJSON }

    var body: some View {
        NavigationStack {
            PluginJSONViewer(json: json, identifier: "plugins.manifest.json", fillsAvailableSpace: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .navigationTitle("AUTO_BROWSER_MANIFEST_JSON")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("AUTO_KEYBOARD_DONE", action: done).accessibilityIdentifier("plugins.manifest.close")
                    }
                }
        }
        .tint(PluginBrowserColor.accent)
    }
}
