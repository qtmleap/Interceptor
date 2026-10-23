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
    @EnvironmentObject private var client: Tuberose
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @StateObject private var tabNavigationAlignment = TabNavigationAlignment()
    @StateObject private var fileDestinations = PluginFileDestinationController()
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0

    private var requiresConsent: Bool {
        consentVersion != CaptureAuthorization.version
    }

    var body: some View {
        Group {
            if requiresConsent {
                NavigationStack {
                    DataUseConsentView { isFirstLaunch.wrappedValue = false }
                }
            } else {
                mainTabs
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            fileDestinations.becameActive()
            while !Task.isCancelled {
                await PluginFilesExporter.shared.synchronize()
                await fileDestinations.synchronize()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: $fileDestinations.folderRequest, onDismiss: { fileDestinations.folderSheetDismissed() }) { request in
            PluginStorageFolderPicker(prefix: request.prefix, onSelect: { fileDestinations.selectedFolder($0, for: request) },
                                      onCancel: { fileDestinations.cancelFolderSelection() })
        }
        .alert("AUTO_FILES_EXPORT_FAILED", isPresented: $fileDestinations.showError) {
            Button("OK", role: .cancel) {}
        } message: { Text("AUTO_FILES_EXPORT_FAILED_DETAILS") }
        .onAppear { stopCaptureIfUnauthorized() }
        .onChange(of: consentVersion) { stopCaptureIfUnauthorized() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { fileDestinations.becameInactive() }
            if scenePhase == .active {
                consentVersion = CaptureAuthorization.defaults.integer(forKey: CaptureAuthorization.key)
                stopCaptureIfUnauthorized()
            }
        }
    }

    private func stopCaptureIfUnauthorized() {
        if !CaptureAuthorization.isGranted {
            client.stopVPNTunnel()
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab, content: {
            NavigationView(content: {
                HomeView()
            })
            .background {
                if #available(iOS 27, *) {
                    TabNavigationAlignmentObserver(alignment: tabNavigationAlignment)
                }
            }
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
                ContentUnavailableView("EMPTY_SETTINGS_TITLE", systemImage: "sidebar.left",
                                       description: Text("EMPTY_SETTINGS_DESCRIPTION"))
                    .navigationBarTitleDisplayMode(.inline)
            })
            .background {
                if #available(iOS 27, *) {
                    TabNavigationAlignmentObserver(alignment: tabNavigationAlignment)
                }
            }
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
        .onChange(of: selectedTab) { tabNavigationAlignment.update() }
        .introspect(.tabView, on: .iOS(.v27)) { tabView in
            tabNavigationAlignment.configure(tabView)
        }
        .introspect(.tabView, on: .iOS(.v17, .v18, .v26, .v27)) { tabView in
            // Change only selected tab items; the shared accent still colors primary buttons.
            let selectedColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.62, green: 0.79, blue: 1, alpha: 1)
                    : (UIColor(named: "AccentColor", in: .main, compatibleWith: traits) ?? .systemBlue)
            }
            func selectedAppearance(_ original: UITabBarAppearance) -> UITabBarAppearance {
                let appearance = UITabBarAppearance(barAppearance: original)
                for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                               appearance.compactInlineLayoutAppearance]
                {
                    layout.selected.iconColor = selectedColor
                    layout.selected.titleTextAttributes[.foregroundColor] = selectedColor
                }
                return appearance
            }
            // The iPad floating tab bar inherits the controller view's tint.
            tabView.view.tintColor = selectedColor
            // Keep the content's original accent, including selected sidebar rows.
            for controller in tabView.viewControllers ?? [] {
                controller.view.tintColor = UIColor(named: "AccentColor") ?? .systemBlue
            }
            tabView.tabBar.tintColor = selectedColor
            tabView.tabBar.standardAppearance = selectedAppearance(tabView.tabBar.standardAppearance)
            if let edge = tabView.tabBar.scrollEdgeAppearance {
                tabView.tabBar.scrollEdgeAppearance = selectedAppearance(edge)
            }
        }
        .introspect(.tabView, on: .iOS(.v18), customize: { tabView in
            tabView.traitOverrides.horizontalSizeClass = .unspecified
            tabView.tabBar.backgroundColor = .systemBackground
            tabView.tabBar.isTranslucent = true
        })
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environmentObject(Tuberose.default)
}
