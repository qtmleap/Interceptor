//
//  ServerListView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/21.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct ServerListView: View {
    @EnvironmentObject private var tuberose: Tuberose

    var body: some View {
        Form(content: {
            ForEach(tuberose.options, content: { option in
                Text(option.host)
            })
        })
        .toolbar(content: {
            ToolbarItem(placement: .navigation, content: {
                Button(action: {}, label: {
                    Image(systemName: "plus")
                })
                .disabled(true)
            })
        })
        .navigationTitle(Text("TITLE_SERVER_LIST"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView(content: {
        ServerListView()
    })
    .environmentObject(Tuberose.default)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
