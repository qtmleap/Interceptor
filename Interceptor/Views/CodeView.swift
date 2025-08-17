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
import TreeSitterJSON
import TreeSitterJSONRunestone

struct CodeView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> TextViewController {
        let controller: TextViewController = .init(text: text)
        return controller
    }

    func updateUIViewController(_ uiViewController: TextViewController, context: Context) {}
}

class TextViewController: UIViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let textView: TextView = .init()
        textView.isEditable = false
        textView.isSelectable = false
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.showPageGuide = true
        textView.showTabs = false
        textView.showSpaces = false
        textView.showLineBreaks = false
        textView.showSoftLineBreaks = false
        textView.lineHeightMultiplier = 1.3
        textView.backgroundColor = .systemBackground
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let state = TextViewState(text: text, language: .json)
            DispatchQueue.main.async {
                textView.setState(state)
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
    )
}
