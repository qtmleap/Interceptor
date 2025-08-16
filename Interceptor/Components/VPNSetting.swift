//
//  VPNSetting.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import SwiftUI

struct VPNSetting: View {
    @Environment(Mudmouth.self) private var manager: Mudmouth
    /// VPNの接続状態
    /// 直接Mudmouthの状態を弄れないので一時的に変数に逃がす
    @State private var isConnected: Bool = false

    var body: some View {
        Section(content: {
            LabeledContent(content: {
                Toggle(isOn: $isConnected, label: {
                    Text("LABEL_VPN_IS_CONNECTED")
                })
            }, label: {
                Image(systemName: "wifi")
            })
            LabeledContent(content: {
                Toggle(isOn: manager.$activateOnForeground, label: {
                    Text("LABEL_ACTIVATE_ON_FOREGROUND")
                })
            }, label: {
                Image(systemName: "autostartstop")
            })
        }, header: {
            Text("TITLE_VPN_SETTINGS")
        })
        .onAppear(perform: {
            isConnected = manager.isConnected
        })
        .onChange(of: isConnected, perform: { newValue in
            // 値が変わったときにVPN設定を切り替える
            Task(priority: .background, operation: {
                newValue ? try await manager.startVPNTunnel() : manager.stopVPNTunnel()
            })
        })
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            VPNSetting()
        })
    })
    .environment(Mudmouth())
}
