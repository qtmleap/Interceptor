import AutomationCore
import AutomationRuntime
import CryptoKit
import Foundation
@testable import Interceptor
@testable import Mudmouth
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import XCTest

/// Real loopback TCP + CONNECT + TLS on both sides of the production proxy, using the app's
/// adapter and QuickJS. The origin, trust root, activation file, consent and channels are owned
/// by each test. No capture authorization or external network service is used.
final class HTTPPluginLiveIntegrationTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPPluginLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testRealTLSFourPhasesUseForwardedJSONAndCONNECTAuthorityAcrossFiles() async throws {
        let routes = [
            Route(path: "/search", source: Self.fourPhaseSource),
            Route(host: "other.example.com", path: "/search", source: "Interceptor.attach({request:{onEnter(r){r.body.limit=999;}}});"),
            Route(path: "/unused", source: "throw new Error('an unselected file must never be evaluated'); Interceptor.attach({request:{onEnter(){}}});"),
        ]
        try await withNetwork(routes: routes) { network in
            let response = try await network.roundTrip(path: "/search", hostHeader: "other.example.com")
            XCTAssertEqual(try Self.json(response.body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]))
            XCTAssertEqual(response.status, 200)
            let allPhasesFinished = await network.waitForSuccessfulPhases(4)
            XCTAssertTrue(allPhasesFinished, "all four real callbacks must finish successfully")
            let records = network.processor.records.value
            XCTAssertEqual(Set(records.filter { $0.error == nil }.map(\.phase)), Set(HTTPPluginPhase.allCases))
            XCTAssertTrue(records.allSatisfy { $0.request.host == "api.example.com" })
            XCTAssertEqual(try Self.json(XCTUnwrap(records.first { $0.phase == .requestLeave }?.request.body)), .object(["limit": .integer(5)]))
            let leave = try XCTUnwrap(records.first { $0.phase == .responseLeave })
            XCTAssertEqual(try Self.json(leave.request.body), .object(["limit": .integer(5)]))
            XCTAssertEqual(try Self.json(XCTUnwrap(leave.response?.body)), try Self.json(response.body))
            let seen = try XCTUnwrap(network.originRequests.value.first)
            XCTAssertEqual(try Self.json(seen.body), .object(["limit": .integer(5)]))
            XCTAssertEqual(seen.hostHeader, "other.example.com", "the spoofed decrypted Host is preserved as a header, not used as authority")
            XCTAssertTrue(network.destinations.value.allSatisfy { $0.host == "api.example.com" && $0.port == 443 })

