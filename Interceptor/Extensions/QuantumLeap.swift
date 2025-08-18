//
//  QuantumLeap.swift
//  Interceptor
//
//  Created by devonly on 2025/08/18.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

@MainActor
extension QuantumLeap {
    @ViewBuilder
    static func ServiceList() -> some View {
        ServiceTokenList()
    }

    @ViewBuilder
    static func VPNSettingList() -> some View {
        VPNSetting()
    }

    @ViewBuilder
    static func Certificate() -> some View {
        NavigationLink(destination: {
            CertificateView()
        }, label: {
            Label(systemName: "note.text", color: .indigo, title: {
                Text("TITLE_CERTIFICATE")
            })
        })
    }

//    @ViewBuilder
//    static func ServerList() -> some View {
//        NavigationLink(destination: {
//            ServerListView()
//        }, label: {
//            Label(systemName: "list.dash", color: .green, title: {
//                Text("TITLE_SERVER_LIST")
//            })
//        })
//    }

    @ViewBuilder
    static func Tools() -> some View {
        Section(content: {
            QuantumLeap.Certificate()
        }, header: {
            Text("HEADER_TOOLS")
        })
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
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
