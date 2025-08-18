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
@_spi(Advanced) import SwiftUIIntrospect

struct ServiceTokenLink: View {
    @EnvironmentObject private var client: Tuberose

    var body: some View {
        NavigationLink(destination: {
            Form(content: {
                Section(content: {
                    ForEach(client.tokens, content: { token in
                        NavigationLink(destination: {
                            ServiceTokenView(token: token)
                        }, label: {
                            Text(token.host)
                                .lineLimit(1)
                        })
                    })
                }, header: {
                    Text("HEADER_SERVICE_TOKENS")
                })
            })
            .navigationTitle(Text("TITLE_SERVICE_TOKENS"))
            .navigationBarTitleDisplayMode(.inline)
        }, label: {
            Label(systemName: "lock.shield.fill", color: .teal, title: {
                Text("LABEL_SERVICE_TOKENS")
            })
        })
    }
}

struct ServiceTokenView: View {
//    @Binding var token: AccessToken
    @State private var apiURL: String = ""
    @State private var urlScheme: String = ""
    @State private var isEditable: Bool = false
    let token: AccessToken

    var body: some View {
        Form(content: {
            Section(content: {
                Label(title: {
                    Toggle(isOn: .constant(false), label: {
                        Text("LABEL_REGENERATE_FROM_GAME_WEB_TOKEN")
                    })
                    .disabled(true)
                }, icon: {
                    Image(systemName: "lock")
                })
                Label(title: {
                    Toggle(isOn: .constant(false), label: {
                        Text("LABEL_OPEN_APP_WHEN_TOKEN_EXPIRED")
                    })
                    .disabled(true)
                }, icon: {
                    Image(systemName: "lock")
                })
            }, header: {
                Text("HEADER_GAME_WEB_TOKEN_EXPIRED_ACTION")
            }, footer: {
                Text("LABEL_GAME_WEB_TOKEN_EXPIRED_ACTION_FOOTER")
            })
            .disabled(true)
            Section(content: {
                Label(title: {
                    TextField("LABEL_DESTINATION_URL", text: $apiURL)
                        .keyboardType(.URL)
                        .disabled(true)
                }, icon: {
                    Image(systemName: "lock")
                })
                Label(title: {
                    TextField("LABEL_URL_SCHEME", text: $urlScheme)
                        .keyboardType(.URL)
                        .disabled(true)
                }, icon: {
                    Image(systemName: "lock")
                })
                Label(title: {
                    NavigationLink(destination: {
                        EmptyView()
                    }, label: {
                        Text("LABEL_JAVASCRIPT_CODE")
                    })
                    .disabled(true)
                }, icon: {
                    Image(systemName: "lock")
                })
            }, header: {
                Text("HEADER_SERVICE_SETTING")
            }, footer: {
                Text("FOOTER_SERVICE_SETTING")
            })
            .disabled(true)
            Section(content: {
                LabeledContent(NSLocalizedString("LABEL_ACCESS_TOKEN", bundle: .main, comment: ""), content: {
                    Text(token.accessToken)
                        .lineLimit(1)
                        .textSelection(.enabled)
                })
            }, header: {
                Text("HEADER_ACCESS_TOKEN")
            }, footer: {
                Text("FOOTER_ACCESS_TOKEN")
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
            }, footer: {
                Text("FOOTER_GAME_WEB_TOKEN")
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
            QuantumLeap.VPNSettingList()
            QuantumLeap.Certificate()
            QuantumLeap.ServiceList()
        })
    })
    .environmentObject(Tuberose.default)
    .environment(Tuberose.default.mudmouth)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