            let count = network.processor.records.value.count
            let unmatched = try await network.roundTrip(path: "/missing")
            XCTAssertEqual(try Self.json(unmatched.body), .object(["maintenance": .bool(false), "originLimit": .integer(20)]))
            XCTAssertEqual(network.processor.records.value.count, count, "nonmatching traffic must not invoke or evaluate a hook file")
            XCTAssertEqual(network.originRequests.value.count, 2)
        }
    }

    func testOversizeJSONPassesThroughRealTLSInBothDirections() async throws {
        let routes = [Route(path: "/large-json", source: Self.fourPhaseSource), Route(path: "/search", source: Self.fourPhaseSource)]
        try await withNetwork(routes: routes) { network in
            var expectedBodies: [Data] = []
            for size in [24 * 1024 + 1, 64 * 1024, 1024 * 1024] {
                let prefix = "{\"limit\":20,\"label\":\"日本語😀\",\"padding\":\""
                let suffix = "\"}"
                let body = Data((prefix + String(repeating: "x", count: size - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
                XCTAssertEqual(body.count, size)
                _ = try Self.json(body)
                for chunked in [false, true] {
                    expectedBodies.append(body)
                    let response = try await network.roundTrip(path: "/large-json", body: body, chunked: chunked)
                    XCTAssertEqual(response.status, 200)
                    XCTAssertEqual(response.body, body, "the actual client must receive every original response byte")
                    XCTAssertTrue(network.processor.records.value.isEmpty, "oversized request and response must bypass all four callbacks")
                }
            }
            XCTAssertEqual(network.originRequests.value.map(\.body), expectedBodies, "the actual origin must receive every original request byte")
            let control = try await network.roundTrip(path: "/search")
            XCTAssertEqual(try Self.json(control.body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]))
            let complete = await network.waitForSuccessfulPhases(4)
            XCTAssertTrue(complete, "the same real adapter must still invoke all callbacks for eligible traffic")
            let records = network.processor.records.value
            XCTAssertEqual(records.count, 4)
            XCTAssertTrue(records.allSatisfy { $0.error == nil && $0.request.path == "/search" })
        }
    }

    func testConcurrentTLSConnectionsKeepBothMutationsAndEveryPhaseWithoutBusy() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            async let first = network.roundTrip(path: "/search")
            async let second = network.roundTrip(path: "/search")
            let responses = try await [first, second]
            for response in responses {
                XCTAssertEqual(try Self.json(response.body), .object([
                    "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
                ]))
            }
            let complete = await network.waitForSuccessfulPhases(8)
            XCTAssertTrue(complete, "ordinary overlap on one live adapter must preserve all callbacks")
            let records = network.processor.records.value
            XCTAssertFalse(records.contains { $0.error == .busy }, "the live adapter must queue ordinary overlap before VM admission")
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            let connections = Dictionary(grouping: records, by: { $0.request.id })
            XCTAssertEqual(connections.count, 2)
            for phases in connections.values {
                XCTAssertEqual(phases.count, 4)
                XCTAssertEqual(Set(phases.map(\.phase)), Set(HTTPPluginPhase.allCases))
            }
            XCTAssertEqual(network.originRequests.value.count, 2)
            for request in network.originRequests.value {
                XCTAssertEqual(try Self.json(request.body), .object(["limit": .integer(5)]))
            }
        }
    }

    func testProductionCONNECTForwards100And103BeforeNextEligibleExchange() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            let responses = try await network.expectContinueThenEligible(path: "/search")
            XCTAssertEqual(responses[0].informationalStatuses, [100, 103])
            XCTAssertEqual(responses[0].status, 200)
            XCTAssertEqual(try Self.json(responses[0].body), .object([
                "maintenance": .bool(false), "originLimit": .integer(20),
            ]), "Expect traffic streams unchanged while its client waits for the actual 100 response")
            XCTAssertTrue(responses[1].informationalStatuses.isEmpty)
            XCTAssertEqual(responses[1].status, 200)
            XCTAssertEqual(try Self.json(responses[1].body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]), "the next exchange on the same CONNECT channel must retain its FIFO association")
            let complete = await network.waitForSuccessfulPhases(4)
            XCTAssertTrue(complete)
            let records = network.processor.records.value
            XCTAssertEqual(records.count, 4, "Expect bypass must not invoke hooks or consume the next exchange")
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            XCTAssertEqual(Set(records.map(\.phase)), Set(HTTPPluginPhase.allCases))
            XCTAssertEqual(network.originRequests.value.count, 2)
            XCTAssertEqual(try network.originRequests.value.map { try Self.json($0.body) }, [
                .object(["limit": .integer(20)]), .object(["limit": .integer(5)]),
            ])
            XCTAssertEqual(network.originConnections.value.count, 1, "both HTTP exchanges share one real upstream TLS connection")
        }
    }

    func testSDKEmittedFilesystemPackageRunsThroughRealTLSAdapter() async throws {
        let bytes = try XCTUnwrap(SDKFilesystemHookFixture.package)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), SDKFilesystemHookFixture.sha256)
        let package = try PluginPackage.validate(bytes)
        XCTAssertEqual(package.manifest.schemaVersion, 2)
        XCTAssertEqual(package.sourceFiles.count, 2)
        try await withNetwork(package: package) { network in
            let response = try await network.roundTrip(path: "/search")
            XCTAssertEqual(try Self.json(response.body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]))
            let complete = await network.waitForSuccessfulPhases(4)
            XCTAssertTrue(complete)
            let records = network.processor.records.value
            XCTAssertEqual(records.count, 4)
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            XCTAssertEqual(Set(records.map(\.phase)), Set(HTTPPluginPhase.allCases))
            XCTAssertEqual(try Self.json(XCTUnwrap(network.originRequests.value.first?.body)), .object(["limit": .integer(5)]))
        }
    }

    func testScriptErrorAndInfiniteLoopFallBackThenRealAdapterRecovers() async throws {
        let routes = [
            Route(path: "/error", source: "Interceptor.attach({request:{onEnter(){throw new Error('expected script failure');}}});"),
            Route(path: "/timeout", source: "Interceptor.attach({request:{onEnter(){while(true){}}}});"),
            Route(path: "/search", source: Self.fourPhaseSource),
        ]
        try await withNetwork(routes: routes) { network in
            for path in ["/error", "/timeout"] {
                let response = try await network.roundTrip(path: path)
                XCTAssertEqual(try Self.json(response.body), .object(["maintenance": .bool(false), "originLimit": .integer(20)]), path)
            }
            let recovered = try await network.roundTrip(path: "/search")
            XCTAssertEqual(try Self.json(recovered.body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]))
            let errors = network.processor.records.value.compactMap(\.error)
            XCTAssertTrue(errors.contains(.scriptError))
            XCTAssertTrue(errors.contains(.timeout), "the infinite VM must hit the actual native deadline")
            XCTAssertEqual(network.originRequests.value.count, 3, "fallback and recovery both reach the real TLS origin")
        }
    }

    func testRevokedGrantOrConsentAfterEvaluationClosesBeforeForwarding() async throws {
        for revokeActivation in [true, false] {
            try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)], afterSuccess: { store, consent, phase in
                guard phase == .requestEnter else { return }
                if revokeActivation {
                    _ = try await store.revokeAll()
                } else {
                    consent.value = false
                }
            }) { network in
                do {
                    _ = try await network.roundTrip(path: "/search")
                    XCTFail("revocation must close instead of returning a response")
                } catch {
                    XCTAssertNotEqual(error as? WireFailure, .timeout, "revocation must close promptly, not merely exhaust the test deadline")
                    XCTAssertEqual(network.originRequests.value.count, 0, "no request body may reach the origin after revocation")
                    XCTAssertEqual(network.processor.records.value.filter { $0.phase == .requestEnter && $0.error == nil }.count, 1,
                                   "revocation is injected only after the real VM successfully evaluated the enter hook")
                    let authorized = await network.processor.isAuthorized()
                    XCTAssertFalse(authorized)
                }
            }
        }
    }

    func testBytesFollowingCONNECTInTheSameWriteCloseWithoutHTTPForwarding() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            let client = try await network.rawClient()
            let reader = ConnectReply(loop: client.eventLoop)
            try await client.pipeline.addHandler(reader).get()
            var bytes = client.allocator.buffer(capacity: 128)
            bytes.writeString("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n")
            // A partial ClientHello arrives before CONNECT is established. It must never be
            // interpreted as HTTPServerRequestPart or forwarded into the upstream TLS channel.
            bytes.writeBytes([0x16, 0x03, 0x01, 0x00, 0x01, 0x00])
            try? await client.writeAndFlush(bytes).get()
            do {
                try await self.waitForCONNECTReply(reader, client: client)
                XCTFail("early CONNECT bytes must close the connection")
            } catch {
                if error as? WireFailure == .invalidCONNECT {
                    XCTAssertTrue(reader.statusCode.map { (400 ..< 600).contains($0) } == true,
                                  "an HTTP rejection must be explicit, rather than a malformed success reply")
                } else {
                    XCTAssertEqual(error as? WireFailure, .closed, "early bytes must be rejected promptly")
                }
                let closed = self.expectation(description: "rejected CONNECT peer closed promptly")
                client.closeFuture.whenComplete { _ in closed.fulfill() }
                let completed = await XCTWaiter.fulfillment(of: [closed], timeout: 2)
                XCTAssertEqual(completed, .completed, "an HTTP rejection must also close the peer")
                XCTAssertFalse(reader.didReceiveOK)
                XCTAssertEqual(network.originRequests.value.count, 0)
                XCTAssertTrue(network.processor.records.value.isEmpty)
            }
        }
    }

    func testRejectedCONNECTReplyCancelsClientDeadlineWithoutClosingOpenPeer() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            let client = try await network.delayedRejectionClient()
            let reader = ConnectReply(loop: client.eventLoop)
            try await client.pipeline.addHandler(reader).get()
            var request = client.allocator.buffer(capacity: 128)
            request.writeString("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n")
            try await client.writeAndFlush(request).get()
            do {
                try await self.waitForCONNECTReply(reader, client: client, timeout: .seconds(1))
                XCTFail("the test peer must return an explicit rejection")
            } catch {
                XCTAssertEqual(error as? WireFailure, .invalidCONNECT)
                XCTAssertEqual(reader.statusCode, 403)
            }
            let observing = Locked(true)
            let unexpectedClose = self.expectation(description: "reply deadline must not close an open peer after403")
            unexpectedClose.isInverted = true
            client.closeFuture.whenComplete { _ in
                if observing.value {
                    unexpectedClose.fulfill()
                }
            }
            let observed = await XCTWaiter.fulfillment(of: [unexpectedClose], timeout: 1.25)
            observing.value = false
            XCTAssertEqual(observed, .completed)
            XCTAssertTrue(client.isActive, "a test timer must not masquerade as the peer's TCP close")
        }
    }

    func testProxyCanStopAndRestartWithoutLeavingItsOldListenerOpen() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            for iteration in 0 ..< 2 {
                let response = try await network.roundTrip(path: "/search")
                XCTAssertEqual(try Self.json(response.body).objectValue?["requestLimit"], .integer(5))
                let complete = await network.waitForSuccessfulPhases(4)
                XCTAssertTrue(complete)
                if iteration == 0 {
                    try await network.restartProxy()
                    network.processor.records.value = []
                }
            }
            XCTAssertEqual(network.originRequests.value.count, 2)
        }
    }

    func testProxyStopIsBoundedWhenCONNECTClientWithholdsTLSHandshakeAndReads() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            let client = try await network.connectWithoutTLS()
            let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !network.originConnections.value.isEmpty
            }, object: nil)
            let originAccepted = await XCTWaiter.fulfillment(of: [accepted], timeout: 2)
            XCTAssertEqual(originAccepted, .completed)
            let originPeers = network.originConnections.value
            let stopped = self.expectation(description: "proxy stop finished within TLS shutdown allowance")
            let joined = self.expectation(description: "owned stop task joined")
            let stopping = Task {
                await network.stopProxy()
                stopped.fulfill()
                joined.fulfill()
            }
            defer { stopping.cancel(); client.close(promise: nil) }
            let completed = await XCTWaiter.fulfillment(of: [stopped], timeout: 8)
            XCTAssertEqual(completed, .completed, "NIOSSL's configured five-second shutdown must remain bounded for a silent peer")
            XCTAssertFalse(network.listenerIsActive)
            if completed != .completed {
                client.close(promise: nil)
            }
            // Resume reads only after measuring stop, to observe the remote TCP close.
            try? await client.setOption(ChannelOptions.autoRead, value: true).get()
            let released = self.expectation(description: "client and paired origin connections closed")
            released.expectedFulfillmentCount = originPeers.count + 1
            for channel in originPeers + [client] {
                channel.closeFuture.whenComplete { _ in released.fulfill() }
            }
            let channelsClosed = await XCTWaiter.fulfillment(of: [released], timeout: 2)
            XCTAssertEqual(channelsClosed, .completed)
            let stopJoined = await XCTWaiter.fulfillment(of: [joined], timeout: 2)
            XCTAssertEqual(stopJoined, .completed)
            if stopJoined == .completed {
                await stopping.value
            }
            XCTAssertTrue(network.processor.records.value.isEmpty)
            XCTAssertTrue(network.originRequests.value.isEmpty)
        }
    }

    func testDuplicateProxyStartRejectsWithoutReplacingActiveListenerOrProcessor() async throws {
        try await withNetwork(routes: [Route(path: "/search", source: Self.fourPhaseSource)]) { network in
            do {
                let unexpected = try await network.duplicateStartWithoutProcessor()
                try? await unexpected.close().get()
                XCTFail("an active proxy deliberately rejects a second start")
            } catch LocalProxyChannels.Failure.alreadyRunning {
                XCTAssertTrue(network.listenerIsActive)
            }
            let response = try await network.roundTrip(path: "/search")
            XCTAssertEqual(try Self.json(response.body), .object([
                "maintenance": .bool(true), "originLimit": .integer(5), "requestLimit": .integer(5),
            ]))
            let complete = await network.waitForSuccessfulPhases(4)
            XCTAssertTrue(complete, "the originally active processor must still run all four callbacks")
            XCTAssertTrue(network.processor.records.value.allSatisfy { $0.error == nil })
        }
    }
}

