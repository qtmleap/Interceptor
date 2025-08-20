//
//  Interceptor.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import AdSupport
import AppTrackingTransparency
import Firebase
import FirebaseAppCheck
import FirebaseMessaging
import Mudmouth
import SwiftData
import SwiftUI
import SwiftyLogger

class AppCheckReleaseProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        if #available(iOS 14.0, *) {
            AppAttestProvider(app: app)
        } else {
            DeviceCheckProvider(app: app)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    weak var tuberose: Tuberose?

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool { true }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG || targetEnvironment(simulator)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppCheckReleaseProviderFactory())
        #endif
        FirebaseApp.configure()
        SwiftyLogger.configure()
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        #if DEBUG || targetEnvironment(simulator)
        if let fcmToken {
            SwiftyLogger.debug("FCM Token: \(fcmToken)")
        }
        #endif
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run(body: {
            try? tuberose?.setToken(response)
        })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct Interceptor: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let tuberose: Tuberose = .default

    init() {
        appDelegate.tuberose = tuberose
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tuberose)
                .environment(tuberose.mudmouth)
                .environmentIsFirstLaunch()
                .modelContainer(ModelContainer.default)
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            ATTrackingManager.requestTrackingAuthorization(completionHandler: { _ in
                            })
                        }
                    }
                }
        }
    }
}
