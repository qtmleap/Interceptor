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
    @Bindable var option: ProxyOption
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
                Toggle(isOn: $option.capture, label: {
                    Text("LABEL_SERVER_LIST_ENABLE")
                })
                Toggle(isOn: $option.notify, label: {
                    Text("LABEL_SERVER_LIST_NOTIFICATION_ENABLE")
                })
            })
            if !option.paths.isEmpty {
                Section(content: {
                    ForEach($option.paths, content: { $path in
                        Toggle(isOn: $path.notify, label: {
                            Text(path.path)
                        })
                    })
                }, header: {
                    Text("HEADER_SERVER_NOTIFICATION")
                }, footer: {
                    Text("FOOTER_SERVER_NOTIFICATION")
                })
            }
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
//    @Environment(Tuberose.self) private var client: Tuberose
    @Bindable var client: Tuberose = .default
    @State var editMode: EditMode = .active

    func onDelete(offsets: IndexSet) {
        client.options.remove(atOffsets: offsets)
    }

    func onMove(offsets: IndexSet, to destination: Int) {
        client.options.move(fromOffsets: offsets, toOffset: destination)
    }

    var body: some View {
        Form(content: {
            Section(content: {
                ForEach(client.options, content: { option in
                    NavigationLink(destination: {
                        ServerView(option: option)
                    }, label: {
                        Label(title: {
                            Text(option.host)
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
    .environment(Tuberose.default)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
