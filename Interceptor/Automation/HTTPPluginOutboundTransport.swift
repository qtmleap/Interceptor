import AutomationCore
import Darwin
import dnssd
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS

struct HTTPPluginOutboundRequest: Sendable {
    let host: String
    let path: String
    let headers: [String: String]
    let method: String
    /// Exact strict-JSON UTF-8 bytes captured at send time; only POST/PUT may carry one.
    let jsonBody: Data?

    init(host: String, path: String, headers: [String: String], method: String = "GET", jsonBody: Data? = nil) {
        self.host = host
        self.path = path
        self.headers = headers
        self.method = method
        self.jsonBody = jsonBody
    }

    /// Defense in depth after manifest/result validation. All HTTP framing is owned here.
    var isValid: Bool {
        guard ["GET", "POST", "PUT"].contains(method) else { return false }
        if let jsonBody {
            guard method != "GET", PluginOutboundPolicy.isAllowedJSONBody(jsonBody),
                  headers["content-type"].map({ $0 == "application/json" }) ?? true else { return false }
        }
        guard !host.contains("/"), path.hasPrefix("/"),
              PluginOutboundPolicy.isAllowedURL("https://" + host + path),
              headers.count <= PluginOutboundPolicy.maxDeclaredHeaders else { return false }
        var size = 0
        for (name, value) in headers {
            guard PluginOutboundPolicy.isAllowedHeaderName(name), PluginOutboundPolicy.isAllowedHeaderValue(value),
                  value.utf8.count <= PluginOutboundPolicy.maxHeaderValueBytes else { return false }
            size += value.utf8.count
        }
        return size <= PluginOutboundPolicy.maxTotalHeaderValueBytes
    }
}

enum HTTPPluginOutboundOutcome: Sendable, Equatable {
    case response(Int)
    case rejected
    case failed
    case cancelled
    case timedOut
    case tooLarge
}

/// Standard-fetch result: only status and the strictly framed, identity-encoded, UTF-8 body.
enum HTTPPluginFetchOutcome: Sendable, Equatable {
    case response(status: Int, body: Data)
    case rejected
    case failed
    case cancelled
    case timedOut
    case tooLarge
}

