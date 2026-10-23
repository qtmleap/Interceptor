import dnssd
import Foundation
@testable import Interceptor
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import XCTest

final class HTTPPluginOutboundTransportTests: XCTestCase, @unchecked Sendable {
    func testOnlyPublicBinaryAddressesAreEligible() {
        for address in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(HTTPPluginPublicAddress.isAllowed(address), address)
        }
        for address in [
            "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255",
            "192.0.0.0", "192.0.0.1", "192.0.0.8", "192.0.0.9", "192.0.0.10", "192.0.0.255", "192.0.2.1", "192.168.0.1", "198.18.0.1", "198.19.255.255",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1", "255.255.255.255", "::", "::1", "fc00::1", "fd00::1", "fe80::1", "ff02::1",
            "2001:db8::1", "2001:3::1", "2001:2::1", "2001:10::1", "2001:20::1", "3fff::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8",
            "64:ff9b::a00:1", "64:ff9b:1::a00:1", "2002:0a00:0001::1", "2002:0808:0808::1", "2001::1",
            "fe80::1%en0", "127.1", "0177.0.0.1", "2130706433", "0x7f000001", "example.com", "",
        ] {
            XCTAssertFalse(HTTPPluginPublicAddress.isAllowed(address), address)
        }
    }

    func testRequestTargetAndHeaderFramingCannotInjectBytes() {
        XCTAssertTrue(HTTPPluginOutboundRequest(host: "api.example.com", path: "/auth/bearer", headers: ["authorization": "Bearer test-token"]).isValid)
        XCTAssertTrue(HTTPPluginOutboundRequest(host: "api.example.com", path: "/%E6%97%A5%2F", headers: [:]).isValid)
        XCTAssertTrue(
            HTTPPluginOutboundRequest(host: "api.example.com", path: "//other.example.com/", headers: [:]).isValid,
            "origin-form path keeps the manifest host",
        )
        for path in [
            "/auth/bearer?probe=1",
            "/bad%0d",
            "/bad%7f",
            "/bad%5c",
            "https://other.example.com/",
            "/bad\r\nInjected: yes",
            "/a b",
            "/a\\b",
            "/a#fragment",
            "/bad%",
            "/bad%0G",
            "/日本語",
        ] {
            XCTAssertFalse(HTTPPluginOutboundRequest(host: "api.example.com", path: path, headers: [:]).isValid, path)
        }
        for host in [
            "127.0.0.1",
            "API.example.com",
            "api.example.com.",
            "api.example.com:443",
            "api.example.com/path",
            "user@api.example.com",
            "localhost",
            "a.local",
            "api.example.com\r\n",
        ] {
            XCTAssertFalse(HTTPPluginOutboundRequest(host: host, path: "/", headers: [:]).isValid, host)
        }
        for name in [
            "Host",
            "host",
            "connection",
            "content-length",
            "transfer-encoding",
            "upgrade",
            "te",
            "trailer",
            "expect",
            "keep-alive",
            "proxy-authorization",
            "set-cookie",
            ":authority",
            "bad name",
        ] {
            XCTAssertFalse(HTTPPluginOutboundRequest(host: "api.example.com", path: "/", headers: [name: "value"]).isValid, name)
        }
        for value in ["Bearer token\r\nCookie: injected", "a\0b", "a\u{7f}b", "日本語", String(repeating: "x", count: 4_097)] {
            XCTAssertFalse(HTTPPluginOutboundRequest(host: "api.example.com", path: "/", headers: ["authorization": value]).isValid)
        }
        XCTAssertTrue(HTTPPluginOutboundRequest(host: "api.example.com", path: "/", headers: ["x-test": "\t visible value "]).isValid)
        XCTAssertFalse(HTTPPluginOutboundRequest(
            host: "api.example.com",
            path: "/",
            headers: Dictionary(uniqueKeysWithValues: (0 ..< 9).map { ("x-\($0)", "value") }),
        ).isValid)
        XCTAssertFalse(HTTPPluginOutboundRequest(
            host: "api.example.com",
            path: "/",
            headers: ["a": String(repeating: "a", count: 4_096), "b": String(repeating: "b", count: 4_096), "c": "x"],
        ).isValid)
    }

    func testDNSFamilyMissDoesNotDiscardOtherFamilyAnswers() {
        XCTAssertEqual(HTTPPluginDNSReplyDisposition(flags: 0, error: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)), .ignored)
        XCTAssertEqual(HTTPPluginDNSReplyDisposition(flags: 0, error: DNSServiceErrorType(kDNSServiceErr_NoError)), .ignored)
        XCTAssertEqual(HTTPPluginDNSReplyDisposition(flags: DNSServiceFlags(kDNSServiceFlagsAdd), error: DNSServiceErrorType(kDNSServiceErr_NoError)), .address)
        XCTAssertEqual(
            HTTPPluginDNSReplyDisposition(flags: DNSServiceFlags(kDNSServiceFlagsAdd), error: DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)),
            .failed,
        )
        XCTAssertEqual(HTTPPluginDNSReplyDisposition(flags: 0, error: DNSServiceErrorType(kDNSServiceErr_BadParam)), .failed)
    }

    func testRevokedAuthorizationRejectsWithoutResolving() async {
        let result = await HTTPPluginDirectTransport().perform(.init(host: "api.example.com", path: "/", headers: [:]), isAuthorized: { false })
        XCTAssertEqual(result, .rejected)
    }

    func testDirectTLSSendsOnlyTheDeclaredHeadersToTheAuthenticatedOrigin() async throws {
        try await withOrigin { origin in
            let bearer = await origin.transport.perform(
                .init(host: "api.example.com", path: "/auth/bearer", headers: ["authorization": "Bearer fixture-token"]),
                isAuthorized: { true },
            )
            let cookie = await origin.transport.perform(
                .init(host: "api.example.com", path: "/auth/cookie", headers: ["cookie": "fixture_session=test-session"]),
                isAuthorized: { true },
            )
            XCTAssertEqual(bearer, .response(200))
            XCTAssertEqual(cookie, .response(200))
            let requests = origin.requests.value
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.host == "api.example.com" && $0.bodyBytes == 0 })
            XCTAssertEqual(requests[0].authorization, "Bearer fixture-token")
            XCTAssertNil(requests[0].cookie)
            XCTAssertEqual(requests[1].cookie, "fixture_session=test-session")
            XCTAssertNil(requests[1].authorization)
            XCTAssertTrue(requests
                .allSatisfy { $0.headerNames == ["host", "connection", $0.path == "/auth/bearer" ? "authorization" : "cookie"] })
            XCTAssertTrue(requests.allSatisfy(\.userAgentValues.isEmpty), "no undeclared user-agent metadata may be added")
        }
    }

    func testExplicitUserAgentIsForwardedExactlyOnce() async throws {
        try await withOrigin { origin in
            let result = await origin.transport.perform(
                .init(host: "api.example.com", path: "/auth/bearer", headers: [
                    "authorization": "Bearer fixture-token", "user-agent": "DeclaredFixture/1",
                ]),
                isAuthorized: { true },
            )
            XCTAssertEqual(result, .response(200))
            let observed = try XCTUnwrap(origin.requests.value.first)
            XCTAssertEqual(observed.userAgentValues, ["DeclaredFixture/1"])
            XCTAssertEqual(observed.headerNames, ["host", "connection", "authorization", "user-agent"])
        }
    }

    func testProductionDestinationGateRejectsInjectedPrivateAddressesAndWrongPortBeforeNetwork() async throws {
        let tls = try OutboundOrigin.clientContext()
        for (literal, port) in [
            ("127.0.0.1", 443), ("10.0.0.1", 443), ("192.0.0.8", 443),
            ("::1", 443), ("fd00::1", 443), ("8.8.8.8", 8443),
        ] {
            let resolutions = OutboundLocked(0), authorizationChecks = OutboundLocked(0)
            let transport = HTTPPluginDirectTransport(
                testingResolver: { _ in
                    resolutions.change { $0 += 1 }
                    return try SocketAddress(ipAddress: literal, port: port)
                },
                testingTLSContext: tls,
                bypassDestinationPolicyForTesting: false,
            )
            let result = await transport.perform(.init(host: "api.example.com", path: "/", headers: [:]), isAuthorized: {
                authorizationChecks.change { $0 += 1 }
                return true
            })
            XCTAssertEqual(result, .rejected, literal + ":" + String(port))
            XCTAssertEqual(resolutions.value, 1)
            XCTAssertEqual(authorizationChecks.value, 1, "destination must reject before post-DNS authorization, TCP or TLS admission")
        }
    }

    func testDirectTLSDoesNotFollowRedirectsOrCarryHeadersToAnotherRequest() async throws {
        try await withOrigin { origin in
            let result = await origin.transport.perform(
                .init(host: "api.example.com", path: "/redirect", headers: ["authorization": "Bearer fixture-token"]),
                isAuthorized: { true },
            )
            XCTAssertEqual(result, .response(307))
            XCTAssertEqual(origin.requests.value.map(\.path), ["/redirect"])
        }
    }

    func testWireLimitCountsHeadersAndBodyWithoutRetainingTheResponse() async throws {
        try await withOrigin { origin in
            let small = await origin.transport.perform(.init(host: "api.example.com", path: "/near-limit", headers: [:]), isAuthorized: { true })
            XCTAssertEqual(small, .response(200))
            let oversized = await origin.transport.perform(.init(host: "api.example.com", path: "/over-limit", headers: [:]), isAuthorized: { true })
            XCTAssertEqual(oversized, .tooLarge)
        }
    }

    func testNormalTLSHostnameVerificationRejectsAnUnrelatedDNSHost() async throws {
        try await withOrigin { origin in
            let result = await origin.transport.perform(
                .init(host: "other.example.com", path: "/auth/bearer", headers: ["authorization": "Bearer fixture-token"]),
                isAuthorized: { true },
            )
            XCTAssertEqual(result, .failed)
            XCTAssertTrue(origin.requests.value.isEmpty, "credentials must never be written before normal TLS hostname verification")
        }
    }

    func testAuthorizationIsCheckedAfterTLSBeforeWritingAnyCredentials() async throws {
        try await withOrigin { origin in
            let checks = OutboundLocked(0)
            let result = await origin.transport.perform(
                .init(host: "api.example.com", path: "/auth/bearer", headers: ["authorization": "Bearer fixture-token"]),
                isAuthorized: {
                    checks.change { $0 += 1; return $0 < 3 }
                },
            )
            XCTAssertEqual(result, .rejected)
            XCTAssertEqual(checks.value, 3)
            XCTAssertTrue(origin.requests.value.isEmpty)
        }
    }

    func testThreeSecondDeadlineClosesASilentOrigin() async throws {
        try await withOrigin { origin in
            let start = ContinuousClock.now
            let result = await origin.transport.perform(.init(host: "api.example.com", path: "/silent", headers: [:]), isAuthorized: { true })
            XCTAssertEqual(result, .timedOut)
            XCTAssertLessThan(start.duration(to: .now), .seconds(5), "TLS close-notify must not add its default five-second shutdown timeout")
            XCTAssertEqual(origin.requests.value.map(\.path), ["/silent"])
        }
    }

    func testCancellationStopsAnOutstandingDNSLookup() async throws {
        let started = expectation(description: "resolver started")
        let cancelled = OutboundLocked(false)
        let tls = try OutboundOrigin.clientContext()
        let transport = HTTPPluginDirectTransport(testingResolver: { _ in
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return try SocketAddress(ipAddress: "127.0.0.1", port: 443)
            } catch {
                cancelled.change { $0 = true }
                throw error
            }
        }, testingTLSContext: tls)
        let task = Task { await transport.perform(.init(host: "api.example.com", path: "/", headers: [:]), isAuthorized: { true }) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(cancelled.value)
    }

    func testCancellationClosesAnOutstandingTLSResponse() async throws {
        try await withOrigin { origin in
            let task = Task { await origin.transport.perform(.init(host: "api.example.com", path: "/silent", headers: [:]), isAuthorized: { true }) }
            for _ in 0 ..< 100 where origin.requests.value.isEmpty {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(origin.requests.value.map(\.path), ["/silent"])
            task.cancel()
            let result = await task.value
            XCTAssertEqual(result, .cancelled)
        }
    }

    private func withOrigin(_ body: (OutboundOrigin) async throws -> Void) async throws {
        let origin = try await OutboundOrigin.start()
        do {
            try await body(origin)
        } catch {
            await origin.stop()
            throw error
        }
        await origin.stop()
    }
}

