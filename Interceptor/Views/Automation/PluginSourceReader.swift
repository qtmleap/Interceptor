import SwiftUI

/// The row that opens the full-screen source reader. Shows the selected file so the destination is obvious.
struct PluginSourceRow: View {
    let fileName: String?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("AUTO_SOURCE").foregroundStyle(.primary)
                Spacer()
                if let fileName {
                    Text(verbatim: fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Full-screen, read-only source. Presenting it is a view concern only: it never touches the session's run
/// state, and the file choice is the caller's binding, never runtime dispatch.
struct PluginSourceReader: View {
    let fileNames: [String]
    @Binding var selection: String?
    let source: (String?) -> String
    let sourceIdentifier: String
    let pickerIdentifier: String
    let closeIdentifier: String
    var title: String?
    var accentColor = Color("PluginAccent")
    let done: () -> Void

    var body: some View {
        NavigationStack {
            PluginSourceViewer(source: source(selection), identifier: sourceIdentifier, fillsAvailableSpace: true)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(title.map { Text(verbatim: $0) } ?? Text("AUTO_SOURCE"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("AUTO_KEYBOARD_DONE", action: done).accessibilityIdentifier(closeIdentifier)
                    }
                    if fileNames.count > 1 {
                        ToolbarItem(placement: .principal) {
                            Picker("AUTO_SOURCE_FILE", selection: $selection) {
                                ForEach(fileNames, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                            }
                            .pickerStyle(.menu).accessibilityIdentifier(pickerIdentifier)
                        }
                    }
                }
        }
        .tint(accentColor)
    }
}
