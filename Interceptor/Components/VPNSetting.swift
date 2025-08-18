//
//  VPNSetting.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct VPNSetting: View {
    @EnvironmentObject private var client: Tuberose
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConnected: Bool = false

    var body: some View {
        Section(content: {
            Label(systemName: "wifi", color: .blue, title: {
                Toggle(isOn: $isConnected, label: {
                    Text("LABEL_VPN_IS_CONNECTED")
                })
            })
            Label(systemName: "autostartstop", color: .blue, title: {
                Toggle(isOn: client.$activateOnForeground, label: {
                    Text("LABEL_ACTIVATE_ON_FOREGROUND")
                })
            })
        }, header: {
            Text("TITLE_VPN_SETTINGS")
        })
        .onAppear(perform: {
            isConnected = client.isConnected
        })
        .onChange(of: scenePhase) {
            isConnected = client.isConnected
        }
        .onChange(of: client.isConnected) {
            isConnected = client.isConnected
        }
        .onChange(of: isConnected) {
            // 値が変わったときにVPN設定を切り替える
            Task(priority: .background, operation: {
                isConnected ? try await client.startVPNTunnel() : client.stopVPNTunnel()
            })
        }
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            QuantumLeap.VPNSettingList()
            QuantumLeap.Certificate()
            QuantumLeap.ServiceList()
//            QuantumLeap.ServerList()
//            QuantumLeap.ServerList()
        })
    })
    .environment(Tuberose.default.mudmouth)
    .environment(\.colorScheme, .dark)
    .environmentObject(Tuberose.default)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
