import Foundation
@testable import Interceptor
import XCTest

final class HTTPPluginFetchDispatcherTests: XCTestCase {
    func testSecondSubmissionIsRejectedWithoutQueueing() async {
        let release = AsyncGate()
        let completions = CompletionLog()
        let dispatcher = HTTPPluginFetchDispatcher { completions.append($0) }
        XCTAssertTrue(dispatcher.submit { await release.wait() })
        XCTAssertFalse(dispatcher.submit { XCTFail("must not queue") })
        XCTAssertEqual(completions.values, [.rejected])
        await release.open()
        dispatcher.shutdown()
        let drained = await dispatcher.waitUntilStopped()
        XCTAssertTrue(drained)
    }

    func testShutdownCancelsAndWaitProvesDrain() async {
        let started = expectation(description: "started")
        let dispatcher = HTTPPluginFetchDispatcher()
        dispatcher.submit {
            started.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        await fulfillment(of: [started], timeout: 2)
        dispatcher.shutdown()
        let drained = await dispatcher.waitUntilStopped()
        XCTAssertTrue(drained)
        XCTAssertFalse(dispatcher.submit {}, "no admission after shutdown")
    }

    func testWaitBeforeShutdownIsNotAProof() async {
        let dispatcher = HTTPPluginFetchDispatcher()
        let drained = await dispatcher.waitUntilStopped(timeoutNanoseconds: 10_000_000)
        XCTAssertFalse(drained)
    }

    func testShutdownRacingImmediatelyFinishingTask() async {
        for _ in 0 ..< 200 {
            let dispatcher = HTTPPluginFetchDispatcher()
            dispatcher.submit {}
            dispatcher.shutdown()
            let drained = await dispatcher.waitUntilStopped()
            XCTAssertTrue(drained)
        }
    }

    func testFailureMapsWithoutLeakingErrorDetail() async {
        let done = expectation(description: "done")
        let completions = CompletionLog()
        let dispatcher = HTTPPluginFetchDispatcher { completions.append($0); done.fulfill() }
        dispatcher.submit { throw NSError(domain: "secret-token", code: 1) }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(completions.values, [.failed])
        dispatcher.shutdown()
    }
}

final class HTTPPluginFetchTransportPolicyTests: XCTestCase {
    func testDefaultTransportImplementationRejectsFetch() async {
        let transport = OutboundRecordingTransport()
        let request = HTTPPluginOutboundRequest(host: "api.example.com", path: "/x", headers: [:])
        let outcome = await transport.fetch(request, timeoutMilliseconds: 5000, maxResponseBytes: 1 << 20, isAuthorized: { true })
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFetchLimitsClampDeadlineAndBody() throws {
        let limits = try XCTUnwrap(HTTPPluginExchangeLimits.fetch(timeoutMilliseconds: 120_000, maxResponseBytes: 64 << 20))
        XCTAssertEqual(limits.deadlineNanoseconds, 5_000_000_000)
        XCTAssertEqual(limits.bodyBytes, 1_048_576)
        XCTAssertTrue(limits.isFetch)
        XCTAssertNil(HTTPPluginExchangeLimits.fetch(timeoutMilliseconds: 0, maxResponseBytes: 10))
        XCTAssertNil(HTTPPluginExchangeLimits.fetch(timeoutMilliseconds: 10, maxResponseBytes: 0))
    }

    func testLegacyLimitsUnchanged() {
        XCTAssertEqual(HTTPPluginExchangeLimits.legacy.wireBytes, 65_536)
        XCTAssertEqual(HTTPPluginExchangeLimits.legacy.deadlineNanoseconds, 3_000_000_000)
        XCTAssertFalse(HTTPPluginExchangeLimits.legacy.isFetch)
    }

    func testDirectTransportRejectsInvalidRequestBeforeNetwork() async {
        let transport = HTTPPluginDirectTransport()
        let bad = HTTPPluginOutboundRequest(host: "localhost", path: "/", headers: [:])
        let outcome = await transport.fetch(bad, timeoutMilliseconds: 1000, maxResponseBytes: 1024, isAuthorized: { true })
        XCTAssertEqual(outcome, .rejected)
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

private final class CompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HTTPPluginFetchDispatcher.Completion] = []
    var values: [HTTPPluginFetchDispatcher.Completion] {
        lock.withLock { storage }
    }

    func append(_ value: HTTPPluginFetchDispatcher.Completion) {
        lock.withLock { storage.append(value) }
    }
}
