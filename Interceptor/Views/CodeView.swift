//
//  CodeView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/17.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Runestone
import SwiftUI
import TreeSitter
import TreeSitterJavaScript
import TreeSitterJavaScriptQueries
import TreeSitterJSON
import TreeSitterJSONRunestone

/// `DefaultTheme` is `final`, so this forwards every `Theme` member to it and only replaces the fonts.
/// Runestone compares themes by identity, so a new instance is created for every content size category.
final class ScaledCodeTheme: Runestone.Theme {
    static let baseFontSize: CGFloat = 17
    static let maximumFontSize: CGFloat = 40

    let contentSizeCategory: UIContentSizeCategory
    let font: UIFont
    let lineNumberFont: UIFont
    private let base: DefaultTheme = .init()

    init(contentSizeCategory: UIContentSizeCategory) {
        let traits: UITraitCollection = .init(preferredContentSizeCategory: contentSizeCategory)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: Self.baseFontSize, weight: .regular),
            maximumPointSize: Self.maximumFontSize,
            compatibleWith: traits,
        )
        self.contentSizeCategory = contentSizeCategory
        font = scaled
        lineNumberFont = scaled
    }

    var textColor: UIColor {
        base.textColor
    }

    var gutterBackgroundColor: UIColor {
        base.gutterBackgroundColor
    }

    var gutterHairlineColor: UIColor {
        base.gutterHairlineColor
    }

    var gutterHairlineWidth: CGFloat {
        base.gutterHairlineWidth
    }

    var lineNumberColor: UIColor {
        base.lineNumberColor
    }

    var selectedLineBackgroundColor: UIColor {
        base.selectedLineBackgroundColor
    }

    var selectedLinesLineNumberColor: UIColor {
        base.selectedLinesLineNumberColor
    }

    var selectedLinesGutterBackgroundColor: UIColor {
        base.selectedLinesGutterBackgroundColor
    }

    var invisibleCharactersColor: UIColor {
        base.invisibleCharactersColor
    }

    var pageGuideHairlineColor: UIColor {
        base.pageGuideHairlineColor
    }

    var pageGuideHairlineWidth: CGFloat {
        base.pageGuideHairlineWidth
    }

    var pageGuideBackgroundColor: UIColor {
        base.pageGuideBackgroundColor
    }

    var markedTextBackgroundColor: UIColor {
        base.markedTextBackgroundColor
    }

    var markedTextBackgroundCornerRadius: CGFloat {
        base.markedTextBackgroundCornerRadius
    }

    func textColor(for highlightName: String) -> UIColor? {
        base.textColor(for: highlightName)
    }

    func font(for highlightName: String) -> UIFont? {
        base.font(for: highlightName)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        base.fontTraits(for: highlightName)
    }

    func shadow(for highlightName: String) -> NSShadow? {
        base.shadow(for: highlightName)
    }

    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        base.highlightedRange(forFoundTextRange: foundTextRange, ofStyle: style)
    }
}

struct CodeView: UIViewControllerRepresentable {
    let text: String
    let language: TreeSitterLanguage

    func makeUIViewController(context: Context) -> TextViewController {
        .init(text: text, language: language)
    }

    func updateUIViewController(_ uiViewController: TextViewController, context: Context) {}
}

class TextViewController: UIViewController {
    private let text: String
    private var language: TreeSitterLanguage
    private weak var textView: TextView?
    private var appliedTheme: ScaledCodeTheme?

    init(text: String, language: TreeSitterLanguage) {
        self.text = text
        self.language = language
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeTheme() -> ScaledCodeTheme {
        .init(contentSizeCategory: traitCollection.preferredContentSizeCategory)
    }

    /// Single UIKit path for Dynamic Type changes. Also used after `setState`, which replaces the theme with the state's.
    private func applyLatestTheme() {
        guard let textView else { return }
        let latest = makeTheme()
        if let appliedTheme, appliedTheme.contentSizeCategory == latest.contentSizeCategory,
           textView.theme === appliedTheme
        {
            return
        }
        appliedTheme = latest
        textView.theme = latest
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let textView: TextView = .init()
        textView.accessibilityIdentifier = "CapturedBodyText"
        textView.isEditable = false
        textView.isSelectable = true
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .disabled
        textView.showPageGuide = true
        textView.showTabs = false
        textView.showSpaces = false
        textView.showLineBreaks = false
        textView.showSoftLineBreaks = false
        textView.lineHeightMultiplier = 1.3
        textView.backgroundColor = .systemBackground
        self.textView = textView
        // Read traits on the main thread; the background closure only receives values.
        let initialTheme = makeTheme()
        appliedTheme = initialTheme
        textView.theme = initialTheme
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: TextViewController, _) in
            controller.applyLatestTheme()
        }
        let text = text
        let language = language
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = TextViewState(text: text, theme: initialTheme, language: language)
            DispatchQueue.main.async {
                guard let self, let textView = self.textView else { return }
                textView.setState(state)
                // setState adopts the state's (possibly stale) theme; reapply the latest.
                self.applyLatestTheme()
            }
        }
        view.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

#Preview {
    CodeView(
        text: String(data: try! JSONSerialization.data(withJSONObject: [
            "key": "value",
            "array": [1, 2, 3],
            "nested": [
                "key": "nestedValue",
            ],
        ], options: .prettyPrinted), encoding: .utf8)!,
        language: .json,
    )
}
