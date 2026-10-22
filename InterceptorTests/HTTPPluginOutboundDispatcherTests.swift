import AutomationCore
import AutomationRuntime
import Foundation
@testable import Interceptor
import XCTest

final class HTTPPluginOutboundDispatcherTests: XCTestCase, @unchecked Sendable {
    func testRealRuntimeActionsCrossCoreValidationAndDispatcher() async throws {
        for method in ["POST", "PUT"] {
            let package = try OutboundAppFixtures.package(
                callback: "Interceptor.send('profile',{headers:{authorization:'Bearer token'},json:{name:'日本語'}});",
                method: method)
            let output = try await JavaScriptExecutor().runV2(
                packageJSON: package.bytes, hook: .responseLeave,
                eventJSON: Data(#"{"request":{"method":"GET","host":"api.example.com","path":"/credentials"},"response":{"status":200,"headers":{},"body":{}}}"#.utf8),
                configJSON: Data("{}".utf8))
            let actions = try XCTUnwrap(try JSONValue(parsing: output).objectValue?["actions"]?.arrayValue)
            let intents = try actions.map { try PluginOutboundIntent.validating($0, manifest: package.manifest) }
            let done = expectation(description: "runtime \(method) delivered")
            let transport = OutboundRecordingTransport()
            let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { _, outcome in
                XCTAssertEqual(outcome, .response(200))
                done.fulfill()
            }
            defer { dispatcher.shutdown() }
            XCTAssertEqual(dispatcher.submit(intents, isAuthorized: { true }), 1)
            await fulfillment(of: [done], timeout: 2)
            let request = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(request.method, method)
            XCTAssertEqual(request.jsonBody, Data(#"{"name":"日本語"}"#.utf8))
            XCTAssertEqual(request.headers, ["authorization": "Bearer token"])
        }
    }

    func testCapacityIsReservedSynchronouslyAndOverloadHasNoWaitingQueue() async throws {
        let started = expectation(description: "four admitted operations")
        started.expectedFulfillmentCount = 4
        let cancelled = expectation(description: "owned operations cancelled")
        cancelled.expectedFulfillmentCount = 4
        let transport = OutboundRecordingTransport { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return .cancelled }
            return .failed
        }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { _, outcome in
            if outcome == .cancelled { cancelled.fulfill() }
        }
        defer { dispatcher.shutdown() }
        let intent = try OutboundAppFixtures.intent()
        XCTAssertEqual(dispatcher.submit(Array(repeating: intent, count: 5), isAuthorized: { true }), 4)
        XCTAssertEqual(dispatcher.submit([intent], isAuthorized: { true }), 0)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(transport.requests.count, 4)
        dispatcher.shutdown()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(dispatcher.submit([intent], isAuthorized: { true }), 0, "shutdown permanently invalidates admission")
        XCTAssertEqual(transport.requests.count, 4, "overload must not enqueue a fifth operation")
    }

    func testRejectedAuthorizationNeverInvokesTransport() async throws {
        let observed = expectation(description: "rejection")
        let transport = OutboundRecordingTransport { _ in .response(200) }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { binding, outcome in
            XCTAssertEqual(binding, "profile")
            XCTAssertEqual(outcome, .rejected)
            observed.fulfill()
        }
        defer { dispatcher.shutdown() }
        XCTAssertEqual(dispatcher.submit([try OutboundAppFixtures.intent()], isAuthorized: { false }), 1)
        await fulfillment(of: [observed], timeout: 2)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTransportReceivesOnlyFixedTargetAndDeclaredHeadersAndCompletionFreesCapacity() async throws {
        let firstFour = expectation(description: "first four responses")
        firstFour.expectedFulfillmentCount = 4
        let fifth = expectation(description: "reused slot response")
        let count = OutboundCounter()
        let transport = OutboundRecordingTransport { authorization in
            guard await authorization() else { return .rejected }
            return .response(204)
        }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { binding, outcome in
            XCTAssertEqual(binding, "profile")
            XCTAssertEqual(outcome, .response(204))
            if count.increment() <= 4 { firstFour.fulfill() } else { fifth.fulfill() }
        }
        defer { dispatcher.shutdown() }
        let intent = try OutboundAppFixtures.intent()
        XCTAssertEqual(dispatcher.submit(Array(repeating: intent, count: 4), isAuthorized: { true }), 4)
        await fulfillment(of: [firstFour], timeout: 2)
        XCTAssertEqual(dispatcher.submit([intent], isAuthorized: { true }), 1)
        await fulfillment(of: [fifth], timeout: 2)
        XCTAssertEqual(transport.requests.count, 5)
        for request in transport.requests {
            XCTAssertEqual(request.host, "secondary.example.com")
            XCTAssertEqual(request.path, "/profile")
            XCTAssertEqual(request.headers, ["authorization": "Bearer token"])
        }
    }

    func testTransportReceivesDeclaredMethodAndExactJSONBodyBytes() async throws {
        let body = #"{"name":"日本語","n":1.50e+2,"s":"a\"b\\A"}"#
        let cases: [(String, String?)] = [("GET", nil), ("POST", nil), ("POST", body), ("PUT", "null"), ("PUT", body)]
        for (method, jsonBody) in cases {
            let done = expectation(description: "\(method) \(jsonBody ?? "nil")")
            let transport = OutboundRecordingTransport()
            let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { _, outcome in
                XCTAssertEqual(outcome, .response(200))
                done.fulfill()
            }
            defer { dispatcher.shutdown() }
            let intent = try OutboundAppFixtures.intent(method: method, jsonBody: jsonBody)
            XCTAssertEqual(intent.jsonBody, jsonBody.map { Data($0.utf8) })
            XCTAssertEqual(dispatcher.submit([intent], isAuthorized: { true }), 1)
            await fulfillment(of: [done], timeout: 2)
            let request = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(request.method, method)
            XCTAssertEqual(request.jsonBody, jsonBody.map { Data($0.utf8) }, "dispatcher must forward the exact validated bytes")
            XCTAssertEqual(request.host, "secondary.example.com")
            XCTAssertEqual(request.path, "/profile")
            XCTAssertEqual(request.headers, ["authorization": "Bearer token"])
            XCTAssertTrue(request.isValid)
        }
    }

    func testShutdownDrainWaitsForObserverCallbacksAndResumesEveryWaiter() async throws {
        let entered = expectation(description: "observer running")
        let callback = OutboundBlockingCallback()
        defer { callback.release() }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: OutboundRecordingTransport()) { _, _ in
            entered.fulfill()
            callback.wait()
        }
        XCTAssertEqual(dispatcher.submit([try OutboundAppFixtures.intent()], isAuthorized: { true }), 1)
        await fulfillment(of: [entered], timeout: 2)
        dispatcher.shutdown()
        let completed = OutboundCounter()
        let a = Task { let result = await dispatcher.waitUntilStopped(); _ = completed.increment(); return result }
        let b = Task { let result = await dispatcher.waitUntilStopped(); _ = completed.increment(); return result }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(completed.current, 0, "task removal alone must not complete a drain")
        callback.release()
        let results = await [a.value, b.value]
        XCTAssertEqual(results, [true, true])
        let alreadyStopped = await dispatcher.waitUntilStopped()
        XCTAssertTrue(alreadyStopped)
    }

    func testShutdownDrainIncludesSynchronousOverloadObserver() async throws {
        let entered = expectation(description: "overload callback running")
        let callback = OutboundBlockingCallback()
        defer { callback.release() }
        let transport = OutboundRecordingTransport { _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return .cancelled }
            return .failed
        }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: transport) { _, outcome in
            if outcome == .rejected { entered.fulfill(); callback.wait() }
        }
        let intent = try OutboundAppFixtures.intent()
        let submission = Task.detached { dispatcher.submit(Array(repeating: intent, count: 5), isAuthorized: { true }) }
        await fulfillment(of: [entered], timeout: 2)
        dispatcher.shutdown()
        let timedOut = await dispatcher.waitUntilStopped(timeoutNanoseconds: 50_000_000)
        XCTAssertFalse(timedOut)
        callback.release()
        let admitted = await submission.value
        XCTAssertEqual(admitted, 4)
        let drained = await dispatcher.waitUntilStopped()
        XCTAssertTrue(drained)
        XCTAssertEqual(dispatcher.submit([intent], isAuthorized: { true }), 0)
    }

