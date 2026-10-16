import Runestone
import SwiftUI
import TreeSitterJavaScriptRunestone

/// A separate editable view; captured response bodies keep their read-only CodeView.
struct PluginSourceEditor: UIViewRepresentable {
    @Binding var text: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.editorDelegate = context.coordinator
        view.accessibilityIdentifier = "plugin.source"
        view.isEditable = true
        view.isSelectable = true
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .disabled
        view.backgroundColor = .systemBackground
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        let theme = ScaledCodeTheme(contentSizeCategory: view.traitCollection.preferredContentSizeCategory)
        context.coordinator.category = theme.contentSizeCategory
        view.setState(TextViewState(text: text, theme: theme, language: .javaScript))
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text {
            context.coordinator.applying = true
            view.text = text
            context.coordinator.applying = false
        }
        let category = view.traitCollection.preferredContentSizeCategory
        if context.coordinator.category != category {
            context.coordinator.category = category
            view.theme = ScaledCodeTheme(contentSizeCategory: category)
        }
    }

    final class Coordinator: NSObject, TextViewDelegate {
        var text: Binding<String>
        var applying = false
        var category: UIContentSizeCategory?

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: TextView) {
            guard !applying else { return }
            text.wrappedValue = textView.text
        }

        func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement.utf8.count <= 131_072,
                  let swiftRange = Range(range, in: textView.text) else { return false }
            let proposed = textView.text.replacingCharacters(in: swiftRange, with: replacement)
            return proposed.utf8.count <= 131_072
        }
    }
}
