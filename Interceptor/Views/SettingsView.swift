//
//  SettingsView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import LicenseList
import QuantumLeap
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: Tuberose
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0
    @State private var showSetup = false

    var body: some View {
        Form(content: {
            QuantumLeap.Support()
            Section {
                NavigationLink("Data Use and Consent") { DataUseConsentView() }
                Button("Set Up Capture") { showSetup = true }
                    .disabled(consentVersion != CaptureAuthorization.version)
                Button("Capture Notifications") {
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                }.disabled(consentVersion != CaptureAuthorization.version)
            }
            QuantumLeap.VPNSettingList()
            QuantumLeap.Tools()
            Section {
                Link("Terms of Service", destination: URL(string: "https://qleap.jp/term/eula")!)
                Link("Privacy Policy", destination: URL(string: "https://qleap.jp/term/interceptor_privacy_policy")!)
                Link("Developers", destination: URL(string: "https://qleap.jp")!)
                NavigationLink("Licenses") {
                    LicenseListView().licenseViewStyle(.withRepositoryAnchorLink)
                        .navigationTitle("Licenses")
                }
            }
            QuantumLeap.Version()
        })
        .fullScreenCover(isPresented: $showSetup) { FirstLaunchView() }
        .navigationTitle(Text("TITLE_SETTINGS"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environmentObject(Tuberose.default)
}
