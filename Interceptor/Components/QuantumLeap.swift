//
//  QuantumLeap.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import SwiftUI
import QuantumLeap

struct TokenListView: View {
    var body: some View {
        Group(content: {
            Section(content: {
                SecureField(text: .constant("1234567890"), label: {
                    Text("TOKEN_BULLET_TOKENS")
                })
                LabeledContent("LABEL_EXPIRES_IN", value: "-")
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/5741031244955648")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
            }, header: {
                Text("HEADER_SPLATOON_2")
            }, footer: {
                Text("FOOTER_SPLATOON_2")
            })
            Section(content: {
                SecureField(text: .constant("1234567890"), label: {
                    Text("TOKEN_BULLET_TOKENS")
                })
                LabeledContent("LABEL_EXPIRES_IN", value: "-")
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/4834290508791808")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
            }, header: {
                Text("HEADER_SPLATOON_3")
            }, footer: {
                Text("FOOTER_SPLATOON_3")
            })
            Section(content: {
                SecureField(text: .constant("1234567890"), label: {
                    Text("TOKEN_BULLET_TOKENS")
                })
                LabeledContent("LABEL_EXPIRES_IN", value: "-")
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/5598642853249024")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
            }, header: {
                Text("HEADER_SMASH_BROS_SPECIAL")
            }, footer: {
                Text("FOOTER_SMASH_BROS_SPECIAL")
            })
            Section(content: {
                SecureField(text: .constant("1234567890"), label: {
                    Text("TOKEN_BULLET_TOKENS")
                })
                LabeledContent("LABEL_EXPIRES_IN", value: "-")
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/4953919198265344")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
                .disabled(true)
            }, header: {
                Text("HEADER_ZELDA_NOTES")
            }, footer: {
                Text("FOOTER_ZELDA_NOTES")
            })
            Section(content: {
                SecureField(text: .constant("1234567890"), label: {
                    Text("TOKEN_BULLET_TOKENS")
                })
                LabeledContent("LABEL_EXPIRES_IN", value: "-")
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://znca/game/4953919198265344")!)
                }, label: {
                    Text("BUTTON_REFRESH_TOKEN")
                })
            }, header: {
                Text("HEADER_NOOK_LINK")
            }, footer: {
                Text("FOOTER_NOOK_LINK")
            })
        })
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
        .textContentType(.password)
        .disabled(true)
        .navigationTitle(Text("NINTENDO_TOKEN_LIST"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension QuantumLeap {
     static func TokenList() -> some View {
         return TokenListView()
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            QuantumLeap.TokenList()
        })
    })
}
