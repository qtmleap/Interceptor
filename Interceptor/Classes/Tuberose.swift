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

    /// VPN設定
    /// NOTE: とりあえず最初はスプラ2とスプラ3のみに対応
    /// NOTE: キャプチャ自体は対応しておく
    private(set) var options: [ProxyOption] = [
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
        .init(host: "app.smashbros.nintendo.net", paths: [
            .init(path: "/"),
        ]),
        .init(host: "web.sd.lp1.acbaa.srv.nintendo.net", paths: []),
    ]

    /// アクセストークン一覧
    @Published
    private(set) var tokens: [AccessToken] = []

    private let decoder: JSONDecoder = .init()
    private let encoder: JSONEncoder = .init()
    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!).synchronizable(true)

    let mudmouth: Mudmouth = .default

    var isConnected: Bool {
        mudmouth.isConnected
    }

    init() {
        tokens = options.map(\.host).compactMap { host in
            try? keychain.getToken(forKey: host)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActiveNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func startVPNTunnel() async throws {
        try await mudmouth.startVPNTunnel(options: options)
    }

    func stopVPNTunnel() {
        mudmouth.stopVPNTunnel()
    }

    func setToken(_ value: UNNotificationResponse) throws {
        let userInfo = value.notification.request.content.userInfo
        if let data: Data = userInfo.data(forKey: "headers"),
           let headers: [String: String] = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let cookies: [String: String] = headers.cookies,
           let host: String = headers.host
        {
            switch host {
                case "app.smashbros.nintendo.net":
                    if let token: String = cookies.value(forKey: "super_smash_session"),
                       let gtoken: String = headers.value(forKey: "X-GameWebToken")
                    {
                        SwiftyLogger.debug("Captured token: \(token) \(gtoken)")
                        try? keychain.setToken(.init(contentId: .SMSP, host: host, gtoken: gtoken, accessToken: token), forKey: host)
                    }
                case "app.splatoon2.nintendo.net":
                    if let token: String = cookies.value(forKey: "iksm_session"),
                       let gtoken: String = headers.value(forKey: "X-GameWebToken")
                    {
                        SwiftyLogger.debug("Captured token: \(token) \(gtoken)")
                        try? keychain.setToken(.init(contentId: .SP2, host: host, gtoken: gtoken, accessToken: token), forKey: host)
                    }
                case "api.lp1.av5ja.srv.nintendo.net":
                    if let data: Data = userInfo.data(forKey: "body"),
                       let body: [String: Any] = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let token: String = body.value(forKey: "bulletToken") as? String,
                       let gtoken: String = cookies.value(forKey: "_gtoken")
                    {
                        SwiftyLogger.debug("Captured token: \(token) \(gtoken)")
                        try? keychain.setToken(.init(contentId: .SP3, host: host, gtoken: gtoken, accessToken: token), forKey: host)
                    }
                default:
                    break
            }
        }
        tokens = options.map(\.host).compactMap { host in
            try? keychain.getToken(forKey: host)
        }
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

extension [String: String] {
    var host: String? {
        value(forKey: "Host")
    }

    var cookies: [String: String]? {
        guard let value: String = first(where: { $0.key.lowercased() == "cookie" })?.value as? String
        else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { component in
            let parts = component.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
    }

    func value(forKey key: String) -> String? {
        first(where: { $0.key == key })?.value
    }
}

extension [String: Any] {
    func value(forKey key: String) -> Any? {
        first(where: { $0.key == key })?.value
    }
}

extension [HTTP.Parameter] {
    var host: String? {
        value(forKey: "Host")
    }

    func value(forKey key: String) -> String? {
        first(where: { $0.key == key })?.value
    }
}

extension [AnyHashable: Any] {
    func data(forKey key: String) -> Data? {
        guard let value = (self[key] as? String).map(\.base64DecodedString),
              let data: Data = value?.data(using: .utf8)
        else {
            return nil
        }
        return data
    }
}

extension Keychain {
    func setToken(_ value: AccessToken, forKey: String) throws {
        let encoder: JSONEncoder = .init()
        let data: Data = try encoder.encode(value)
        try set(data, key: forKey)
    }

    func getToken(forKey: String) throws -> AccessToken {
        guard let data: Data = try getData(forKey)
        else {
            throw DecodingError.valueNotFound(AccessToken.self, .init(codingPath: [], debugDescription: ""))
        }
        let decoder: JSONDecoder = .init()
        return try decoder.decode(AccessToken.self, from: data)
    }
}