private extension HTTPPluginLiveIntegrationTests {
    func waitForCONNECTReply(_ reader: ConnectReply, client: Channel, timeout: TimeAmount = .seconds(5)) async throws {
        let deadline = client.eventLoop.scheduleTask(in: timeout) {
            reader.fail(WireFailure.timeout)
            client.close(promise: nil)
        }
        // Cancel on the event loop even if the awaiting task resumes late.
        reader.result.whenComplete { _ in deadline.cancel() }
        // This scope ends at the HTTP reply, before any independent peer-close observation.
        defer { deadline.cancel() }
        try await reader.result.get()
    }

    struct Route {
        var host = "api.example.com"
        let path: String
        let source: String
        var file: String {
            "hooks/\(host)\(path)/POST.js"
        }
    }

    func package(_ routes: [Route]) throws -> PluginPackage {
        let matches: [JSONValue] = routes.map { route in
            var hooks: [String: JSONValue] = [:]
            for leg in ["request", "response"] {
                var phases: [String: JSONValue] = [:]
                for phase in ["onEnter", "onLeave"] where route.source.contains(phase + "(") {
                    // The fixture below has callbacks for both legs. Failure-only fixtures have
                    // request callbacks; explicit per-leg presence keeps their manifest exact.
                    if route.source.contains(leg + ":{") {
                        phases[phase] = .string(route.file)
                    }
                }
                if !phases.isEmpty {
                    hooks[leg] = .object(phases)
                }
            }
            return .object([
                "hosts": .array([.string(route.host)]), "methods": .array([.string("POST")]),
                "path": .object(["kind": .string("exact"), "value": .string(route.path)]), "hooks": .object(hooks),
            ])
        }
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(2), "id": .string(UUID().uuidString), "name": .string("Live TLS fixture"), "version": .string("1.0.0"),
            "matches": .array(matches),
            "read": .object(["metadata": .array(["method", "host", "path", "status"].map(JSONValue.string)),
                             "headers": .array([]), "queryKeys": .array([]), "body": .object(["mode": .string("json")])]),
            "write": .object(["requestBody": .bool(true), "responseBody": .bool(true)]),
            "endpointBindings": .array([]), "settings": .object([:]),
        ])
        let files = Dictionary(uniqueKeysWithValues: routes.map { ($0.file, JSONValue.string($0.source)) })
        return try PluginPackage.validate(JSONValue.object(["manifest": manifest, "sourceFiles": .object(files)]).data())
    }

    func withNetwork(
        routes: [Route],
        afterSuccess: (@Sendable (PluginActivationStore, Locked<Bool>, HTTPPluginPhase) async throws -> Void)? = nil,
        body: (Network) async throws -> Void,
    ) async throws {
        let package = try package(routes)
        try await withNetwork(package: package, afterSuccess: afterSuccess, body: body)
    }

    func withNetwork(
        package: PluginPackage,
        afterSuccess: (@Sendable (PluginActivationStore, Locked<Bool>, HTTPPluginPhase) async throws -> Void)? = nil,
        body: (Network) async throws -> Void,
    ) async throws {
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: [package], activationURL: directory.appendingPathComponent(UUID().uuidString + ".json"))
        let empty = try await store.snapshot()
        let snapshot = try await store.activate(package, revisionID: XCTUnwrap(revisions.first).id, expectedGeneration: empty.generation)
        let consent = Locked(true)
        let adapter = HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: { consent.value })
        let processor = WitnessingProcessor(delegate: adapter, afterSuccess: { phase in try await afterSuccess?(store, consent, phase) })
        let network = Network(processor: processor, consent: consent)
        do {
            try await network.start()
            try await body(network)
            await network.stop()
        } catch {
            await network.stop()
            throw error
        }
    }

    static func json(_ bytes: Data) throws -> JSONValue {
        try JSONValue(parsing: bytes)
    }

    static let fourPhaseSource = """
    Interceptor.attach({request:{
      onEnter(r){if(r.host!=='api.example.com')throw new Error('wrong authority');r.body.limit=5;},
      onLeave(r){
        if(r.body.limit!==5)throw new Error('request leave needs forwarded body');
        const rejected=(()=>{try{r.body.limit=99;return false;}catch{return true;}})();
        if(!rejected||r.body.limit!==5)throw new Error('request leave must be read-only');
      }
    },response:{
      onEnter(r){
        if(!r.request.body||r.request.body.limit!==5)throw new Error('forwarded request missing');
        const rejected=(()=>{try{r.request.body.limit=99;return false;}catch{return true;}})();
        if(!rejected||r.request.body.limit!==5)throw new Error('associated request must be read-only');
        r.body.maintenance=true;r.body.requestLimit=r.request.body.limit;
      },
      onLeave(r){
        if(r.body.maintenance!==true||r.body.requestLimit!==5||r.request.body.limit!==5)throw new Error('response leave needs both forwarded bodies');
        const rejected=(()=>{try{r.body.maintenance=false;return false;}catch{return true;}})();
        const requestRejected=(()=>{try{r.request.body.limit=99;return false;}catch{return true;}})();
        if(!rejected||!requestRejected)throw new Error('response leave must be read-only');
      }
    }});
    """
}

