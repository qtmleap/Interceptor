import CryptoKit
import Foundation
import XCTest
@testable import AutomationCore
@testable import AutomationRepository

// Transport-level fixtures only: `FixtureProtocol` supplies bytes/redirects/challenges/delays/resets underneath
// the REAL RepositoryClient delegate, bounding and parsing code. Nothing here asserts the fixture itself
// except where it is used as an observation probe (requests seen, bytes delivered, stop calls).

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let repoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let pluginID = UUID(uuidString: "f08c828f-52b6-41bc-b465-fddffae57141")!
private let repoURL = try! RepositoryURL(parsing: "https://example.com/r/repository.json")
private let envelopeAbs = "https://example.com/r/repository.json"
private let packageAbs = "https://example.com/r/p.json"

private func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
}
private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

// MARK: valid full-v1 package/repository builders

private func packageBytes(id: UUID = pluginID, name: String = "Request alert", version: String = "1.0.0") -> Data {
    Data(#"""
    {"manifest":{"schemaVersion":1,"id":"\#(id)","name":"\#(name)","version":"\#(version)","subscriptions":[{"phase":"request.completed","match":{"hosts":["api.example.com"],"methods":["POST"],"path":{"kind":"exact","value":"/v1/jobs"}}}],"read":{"metadata":["method","host"],"headers":[],"queryKeys":[],"body":{"mode":"none"}},"endpointBindings":["alert"],"settings":{}},"source":"function onRequest(event, config) { return { actions: [] }; }"}
    """#.utf8)
}

private func entry(for bytes: Data, id: UUID = pluginID, name: String = "Request alert", version: String = "1.0.0") -> IndexEntry {
    IndexEntry(id: id, name: name, version: version, packagePath: "p.json", sha256: sha(bytes), size: bytes.count)
}

private func indexPayload(_ e: IndexEntry, expires: Date = now.addingTimeInterval(86_400)) -> Data {
    Data(#"{"schemaVersion":1,"id":"\#(repoID)","name":"R","sequence":1,"issuedAt":"\#(iso(now))","expiresAt":"\#(iso(expires))","plugins":[{"id":"\#(e.id)","name":"\#(e.name)","version":"\#(e.version)","packagePath":"\#(e.packagePath)","sha256":"\#(e.sha256)","size":\#(e.size)}]}"#.utf8)
}

private func envelope(_ payload: Data, key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
    var sig = ""
    if let key {
        let s = try key.signature(for: Data("InterceptorRepository/v1".utf8) + [0] + payload)
        sig = #","signature":{"algorithm":"ed25519","publicKey":"\#(key.publicKey.rawRepresentation.base64EncodedString())","value":"\#(s.base64EncodedString())"}"#
    }
    return Data(#"{"schemaVersion":1,"payload":"\#(payload.base64EncodedString())"\#(sig)}"#.utf8)
}

private func validEnvelope() throws -> (envelope: Data, payload: Data, package: Data, entry: IndexEntry) {
    let pkg = packageBytes(); let e = entry(for: pkg); let p = indexPayload(e)
    return (try envelope(p), p, pkg, e)
}

private func split(_ d: Data, into size: Int) -> [Data] {
    stride(from: 0, to: d.count, by: size).map { d.subdata(in: $0..<min($0 + size, d.count)) }
}

// MARK: transport fixtures

enum Behavior: Sendable {
    /// `firstDelay` before the first chunk, `gap` between chunks; `finish == false` stalls forever after the last chunk.
    case respond(status: Int, headers: [String: String] = [:], chunks: [Data], firstDelay: TimeInterval = 0, gap: TimeInterval = 0, finish: Bool = true, failAfter: URLError.Code? = nil)
    case nonHTTP(Data)
    case redirect(status: Int, to: String)
    case challenge(method: String)
    case fail(URLError.Code)
}

final class FixtureStore: @unchecked Sendable {
    static let shared = FixtureStore()
    private let lock = NSLock()
    private var routes: [String: Behavior] = [:]
    private var _requests: [URLRequest] = []
    private var _stops = 0, _bytesSent = 0, _afterStop = 0, _credentialUses = 0, _challengeResolutions = 0

    func reset() { lock.lock(); defer { lock.unlock() }
        routes = [:]; _requests = []; _stops = 0; _bytesSent = 0; _afterStop = 0; _credentialUses = 0; _challengeResolutions = 0 }
    func route(_ url: String, _ b: Behavior) { lock.lock(); routes[url] = b; lock.unlock() }
    func behavior(_ url: String) -> Behavior? { lock.lock(); defer { lock.unlock() }; return routes[url] }
    func record(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }
    func addSent(_ n: Int, stopped: Bool) { lock.lock(); if stopped { _afterStop += n } else { _bytesSent += n }; lock.unlock() }
    func noteStop() { lock.lock(); _stops += 1; lock.unlock() }
    func noteCredentialUse() { lock.lock(); _credentialUses += 1; lock.unlock() }
    func noteChallengeResolution() { lock.lock(); _challengeResolutions += 1; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return _bytesSent }
    var deliveredAfterStop: Int { lock.lock(); defer { lock.unlock() }; return _afterStop }
    var credentialUses: Int { lock.lock(); defer { lock.unlock() }; return _credentialUses }
    var challengeResolutions: Int { lock.lock(); defer { lock.unlock() }; return _challengeResolutions }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    weak var proto: FixtureProtocol?
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { FixtureStore.shared.noteCredentialUse(); done() }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { done() }
    func cancel(_ challenge: URLAuthenticationChallenge) { done() }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { done() }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { done() }
    private func done() {
        FixtureStore.shared.noteChallengeResolution()
        if let p = proto { p.client?.urlProtocol(p, didFailWithError: URLError(.userAuthenticationRequired)) }
    }
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }
    private var sender: ChallengeSender?
    private let queue = DispatchQueue(label: "fixture.protocol")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        FixtureStore.shared.record(request)
        let urlString = request.url!.absoluteString
        guard let behavior = FixtureStore.shared.behavior(urlString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        switch behavior {
        case let .respond(status, headers, chunks, firstDelay, gap, finish, failAfter):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            send(chunks[...], delay: firstDelay, gap: gap, finish: finish, failAfter: failAfter)
        case let .nonHTTP(data):
            let resp = URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            send([data][...], delay: 0, gap: 0, finish: true)
        case let .redirect(status, to):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: resp)
        case let .challenge(method):
            let space = URLProtectionSpace(host: request.url!.host!, port: 443, protocol: "https", realm: "r", authenticationMethod: method)
            let s = ChallengeSender(); s.proto = self; sender = s
            let ch = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                failureResponse: nil, error: nil, sender: s)
            client?.urlProtocol(self, didReceive: ch)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    private func send(_ chunks: ArraySlice<Data>, delay: TimeInterval, gap: TimeInterval, finish: Bool, failAfter: URLError.Code? = nil) {
        guard let first = chunks.first else {
            if finish { queue.asyncAfter(deadline: .now() + delay) { [self] in
                if isStopped { return }
                if let failAfter { client?.urlProtocol(self, didFailWithError: URLError(failAfter)) } else { client?.urlProtocolDidFinishLoading(self) }
            } }
            return
        }
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let was = isStopped
            if was { return }
            FixtureStore.shared.addSent(first.count, stopped: false)
            client?.urlProtocol(self, didLoad: first)
            send(chunks.dropFirst(), delay: gap, gap: gap, finish: finish, failAfter: failAfter)
        }
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        FixtureStore.shared.noteStop()
    }
}

private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return cond()
}

final class RepositoryClientTests: XCTestCase, @unchecked Sendable {
    var store: FixtureStore { .shared }

    override func setUp() {
        super.setUp()
        store.reset()
    }

    private func makeClient(deadline: TimeInterval = RepositoryClient.defaultDeadline) -> RepositoryClient {
        RepositoryClient(deadline: deadline, protocolClasses: [FixtureProtocol.self])
    }

    private func serveValid(_ v: (envelope: Data, payload: Data, package: Data, entry: IndexEntry)) {
        store.route(envelopeAbs, .respond(status: 200, headers: ["Content-Length": "\(v.envelope.count)"], chunks: split(v.envelope, into: 97)))
        store.route(packageAbs, .respond(status: 200, headers: ["Content-Length": "\(v.package.count)"], chunks: split(v.package, into: 61)))
    }

    private func assertPreviewFails(_ expected: RepositoryClientError, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await makeClient().preview(url: repoURL, now: now); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? RepositoryClientError, expected, file: file, line: line) }
    }

    // MARK: valid flows

    func testPreviewValidRepository() async throws {
        let v = try validEnvelope(); serveValid(v)
        let snap = try await makeClient().preview(url: repoURL, now: now)
        XCTAssertEqual(snap.url, repoURL)
        XCTAssertEqual(snap.index.plugins, [v.entry])
        XCTAssertEqual(snap.signature, .unsigned)
        XCTAssertEqual(snap.payloadDigest, sha(v.payload))
        XCTAssertEqual(store.requests.map { $0.url?.absoluteString }, [envelopeAbs])
    }

    func testPreviewSignedRepositoryReportsKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let pkg = packageBytes(); let p = indexPayload(entry(for: pkg)); let env = try envelope(p, key: key)
        store.route(envelopeAbs, .respond(status: 200, chunks: [env]))
        let snap = try await makeClient().preview(url: repoURL, now: now)
        guard case let .signed(fp) = snap.signature else { return XCTFail("expected signed") }
        XCTAssertEqual(fp.rawKey, key.publicKey.rawRepresentation)
    }

    func testPreviewExpiredRepositoryRejectedUsingSuppliedNow() async throws {
        let pkg = packageBytes(); let e = entry(for: pkg)
        let env = try envelope(indexPayload(e, expires: now.addingTimeInterval(86_400)))
        store.route(envelopeAbs, .respond(status: 200, chunks: [env]))
        do { _ = try await makeClient().preview(url: repoURL, now: now.addingTimeInterval(2 * 86_400)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .expired) }
    }

    func testFetchPackageValid() async throws {
        let v = try validEnvelope(); serveValid(v)
        let c = makeClient()
        let snap = try await c.preview(url: repoURL, now: now)
        let pkg = try await c.fetchPackage(entry: v.entry, from: snap)
        XCTAssertEqual(pkg.bytes, v.package)
        XCTAssertEqual(pkg.revision, sha(v.package))
        XCTAssertEqual(pkg.manifest.id, pluginID)
        XCTAssertEqual(store.requests.last?.url?.absoluteString, packageAbs)
    }

    func testIndependentConcurrentPreviewsDoNotShareState() async throws {
        let v = try validEnvelope(); serveValid(v)
        let c = makeClient()
        async let a = c.preview(url: repoURL, now: now)
        async let b = c.preview(url: repoURL, now: now)
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, y)
        XCTAssertEqual(store.requests.count, 2)
    }

    // MARK: package integrity / identity

    private func fetch(served: Data, entry e: IndexEntry, indexEntry: IndexEntry? = nil) async throws -> PluginPackage {
        // Index lists `indexEntry` (defaults to e); the package route serves `served`.
        let ie = indexEntry ?? e
        store.route(envelopeAbs, .respond(status: 200, chunks: [try envelope(indexPayload(ie))]))
        store.route(packageAbs, .respond(status: 200, chunks: split(served, into: 128)))
        let c = makeClient()
        let snap = try await c.preview(url: repoURL, now: now)
        return try await c.fetchPackage(entry: ie, from: snap)
    }

    func testPackageHashMismatchSameSize() async throws {
        let good = packageBytes(); var bad = good; bad[bad.count - 3] ^= 0x01
        do { _ = try await fetch(served: bad, entry: entry(for: good)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .hashMismatch) }
    }

    func testPackageSizeMismatchShorter() async throws {
        let good = packageBytes()
        do { _ = try await fetch(served: good.dropLast(), entry: entry(for: good)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .sizeMismatch) }
    }

    func testPackageSizeMismatchLongerIsRejected() async throws {
        let good = packageBytes()
        do { _ = try await fetch(served: good + Data(" ".utf8), entry: entry(for: good)); XCTFail() }
        catch {
            // Either early cap at entry.size or exact-size validation is acceptable; never success.
            XCTAssertTrue(error as? AutomationError == .sizeMismatch || error as? RepositoryClientError == .responseTooLarge, "\(error)")
        }
    }

    func testPackageIdentityMismatchIsRejected() async throws {
        let other = UUID(uuidString: "05ff53a2-46bb-4bf1-9fd0-908b437f92cc")!
        let variants: [(Data, IndexEntry)] = [
            (packageBytes(id: other), entry(for: packageBytes(id: other), id: pluginID)),
            (packageBytes(name: "Different"), entry(for: packageBytes(name: "Different"), name: "Request alert")),
            (packageBytes(version: "2.0.0"), entry(for: packageBytes(version: "2.0.0"), version: "1.0.0")),
        ]
        for (bytes, e) in variants {
            store.reset()
            do { _ = try await fetch(served: bytes, entry: e); XCTFail("accepted mismatched identity") }
            catch { XCTAssertEqual(error as? AutomationError, .metadataMismatch) }
        }
    }

    // MARK: status / response kind / redirects

    func testNon200StatusesRejected() async {
        for status in [204, 206, 301, 302, 304, 400, 401, 403, 404, 429, 500, 503] {
            store.reset()
            let body = (try? validEnvelope().envelope) ?? Data()
            store.route(envelopeAbs, .respond(status: status, headers: status == 401 ? ["WWW-Authenticate": "Basic realm=\"r\""] : [:], chunks: [body]))
            await assertPreviewFails(.unexpectedStatus(status))
        }
    }

    func testRedirectsFailAndTargetIsNeverRequested() async {
        for status in [301, 302, 303, 307, 308] {
            store.reset()
            store.route(envelopeAbs, .redirect(status: status, to: "https://evil.example.net/repository.json"))
            store.route("https://evil.example.net/repository.json", .respond(status: 200, chunks: [(try? validEnvelope().envelope) ?? Data()]))
            await assertPreviewFails(.redirected)
            XCTAssertFalse(store.requests.contains { $0.url?.host == "evil.example.net" }, "followed \(status)")
        }
    }

    func testPackageRedirectFails() async throws {
        let v = try validEnvelope()
        store.route(envelopeAbs, .respond(status: 200, chunks: [v.envelope]))
        store.route(packageAbs, .redirect(status: 302, to: "https://example.com/other.json"))
        store.route("https://example.com/other.json", .respond(status: 200, chunks: [v.package]))
        let c = makeClient(); let snap = try await c.preview(url: repoURL, now: now)
        do { _ = try await c.fetchPackage(entry: v.entry, from: snap); XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryClientError, .redirected) }
        XCTAssertFalse(store.requests.contains { $0.url?.path == "/other.json" })
    }

    func testNonHTTPResponseRejected() async throws {
        store.route(envelopeAbs, .nonHTTP(try validEnvelope().envelope))
        await assertPreviewFails(.nonHTTPResponse)
    }

    // MARK: size bounds

    func testOversizeWithoutContentLengthStopsEarly() async {
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        let chunks = Array(repeating: chunk, count: 24)  // 1.5 MiB > 768 KiB cap
        store.route(envelopeAbs, .respond(status: 200, chunks: chunks, gap: 0.01))
        await assertPreviewFails(.responseTooLarge)
        _ = await waitUntil { self.store.stops >= 1 }
        XCTAssertLessThan(store.bytesSent, chunk.count * chunks.count, "download not cancelled at cap")
        XCTAssertLessThanOrEqual(store.bytesSent, Limits.envelope + 2 * chunk.count)
    }

    func testActualBytesCapAppliesWhenContentLengthLies() async {
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        store.route(envelopeAbs, .respond(status: 200, headers: ["Content-Length": "100"], chunks: Array(repeating: chunk, count: 24), gap: 0.01))
        await assertPreviewFails(.responseTooLarge)
        XCTAssertLessThan(store.bytesSent, chunk.count * 24)
    }

    func testDeclaredLengthRejectsWithoutWaitingForCompleteBody() async {
        // URL loading may sniff initial bytes before exposing headers. Never wait for a complete body/EOF.
        store.route(envelopeAbs, .respond(status: 200, headers: ["Content-Length": "\(Limits.envelope + 1)", "Content-Type": "application/json"], chunks: [Data(" ".utf8)], finish: false))
        do { _ = try await makeClient(deadline: 1).preview(url: repoURL, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryClientError, .responseTooLarge) }
    }

    func testPackageOversizeStopsEarly() async throws {
        // Index claims the maximum package size; server streams far more.
        let big = Data(repeating: 0x20, count: Limits.package)
        let e = IndexEntry(id: pluginID, name: "Request alert", version: "1.0.0", packagePath: "p.json", sha256: sha(big), size: Limits.package)
        store.route(envelopeAbs, .respond(status: 200, chunks: [try envelope(indexPayload(e))]))
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        store.route(packageAbs, .respond(status: 200, chunks: Array(repeating: chunk, count: 16), gap: 0.01))
        let c = makeClient(); let snap = try await c.preview(url: repoURL, now: now)
        do { _ = try await c.fetchPackage(entry: e, from: snap); XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryClientError, .responseTooLarge) }
        XCTAssertLessThan(store.bytesSent, 16 * chunk.count)
    }

    // MARK: transport failure / deadline / cancellation

    func testConnectionResetIsTransportError() async {
        store.route(envelopeAbs, .fail(.networkConnectionLost))
        await assertPreviewFails(.transport)
    }

    func testResetAfterHeadersAndPartialBodyIsTransportError() async throws {
        let v = try validEnvelope()
        store.route(envelopeAbs, .respond(status: 200, chunks: [v.envelope.prefix(40)], failAfter: .networkConnectionLost))
        await assertPreviewFails(.transport)
        XCTAssertGreaterThan(store.bytesSent, 0, "fixture must fail after delivering body bytes")
    }


    func testStalledResponseHitsAbsoluteDeadline() async throws {
        store.route(envelopeAbs, .respond(status: 200, chunks: [Data("{".utf8)], finish: false))
        let start = Date()
        do { _ = try await makeClient(deadline: 0.4).preview(url: repoURL, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryClientError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let awaited418 = await waitUntil { self.store.stops >= 1 }
        XCTAssertTrue(awaited418, "request not cancelled at deadline")
    }

    func testSlowDripCannotExtendAbsoluteDeadline() async {
        // Each gap is shorter than any idle timeout, but total exceeds the absolute deadline.
        let chunks = Array(repeating: Data(" ".utf8), count: 40)
        store.route(envelopeAbs, .respond(status: 200, chunks: chunks, gap: 0.1))
        let start = Date()
        do { _ = try await makeClient(deadline: 0.5).preview(url: repoURL, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryClientError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertLessThan(store.bytesSent, 40)
    }

    func testCancellationDuringResponseThrowsCancellationAndDeliversNothingLate() async throws {
        let v = try validEnvelope()
        // First chunk now, remainder (a complete valid envelope) arrives late after cancellation.
        let parts = split(v.envelope, into: v.envelope.count / 2 + 1)
        store.route(envelopeAbs, .respond(status: 200, chunks: parts, gap: 0.5))
        let c = makeClient()
        let task = Task { try await c.preview(url: repoURL, now: now) }
        let awaited440 = await waitUntil { self.store.bytesSent > 0 }
        XCTAssertTrue(awaited440, "request never started")
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled fetch returned a result") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let awaited444 = await waitUntil { self.store.stops >= 1 }
        XCTAssertTrue(awaited444)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(store.requests.count, 1)
        serveValid(v)
        let recovered = try await c.preview(url: repoURL, now: now)
        XCTAssertEqual(recovered.index.id, repoID)
    }

    func testAlreadyCancelledTaskSendsNoRequest() async throws {
        serveValid(try validEnvelope())
        let c = makeClient()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await c.preview(url: repoURL, now: now)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testCancelledPackageFetchDoesNotReturnPackage() async throws {
        let v = try validEnvelope()
        store.route(envelopeAbs, .respond(status: 200, chunks: [v.envelope]))
        store.route(packageAbs, .respond(status: 200, chunks: split(v.package, into: v.package.count / 2 + 1), gap: 0.5))
        let c = makeClient(); let snap = try await c.preview(url: repoURL, now: now)
        let task = Task { try await c.fetchPackage(entry: v.entry, from: snap) }
        let awaited469 = await waitUntil { self.store.bytesSent > 0 }
        XCTAssertTrue(awaited469)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.deliveredAfterStop, 0)
    }

    // MARK: credentials / cookies / cache

    func testRequestShapeHasNoCookiesOrCredentials() async throws {
        let url = URL(string: envelopeAbs)!
        let cookie = HTTPCookie(properties: [.name: "interceptor-test-" + UUID().uuidString, .value: "secret", .domain: "example.com", .path: "/"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let v = try validEnvelope()
        store.route(envelopeAbs, .respond(status: 200, headers: ["Set-Cookie": "leak=1; Path=/"], chunks: [v.envelope]))
        _ = try await makeClient().preview(url: repoURL, now: now)
        let req = try XCTUnwrap(store.requests.first)
        XCTAssertEqual(req.httpMethod ?? "GET", "GET")
        XCTAssertEqual(req.url, url)
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(req.httpShouldHandleCookies)
        XCTAssertNil(req.httpBody)
        XCTAssertFalse((HTTPCookieStorage.shared.cookies(for: url) ?? []).contains { $0.name == "leak" })
        XCTAssertNil(URLCache.shared.cachedResponse(for: URLRequest(url: url)))
    }

    func testAuthenticationChallengesAreNeverAnswered() async {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodClientCertificate] {
            store.reset()
            store.route(envelopeAbs, .challenge(method: method))
            do { _ = try await makeClient(deadline: 2).preview(url: repoURL, now: now); XCTFail("succeeded under \(method)") }
            catch { XCTAssertNotNil(error as? RepositoryClientError, "\(error)") }
            XCTAssertEqual(store.credentialUses, 0, method)
        }
    }
}
