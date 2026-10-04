//
//  AccessToken.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Foundation
import Mudmouth

struct AccessToken: Codable, Identifiable, @unchecked Sendable {
    /// ゲームのコンテンツID
    let contentId: ContentId
    /// ゲームトークン
    let gtoken: GameWebToken
    /// アクセストークン
    let accessToken: String
    /// 取得時間+有効期限
    let expiresIn: Date
    /// ホスト
    let host: String

    var id: String {
        gtoken.payload.aud
    }

    var url: URL {
        .init(string: "com.nintendo.znca://znca/game/\(contentId.rawValue)")!
    }

    var isRefreshNeeded: Bool {
        gtoken.isRefreshNeeded
    }

    init(contentId: ContentId, host: String, gtoken: String, accessToken: String, timeInterval timeIntervalSinceNow: TimeInterval = 60 * 60 * 2) throws {
        self.contentId = contentId
        self.host = host
        self.gtoken = try .init(gtoken)
        self.accessToken = accessToken
        expiresIn = .init(timeIntervalSinceNow: timeIntervalSinceNow)
    }
}
