//
//  TokenList.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI

struct TokenListView: View {
    @Environment(WebTokenStore.self) private var store: WebTokenStore

    var body: some View {
        Section(content: {
            ForEach(store.tokens, content: { token in
                NavigationLink(destination: {
                    TokenConfigView(token: token)
                }, label: {
                    Text(NSLocalizedString(token.host, bundle: .main, comment: ""))
                })
            })
        }, header: {
            Text("TITLE_GAME_WEB_TOKEN")
        })
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
        .textContentType(.password)
    }
}

struct TokenConfigView: View {
//    @Binding var token: AccessToken
    @State private var destinationURL: String = ""
    @State private var isEditable: Bool = false
    let token: AccessToken

    var body: some View {
        Form(content: {
            Section(content: {
                LabeledContent(content: {
                    Toggle(isOn: .constant(false), label: {
                        Text("LABEL_REGENERATE_FROM_GAME_WEB_TOKEN")
                    })
                }, label: {
                    Image(systemName: "wifi.exclamationmark")
                })
                LabeledContent(content: {
                    Toggle(isOn: .constant(false), label: {
                        Text("LABEL_OPEN_APP_WHEN_TOKEN_EXPIRED")
                    })
                }, label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                })
            }, header: {
                Text("HEADER_GAME_WEB_TOKEN_EXPIRED_ACTION")
            }, footer: {
                Text("LABEL_GAME_WEB_TOKEN_EXPIRED_ACTION_FOOTER")
            })
            .disabled(true)
            Section(content: {
                TextField("LABEL_DESTINATION_URL", text: $destinationURL)
                    .keyboardType(.URL)
                    .disabled(!isEditable)
            }, header: {
                Text("HEADER_SERVICE_SETTING")
            }, footer: {
                Text("FOOTER_SERVICE_SETTING")
            })
            Section(content: {
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_MEMBERSHIP", bundle: .main, comment: ""), content: {
                    Text(token.gtoken.payload.membership.active ? "ENABLED" : "DISABLED")
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_IS_CHILD_RESTRICTED", bundle: .main, comment: ""), content: {
                    Text(token.gtoken.payload.isChildRestricted ? "ENABLED" : "DISABLED")
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_AUD", comment: ""), content: {
                    Text(token.gtoken.payload.aud)
                        .lineLimit(1)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_EXP", comment: ""), content: {
                    Text(Date(timeIntervalSince1970: TimeInterval(token.gtoken.payload.exp)).formatted())
                        .lineLimit(1)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_IAT", comment: ""), content: {
                    Text(Date(timeIntervalSince1970: TimeInterval(token.gtoken.payload.iat)).formatted())
                        .lineLimit(1)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_ISS", comment: ""), content: {
                    Text(token.gtoken.payload.iss)
                        .lineLimit(1)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_JTI", comment: ""), content: {
                    Text(token.gtoken.payload.jti.uuidString)
                        .lineLimit(1)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_SUB", comment: ""), content: {
                    Text(token.gtoken.payload.sub, format: .number)
                        .lineLimit(1)
                })
            }, header: {
                Text("HEADER_GAME_WEB_TOKEN")
            })
            Button(action: {
                UIApplication.shared.open(token.url)
            }, label: {
                Text("LABEL_OPEN_APP")
            })
        })
        .monospacedDigit()
        .navigationTitle(Text(token.host))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            QuantumLeap.TokenList()
            QuantumLeap.VPNSettingList()
        })
    })
    .environment(WebTokenStore.default)
    .environment(Mudmouth.default)
}
