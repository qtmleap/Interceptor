import LicenseList
import SwiftUI

/// Adds the vendored engine notice alongside SwiftPM dependency notices.
struct PluginLicenseListStyle: LicenseListViewStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> some View {
        List {
            NavigationLink("QuickJS") { QuickJSLicenseView() }
            ForEach(configuration.libraries) { library in
                NavigationLink {
                    LicenseView(library: library)
                } label: {
                    Text(verbatim: library.name)
                }
            }
        }
    }
}

struct QuickJSLicenseView: View {
    private var notice: String {
        guard let url = Bundle.main.url(forResource: "QuickJS-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "QuickJS — MIT License (Fabrice Bellard and Charlie Gordon)."
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(verbatim: notice)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("QuickJS")
        .navigationBarTitleDisplayMode(.inline)
    }
}