private struct OutboundObservedRequest: Sendable {
    let method: String
    let path: String
    let host: String?
    let authorization: String?
    let cookie: String?
    let userAgentValues: [String]
    let headerNames: Set<String>
    let bodyBytes: Int
}

private final class OutboundLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock(); defer { lock.unlock() }; return storage
    }

    @discardableResult func change<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return operation(&storage)
    }
}

private final class OutboundOrigin: @unchecked Sendable {
    let transport: HTTPPluginDirectTransport
    let requests: OutboundLocked<[OutboundObservedRequest]>
    private let channels: OutboundLocked<[Channel]>
    private let group: MultiThreadedEventLoopGroup

    private init(
        transport: HTTPPluginDirectTransport,
        requests: OutboundLocked<[OutboundObservedRequest]>,
        channels: OutboundLocked<[Channel]>,
        group: MultiThreadedEventLoopGroup,
    ) {
        self.transport = transport; self.requests = requests; self.channels = channels; self.group = group
    }

    static func clientContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = try .certificates(NIOSSLCertificate.fromPEMBytes(Array(OutboundTestTLS.certificate.utf8)))
        configuration.certificateVerification = .fullVerification
        return try NIOSSLContext(configuration: configuration)
    }

    static func start() async throws -> OutboundOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channels = OutboundLocked<[Channel]>([])
        let requests = OutboundLocked<[OutboundObservedRequest]>([])
        do {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Array(OutboundTestTLS.certificate.utf8))
            let key = try NIOSSLPrivateKey(bytes: Array(OutboundTestTLS.privateKey.utf8), format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key))
            configuration.shutdownTimeout = .milliseconds(1)
            let serverTLS = try NIOSSLContext(configuration: configuration)
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channels.change { $0.append(channel) }
                do {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSLServerHandler(context: serverTLS))
                    try pipeline.configureHTTPServerPipeline()
                    try pipeline.addHandler(OutboundOriginHandler(requests: requests))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host: "127.0.0.1", port: 0).get()
            channels.change { $0.append(listener) }
            let port = try XCTUnwrap(listener.localAddress?.port)
            let transport = try HTTPPluginDirectTransport(
                testingResolver: { _ in try SocketAddress(ipAddress: "127.0.0.1", port: port) },
                testingTLSContext: clientContext(),
            )
            return OutboundOrigin(transport: transport, requests: requests, channels: channels, group: group)
        } catch {
            for channel in channels.value {
                try? await channel.close().get()
            }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        for channel in channels.value {
            try? await channel.close().get()
        }
        try? await group.shutdownGracefully()
    }
}