private enum WireFailure: Error, Equatable { case closed, timeout, invalidCONNECT, invalidResponse }

/// Locked state is only for communication between the test task and NIO loops.
private final class Locked<Value>: @unchecked Sendable {
    init(_ value: Value) {
        storage = value
    }

    private let lock = NSLock()
    private var storage: Value
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func update(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private struct PhaseWitness: Sendable {
    let phase: HTTPPluginPhase
    let request: HTTPPluginRequest
    let response: HTTPPluginResponse?
    let error: JavaScriptExecutionError?
}

/// Wraps the real adapter, never replaces it with a fake processor. Successful leave witnesses
/// prove the selected JavaScript callback completed, including its forwarded/read-only assertions.
private final class WitnessingProcessor: HTTPPluginProcessing, @unchecked Sendable {
    init(delegate: HTTPPluginProcessor, afterSuccess: @escaping @Sendable (HTTPPluginPhase) async throws -> Void) {
        self.delegate = delegate
        self.afterSuccess = afterSuccess
    }

    let records = Locked<[PhaseWitness]>([])
    private let delegate: HTTPPluginProcessor
    private let afterSuccess: @Sendable (HTTPPluginPhase) async throws -> Void
    func matches(_ request: HTTPPluginRequest) -> Bool {
        delegate.matches(request)
    }

    func isAuthorized() async -> Bool {
        await delegate.isAuthorized()
    }

    func process(_ phase: HTTPPluginPhase, request: HTTPPluginRequest, response: HTTPPluginResponse?) async throws -> Data? {
        do {
            let result = try await delegate.process(phase, request: request, response: response)
            try await afterSuccess(phase)
            records.update { $0.append(PhaseWitness(phase: phase, request: request, response: response, error: nil)) }
            return result
        } catch {
            records.update { $0.append(PhaseWitness(phase: phase, request: request, response: response,
                                                    error: error as? JavaScriptExecutionError ?? .internalFailure)) }
            throw error
        }
    }
}

private struct WireResponse: Sendable {
    let status: Int
    let body: Data
    let informationalStatuses: [Int]
}

private struct OriginRequest: Sendable { let hostHeader: String?; let body: Data }
private struct Destination: Sendable { let host: String; let port: Int }

private final class Network: @unchecked Sendable {
    init(processor: WitnessingProcessor, consent: Locked<Bool>) {
        self.processor = processor
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        proxy = LocalHTTPProxy(group: group, isConsentGranted: { consent.value })
    }

    let processor: WitnessingProcessor
    let originRequests = Locked<[OriginRequest]>([])
    let originConnections = Locked<[Channel]>([])
    let destinations = Locked<[Destination]>([])
    private let group: MultiThreadedEventLoopGroup
    private let ownedChannels = Locked<[Channel]>([])
    private let proxy: LocalHTTPProxy
    private var listener: Channel?
    private var clientContext: NIOSSLContext?
    private var serverContext: NIOSSLContext?
    private var upstream: HTTPProxyUpstream?

    func start() async throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(TestTLS.certificate.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(TestTLS.privateKey.utf8), format: .pem)
        let serverConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key),
        )
        let serverContext = try NIOSSLContext(configuration: serverConfiguration)
        self.serverContext = serverContext
        var clientConfiguration = TLSConfiguration.makeClientConfiguration()
        clientConfiguration.trustRoots = .certificates(certificates)
        // Full hostname verification proves upstream TLS keeps the CONNECT authority despite
        // the injected loopback socket address and a hostile decrypted Host header.
        clientConfiguration.certificateVerification = .fullVerification
        clientContext = try NIOSSLContext(configuration: clientConfiguration)
        let owned = ownedChannels, requests = originRequests, originConnections = originConnections
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                owned.update { $0.append(channel) }
                originConnections.update { $0.append(channel) }
                return channel.pipeline.addHandler(NIOSSLServerHandler(context: serverContext))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(OriginHandler(requests: requests)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        ownedChannels.update { $0.append(origin) }
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let destinations = destinations
        let upstream = HTTPProxyUpstream(address: { host, port in
            destinations.update { $0.append(Destination(host: host, port: port)) }
            return try SocketAddress(ipAddress: "127.0.0.1", port: originPort)
        }, tlsConfiguration: clientConfiguration)
        self.upstream = upstream
        listener = try await proxy.start(port: 0, allowedHosts: ["api.example.com"], serverContext: serverContext,
                                         processor: processor, upstream: upstream)
    }

