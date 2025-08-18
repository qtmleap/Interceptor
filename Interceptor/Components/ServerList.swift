//
//  ServerList.swift
//  Interceptor
//
//  Created by devonly on 2025/08/18.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect
import TreeSitterJavaScriptRunestone

struct ServerView: View {
    let paths: [String] = [
        "/",
        "/tokens",
    ]

    let script: String = {
        guard let path: String = Bundle.main.path(forResource: "s3s3", ofType: "js"),
              let script: String = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return
                """
                console.log("Interceptor, JavaScript Server Script");
                """
        }
        return script
    }()

    var body: some View {
        Form(content: {
            Section(content: {
                Toggle(isOn: .constant(true), label: {
                    Text("LABEL_SERVER_LIST_ENABLE")
                })
                Toggle(isOn: .constant(true), label: {
                    Text("LABEL_SERVER_LIST_NOTIFICATION_ENABLE")
                })
            })
            Section(content: {
                ForEach(paths, id: \.self, content: { path in
                    Toggle(isOn: .constant(true), label: {
                        Text(path)
                    })
                })
            }, header: {
                Text("HEADER_SERVER_NOTIFICATION")
            }, footer: {
                Text("FOOTER_SERVER_NOTIFICATION")
            })
            Section(content: {
                Toggle(isOn: .constant(true), label: {
                    Text("LABEL_SERVER_SCRIPT_ENABLE")
                })
                NavigationLink(destination: {
                    CodeView(text: script, language: .javaScript)
                }, label: {
                    Text("LABEL_SERVER_SCRIPT")
                })
            }, header: {
                Text("HEADER_SERVER_SCRIPT")
            })
        })
        .navigationTitle(Text("TITLE_SERVER"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ServerListView: View {
    @State var editMode: EditMode = .inactive
    @State private var servers: [URL] = [
        URL(string: "https://api.accounts.nintendo.com/")!, // Nintendo
        URL(string: "https://api-lp1.znc.srv.nintendo.net/")!, // Nintendo (暗号化されているので現在は取得不可)
        URL(string: "https://api.lp1.usagi.srv.nintendo.net/")!, // Splatoon 3
        URL(string: "https://api.lp1.av5ja.srv.nintendo.net/")!, // Splatoon 3
        URL(string: "https://api.lp1.87abc152.srv.nintendo.net/")!, // Zelda Notes
        URL(string: "https://accounts.nintendo.com/")!, // Nintendo
        URL(string: "https://app.splatoon2.nintendo.net/")!, // Splatoon 2
        URL(string: "https://app.smashbros.nintendo.net/")!, // Smash World
        URL(string: "https://web.sd.lp1.acbaa.srv.nintendo.net/")!, // NookLink
    ].sorted(by: { $0.host! < $1.host! })

    func onDelete(offsets: IndexSet) {
        // Handle deletion logic here
    }

    func onMove(offsets: IndexSet, to destination: Int) {
        // Handle move logic here
    }

    var body: some View {
        Form(content: {
            Section(content: {
                ForEach(servers, id: \.self, content: { server in
                    NavigationLink(destination: {
                        ServerView()
                    }, label: {
                        Label(title: {
                            Text(server.host!)
                        }, icon: {
                            Image(systemName: "checkmark")
                                .fontWeight(.bold)
                                .foregroundStyle(.green)
                        })
                    })
                })
                .onDelete(perform: editMode.isEditing ? onDelete : nil)
                .onMove(perform: editMode.isEditing ? onMove : nil)
                .environment(\.editMode, $editMode)
            }, header: {
                Text("HEADER_SERVER_LIST")
            }, footer: {
                Text("FOOTER_SERVER_LIST")
            })
        })
        .toolbar(content: {
            ToolbarItem(placement: .navigation, content: {
                EditButton()
            })
        })
        .navigationTitle(Text("TITLE_SERVER_LIST"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            QuantumLeap.VPNSettingList()
            QuantumLeap.Certificate()
            QuantumLeap.ServerList()
        })
    })
    .environment(WebTokenStore.default)
    .environment(Mudmouth.default)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