    func testCancellingADrainWaiterDoesNotLoseLaterCompletion() async throws {
        let entered = expectation(description: "callback running")
        let callback = OutboundBlockingCallback()
        defer { callback.release() }
        let dispatcher = HTTPPluginOutboundDispatcher(transport: OutboundRecordingTransport()) { _, _ in
            entered.fulfill(); callback.wait()
        }
        _ = dispatcher.submit([try OutboundAppFixtures.intent()], isAuthorized: { true })
        await fulfillment(of: [entered], timeout: 2)
        dispatcher.shutdown()
        let waiter = Task { await dispatcher.waitUntilStopped() }
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertFalse(cancelled)
        callback.release()
        let final = await dispatcher.waitUntilStopped()
        XCTAssertTrue(final)
    }
}

private final class OutboundBlockingCallback: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() { condition.lock(); defer { condition.unlock() }; while !released { condition.wait() } }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class OutboundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// Injected transport observes the native boundary; it never opens a socket.
final class OutboundRecordingTransport: HTTPPluginOutboundTransport, @unchecked Sendable {
    typealias Operation = @Sendable (@escaping @Sendable () async -> Bool) async -> HTTPPluginOutboundOutcome
    private let lock = NSLock()
    private var recorded: [HTTPPluginOutboundRequest] = []
    private let operation: Operation
    init(operation: @escaping Operation = { authorization in await authorization() ? .response(200) : .rejected }) {
        self.operation = operation
    }
    var requests: [HTTPPluginOutboundRequest] { lock.withLock { recorded } }
    func perform(_ request: HTTPPluginOutboundRequest,
                 isAuthorized: @escaping @Sendable () async -> Bool) async -> HTTPPluginOutboundOutcome {
        lock.withLock { recorded.append(request) }
        return await operation(isAuthorized)
    }
}