    func restartProxy() async throws {
        let old = try XCTUnwrap(listener)
        await proxy.stop()
        XCTAssertFalse(old.isActive, "the previous ephemeral listener must close before restart")
        listener = try await proxy.start(port: 0, allowedHosts: ["api.example.com"], serverContext: XCTUnwrap(serverContext),
                                         processor: processor, upstream: XCTUnwrap(upstream))
    }

    func rawClient() async throws -> Channel {
        let port = try XCTUnwrap(listener?.localAddress?.port)
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5)).connect(host: "127.0.0.1", port: port).get()
        ownedChannels.update { $0.append(channel) }
        return channel
    }

    func delayedRejectionClient() async throws -> Channel {
        let owned = ownedChannels
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                owned.update { $0.append(channel) }
                return channel.pipeline.addHandler(DelayedCONNECTRejection())
            }
            .bind(host: "127.0.0.1", port: 0).get()
        ownedChannels.update { $0.append(server) }
        let port = try XCTUnwrap(server.localAddress?.port)
        let client = try await ClientBootstrap(group: group).connectTimeout(.seconds(5)).connect(host: "127.0.0.1", port: port).get()
        ownedChannels.update { $0.append(client) }
        return client
    }

    var listenerIsActive: Bool {
        listener?.isActive == true
    }

    func stopProxy() async {
        await proxy.stop()
    }

    func duplicateStartWithoutProcessor() async throws -> Channel {
        try await proxy.start(
            port: 0,
            allowedHosts: ["api.example.com"],
            serverContext: XCTUnwrap(serverContext),
            processor: nil,
            upstream: XCTUnwrap(upstream),
        )
    }

    func connectWithoutTLS() async throws -> Channel {
        let client = try await rawClient()
        let reader = ConnectReply(loop: client.eventLoop)
        try await client.pipeline.addHandler(reader).get()
        let timeout = client.eventLoop.scheduleTask(in: .seconds(5)) {
            reader.fail(WireFailure.timeout)
            client.close(promise: nil)
        }
        defer { timeout.cancel() }
        var preface = client.allocator.buffer(capacity: 128)
        preface.writeString("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n")
        try await client.writeAndFlush(preface).get()
        try await reader.result.get()
        try await client.setOption(ChannelOptions.autoRead, value: false).get()
        return client
    }

    func roundTrip(path: String, hostHeader: String = "api.example.com", body: Data = Data(#"{"limit":20}"#.utf8),
                   chunked: Bool = false) async throws -> WireResponse
    {
        let client = try await tlsClient()
        return try await request(path: path, hostHeader: hostHeader, client: client, body: body, chunked: chunked)
    }

    func expectContinueThenEligible(path: String) async throws -> [WireResponse] {
        let client = try await tlsClient()
        let first = try await request(path: path, client: client, expectsContinue: true)
        let second = try await request(path: path, client: client)
        return [first, second]
    }

    private func tlsClient() async throws -> Channel {
        let client = try await rawClient()
        // Retain this channel until test cleanup so its observational response leave can finish.
        let connect = ConnectReply(loop: client.eventLoop)
        try await client.pipeline.addHandler(connect).get()
        let connected = connect.result
        let connectTimeout = client.eventLoop.scheduleTask(in: .seconds(5)) {
            connect.fail(WireFailure.timeout)
            client.close(promise: nil)
        }
        defer { connectTimeout.cancel() }
        var preface = client.allocator.buffer(capacity: 128)
        preface.writeString("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n")
        try await client.writeAndFlush(preface).get()
        _ = try await connected.get()
        connectTimeout.cancel()
        try await client.pipeline.removeHandler(connect).get()
        let tls = try NIOSSLClientHandler(context: XCTUnwrap(clientContext), serverHostname: "api.example.com")
        try await client.pipeline.addHandler(tls).get()
        try await client.pipeline.addHandler(HTTPRequestEncoder()).get()
        try await client.pipeline.addHandler(ByteToMessageHandler(
            HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward),
        )).get()
        return client
    }

    private func request(
        path: String, hostHeader: String = "api.example.com", client: Channel, expectsContinue: Bool = false,
        body: Data = Data(#"{"limit":20}"#.utf8), chunked: Bool = false,
    ) async throws -> WireResponse {
        let response = ResponseCollector(loop: client.eventLoop, expectsContinue: expectsContinue)
        try await client.pipeline.addHandler(response).get()
        let completed = response.result
        let responseTimeout = client.eventLoop.scheduleTask(in: .seconds(5)) {
            response.fail(WireFailure.timeout)
            client.close(promise: nil)
        }
        defer { responseTimeout.cancel() }
        var headers = HTTPHeaders([("Host", hostHeader), ("Content-Type", "application/json")])
        headers.add(name: chunked ? "Transfer-Encoding" : "Content-Length", value: chunked ? "chunked" : String(body.count))
        if expectsContinue {
            headers.add(name: "Expect", value: "100-continue")
        }
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: headers)
        if let continued = response.continued {
            try await client.writeAndFlush(HTTPClientRequestPart.head(head)).get()
            // A real client does not send its body until 100 crosses both TLS legs.
            try await continued.get()
        } else {
            client.write(HTTPClientRequestPart.head(head), promise: nil)
        }
        let parts = chunked ? [body.prefix(body.count / 2), body.dropFirst(body.count / 2)] : [body]
        for part in parts {
            var buffer = client.allocator.buffer(capacity: part.count)
            buffer.writeBytes(part)
            client.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        try await client.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        let result = try await completed.get()
        try await client.pipeline.removeHandler(response).get()
        return result
    }

    func waitForSuccessfulPhases(_ count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if processor.records.value.filter({ $0.error == nil }).count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func stop() async {
        await proxy.stop()
        let closing = ownedChannels.value.map { $0.close() }
        for future in closing {
            try? await future.get()
        }
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { error in
                if let error {
                    XCTFail("owned NIO group failed to shut down: \(error)")
                }
                continuation.resume()
            }
        }
    }
}

