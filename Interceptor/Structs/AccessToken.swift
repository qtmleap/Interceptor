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

    var id: String {
        gtoken.payload.aud
    }

    var isRefreshNeeded: Bool {
        gtoken.isRefreshNeeded
    }

    init(contentId: ContentId, gtoken: String, accessToken: String, timeInterval timeIntervalSinceNow: TimeInterval = 60 * 60 * 2) {
        self.contentId = contentId
        self.gtoken = try! .init(gtoken)
        self.accessToken = accessToken
        expiresIn = .init(timeIntervalSinceNow: timeIntervalSinceNow)
    }
}
