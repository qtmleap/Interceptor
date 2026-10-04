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
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0
    @State private var connectionError: String?

    var body: some View {
        Section(content: {
            Label(systemName: "wifi", color: .blue, title: {
                Toggle(isOn: Binding(get: { isConnected }, set: { enabled in
                    Task {
                        do {
                            if enabled { try await client.startVPNTunnel() }
                            else { client.stopVPNTunnel() }
                            isConnected = client.isConnected
                        } catch { connectionError = error.localizedDescription; isConnected = false }
                    }
                }), label: {
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
        .disabled(consentVersion != CaptureAuthorization.version)
        .onChange(of: consentVersion) {
            if !CaptureAuthorization.isGranted {
                isConnected = false
                client.activateOnForeground = false
                client.stopVPNTunnel()
            }
        }
        .alert("Unable to Start Capture", isPresented: Binding(get: { connectionError != nil }, set: { if !$0 { connectionError = nil } })) {
            Button("OK", role: .cancel) { connectionError = nil }
        } message: { Text(connectionError ?? "") }
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
