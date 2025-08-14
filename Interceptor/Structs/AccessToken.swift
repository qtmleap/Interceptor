//
//  AccessToken.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Foundation

struct AccessToken: Codable, @unchecked Sendable {
    /// ゲームトークン
    let gtoken: String
    /// アクセストークン
    let accessToken: String
    /// 取得時間+有効期限
    let expiresIn: Date
    
    var isExpired: Bool {
        expiresIn <= Date()
    }
    
    init(gtoken: String, accessToken: String, expiresIn: Date) {
        self.gtoken = gtoken
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }
}

//{
//    "isChildRestricted": false,
//    "aud": "6699641390694400",
//    "exp": 1755139096,
//    "iat": 1755128296,
//    "iss": "api-lp1.znc.srv.nintendo.net",
//    "jti": "55dca1e7-f183-4ff8-abdb-89d6768fc617",
//    "sub": 4737360831381504,
//    "links": {
//        "networkServiceAccount": {
//            "id": "3f89c3791c43ea57"
//        }
//    },
//    "typ": "id_token",
//    "membership": {
//        "active": true
//    }
//}

// Set-Cookie
// https://app.smashbros.nintendo.net/
// NOTE: super_smash_session
//{
//    "isChildRestricted": false,
//    "aud": "5410106071449600",
//    "exp": 1755139137,
//    "iat": 1755128337,
//    "iss": "api-lp1.znc.srv.nintendo.net",
//    "jti": "0cdd8799-4d8a-4a7c-9eca-c0dd75944aa6",
//    "sub": 4737360831381504,
//    "links": {
//        "networkServiceAccount": {
//            "id": "3f89c3791c43ea57"
//        }
//    },
//    "typ": "id_token",
//    "membership": {
//        "active": true
//    }
//}

// Set-Cookie
// https://api.lp1.87abc152.srv.nintendo.net/
// NOTE: a5_token
//{
//    "isChildRestricted": false,
//    "aud": "5315326957223936",
//    "exp": 1755146431,
//    "iat": 1755135631,
//    "iss": "api-lp1.znc.srv.nintendo.net",
//    "jti": "2fbbdb23-e59a-4a4b-82d5-efc64a960018",
//    "sub": "4737360831381504",
//    "links": {
//        "networkServiceAccount": {
//            "id": "3f89c3791c43ea57"
//        }
//    },
//    "typ": "id_token",
//    "membership": {
//        "active": true
//    }
//}

// Set-Cookie
// https://app.splatoon2.nintendo.net/
// NOTE: iksm_session
//{
//    "isChildRestricted": false,
//    "aud": "5vo2i2kmzx6ps1l1vjsjgnjs99ymzcw0",
//    "exp": 1755138996,
//    "iat": 1755128196,
//    "iss": "api-lp1.znc.srv.nintendo.net",
//    "jti": "f220837c-1595-4006-856b-c30d9e872362",
//    "sub": 4737360831381504,
//    "links": {
//        "networkServiceAccount": {
//            "id": "3f89c3791c43ea57"
//        }
//    },
//    "typ": "id_token",
//    "membership": {
//        "active": true
//    }
//}

// Body
// https://api.lp1.usagi.srv.nintendo.net/api/primer_tokens
// NOTE: primer_token

// Body
// https://api.lp1.av5ja.srv.nintendo.net/api/bullet_tokens
// NOTE: bulletToken
//{
//    "isChildRestricted": false,
//    "aud": "6633677291552768",
//    "exp": 1755139009,
//    "iat": 1755128209,
//    "iss": "api-lp1.znc.srv.nintendo.net",
//    "jti": "d92ca54d-a752-4a23-8349-20cdfa3ed231",
//    "sub": 4737360831381504,
//    "links": {
//        "networkServiceAccount": {
//            "id": "3f89c3791c43ea57"
//        }
//    },
//    "typ": "id_token",
//    "membership": {
//        "active": true
//    }
//}
