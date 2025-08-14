//
//  QuantumLeap.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import QuantumLeap
import SwiftUI

struct TokenListView: View {
    @Environment(WebTokenStore.self) private var store: WebTokenStore

    var body: some View {
        ForEach(store.tokens, content: { token in
            Section(content: {
                Text(token.accessToken)
                    .lineLimit(1)
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/\(token.contentId.rawValue)")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
            }, header: {
                Text("HEADER_SPLATOON_2")
            }, footer: {
                Text("FOOTER_SPLATOON_2")
            })
        })
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
        .textContentType(.password)
        .navigationTitle(Text("NINTENDO_TOKEN_LIST"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension QuantumLeap {
    static func TokenList() -> some View {
        TokenListView()
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            QuantumLeap.TokenList()
        })
    })
    .environment(WebTokenStore.default)
}
