import Runestone
import SwiftUI
import TreeSitterJavaScriptRunestone

/// Read-only, syntax-highlighted package source. The text is shown exactly as downloaded.
struct PluginSourceViewer: View {
    private let sourceUTF8: [UInt8]
    private let identifier: String
    private let fillsAvailableSpace: Bool
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 17 * 1.3

    /// The default is the compact, wrapping viewer. `fillsAvailableSpace` is the full-screen reader: it takes
    /// all offered space and does not wrap, so long lines scroll horizontally.
    init(source: String, identifier: String = "repo.script.source", fillsAvailableSpace: Bool = false) {
        sourceUTF8 = Array(source.utf8)
        self.identifier = identifier
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    var body: some View {
        if fillsAvailableSpace {
            PluginSourceViewerRepresentable(sourceUTF8: sourceUTF8, identifier: identifier, wraps: false)
        } else {
            // Approximate natural height by newline count, bounded so short scripts stay compact and large ones scroll.
            let lines = CGFloat(sourceUTF8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 })
            let height = min(max(lines * lineHeight + 24, 120), 320)
            PluginSourceViewerRepresentable(sourceUTF8: sourceUTF8, identifier: identifier, wraps: true).frame(height: height)
        }
    }
}

private struct PluginSourceViewerRepresentable: UIViewRepresentable {
    let sourceUTF8: [UInt8]
    let identifier: String
    let wraps: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.isEditable = false
        view.isSelectable = true
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .disabled
        view.isLineWrappingEnabled = wraps
        view.lineHeightMultiplier = 1.3
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.accessibilityLabel = NSLocalizedString("AUTO_SOURCE", comment: "")
        view.accessibilityIdentifier = identifier
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        view.accessibilityIdentifier = identifier
        apply(to: view, coordinator: context.coordinator)
    }

    /// Rebuilds the state only when the source or the content size category changed.
    private func apply(to view: TextView, coordinator: Coordinator) {
        let category = view.traitCollection.preferredContentSizeCategory
        guard coordinator.sourceUTF8 != sourceUTF8 || coordinator.category != category else { return }
        coordinator.sourceUTF8 = sourceUTF8
        coordinator.category = category
        let theme = ScaledCodeTheme(contentSizeCategory: category)
        view.setState(TextViewState(text: String(decoding: sourceUTF8, as: UTF8.self), theme: theme, language: .javaScript))
    }

    final class Coordinator {
        var sourceUTF8: [UInt8]?
        var category: UIContentSizeCategory?
    }
}