private final class OutboundOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let requests: OutboundLocked<[OutboundObservedRequest]>
    private var head: HTTPRequestHead?
    private var bodyBytes = 0
    init(requests: OutboundLocked<[OutboundObservedRequest]>) {
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head): self.head = head
            case let .body(body): bodyBytes += body.readableBytes
            case .end:
                guard let head else { context.close(promise: nil); return }
                requests.change { $0.append(.init(method: head.method.rawValue, path: head.uri,
                                                  host: head.headers.first(name: "host"), authorization: head.headers.first(name: "authorization"),
                                                  cookie: head.headers.first(name: "cookie"), userAgentValues: head.headers["user-agent"],
                                                  headerNames: Set(head.headers.map { $0.name.lowercased() }),
                                                  bodyBytes: bodyBytes))
                }
                guard head.uri != "/silent" else { return }
                let status: HTTPResponseStatus = if head.uri == "/redirect" {
                    .temporaryRedirect
                } else if head.uri == "/auth/bearer" {
                    head.headers.first(name: "authorization") == "Bearer fixture-token" ? .ok : .unauthorized
                } else if head.uri == "/auth/cookie" {
                    head.headers.first(name: "cookie") == "fixture_session=test-session" ? .ok : .unauthorized
                } else {
                    .ok
                }
                let size = head.uri == "/over-limit" ? 65_536 : (head.uri == "/near-limit" ? 64_512 : 2)
                var headers = HTTPHeaders([("content-length", String(size))])
                if status == .temporaryRedirect {
                    headers.add(name: "location", value: "https://other.example.com/must-not-be-followed")
                }
                context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
                var buffer = context.channel.allocator.buffer(capacity: size)
                buffer.writeRepeatingByte(120, count: size)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Existing public test-only TLS fixture, self-signed for api.example.com; never used outside loopback.
