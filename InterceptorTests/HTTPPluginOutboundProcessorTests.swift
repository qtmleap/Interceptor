import AutomationCore
import AutomationRuntime
import Foundation
@testable import Interceptor
import MudmouthHTTPHooks
import XCTest

final class HTTPPluginOutboundProcessorTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OutboundProcessor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func harness(_ packages: [PluginPackage], transport: OutboundRecordingTransport,
                         consent: @escaping @Sendable () -> Bool = { true },
                         observer: HTTPPluginOutboundDispatcher.Observer? = nil) async throws -> (HTTPPluginProcessor, PluginActivationStore) {
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: packages, activationURL: directory.appendingPathComponent("active.json"))
        var snapshot = try await store.snapshot()
        for revision in revisions { snapshot = try await store.activate(revision.package, revisionID: revision.id, expectedGeneration: snapshot.generation) }
        return (HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: consent,
                                    outboundTransport: transport, outboundObserver: observer), store)
    }
    private var request: HTTPPluginRequest {
        HTTPPluginRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/credentials", headers: [:], body: Data())
    }
    private var response: HTTPPluginResponse {
        HTTPPluginResponse(status: 200, headers: ["set-cookie": "fixture_session=session-token; Path=/; HttpOnly"], body: Data(#"{"accessToken":"token"}"#.utf8))
    }

    func testEmptyOriginalGETResponseSuppliesBearerAndOnlyCookiePairToSecondaryGET() async throws {
        let sent = expectation(description: "secondary request")
        let transport = OutboundRecordingTransport { _ in sent.fulfill(); return .response(200) }
        let package = try OutboundAppFixtures.package(callback: """
        Interceptor.send('profile',{headers:{authorization:'Bearer '+r.body.accessToken,cookie:r.headers['set-cookie'].split(';')[0]}});
        """, readHeaders: ["set-cookie"])
        let (processor, _) = try await harness([package], transport: transport)
        defer { processor.shutdown() }
        let mutation = try await processor.process(.responseLeave, request: request, response: response)
        XCTAssertNil(mutation)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.host, "secondary.example.com")
        XCTAssertEqual(transport.requests.first?.path, "/profile")
        XCTAssertEqual(transport.requests.first?.headers, ["authorization": "Bearer token", "cookie": "fixture_session=session-token"])
    }

    func testLaterRevisionErrorDiscardsEarlierIntentsAndMutation() async throws {
        let first = try OutboundAppFixtures.package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")),
            callback: "r.body.changed=true;Interceptor.send('profile',{headers:{authorization:'Bearer token'}});", phase: "onEnter")
        let last = try OutboundAppFixtures.package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000B")),
            callback: "throw new Error('later revision failed');", phase: "onEnter")
        let transport = OutboundRecordingTransport()
        let (processor, _) = try await harness([first, last], transport: transport)
        defer { processor.shutdown() }
        do {
            _ = try await processor.process(.responseEnter, request: request, response: response)
            XCTFail("a later failure must abort the complete phase")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testComposedPhaseLimitDiscardsAllIntents() async throws {
        let packages = try (1 ... 3).map { n in
            try OutboundAppFixtures.package(id: XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))),
                callback: "Interceptor.send('profile',{headers:{authorization:'Bearer token'}});")
        }
        let transport = OutboundRecordingTransport()
        let (processor, _) = try await harness(packages, transport: transport)
        defer { processor.shutdown() }
        do {
            _ = try await processor.process(.responseLeave, request: request, response: response)
            XCTFail("three sends across revisions must fail atomically")
        } catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .invalidResult) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCaughtInvalidSendIsStickyAndNeverDispatches() async throws {
        let package = try OutboundAppFixtures.package(callback: """
        Interceptor.send('profile',{headers:{authorization:'Bearer token'}});
        try{Interceptor.send('profile',{headers:{'x-undeclared':'private'}});}catch{}
        """)
        let transport = OutboundRecordingTransport()
        let (processor, _) = try await harness([package], transport: transport)
        defer { processor.shutdown() }
        do {
            _ = try await processor.process(.responseLeave, request: request, response: response)
            XCTFail("catching an invalid send must not commit earlier intents")
        } catch {
            XCTAssertTrue(error as? JavaScriptExecutionError == .scriptError || error as? JavaScriptExecutionError == .invalidResult,
                          "a caught invalid send must remain a VM failure")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNetworkWaitDoesNotRetainPhaseAdmission() async throws {
        let started = expectation(description: "both phases dispatch before either response")
        started.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "both owned waits cancelled")
        cancelled.expectedFulfillmentCount = 2
        let transport = OutboundRecordingTransport { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return .cancelled }
            return .failed
        }
        let package = try OutboundAppFixtures.package(callback: "Interceptor.send('profile',{headers:{authorization:'Bearer token'}});")
        let (processor, _) = try await harness([package], transport: transport, observer: { _, outcome in
            if outcome == .cancelled { cancelled.fulfill() }
        })
        defer { processor.shutdown() }
        _ = try await processor.process(.responseLeave, request: request, response: response)
        _ = try await processor.process(.responseLeave, request: request, response: response)
        await fulfillment(of: [started], timeout: 2)
        processor.shutdown()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testRevokedGenerationPreventsAnySend() async throws {
        let package = try OutboundAppFixtures.package(callback: "Interceptor.send('profile',{headers:{authorization:'Bearer token'}});")
        let transport = OutboundRecordingTransport()
        let (processor, store) = try await harness([package], transport: transport)
        defer { processor.shutdown() }
        _ = try await store.revokeAll()
        do {
            _ = try await processor.process(.responseLeave, request: request, response: response)
            XCTFail("a stale snapshot cannot send")
        } catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .revoked) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRevocationAfterAdmissionIsVisibleToTransportBeforeCredentialsAreWritten() async throws {
        let admitted = expectation(description: "transport admitted before simulated DNS/TLS")
        let rejected = expectation(description: "transport rechecks generation before write")
        let gate = OutboundWriteGate()
        defer { Task { await gate.release() } }
        let transport = OutboundRecordingTransport { authorization in
            admitted.fulfill()
            await gate.wait()
            let allowed = await authorization()
            XCTAssertFalse(allowed)
            rejected.fulfill()
            return allowed ? .response(200) : .rejected
        }
        let package = try OutboundAppFixtures.package(callback: "Interceptor.send('profile',{headers:{authorization:'Bearer token'}});")
        let (processor, store) = try await harness([package], transport: transport)
        defer { processor.shutdown() }
        _ = try await processor.process(.responseLeave, request: request, response: response)
        await fulfillment(of: [admitted], timeout: 2)
        _ = try await store.revokeAll()
        await gate.release()
        await fulfillment(of: [rejected], timeout: 2)
    }

    func testDryRunShowsHTTPIntentWithoutWebhookIdentityAndLegacyParserRejectsIt() throws {
        let manifest = try OutboundAppFixtures.package().manifest
        let output = Data(#"{"actions":[{"type":"http","binding":"profile","headers":{"authorization":"Bearer token"}}]}"#.utf8)
        let result = try SyntheticResult.parse(output, hook: .responseLeave, manifest: manifest)
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertNil(result.actions.first?.endpointID)
        XCTAssertEqual(result.actions.first?.outboundBinding, "profile")
        XCTAssertEqual(result.actions.first?.destination, "https://secondary.example.com/profile")
        XCTAssertThrowsError(try ValidatedAction.parse(output), "legacy dry-run parsing must never accept HTTP")
        XCTAssertThrowsError(try SyntheticResult.parse(output, hook: .responseLeave, manifest: PluginPackage.template().manifest))
    }

    func testDryRunRejectsUndeclaredHeadersUnknownBindingsAndExtraHTTPFields() throws {
        let manifest = try OutboundAppFixtures.package().manifest
        for action in [
            #"{"type":"http","binding":"profile","headers":{"x-undeclared":"private"}}"#,
            #"{"type":"http","binding":"missing","headers":{}}"#,
            #"{"type":"http","binding":"profile","headers":{},"url":"https://other.example.com/"}"#,
        ] {
            let output = Data("{\"actions\":[\(action)]}".utf8)
            XCTAssertThrowsError(try SyntheticResult.parse(output, hook: .responseLeave, manifest: manifest))
        }
    }
}

private actor OutboundWriteGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