/// Keeps its socket open after a delayed rejection, isolating the test client's deadline ownership.
private final class DelayedCONNECTRejection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var bytes = Data()
    private var rejection: Scheduled<Void>?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard rejection == nil, bytes.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        let channel = context.channel
        rejection = context.eventLoop.scheduleTask(in: .milliseconds(100)) {
            var response = channel.allocator.buffer(capacity: 64)
            response.writeString("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            channel.writeAndFlush(response, promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        rejection?.cancel()
        context.fireChannelInactive()
    }
}

/// State below is confined to the channel event loop. No handler blocks a loop on a Swift task.
private final class ConnectReply: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    init(loop: EventLoop) {
        promise = loop.makePromise(of: Void.self)
    }

    private let promise: EventLoopPromise<Void>
    var result: EventLoopFuture<Void> {
        promise.futureResult
    }

    private var bytes = Data()
    private var finished = false
    private(set) var didReceiveOK = false
    private(set) var statusCode: Int?
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard !finished, bytes.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        let statusLine = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")[0]
        let fields = statusLine.split(separator: " ")
        if fields.count >= 2, fields[0] == "HTTP/1.1" {
            statusCode = Int(fields[1])
        }
        didReceiveOK = statusCode == 200
        finished = true
        if didReceiveOK {
            promise.succeed(())
        } else {
            promise.fail(WireFailure.invalidCONNECT)
        }
    }

    func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        promise.fail(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(WireFailure.closed); context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error); context.close(promise: nil)
    }
}