private enum OutboundTestTLS {
    static let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIDgzCCAmugAwIBAgIUNKiHQpPM7aRky9itsMcKhvV7VKkwDQYJKoZIhvcNAQEL
    BQAwQzEYMBYGA1UEAwwPYXBpLmV4YW1wbGUuY29tMScwJQYDVQQKDB5JbnRlcmNl
    cHRvciBMb29wYmFjayBUZXN0IE9ubHkwHhcNMjYxMDE5MTMxNTUwWhcNMzYxMDE2
    MTMxNTUwWjBDMRgwFgYDVQQDDA9hcGkuZXhhbXBsZS5jb20xJzAlBgNVBAoMHklu
    dGVyY2VwdG9yIExvb3BiYWNrIFRlc3QgT25seTCCASIwDQYJKoZIhvcNAQEBBQAD
    ggEPADCCAQoCggEBAM29d9Qhl0/A56Eo1G+HKKvNaDHHrGb2i+ybT7MFAiZ74j4P
    RsSLjwETkb4UM70PnsF43n5J0SeFAuYk1cY9S6We1Z4qB3BoCn6w27lfn74OR7Gg
    bJ0rORt6P0INr1iHxqJbSJknPgxPNBUYN9dLJ8QtFUOZOIa3awVL49ZV/yGWX4uY
    uHqi/vPuWxz35st9x9Sq3NiEN8nnBhf/t395vcuvO9ce174LHAYJa27WwdlxQ2ab
    ZsXb8yA3wNbwKfcm1DP210eDo7Jrpbr7nYAnEOeEKsEvTHqwOFlxZkctOaEz0Q+C
    CPhPPLk6V7WyBKYkbGYakguJ0FZOuAoiHLUNFtUCAwEAAaNvMG0wHQYDVR0OBBYE
    FOs+GssVXg7sCD5peI/4xO/rmXfZMB8GA1UdIwQYMBaAFOs+GssVXg7sCD5peI/4
    xO/rmXfZMBoGA1UdEQQTMBGCD2FwaS5leGFtcGxlLmNvbTAPBgNVHRMBAf8EBTAD
    AQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAy/HBsxvwfo6yRpjHof4fTN8w1nDAnigba
    pX4xM+Dhb9DL5ggIQ76w1R2cpYy8nydm/uF1XzeytQXVOhCEHp3bYhhP/HOvlteK
    yS1ksMyW3WtIT2h0ofqdTCzqodYcABjRaqgph0S4Jmj7YTxEKnUDRDveHAhBWHyZ
    CoAo5tdyC/AvKamgczt6UGe0oTnxYIsSp1TrwqS0e1s52GcsSJ0jRBULfSMCvtWD
    nf+D72dmj9VHk89mY0zF70T5yeACRvIicHjPr3bADCFr7ISmp1kWYYdX9CkZgIvZ
    jeeb/JBKiUhCUsmkYbuwrlkaO1qzKHO48qwxjuiujDlvUeapreJr
    -----END CERTIFICATE-----
    """
    static let privateKey = """
    -----BEGIN PRIVATE KEY-----
    MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDNvXfUIZdPwOeh
    KNRvhyirzWgxx6xm9ovsm0+zBQIme+I+D0bEi48BE5G+FDO9D57BeN5+SdEnhQLm
    JNXGPUulntWeKgdwaAp+sNu5X5++DkexoGydKzkbej9CDa9Yh8aiW0iZJz4MTzQV
    GDfXSyfELRVDmTiGt2sFS+PWVf8hll+LmLh6ov7z7lsc9+bLfcfUqtzYhDfJ5wYX
    /7d/eb3LrzvXHte+CxwGCWtu1sHZcUNmm2bF2/MgN8DW8Cn3JtQz9tdHg6Oya6W6
    +52AJxDnhCrBL0x6sDhZcWZHLTmhM9EPggj4Tzy5Ole1sgSmJGxmGpILidBWTrgK
    Ihy1DRbVAgMBAAECggEAEff9RWkVo229DSwMU1B7pd2ci9R2yZtSbZZdWv/eyAIQ
    qJjoj/WCxnZK4U4EYsiNdgC0QrvE6Tp9t7n52oSzkA7gqB3fMafa9GVGTqXIxTs1
    ppBufzktYkMsz5XZ/aJshihXNw3gjNSrpZ5mEIb/PYWU30C8WU+427XDSI7ENJua
    oDr9hWyXaAM7E56Rz5vtiHexnbIhqgSeH3EBMycs8HaR+15rGdn9OovxEXkjNOo6
    /yu0CVstQtBK5HuENTC994auPbOqF4FuTGhPSAvtLw/BJ9Z00dfm/tCulNSEQMMe
    7T1R3Kf3cyM3LrZe4fd//jMpZYiH6vybBs3BIwEi1QKBgQD+WodpITcU+km5tO7F
    jozRr1UPwjAbzO43R1D/Tmsb+gfjpyxpxayCV5in5ijeDJqJoYIKWxeSMjz42ywM
    VH2muumdk1KO+oBVoFSjTGkiN6QklOV47saJ0kWtxH5Zh5Yda4/eV+mXznLfrvfo
    PdIE9XNN30H2L6SdK8dcr+wljwKBgQDPEmKa8Zl/Mn8cWH72XXfo87cn6pJJ3rBm
    XpT7io3WGfO70hO4WsVHETj9itEe/NGTxWPIseXi4CcOAcJHKamiv8UBC93vu1Sr
    DmWn/VZh6NKIvHJ6swPvFF/xQx1jckyJ7mBJAVV5xSvIaQSWkI7JC2oplXgr2/w2
    JEwQm7vzWwKBgQCAnGHv5J2ne88fmb9KIYRO2msWZshQplSlmuf30D0Ujl7C29r3
    OL67wXMtIpHzhUf247WPavQGNmTiKGCjc219ivFpff620S9nHITvdUmLxbq3zJoj
    hgjZ03rsHHkO6CIdii/a63TwD7HCLQSpZ+j0HPBKpeMCiqCf4G0UDthHPQKBgQCE
    bqO1qLKc0PTOciKw+dJIoCYRV0o8CDoVHoR144UW2v4wrwiBrTviWbdzICbihJqc
    wW8x2eTGlskjgih4TsL5HWCnbKmCOvLJe6m0KKfocnjDjpJAuuDXNNavfFb9VQpy
    ZIwb5Mh/2oRH5jJTARzwo2ZANiHnGwhQsCIdtRwdZQKBgQCxevArEXntCOf+TXK1
    4WubQ4J0ITal3qfHAyaUR/MQnJn2XZdWH7X75TpywseBj/E/H4jtPRQy3ee/KIZe
    1Faz/Wv5sKLBUvERWvCOnR5+NZgGc5+Jq9LmpGjhMHb89D9KfAPqCpWBTdbwuS5L
    8dGM84PBndNFgTq8i6d/JHx1qQ==
    -----END PRIVATE KEY-----
    """
}
