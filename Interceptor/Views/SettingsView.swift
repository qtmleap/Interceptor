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
        NavigationView(content: {
            Form(content: {
                QuantumLeap.Support(label: {
                    NavigationLink(destination: {
                        ConfigurationView()
                    }, label: {
                        Label(title: {
                            Text("LABEL_DEVELOPER_SETTINGS")
                        }, icon: {
                            RoundedRectangle(cornerRadius: 8)
                                .overlay(content: {
                                    Image(systemName: "gear.badge.checkmark")
                                        .imageScale(.medium)
                                        .foregroundStyle(.white)
                                })
                                .foregroundStyle(.cyan)
                                .frame(width: 28, height: 28)
                        })
                    })
                })
                Services()
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
        })
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environment(Mudmouth())
}
