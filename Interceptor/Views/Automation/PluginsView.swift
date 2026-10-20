import AutomationCore
import SwiftUI
import UIKit

/// Presented full screen from Settings, with its own three destinations and one shared queue.
struct PluginsView: View {
    @State private var model: PluginBrowserModel

    init() {
        _model = State(initialValue: PluginBrowserModel(controller: AutomationController.live()))
    }

    var body: some View {
        PluginBrowserView(model: model)
    }
}

struct TrustBadgeLabel: View {
    let badge: AutomationTrustBadge
    var body: some View {
        Label(LocalizedStringKey(badge.titleKey), systemImage: badge.systemImage)
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch badge {
            case .publisherKeyVerified: AutomationStatusColor.ok
            case .unsigned, .signedKeyUnverified: AutomationStatusColor.warning
            case .localEdit, .localFile: .secondary
        }
    }
}

/// Read-only, selectable fingerprint text. Character wrapping never inserts visual hyphens.
struct HashText: UIViewRepresentable {
    let value: String
    let identifier: String?

    init(value: String, identifier: String? = nil) {
        self.value = value
        self.identifier = identifier
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = identifier
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityIdentifier = identifier
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        paragraph.lineBreakStrategy = []
        let baseSize = UIFont.preferredFont(forTextStyle: .footnote,
                                            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
            compatibleWith: view.traitCollection,
        )
        view.attributedText = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
