//
//  Tuberose.swift
//  Interceptor
//
//  Created by devonly on 2025/08/18.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import KeychainAccess
import Mudmouth
import SwiftUI
import SwiftyLogger

@MainActor
public final class Tuberose: ObservableObject {
    @AppStorage("ACTIVATE_ON_FOREGROUND")
    var activateOnForeground: Bool = true

    @Published
    var options: [ProxyOption]

    private let decoder: JSONDecoder = .init()
    private let encoder: JSONEncoder = .init()
    private let keychain: Keychain = .init(accessGroup: "group.\(Bundle.main.bundleIdentifier!)")

    let mudmouth: Mudmouth = .default

    var isConnected: Bool {
        mudmouth.isConnected
    }

    init() {
        if let data: Data = UserDefaults.standard.data(forKey: "APP_PROXY_OPTIONS"),
           let options: [ProxyOption] = try? decoder.decode([ProxyOption].self, from: data)
        {
            self.options = options
        } else {
            // なければ初期値を代入
            options = [
                .init(host: "api.accounts.nintendo.com", paths: []),
                .init(host: "api-lp1.znc.srv.nintendo.net", paths: []),
                .init(host: "api.lp1.usagi.srv.nintendo.net", paths: []),
                .init(host: "api.lp1.av5ja.srv.nintendo.net", paths: [
                    .init(path: "/api/bullet_tokens"),
                ]),
                .init(host: "api.lp1.87abc152.srv.nintendo.net", paths: []),
                .init(host: "accounts.nintendo.com", paths: []),
                .init(host: "app.splatoon2.nintendo.net", paths: [
                    .init(path: "/"),
                ]),
                .init(host: "app.smashbros.nintendo.net", paths: []),
                .init(host: "web.sd.lp1.acbaa.srv.nintendo.net", paths: []),
            ]
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActiveNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func startVPNTunnel() async throws {
        SwiftyLogger.debug("Starting VPN tunnel with options: \(options)")
        for option in options {
            print(option)
        }
        try await mudmouth.startVPNTunnel(options: options)
    }

    func stopVPNTunnel() {
        mudmouth.stopVPNTunnel()
    }

    func setToken(_ value: UNNotificationResponse) throws {
        SwiftyLogger.debug("Setting token from notification response. \(value)")
    }

    @objc
    private func didBecomeActiveNotification() {
        if activateOnForeground {
            Task(priority: .background, operation: {
                try await startVPNTunnel()
            })
        }
    }
}

public extension Tuberose {
    static let `default`: Tuberose = .init()
}
