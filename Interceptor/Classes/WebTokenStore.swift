//
//  WebTokenStore.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import SwiftUI
import Foundation
import KeychainAccess
import SwiftyLogger
import Mudmouth

@Observable
final class WebTokenStore {
    // iCloud Keychainを利用する
    // ライブラリ側と共通なので見ようと思ったらプライベートキーも参照できる？
    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!).synchronizable(true)
    
    init() {}
    
    
    /// 通知で受け取ったデータをKeychainに保存する
    /// 過去のデータとかはとりあえず気にしなくていいと思う
    /// - Parameter value: <#value description#>
    func setToken(_ value: UNNotificationResponse) throws {
        let userInfo = value.notification.request.content.userInfo
        if let headers: HTTP.Parameters = userInfo.data(forKey: "headers"),
           let body: HTTP.Parameters = userInfo.data(forKey: "body"),
           let host: String = headers.host
        {
            print(headers)
            print(body)
            switch host {
                case "app.splatoon2.nintendo.net": // Splatoon 2
                    if let token: String = headers.cookie.value(forKey: "iksm_session")
                    {
//                        try keychain.setToken(.init(accessToken: token, expiresIn: .init(timeIntervalSinceNow: 60 * 60 * 24)), forKey: "app.splatoon2.nintendo.net")
                    }
                    break
                case "api.lp1.av5ja.srv.nintendo.net": // Splatoon 3
                    if let token: String = body.value(forKey: "bulletToken")
                    {
//                        try keychain.setToken(.init(accessToken: token, expiresIn: .init(timeIntervalSinceNow: 60 * 60 * 2)), forKey: "api.lp1.av5ja.srv.nintendo.net")
                    }
                    break
                case "web.sd.lp1.acbaa.srv.nintendo.net": // NookLink
                    break
                case "app.smashbros.nintendo.net": // Smash World
                    if let token: String = headers.cookie.value(forKey: "super_smash_token")
                    {
//                        try keychain.setToken(.init(accessToken: token, expiresIn: .init(timeIntervalSinceNow: 60 * 60 * 2)), forKey: "app.smashbros.nintendo.net")
                    }
                    break
                case "api.lp1.87abc152.srv.nintendo.net": // Zelda Notes
                    break
                default:
                    break
            }
        }
    }
}

extension Keychain {
    func setToken(_ value: AccessToken, forKey: String) throws {
        let encoder: JSONEncoder = .init()
        let data: Data = try encoder.encode(value)
        try self.set(data, key: forKey)
    }
    
    func getToken(forKey: String) throws -> AccessToken {
        guard let data: Data = try self.getData(forKey)
        else {
            throw DecodingError.valueNotFound(AccessToken.self, .init(codingPath: [], debugDescription: ""))
        }
        let decoder: JSONDecoder = .init()
        return try decoder.decode(AccessToken.self, from: data)
    }
}

extension HTTP.Parameters {
    var host: String? {
        self.first(where: { $0.key == "Host"})?.value
    }
    
    var gtoken: String? {
        self.first(where: { $0.key == "X-GameWebToken" })?.value
    }
    
    var cookie: HTTP.Parameters {
        guard let value: String = self.first(where: { $0.key == "Cookie" })?.value
        else {
            return []
        }
        return value.split(separator: ";").compactMap({ component in
            let values: [String] = component.split(separator: "=").map(String.init)
            return .init(key: values[0].trimmingCharacters(in: .whitespacesAndNewlines), value: values[1].trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }
    
    func value(forKey key: String) -> String? {
        self.first(where: { $0.key == key })?.value
    }
}

extension Dictionary where Key == AnyHashable, Value == Any {
    func data(forKey key: String) -> HTTP.Parameters? {
        guard let value = (self[key] as? String).map(\.base64DecodedString),
              let data: Data = value?.data(using: .utf8)
        else {
            return nil
        }
        let decoder: JSONDecoder = .init()
        return try? decoder.decode(HTTP.Parameters.self, from: data)
        //        return try
//        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension WebTokenStore {
    static let `default`: WebTokenStore = .init()
}
