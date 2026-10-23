import AutomationCore
import AutomationRuntime
import Foundation
@testable import Interceptor
import MudmouthHTTPHooks
import XCTest

/// Standard `fetch` from response.onLeave through the real activation store, C runtime and fetch dispatcher,
/// with a recording transport in place of the network (the real TLS exchange is covered in the transport tests).
final class HTTPPluginFetchProcessorTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private let fetchURL = "https://api.example.com/v1/exchange"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FetchProcessor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// One route with a synchronous request.onEnter (to observe the next sync phase) and the given response.onLeave body.
    private func package(leave: String) throws -> PluginPackage {
        let file = "hooks/api.example.com/credentials/GET.js"
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(2), "id": .string(UUID().uuidString), "name": .string("Fetch test"), "version": .string("1.0.0"),
            "matches": .array([.object([
                "hosts": .array([.string("api.example.com")]), "methods": .array([.string("GET")]),
                "path": .object(["kind": .string("exact"), "value": .string("/credentials")]),
                "hooks": .object(["request": .object(["onEnter": .string(file)]), "response": .object(["onLeave": .string(file)])]),
            ])]),
            "read": .object(["metadata": .array(["method", "host", "path", "status"].map(JSONValue.string)),
                             "headers": .array([.string("set-cookie")]), "queryKeys": .array([]),
                             "body": .object(["mode": .string("json")])]),
            "write": .object(["requestBody": .bool(true), "responseBody": .bool(false)]),
            "endpointBindings": .array([]), "settings": .object([:]),
            "outbound": .object(["profile": .object([
                "url": .string("https://secondary.example.com/profile"), "method": .string("GET"),
                "headers": .array([.string("authorization")]),
            ])]),
        ])
        let source = "Interceptor.attach({request:{onEnter(r){r.body.n=2;}},response:{onLeave(r){\(leave)}}});"
        return try PluginPackage.validate(JSONValue.object(["manifest": manifest, "sourceFiles": .object([file: .string(source)])]).data())
    }

    private struct Harness {
        let processor: HTTPPluginProcessor
        let store: PluginActivationStore
        let completions: Completions
    }

    private func harness(leave: String, transport: FetchStubTransport) async throws -> Harness {
        let package = try package(leave: leave)
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: [package],
                                                                                activationURL: directory.appendingPathComponent("active.json"))
        var snapshot = try await store.snapshot()
        for revision in revisions {
            snapshot = try await store.activate(revision.package, revisionID: revision.id, expectedGeneration: snapshot.generation)
        }
        let completions = Completions()
        let processor = HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: { true }, outboundTransport: transport,
                                            fetchObserver: { completions.append($0) })
        return Harness(processor: processor, store: store, completions: completions)
    }

    private var request: HTTPPluginRequest {
        HTTPPluginRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/credentials", headers: [:], body: Data(#"{"n":1}"#.utf8))
    }

    private var response: HTTPPluginResponse {
        HTTPPluginResponse(status: 200, headers: ["set-cookie": "fixture_session=session-token; Path=/; HttpOnly"],
                           body: Data(#"{"accessToken":"token"}"#.utf8))
    }

    private func awaitCompletion(_ harness: Harness, _ expected: HTTPPluginFetchDispatcher.Completion, count: Int = 1) async {
        for _ in 0 ..< 500 where harness.completions.values.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(harness.completions.values.last, expected)
    }

    private func fetchScript(_ then: String = "") -> String {
        "return (async()=>{await fetch('\(fetchURL)');\(then)})();"
    }

    func testResponseLeaveReturnsBeforeABlockedFetchFinishesAndTheNextSyncPhaseRuns() async throws {
        let gate = AsyncGate()
        let transport = FetchStubTransport { _ in await gate.wait(); return .response(status: 200, body: Data("{}".utf8)) }
        let harness = try await harness(leave: fetchScript(), transport: transport)
        defer { harness.processor.shutdown() }
        let leave = try await harness.processor.process(.responseLeave, request: request, response: response)
        XCTAssertNil(leave)
        await transport.waitUntilEntered(1)
        XCTAssertTrue(harness.completions.values.isEmpty, "the fetch is still blocked after the phase returned")
        let enter = try await harness.processor.process(.requestEnter, request: request, response: nil)
        XCTAssertEqual(try JSONValue(parsing: XCTUnwrap(enter)), .object(["n": .integer(2)]))
        await gate.open()
        await awaitCompletion(harness, .completed)
    }

    func testCapturedTokenBodyAndHeadersReachFetchJavaScript() async throws {
        let transport = FetchStubTransport { _ in .response(status: 200, body: Data("{}".utf8)) }
        let script = """
        return (async()=>{await fetch('\(fetchURL)',{method:'POST',headers:{authorization:'Bearer '+r.body.accessToken,\
        cookie:r.headers['set-cookie'].split(';')[0]},body:JSON.stringify({token:r.body.accessToken})});})();
        """
        let harness = try await harness(leave: script, transport: transport)
        defer { harness.processor.shutdown() }
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await awaitCompletion(harness, .completed)
        let sent = try XCTUnwrap(transport.fetched.first)
        XCTAssertEqual(sent.host, "api.example.com")
        XCTAssertEqual(sent.path, "/v1/exchange")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers, ["authorization": "Bearer token", "cookie": "fixture_session=session-token",
                                      "content-type": "application/json"])
        XCTAssertEqual(sent.jsonBody, Data(#"{"token":"token"}"#.utf8))
    }

    func testAnExtraResponseLeaveWhileOneFetchRunIsActiveIsRejectedNotQueued() async throws {
        let gate = AsyncGate()
        let transport = FetchStubTransport { _ in await gate.wait(); return .response(status: 200, body: Data()) }
        let harness = try await harness(leave: fetchScript(), transport: transport)
        defer { harness.processor.shutdown() }
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await transport.waitUntilEntered(1)
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        XCTAssertEqual(harness.completions.values, [.rejected])
        await gate.open()
        await awaitCompletion(harness, .completed, count: 2)
        XCTAssertEqual(transport.fetched.count, 1, "the rejected run must never reach the transport")
    }

    func testShutdownCancelsABlockedFetchAndWaitProvesBothSystemsDrained() async throws {
        let transport = FetchStubTransport { _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return .cancelled }
            return .response(status: 200, body: Data())
        }
        let harness = try await harness(leave: fetchScript(), transport: transport)
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await transport.waitUntilEntered(1)
        harness.processor.shutdown()
        let drained = await harness.processor.waitUntilStopped()
        XCTAssertTrue(drained)
        XCTAssertEqual(transport.fetched.count, 1)
        XCTAssertEqual(harness.completions.values.count, 1)
        XCTAssertNotEqual(harness.completions.values.first, .completed)
        let authorized = await harness.processor.isAuthorized()
        XCTAssertFalse(authorized)
    }

    func testRevocationPreventsTheNextFetchAndAnyFollowUp() async throws {
        let transport = FetchStubTransport()
        let script = """
        return (async()=>{
        try{await fetch('\(fetchURL)');}catch(e){}
        try{await fetch('\(fetchURL)');}catch(e){}
        Interceptor.send('profile',{headers:{authorization:'Bearer x'}});
        })();
        """
        let harness = try await harness(leave: script, transport: transport)
        defer { harness.processor.shutdown() }
        let store = harness.store
        transport.setHandler { _ in
            _ = try? await store.revokeAll()
            return .response(status: 200, body: Data("{}".utf8))
        }
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await awaitCompletion(harness, .failed)
        XCTAssertEqual(transport.fetched.count, 1, "the second fetch must be refused by the revoked authorization")
        XCTAssertTrue(transport.performed.isEmpty, "revocation must also drop the legacy follow-up")
    }

    func testInvalidResultAfterFetchDispatchesNoFollowUps() async throws {
        let transport = FetchStubTransport { _ in .response(status: 200, body: Data("{}".utf8)) }
        // response.onLeave is read-only: the attempted mutation fails the run, so the earlier send must never dispatch.
        let script = """
        return (async()=>{await fetch('\(fetchURL)');Interceptor.send('profile',{headers:{authorization:'Bearer x'}});r.body.accessToken='changed';})();
        """
        let harness = try await harness(leave: script, transport: transport)
        defer { harness.processor.shutdown() }
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await awaitCompletion(harness, .failed)
        XCTAssertEqual(transport.fetched.count, 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(transport.performed.isEmpty)
    }

    func testValidFetchFollowedBySendDispatchesExactlyTheLegacyIntentAfterCompletion() async throws {
        let transport = FetchStubTransport { _ in .response(status: 200, body: Data(#"{"t":"fresh"}"#.utf8)) }
        let script = """
        return (async()=>{const j=await (await fetch('\(fetchURL)')).json();\
        Interceptor.send('profile',{headers:{authorization:'Bearer '+j.t}});})();
        """
        let harness = try await harness(leave: script, transport: transport)
        defer { harness.processor.shutdown() }
        _ = try await harness.processor.process(.responseLeave, request: request, response: response)
        await awaitCompletion(harness, .completed)
        for _ in 0 ..< 200 where transport.performed.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let sent = try XCTUnwrap(transport.performed.first)
        XCTAssertEqual(transport.performed.count, 1)
        XCTAssertEqual(sent.host, "secondary.example.com")
        XCTAssertEqual(sent.path, "/profile")
        XCTAssertEqual(sent.headers, ["authorization": "Bearer fresh"])
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class Completions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HTTPPluginFetchDispatcher.Completion] = []
    var values: [HTTPPluginFetchDispatcher.Completion] {
        lock.withLock { storage }
    }

    func append(_ value: HTTPPluginFetchDispatcher.Completion) {
        lock.withLock { storage.append(value) }
    }
}

/// Like the real transport, a fetch is refused when authorization is already gone and only authorized calls are recorded.
private final class FetchStubTransport: HTTPPluginOutboundTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPPluginOutboundRequest) async -> HTTPPluginFetchOutcome
    private let lock = NSLock()
    private var handler: Handler
    private var fetchedStorage: [HTTPPluginOutboundRequest] = []
    private var performedStorage: [HTTPPluginOutboundRequest] = []

    init(handler: @escaping Handler = { _ in .response(status: 200, body: Data()) }) {
        self.handler = handler
    }

    var fetched: [HTTPPluginOutboundRequest] {
        lock.withLock { fetchedStorage }
    }

    var performed: [HTTPPluginOutboundRequest] {
        lock.withLock { performedStorage }
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func waitUntilEntered(_ count: Int) async {
        for _ in 0 ..< 500 where fetched.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(fetched.count, count)
    }

    func perform(_ request: HTTPPluginOutboundRequest,
                 isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginOutboundOutcome
    {
        guard await isAuthorized() else { return .rejected }
        lock.withLock { performedStorage.append(request) }
        return .response(200)
    }

    func fetch(_ request: HTTPPluginOutboundRequest, timeoutMilliseconds: Int, maxResponseBytes: Int,
               isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginFetchOutcome
    {
        guard await isAuthorized() else { return .rejected }
        let current = lock.withLock { () -> Handler in
            fetchedStorage.append(request)
            return handler
        }
        return await current(request)
    }
}
