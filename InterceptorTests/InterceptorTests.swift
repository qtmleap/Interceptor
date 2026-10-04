//
//  InterceptorTests.swift
//  InterceptorTests
//

@testable import Interceptor
import Foundation
@testable import Mudmouth
import XCTest

@MainActor
final class InterceptorTests: XCTestCase {
    private func gameWebToken() throws -> String {
        let header: [String: Any] = [
            "alg": "RS256", "jku": "https://example.invalid/keys", "kid": "fixture", "typ": "JWT",
            "fixtureNote": "?????????~~~~~~~~~",
        ]
        let payload: [String: Any] = [
            "isChildRestricted": false, "aud": "fixture-audience", "exp": 4_102_444_800,
            "iat": 1_700_000_000, "iss": "fixture-issuer", "sub": 123,
            "jti": "00000000-0000-0000-0000-000000000001", "typ": "JWT",
            "links": ["networkServiceAccount": ["id": "fixture-account"]],
            "membership": ["active": true],
        ]
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try "\(encode(header)).\(encode(payload)).YWJj"
    }

    private func record(host: String, headers: [String: String] = [:], body: Data? = nil) throws -> Record {
        // The public preview fixture builds the same SwiftData relationships as capture records.
        let record = try XCTUnwrap(RecordGroup().records.first)
        record.request.host = host
        record.request.header = try JSONSerialization.data(withJSONObject: headers)
        record.response.data = body
        return record
    }

    func testDecodesUnpaddedBase64URLGameWebToken() throws {
        let encoded = try gameWebToken()
        XCTAssertTrue(encoded.contains("-"))
        XCTAssertTrue(encoded.contains("_"))
        XCTAssertFalse(encoded.contains("="))
        let token = try GameWebToken(encoded)
        XCTAssertEqual(token.header.kid, "fixture")
        XCTAssertEqual(token.payload.aud, "fixture-audience")
        XCTAssertEqual(token.payload.sub, 123)
        XCTAssertEqual(token.signature, "YWJj")
        XCTAssertFalse(token.isRefreshNeeded)
    }

    func testRejectsMalformedGameWebTokensWithoutCrashing() {
        for malformed in ["", "..", "a.b.c.d", "@@@@.@@@@.sig", "e30.e30.sig"] {
            XCTAssertThrowsError(try GameWebToken(malformed), "Malformed fixture: \(malformed)")
        }
    }

    func testCookieDuplicatesEmptyValuesAndCaseInsensitiveHeaderNames() {
        let headers = [
            "cOoKiE": "iksm_session=old; iksm_session=new; empty=; signed=a=b",
            "hOsT": "example.invalid",
        ]
        XCTAssertEqual(headers.cookies?["iksm_session"], "new")
        XCTAssertEqual(headers.cookies?["empty"], "")
        XCTAssertEqual(headers.cookies?["signed"], "a=b")
        XCTAssertEqual(headers.host, "example.invalid")
    }

    func testExtractsSplatoon2TokenFromSavedRecord() throws {
        let record = try record(host: "app.splatoon2.nintendo.net", headers: [
            "Cookie": "iksm_session=old; iksm_session=fixture-session",
            "x-gamewebtoken": gameWebToken(),
        ])
        let token = try XCTUnwrap(Tuberose.token(from: record))
        XCTAssertEqual(token.contentId.rawValue, ContentId.SP2.rawValue)
        XCTAssertEqual(token.accessToken, "fixture-session")
        XCTAssertEqual(token.host, "app.splatoon2.nintendo.net")
    }

    func testExtractsSmashTokenFromSavedRecord() throws {
        let record = try record(host: "app.smashbros.nintendo.net", headers: [
            "Cookie": "super_smash_session=fixture-smash-session", "X-GameWebToken": gameWebToken(),
        ])
        let token = try XCTUnwrap(Tuberose.token(from: record))
        XCTAssertEqual(token.contentId.rawValue, ContentId.SMSP.rawValue)
        XCTAssertEqual(token.accessToken, "fixture-smash-session")
    }

