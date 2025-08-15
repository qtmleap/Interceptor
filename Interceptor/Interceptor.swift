//
//  Interceptor.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Firebase
import Mudmouth
import SwiftUI
import SwiftyLogger

class AppDelegate: NSObject, UIApplicationDelegate, UIWindowSceneDelegate {
    weak var tokenStore: WebTokenStore?

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool { true }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Firebaseの設定
        FirebaseApp.configure()
        // ログ収集を開始
        SwiftyLogger.configure()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = AppDelegate.self
        return config
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {}

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        if let url = connectionOptions.urlContexts.first?.url {}
    }

    func sceneDidBecomeActive(_ scene: UIScene) {}
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run(body: {
            try? tokenStore?.setToken(response)
        })
    }
}

@main
struct Interceptor: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let tokenStore: WebTokenStore = .default

    init() {
        appDelegate.tokenStore = .default
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(tokenStore)
                .environment(Mudmouth())
                .environmentIsFirstLaunch()
                .onReceive(NotificationCenter.default.publisher(for: .MudmouthDidReceiveRequestHead), perform: { notification in
                    SwiftyLogger.debug(notification)
                })
        }
    }
}