private final class ResponseCollector: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    init(loop: EventLoop, expectsContinue: Bool) {
        promise = loop.makePromise(of: WireResponse.self)
        continuePromise = expectsContinue ? loop.makePromise(of: Void.self) : nil
        continued = continuePromise?.futureResult
    }

    let continued: EventLoopFuture<Void>?
    private var continuePromise: EventLoopPromise<Void>?
    private var informationalStatuses: [Int] = []

    private let promise: EventLoopPromise<WireResponse>
    var result: EventLoopFuture<WireResponse> {
        promise.futureResult
    }

    private var status: Int?
    private var body = Data()
    private var finished = false
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
            case let .head(head):
                let code = Int(head.status.code)
                if (100 ..< 200).contains(code) {
                    informationalStatuses.append(code)
                    if code == 100 {
                        finishContinue(.success(()))
                    }
                } else {
                    finishContinue(.failure(WireFailure.invalidResponse))
                    status = code
                }
            case let .body(buffer): body.append(contentsOf: buffer.readableBytesView)
            case .end:
                finished = true
                if let status {
                    promise.succeed(WireResponse(status: status, body: body, informationalStatuses: informationalStatuses))
                } else {
                    promise.fail(WireFailure.invalidResponse)
                }
        }
    }

    private func finishContinue(_ result: Result<Void, Error>) {
        continuePromise?.completeWith(result)
        continuePromise = nil
    }

    func fail(_ error: Error) {
        finishContinue(.failure(error))
        guard !finished else { return }
        finished = true
        promise.fail(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(WireFailure.closed); context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error); context.close(promise: nil)
    }
}

