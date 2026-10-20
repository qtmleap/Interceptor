import SwiftUI
import UIKit

/// Selectable JSON for inspection. The panel never accepts input and keeps large values scrollable.
struct PluginJSONViewer: UIViewRepresentable {
    let json: String
    let identifier: String
    var fillsAvailableSpace = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityIdentifier = identifier
        let base = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base, compatibleWith: view.traitCollection)
        view.textColor = .label
        if !view.text.utf8.elementsEqual(json.utf8) {
            view.text = json
            view.setContentOffset(.zero, animated: false)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        if fillsAvailableSpace, let height = proposal.height, height.isFinite, height > 0 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: min(max(natural.height, 80), 220))
    }
}