    func testExtractsSplatoon3TokenFromSavedResponseBody() throws {
        let body = try JSONSerialization.data(withJSONObject: ["bulletToken": "fixture-bullet"])
        let record = try record(host: "api.lp1.av5ja.srv.nintendo.net", headers: [
            "Cookie": "_gtoken=\(gameWebToken())",
        ], body: body)
        let token = try XCTUnwrap(Tuberose.token(from: record))
        XCTAssertEqual(token.contentId.rawValue, ContentId.SP3.rawValue)
        XCTAssertEqual(token.accessToken, "fixture-bullet")
    }

    func testIgnoresUnrelatedHostAndIncompleteCapturedRecord() throws {
        let unrelated = try record(host: "example.invalid", headers: [
            "Cookie": "iksm_session=fixture", "X-GameWebToken": gameWebToken(),
        ])
        XCTAssertNil(try Tuberose.token(from: unrelated))
        XCTAssertNil(try Tuberose.token(from: record(host: "app.splatoon2.nintendo.net")))
        let incompleteBody = try JSONSerialization.data(withJSONObject: ["unrelated": "value"])
        XCTAssertNil(try Tuberose.token(from: record(host: "api.lp1.av5ja.srv.nintendo.net", body: incompleteBody)))
    }

    func testRejectsMalformedCapturedJWTAndResponseJSON() throws {
        let invalidJWT = try record(host: "app.splatoon2.nintendo.net", headers: [
            "Cookie": "iksm_session=fixture", "X-GameWebToken": "@@@@.@@@@.sig",
        ])
        XCTAssertThrowsError(try Tuberose.token(from: invalidJWT))
        let invalidBody = try record(host: "api.lp1.av5ja.srv.nintendo.net", body: Data("not JSON".utf8))
        XCTAssertThrowsError(try Tuberose.token(from: invalidBody))
    }

    func testConsentFailsClosedForMissingOldAndFutureVersions() throws {
        let suite = "InterceptorTests.Consent.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CaptureAuthorization.isGranted(in: store))
        store.set(CaptureAuthorization.version - 1, forKey: CaptureAuthorization.key)
        XCTAssertFalse(CaptureAuthorization.isGranted(in: store))
        store.set(CaptureAuthorization.version + 1, forKey: CaptureAuthorization.key)
        XCTAssertFalse(CaptureAuthorization.isGranted(in: store))
        CaptureAuthorization.grant(in: store)
        XCTAssertTrue(CaptureAuthorization.isGranted(in: store))
        CaptureAuthorization.revoke(in: store)
        XCTAssertFalse(CaptureAuthorization.isGranted(in: store))
    }

    func testCertificateServerConsentAndRestart() async throws {
        let store = CaptureAuthorization.defaults
        let original = store.object(forKey: CaptureAuthorization.key)
        let proxy = X509Proxy.default
        defer {
            try? proxy.stop()
            if let original { store.set(original, forKey: CaptureAuthorization.key) }
            else { store.removeObject(forKey: CaptureAuthorization.key) }
        }
        CaptureAuthorization.revoke()
        XCTAssertThrowsError(try proxy.start())
        CaptureAuthorization.grant()
        try proxy.start()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: proxy.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("BEGIN CERTIFICATE"))
        CaptureAuthorization.revoke()
        try proxy.stop()
        do {
            _ = try await session.data(from: proxy.url)
            XCTFail("Certificate listener must be closed after withdrawal")
        } catch { XCTAssertTrue(error is URLError) }
        CaptureAuthorization.grant()
        try proxy.start()
        let (_, restarted) = try await session.data(from: proxy.url)
        XCTAssertEqual((restarted as? HTTPURLResponse)?.statusCode, 200)
    }

    func testTunnelCannotStartWithoutConsentOrValidOptions() async throws {
        let store = CaptureAuthorization.defaults
        let original = store.object(forKey: CaptureAuthorization.key)
        defer {
            if let original { store.set(original, forKey: CaptureAuthorization.key) }
            else { store.removeObject(forKey: CaptureAuthorization.key) }
        }
        CaptureAuthorization.revoke()
        do { try await MITM.startTunnel(); XCTFail("Missing consent must reject start") }
        catch { XCTAssertTrue(error is CaptureAuthorization.Failure) }
        CaptureAuthorization.grant()
        do { try await MITM.startTunnel(); XCTFail("Invalid configuration must reject start") }
        catch { XCTAssertTrue(error is LocalProxyChannels.Failure) }
        await MITM.stopTunnel()
        await MITM.stopTunnel()
    }

}