private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    init(requests: Locked<[OriginRequest]>) {
        self.requests = requests
    }

    private let requests: Locked<[OriginRequest]>
    private var head: HTTPRequestHead?
    private var body = Data()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head):
                self.head = head
                body = Data()
                if head.headers.first(name: "expect") == "100-continue" {
                    context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)
                }
            case let .body(buffer): body.append(contentsOf: buffer.readableBytesView)
            case .end:
                requests.update { $0.append(OriginRequest(hostHeader: head?.headers.first(name: "host"), body: body)) }
                do {
                    if head?.headers.first(name: "expect") == "100-continue" {
                        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: 103)))), promise: nil)
                    }
                    let response: Data
                    if head?.uri == "/large-json" {
                        response = body
                    } else {
                        let parsedRequest = try JSONValue(parsing: body)
                        response = try JSONValue.object(["maintenance": .bool(false), "originLimit": parsedRequest.objectValue?["limit"] ?? .null]).data()
                    }
                    let chunked = head?.uri == "/large-json" && head?.headers.first(name: "transfer-encoding") == "chunked"
                    var headers = HTTPHeaders([("Content-Type", "application/json")])
                    headers.add(name: chunked ? "Transfer-Encoding" : "Content-Length", value: chunked ? "chunked" : String(response.count))
                    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
                    context.write(wrapOutboundOut(.head(head)), promise: nil)
                    let parts = chunked ? [response.prefix(response.count / 2), response.dropFirst(response.count / 2)] : [response]
                    for part in parts {
                        var buffer = context.channel.allocator.buffer(capacity: part.count)
                        buffer.writeBytes(part)
                        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                } catch { context.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Public test-only key, self-signed for api.example.com, never used outside loopback fixtures.
private enum TestTLS {
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
