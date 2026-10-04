//
//  ContentView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Mudmouth
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect
import SwiftyLogger

struct ContentView: View {
    @Environment(\.isFirstLaunch) private var isFirstLaunch: Binding<Bool>
    @AppStorage("CaptureConsentDecided") private var consentDecided = false
    @State private var showConsent = false

    var body: some View {
        TabView(content: {
            NavigationView(content: {
                HomeView()
            })
            .navigationBarTitleDisplayMode(.inline)
            .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
                controller.preferredDisplayMode = .oneBesideSecondary
                controller.preferredSplitBehavior = .displace
                controller.presentsWithGesture = false
            })
            .tabItem {
                Label("LABEL_HOME", systemImage: "paperplane.fill")
            }
            .tag(0)
            NavigationView(content: {
                SettingsView()
            })
            .navigationBarTitleDisplayMode(.inline)
            .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
                controller.preferredDisplayMode = .oneBesideSecondary
                controller.preferredSplitBehavior = .displace
                controller.presentsWithGesture = false
            })
            .tabItem {
                Label("LABEL_SETTINGS", systemImage: "gearshape.fill")
            }
            .tag(1)
        })
        .introspect(.tabView, on: .iOS(.v18), customize: { tabView in
            tabView.traitOverrides.horizontalSizeClass = .unspecified
            tabView.tabBar.backgroundColor = .systemBackground
            tabView.tabBar.isTranslucent = true
        })
        .onAppear {
            let version = CaptureAuthorization.defaults.integer(forKey: CaptureAuthorization.key)
            showConsent = !consentDecided || (version != 0 && version != CaptureAuthorization.version)
            if !CaptureAuthorization.isGranted { Tuberose.default.stopVPNTunnel() }
        }
        .fullScreenCover(isPresented: $showConsent) {
            NavigationStack {
                DataUseConsentView { _ in
                    consentDecided = true
                    isFirstLaunch.wrappedValue = false
                    showConsent = false
                }
            }.interactiveDismissDisabled()
        }
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environmentObject(Tuberose.default)
}
