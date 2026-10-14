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
                    if !client.tokens.isEmpty {
                        Text("HEADER_SERVICE_TOKENS")
                    }
                })
            })
            .overlay {
                if client.tokens.isEmpty {
                    ContentUnavailableView("EMPTY_TOKENS_TITLE", systemImage: "key.horizontal",
                                           description: Text("EMPTY_TOKENS_DESCRIPTION"))
                }
            }
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
    @State private var isTokenVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCopied = false
    @State private var copyGeneration = 0
    let token: AccessToken

    private func copyToken() {
        UIPasteboard.general.string = token.accessToken
        isCopied = true
        copyGeneration += 1
        AccessibilityNotification.Announcement(String(localized: "LABEL_TOKEN_COPIED")).post()
    }

    var body: some View {
        Form(content: {
            Section(content: {
                Button(action: copyToken, label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            if isTokenVisible {
                                Text(token.accessToken)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("LABEL_TOKEN_HIDDEN")
                                    .foregroundStyle(.secondary)
                            }
                            Text(isCopied ? "LABEL_TOKEN_COPIED" : "LABEL_TOKEN_COPY_HINT")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .contextMenu {
                    Button(action: copyToken, label: {
                        Text("LABEL_COPY_TOKEN")
                    })
                    Button(action: { isTokenVisible.toggle() }, label: {
                        Text(isTokenVisible ? "LABEL_HIDE_TOKEN" : "LABEL_SHOW_TOKEN")
                    })
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("LABEL_COPY_TOKEN"))
                .accessibilityIdentifier("access-token-copy")
                .accessibilityValue(isCopied ? Text("LABEL_TOKEN_COPIED") : (isTokenVisible ? Text(verbatim: token.accessToken) : Text("LABEL_TOKEN_HIDDEN")))
                .accessibilityHint(Text("LABEL_TOKEN_COPY_ACCESSIBILITY_HINT"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(isTokenVisible ? "LABEL_HIDE_TOKEN" : "LABEL_SHOW_TOKEN")) {
                    isTokenVisible.toggle()
                }
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
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                })
                LabeledContent(NSLocalizedString("LABEL_TOKEN_PAYLOAD_JTI", comment: ""), content: {
                    Text(token.gtoken.payload.jti.uuidString)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
        .task(id: copyGeneration) {
            guard isCopied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            isCopied = false
        }
        .onDisappear {
            isTokenVisible = false
            isCopied = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isTokenVisible = false
                isCopied = false
            }
        }
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