protocol HTTPPluginOutboundTransport: Sendable {
    func perform(_ request: HTTPPluginOutboundRequest,
                 isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginOutboundOutcome
    /// Retains the response body (<= `maxResponseBytes`) within `min(timeoutMilliseconds, 5000)`.
    func fetch(_ request: HTTPPluginOutboundRequest, timeoutMilliseconds: Int, maxResponseBytes: Int,
               isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginFetchOutcome
}

extension HTTPPluginOutboundTransport {
    /// Existing test doubles and transports do not support fetch.
    func fetch(_ request: HTTPPluginOutboundRequest, timeoutMilliseconds: Int, maxResponseBytes: Int,
               isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginFetchOutcome
    {
        .rejected
    }
}

/// Per-exchange response policy. The legacy preset keeps the original 64 KiB wire cap and discards bodies.
struct HTTPPluginExchangeLimits: Sendable {
    static let legacy = HTTPPluginExchangeLimits(wireBytes: 65_536, bodyBytes: nil, deadlineNanoseconds: 3_000_000_000)
    static let maxFetchDeadlineMilliseconds = 5000
    static let maxFetchResponseBytes = 1_048_576

    let wireBytes: Int
    /// Non-nil collects the body (fetch mode): identity encoding is forced and compressed replies are rejected.
    let bodyBytes: Int?
    let deadlineNanoseconds: UInt64

    var isFetch: Bool {
        bodyBytes != nil
    }

    static func fetch(timeoutMilliseconds: Int, maxResponseBytes: Int) -> HTTPPluginExchangeLimits? {
        guard timeoutMilliseconds > 0, maxResponseBytes > 0 else { return nil }
        let cap = min(maxResponseBytes, maxFetchResponseBytes)
        return HTTPPluginExchangeLimits(wireBytes: cap, bodyBytes: cap,
                                        deadlineNanoseconds: UInt64(min(timeoutMilliseconds, maxFetchDeadlineMilliseconds)) * 1_000_000)
    }
}

private struct HTTPPluginExchangeResult: Sendable {
    let outcome: HTTPPluginOutboundOutcome
    let body: Data
    init(_ outcome: HTTPPluginOutboundOutcome, body: Data = Data()) {
        self.outcome = outcome
        self.body = body
    }
}

/// Numeric-IP sockets never consult CFNetwork's PAC/cookie/credential/cache machinery.
/// The TLS peer is authenticated against the manifest hostname, never the resolved IP.
struct HTTPPluginDirectTransport: HTTPPluginOutboundTransport {
    typealias Resolver = @Sendable (String) async throws -> SocketAddress
    private let resolver: Resolver
    private let tlsContext: NIOSSLContext?
    private let permitsTestAddress: Bool
    /// One shared event loop per extension process, reused across tunnel restarts.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init() {
        resolver = { host in try await HTTPPluginDNSLookup(host: host).resolve() }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .fullVerification
        tlsContext = try? NIOSSLContext(configuration: tls)
        permitsTestAddress = false
    }

    #if DEBUG
    /// Test-owned DNS/socket mapping and trust roots; unavailable in release builds.
    /// Keep the bypass disabled to exercise production public-IP/443 admission with a deterministic resolver.
    init(testingResolver: @escaping Resolver, testingTLSContext: NIOSSLContext,
         bypassDestinationPolicyForTesting: Bool = true)
    {
        resolver = testingResolver
        tlsContext = testingTLSContext
        permitsTestAddress = bypassDestinationPolicyForTesting
    }
    #endif

    func perform(_ request: HTTPPluginOutboundRequest,
                 isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginOutboundOutcome
    {
        await execute(request, limits: .legacy, isAuthorized: isAuthorized).outcome
    }

    func fetch(_ request: HTTPPluginOutboundRequest, timeoutMilliseconds: Int, maxResponseBytes: Int,
               isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginFetchOutcome
    {
        guard let limits = HTTPPluginExchangeLimits.fetch(timeoutMilliseconds: timeoutMilliseconds,
                                                          maxResponseBytes: maxResponseBytes) else { return .rejected }
        let result = await execute(request, limits: limits, isAuthorized: isAuthorized)
        switch result.outcome {
            case let .response(status): return .response(status: status, body: result.body)
            case .rejected: return .rejected
            case .failed: return .failed
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .tooLarge: return .tooLarge
        }
    }

    private func execute(_ request: HTTPPluginOutboundRequest, limits: HTTPPluginExchangeLimits,
                         isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginExchangeResult
    {
        guard request.isValid else { return .init(.rejected) }
        guard !Task.isCancelled else { return .init(.cancelled) }
        // The deadline includes authorization, DNS, TCP, TLS and the entire response.
        return await withTaskGroup(of: HTTPPluginExchangeResult.self) { tasks in
            tasks.addTask { await run(request, limits: limits, isAuthorized: isAuthorized) }
            tasks.addTask {
                do {
                    try await Task.sleep(nanoseconds: limits.deadlineNanoseconds)
                    return .init(.timedOut)
                } catch {
                    return .init(.cancelled)
                }
            }
            let result = await tasks.next() ?? .init(.failed)
            tasks.cancelAll()
            return result
        }
    }

    private func run(_ request: HTTPPluginOutboundRequest, limits: HTTPPluginExchangeLimits,
                     isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginExchangeResult
    {
        guard await isAuthorized() else { return .init(.rejected) }
        guard !Task.isCancelled else { return .init(.cancelled) }
        guard let tlsContext else { return .init(.failed) }
        do {
            let address = try await resolver(request.host)
            guard !Task.isCancelled else { return .init(.cancelled) }
            guard permitsTestAddress || (address.port == 443 && address.ipAddress.map(HTTPPluginPublicAddress.isAllowed) == true)
            else { return .init(.rejected) }
            guard await isAuthorized() else { return .init(.rejected) }
            guard !Task.isCancelled else { return .init(.cancelled) }
            let exchange = HTTPPluginOutboundExchange(loop: Self.group.next(), request: request, limits: limits,
                                                      isAuthorized: isAuthorized)
            return await exchange.perform(address: address, tlsContext: tlsContext)
        } catch is CancellationError {
            return .init(.cancelled)
        } catch {
            return .init(Task.isCancelled ? .cancelled : .failed)
        }
    }
}

/// Conservative global-unicast policy. Reject known IPv4-embedding mechanisms entirely
/// instead of allowing a private IPv4 destination to hide inside an IPv6 spelling.
enum HTTPPluginPublicAddress {
    static func isAllowed(_ literal: String) -> Bool {
        var v4 = in_addr()
        if literal.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { bytes in
                // Darwin accepts leading zeroes in inet_pton; require the canonical
                // dotted-decimal spelling rather than an ambiguous alternative.
                guard bytes.map({ String($0) }).joined(separator: ".") == literal else { return false }
                let a = bytes[0], b = bytes[1], c = bytes[2]
                return a != 0 && a != 10 && a != 127 && a < 224 &&
                    !(a == 100 && (64 ... 127).contains(b)) && !(a == 169 && b == 254) &&
                    !(a == 172 && (16 ... 31).contains(b)) &&
                    !(a == 192 && ((b == 0 && (c == 0 || c == 2)) || b == 168 || (b == 88 && c == 99))) &&
                    !(a == 198 && ((b == 18 || b == 19) || (b == 51 && c == 100))) &&
                    !(a == 203 && b == 0 && c == 113)
            }
        }
        var v6 = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            // This excludes unspecified, loopback, ULA, link-local, multicast,
            // IPv4-mapped/compatible, and both standardized NAT64 prefixes.
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            // Reject 6to4 and the IETF special-purpose 2001::/23 block,
            // including Teredo, benchmark and ORCHID destinations.
            guard !(bytes[0] == 0x20 && bytes[1] == 0x02),
                  !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2),
                  !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8),
                  !(bytes[0] == 0x3f && bytes[1] == 0xfe),
                  !(bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0)
            else { return false }
            return true
        }
    }
}

/// A missing record can describe one address family while the other still has a result.
/// Keep that lookup alive until an eligible answer or the enclosing total deadline.
enum HTTPPluginDNSReplyDisposition: Equatable {
    case ignored, address, failed

    init(flags: DNSServiceFlags, error: DNSServiceErrorType) {
        if error == kDNSServiceErr_NoSuchRecord {
            self = .ignored
        } else if error != kDNSServiceErr_NoError {
            self = .failed
        } else {
            self = flags & DNSServiceFlags(kDNSServiceFlagsAdd) == 0 ? .ignored : .address
        }
    }
}

/// Every mutable field is confined to this lookup's serial queue. Deallocation cancels
/// daemon callbacks, so cancellation never leaves a blocking resolver thread behind.
private final class HTTPPluginDNSLookup: @unchecked Sendable {
    private let host: String
    private let queue = DispatchQueue(label: "jp.qleap.interceptor.plugin-dns")
    private var reference: DNSServiceRef?
    private var continuation: CheckedContinuation<SocketAddress, Error>?
    private var result: Result<SocketAddress, Error>?

    init(host: String) {
        self.host = host
    }

    func resolve() async throws -> SocketAddress {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<SocketAddress, Error>) {
        if let result {
            continuation.resume(with: result); return
        }
        self.continuation = continuation
        let error = host.withCString {
            DNSServiceGetAddrInfo(&reference, 0, 0, 0, $0, { _, flags, _, error, _, address, _, context in
                guard let context else { return }
                Unmanaged<HTTPPluginDNSLookup>.fromOpaque(context).takeUnretainedValue().received(flags: flags, error: error, address: address)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        guard error == kDNSServiceErr_NoError, let reference else { finish(.failure(LookupFailure.failed)); return }
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else { finish(.failure(LookupFailure.failed)); return }
    }

    private func received(flags: DNSServiceFlags, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard result == nil else { return }
        switch HTTPPluginDNSReplyDisposition(flags: flags, error: error) {
            case .ignored: return
            case .failed: finish(.failure(LookupFailure.failed)); return
            case .address: break
        }
        guard let address,
              address.pointee.sa_family == sa_family_t(AF_INET) || address.pointee.sa_family == sa_family_t(AF_INET6)
        else { finish(.failure(LookupFailure.failed)); return }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { finish(.failure(LookupFailure.failed)); return }
        let literal = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard HTTPPluginPublicAddress.isAllowed(literal), let resolved = try? SocketAddress(ipAddress: literal, port: 443)
        else { finish(.failure(LookupFailure.failed)); return }
        finish(.success(resolved))
    }

    private func finish(_ result: Result<SocketAddress, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let reference {
            DNSServiceRefDeallocate(reference); self.reference = nil
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    private enum LookupFailure: Error { case failed }
}

/// State and channel ownership live on one NIO event loop. The task's cancellation
/// closes even a connecting/handshaking channel before its caller releases a slot.
private final class HTTPPluginOutboundExchange: @unchecked Sendable {
    let loop: EventLoop
    private let request: HTTPPluginOutboundRequest
    let limits: HTTPPluginExchangeLimits
    private let isAuthorized: @Sendable () async -> Bool
    private let promise: EventLoopPromise<HTTPPluginOutboundOutcome>
    /// Mutated on the event loop only; read after the promise (completed from the loop) resolves.
    private var collected = Data()
    private var channel: Channel?
    private var finished = false
    private var authorizationTask: Task<Void, Never>?

    init(loop: EventLoop, request: HTTPPluginOutboundRequest, limits: HTTPPluginExchangeLimits,
         isAuthorized: @escaping @Sendable () async -> Bool)
    {
        self.loop = loop
        self.request = request
        self.limits = limits
        self.isAuthorized = isAuthorized
        promise = loop.makePromise(of: HTTPPluginOutboundOutcome.self)
    }

    func perform(address: SocketAddress, tlsContext: NIOSSLContext) async -> HTTPPluginExchangeResult {
        let outcome: HTTPPluginOutboundOutcome = await withTaskCancellationHandler {
            loop.execute {
                guard !self.finished else { return }
                ClientBootstrap(group: self.loop)
                    .connectTimeout(.seconds(3))
                    .channelInitializer { channel in self.configure(channel: channel, tlsContext: tlsContext) }
                    .connect(to: address).whenFailure { _ in self.finish(.failed) }
            }
            return await (try? promise.futureResult.get()) ?? .failed
        } onCancel: {
            self.loop.execute { self.finish(.cancelled) }
        }
        // `finish` runs on the loop before the promise succeeds, so `collected` is final here.
        if case .response = outcome, limits.isFetch {
            return HTTPPluginExchangeResult(outcome, body: collected)
        }
        return HTTPPluginExchangeResult(outcome)
    }

    /// Event-loop only. Returns false once the retained body would exceed the cap.
    func append(_ buffer: ByteBuffer) -> Bool {
        guard let cap = limits.bodyBytes, buffer.readableBytes <= cap - collected.count else { return false }
        collected.append(contentsOf: buffer.readableBytesView)
        return true
    }

    /// Event-loop only. Fetch bodies must be valid UTF-8 for `Response.text()/json()`.
    var collectedIsUTF8: Bool {
        String(data: collected, encoding: .utf8) != nil
    }

    private func configure(channel: Channel, tlsContext: NIOSSLContext) -> EventLoopFuture<Void> {
        self.channel = channel
        guard !finished else { return channel.close() }
        do {
            let pipeline = channel.pipeline.syncOperations
            try pipeline.addHandler(NIOSSLClientHandler(context: tlsContext, serverHostname: request.host))
            try pipeline.addHandler(HTTPPluginOutboundWireLimit(exchange: self))
            try pipeline.addHandler(HTTPRequestEncoder())
            try pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes, informationalResponseStrategy: .forward)))
            try pipeline.addHandler(HTTPPluginOutboundResponse(exchange: self))
            return loop.makeSucceededVoidFuture()
        } catch { return loop.makeFailedFuture(error) }
    }

    func handshakeCompleted() {
        guard !finished else { return }
        authorizationTask = Task {
            let allowed = await isAuthorized()
            loop.execute {
                guard !self.finished else { return }
                guard allowed, let channel = self.channel, channel.isActive else { self.finish(.rejected); return }
                var headers = HTTPHeaders()
                headers.add(name: "host", value: self.request.host)
                headers.add(name: "connection", value: "close")
                if self.limits.isFetch {
                    headers.add(name: "accept-encoding", value: "identity")
                }
                let method: HTTPMethod = self.request.method == "POST" ? .POST : self.request.method == "PUT" ? .PUT : .GET
                let body = self.request.jsonBody
                // Single framing builder: host owns Host/Content-Length/Content-Type; GET stays byte-identical.
                if method != .GET {
                    headers.add(name: "content-length", value: String(body?.count ?? 0))
                    if body != nil {
                        headers.add(name: "content-type", value: "application/json")
                    }
                }
                for (name, value) in self.request.headers.sorted(by: { $0.key < $1.key }) {
                    if body != nil, name == "content-type" {
                        continue
                    }
                    if self.limits.isFetch, name == "accept-encoding" {
                        continue
                    }
                    headers.add(name: name, value: value)
                }
                let head = HTTPRequestHead(version: .http1_1, method: method, uri: self.request.path, headers: headers)
                channel.write(HTTPClientRequestPart.head(head), promise: nil)
                if let body {
                    channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
                }
                channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { _ in self.finish(.failed) }
            }
        }
    }

    func finish(_ outcome: HTTPPluginOutboundOutcome) {
        loop.preconditionInEventLoop()
        guard !finished else { return }
        finished = true
        authorizationTask?.cancel()
        authorizationTask = nil
        if let channel {
            self.channel = nil
            let closed = loop.makePromise(of: Void.self)
            // Close below TLS: its graceful close-notify timeout must not extend the
            // total operation deadline or keep a cancelled socket/dispatcher slot alive.
            if let tls = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLClientHandler.self) {
                tls.close(promise: closed)
            } else {
                channel.close(promise: closed)
            }
            closed.futureResult.whenComplete { _ in self.promise.succeed(outcome) }
        } else {
            promise.succeed(outcome)
        }
    }
}

/// Counts decrypted HTTP wire bytes before decoding, including headers and chunk framing.
private final class HTTPPluginOutboundWireLimit: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let exchange: HTTPPluginOutboundExchange
    private var received = 0
    init(exchange: HTTPPluginOutboundExchange) {
        self.exchange = exchange
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let size = unwrapInboundIn(data).readableBytes
        guard size <= exchange.limits.wireBytes - received else { exchange.finish(.tooLarge); return }
        received += size
        context.fireChannelRead(data)
    }
}

private final class HTTPPluginOutboundResponse: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let exchange: HTTPPluginOutboundExchange
    private var status: Int?
    init(exchange: HTTPPluginOutboundExchange) {
        self.exchange = exchange
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            exchange.handshakeCompleted()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head):
                let code = Int(head.status.code)
                if code == 101 {
                    exchange.finish(.failed)
                } else if code >= 200 {
                    if exchange.limits.isFetch, !Self.isAcceptableFetchHead(head) {
                        exchange.finish(.failed); return
                    }
                    status = code
                }
            case let .body(buffer):
                // Legacy mode never retains or returns secondary response data.
                if exchange.limits.isFetch, status != nil, !exchange.append(buffer) {
                    exchange.finish(.tooLarge)
                }
            case .end:
                if let status {
                    if exchange.limits.isFetch, !exchange.collectedIsUTF8 {
                        exchange.finish(.failed); return
                    }
                    exchange.finish(.response(status))
                }
        }
    }

    /// Identity content only; chunked is the sole transfer coding and never combines with Content-Length.
    /// NIO's decoder already rejects malformed chunking and conflicting Content-Length values.
    private static func isAcceptableFetchHead(_ head: HTTPResponseHead) -> Bool {
        guard head.headers[canonicalForm: "content-encoding"].allSatisfy({ $0.lowercased() == "identity" }) else { return false }
        let transfer = head.headers[canonicalForm: "transfer-encoding"].map { $0.lowercased() }
        guard transfer.isEmpty || transfer == ["chunked"] else { return false }
        return transfer.isEmpty || head.headers[canonicalForm: "content-length"].isEmpty
    }

    func channelInactive(context: ChannelHandlerContext) {
        exchange.finish(.failed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        exchange.finish(.failed)
    }
}
