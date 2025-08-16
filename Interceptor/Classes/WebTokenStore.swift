//
//  WebTokenStore.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Foundation
import KeychainAccess
import Mudmouth
import SwiftUI
import SwiftyLogger

@Observable
final class WebTokenStore {
    // iCloud Keychainを利用する
    // ライブラリ側と共通なので見ようと思ったらプライベートキーも参照できる？
    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!).synchronizable(true)
    // 登録しているホスト一覧
    private let hosts: [String] = [
        "app.splatoon2.nintendo.net",
        "api.lp1.av5ja.srv.nintendo.net",
        "web.sd.lp1.acbaa.srv.nintendo.net",
        "app.smashbros.nintendo.net",
        "api.lp1.87abc152.srv.nintendo.net",
    ]
    private(set) var tokens: [AccessToken] = []

    init() {
        tokens = hosts.compactMap { try? keychain.getToken(forKey: $0) }
        print(tokens)
    }

    private func getToken(forKey: String) throws -> AccessToken {
        try keychain.getToken(forKey: forKey)
    }

    /// 通知で受け取ったデータをKeychainに保存する
    /// 過去のデータとかはとりあえず気にしなくていいと思う
    /// - Parameter value: <#value description#>
    func setToken(_ value: UNNotificationResponse) throws {
//        let userInfo = value.notification.request.content.userInfo
//        if let headers: HTTP.Parameters = userInfo.data(forKey: "headers"),
//           let body: HTTP.Parameters = userInfo.data(forKey: "body"),
//           let host: String = headers.host
//        {
//            print(headers.cookie, headers.gtoken, body)
//            switch host {
//                case "app.splatoon2.nintendo.net": // Splatoon 2
//                    if let token: String = headers.cookie.value(forKey: "iksm_session"),
//                       let gtoken: String = headers.gtoken
//                    {
//                        print(token, gtoken)
//                        try keychain.setToken(.init(contentId: .SP2, host: host, gtoken: gtoken, accessToken: token), forKey: "app.splatoon2.nintendo.net")
//                    }
//                case "api.lp1.av5ja.srv.nintendo.net": // Splatoon 3
//                    if let token: String = body.value(forKey: "bulletToken"),
//                       let gtoken: String = headers.gtoken
//                    {
//                        print(token, gtoken)
//                        try keychain.setToken(.init(contentId: .SP3, host: host, gtoken: gtoken, accessToken: token), forKey: "api.lp1.av5ja.srv.nintendo.net")
//                    }
//                case "web.sd.lp1.acbaa.srv.nintendo.net": // NookLink
//                    break
//                case "app.smashbros.nintendo.net": // Smash World
//                    if let token: String = headers.cookie.value(forKey: "super_smash_session"),
//                       let gtoken: String = headers.gtoken
//                    {
//                        print(token, gtoken)
//                        try keychain.setToken(.init(contentId: .SMSP, host: host, gtoken: gtoken, accessToken: token), forKey: "app.smashbros.nintendo.net")
//                    }
//                case "api.lp1.87abc152.srv.nintendo.net": // Zelda Notes
//                    break
//                default:
//                    break
//            }
//            // トークン一覧を更新
//            tokens = hosts.compactMap { try? keychain.getToken(forKey: $0) }
//        }
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

// extension HTTP.Headers {
//    var host: String? {
//        value(forKey: "Host")
//    }
//
//    var gtoken: String? {
//        cookie.value(forKey: "_gtoken") ?? value(forKey: "X-GameWebToken")
//    }
//
//    var cookie: HTTP.Headers {
//        guard let value: String = first(where: { $0.key == "Cookie" })?.value
//        else {
//            return []
//        }
//        return value.split(separator: ";").compactMap { component in
//            let values: [String] = component.split(separator: "=").map(String.init)
//            return .init(key: values[0].trimmingCharacters(in: .whitespacesAndNewlines), value: values[1].trimmingCharacters(in: .whitespacesAndNewlines))
//        }
//    }
//
//    func value(forKey key: String) -> String? {
//        first(where: { $0.key == key })?.value
//    }
// }

extension [AnyHashable: Any] {
//    func data(forKey key: String) -> HTTP.Parameters? {
//        guard let value = (self[key] as? String).map(\.base64DecodedString),
//              let data: Data = value?.data(using: .utf8)
//        else {
//            return nil
//        }
//        let decoder: JSONDecoder = .init()
//        return try? decoder.decode(HTTP.Parameters.self, from: data)
//    }
}

extension WebTokenStore {
    static let `default`: WebTokenStore = .init()
}
