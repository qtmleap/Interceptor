//
//  SettingsView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form(content: {
            QuantumLeap.Support()
            QuantumLeap.VPNSettingList()
            QuantumLeap.Tools()
            QuantumLeap.Policy()
            QuantumLeap.Version()
        })
        .navigationTitle(Text("TITLE_SETTINGS"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            ToolbarItem(placement: .topBarTrailing, content: {
                Button(action: {
                    dismiss()
                }, label: {
                    Image(systemName: "xmark")
                        .fontWeight(.bold)
                })
            })
        })
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environment(Mudmouth.default)
        .environment(WebTokenStore.default)
}