enum OutboundAppFixtures {
    static func package(id: UUID = UUID(), callback: String = "", phase: String = "onLeave",
                        headers: [String] = ["authorization", "cookie"], readHeaders: [String] = [],
                        method: String = "GET") throws -> PluginPackage {
        let file = "hooks/api.example.com/credentials/GET.js"
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(2), "id": .string(id.uuidString), "name": .string("Outbound test"), "version": .string("1.0.0"),
            "matches": .array([.object([
                "hosts": .array([.string("api.example.com")]), "methods": .array([.string("GET")]),
                "path": .object(["kind": .string("exact"), "value": .string("/credentials")]),
                "hooks": .object(["response": .object([phase: .string(file)])]),
            ])]),
            "read": .object(["metadata": .array(["method", "host", "path", "status"].map(JSONValue.string)),
                             "headers": .array(readHeaders.map(JSONValue.string)), "queryKeys": .array([]),
                             "body": .object(["mode": .string("json")])]),
            "write": .object(["requestBody": .bool(false), "responseBody": .bool(phase == "onEnter")]),
            "endpointBindings": .array([]), "settings": .object([:]),
            "outbound": .object(["profile": .object([
                "url": .string("https://secondary.example.com/profile"), "method": .string(method),
                "headers": .array(headers.map(JSONValue.string)),
            ])]),
        ])
        return try PluginPackage.validate(JSONValue.object([
            "manifest": manifest,
            "sourceFiles": .object([file: .string("Interceptor.attach({response:{\(phase)(r){\(callback)}}});")]),
        ]).data())
    }

    static func intent(method: String = "GET", jsonBody: String? = nil,
                       headers: [String: JSONValue] = ["authorization": .string("Bearer token")]) throws -> PluginOutboundIntent {
        var action: [String: JSONValue] = ["type": .string("http"), "binding": .string("profile"), "headers": .object(headers)]
        if let jsonBody { action["jsonBody"] = .string(jsonBody) }
        return try PluginOutboundIntent.validating(.object(action), manifest: package(method: method).manifest)
    }
}
