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
import SwiftData
import UserNotifications

@MainActor
public final class Tuberose: ObservableObject {
    @AppStorage("ACTIVATE_ON_FOREGROUND")
    var activateOnForeground: Bool = false

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

    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!)
        .synchronizable(false)
        .accessibility(.afterFirstUnlockThisDeviceOnly)
    private let legacyKeychain: Keychain = .init(service: Bundle.main.bundleIdentifier!).synchronizable(true)

    let mudmouth: Mudmouth = .default

    var isConnected: Bool {
        mudmouth.isConnected
    }

    init() {
        loadStoredTokens()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActiveNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func startVPNTunnel() async throws {
        try CaptureAuthorization.requireConsent()
        try await mudmouth.startVPNTunnel(options: options)
    }

    func stopVPNTunnel() {
        mudmouth.stopVPNTunnel()
    }

    func withdrawCaptureConsent() {
        CaptureAuthorization.revoke()
        activateOnForeground = false
        stopVPNTunnel()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func setToken(_ value: UNNotificationResponse) throws {
        try CaptureAuthorization.requireConsent()
        guard let rawID = value.notification.request.content.userInfo["recordID"] as? String,
              let recordID = UUID(uuidString: rawID) else { return }
        var descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == recordID })
        descriptor.fetchLimit = 1
        guard try ModelContainer.default.mainContext.fetch(descriptor).first != nil else { return }
        // A delayed notification must not overwrite a newer token with an older record.
        try refreshTokensFromRecords()
    }

    func refreshTokensFromRecords() throws {
        try CaptureAuthorization.requireConsent()
        let context = ModelContainer.default.mainContext
        for host in options.map(\.host) {
            let descriptor = FetchDescriptor<Record>(
                predicate: #Predicate { $0.request.host == host },
                sortBy: [SortDescriptor(\Record.capturedAt, order: .reverse)]
            )
            for record in try context.fetch(descriptor) {
                // Bad or unrelated responses are ignored; they must not erase saved tokens.
                guard let token = try? Self.token(from: record) else { continue }
                try keychain.setToken(token, forKey: host)
                break
            }
        }
        loadStoredTokens()
    }

    static func token(from record: Record) throws -> AccessToken? {
        let host = record.request.host
        let headers = record.request.headers.values
        let cookies = record.request.cookies.values
        let gtokenHeader = headers.first { $0.key.caseInsensitiveCompare("X-GameWebToken") == .orderedSame }?.value
        switch host {
            case "app.smashbros.nintendo.net":
                guard let token = cookies.first(where: { $0.key == "super_smash_session" })?.value,
                      let gtoken = gtokenHeader else { return nil }
                return try AccessToken(contentId: .SMSP, host: host, gtoken: gtoken, accessToken: token)
            case "app.splatoon2.nintendo.net":
                guard let token = cookies.first(where: { $0.key == "iksm_session" })?.value,
                      let gtoken = gtokenHeader else { return nil }
                return try AccessToken(contentId: .SP2, host: host, gtoken: gtoken, accessToken: token)
            case "api.lp1.av5ja.srv.nintendo.net":
                guard let data = record.response.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = body["bulletToken"] as? String,
                      let gtoken = cookies.first(where: { $0.key == "_gtoken" })?.value else { return nil }
                return try AccessToken(contentId: .SP3, host: host, gtoken: gtoken, accessToken: token)
            default:
                return nil
        }
    }

    private func loadStoredTokens() {
        tokens = options.map(\.host).compactMap { host in
            if let local = try? keychain.getToken(forKey: host) { return local }
            guard let legacy = try? legacyKeychain.getToken(forKey: host) else { return nil }
            // Copy previously synced data without deleting the cloud/other-device copy.
            try? keychain.setToken(legacy, forKey: host)
            return legacy
        }
    }

    @objc
    private func didBecomeActiveNotification() {
        guard CaptureAuthorization.isGranted else { return }
        // Capture remains useful when notification permission is denied or no notification is tapped.
        try? refreshTokensFromRecords()
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
        return value.split(separator: ";").reduce(into: [String: String]()) { result, component in
            let parts = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, !parts[0].isEmpty { result[parts[0]] = parts[1] }
        }
    }

    func value(forKey key: String) -> String? {
        first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
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
        guard let data: Data = try getData(forKey, ignoringAttributeSynchronizable: false)
        else {
            throw DecodingError.valueNotFound(AccessToken.self, .init(codingPath: [], debugDescription: ""))
        }
        let decoder: JSONDecoder = .init()
        return try decoder.decode(AccessToken.self, from: data)
    }
}
