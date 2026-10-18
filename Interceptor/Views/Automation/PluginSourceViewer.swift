import Runestone
import SwiftUI
import TreeSitterJavaScriptRunestone

/// Read-only, syntax-highlighted package source. The text is shown exactly as downloaded.
struct PluginSourceViewer: View {
    let source: String
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 17 * 1.3

    var body: some View {
        // Approximate natural height by newline count, bounded so short scripts stay compact and large ones scroll.
        let lines = CGFloat(source.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 })
        let height = min(max(lines * lineHeight + 24, 120), 320)
        PluginSourceViewerRepresentable(text: source).frame(height: height)
    }
}

private struct PluginSourceViewerRepresentable: UIViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.isEditable = false
        view.isSelectable = true
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .disabled
        view.isLineWrappingEnabled = true
        view.lineHeightMultiplier = 1.3
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.accessibilityLabel = NSLocalizedString("AUTO_SOURCE", comment: "")
        view.accessibilityIdentifier = "repo.script.source"
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    /// Rebuilds the state only when the source or the content size category changed.
    private func apply(to view: TextView, coordinator: Coordinator) {
        let category = view.traitCollection.preferredContentSizeCategory
        guard coordinator.text != text || coordinator.category != category else { return }
        coordinator.text = text
        coordinator.category = category
        let theme = ScaledCodeTheme(contentSizeCategory: category)
        view.setState(TextViewState(text: text, theme: theme, language: .javaScript))
    }

    final class Coordinator {
        var text: String?
        var category: UIContentSizeCategory?
    }
}
