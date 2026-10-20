import AutomationCore
import AutomationRuntime
import Foundation
@testable import Interceptor
import MudmouthHTTPHooks
import XCTest

/// Exercises the same adapter source compiled into the app and PacketTunnel, with the real C runtime
/// and protected activation file. Consent is isolated from the user's shared defaults.
final class HTTPPluginProcessorTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private static let match: JSONValue = .object([
        "hosts": .array([.string("api.example.com")]),
        "methods": .array([.string("POST")]),
        "path": .object(["kind": .string("exact"), "value": .string("/search")]),
    ])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPPluginProcessor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func package(id: UUID = UUID(), match: JSONValue = HTTPPluginProcessorTests.match,
                         metadata: [String] = ["method", "host", "path", "status"],
                         headers: [String] = [], queries: [String] = [], bodyMode: String = "json",
                         requestWrite: Bool = true, responseWrite: Bool = true,
                         settings: JSONValue = .object([:]), request: String = "", response: String = "") throws -> PluginPackage
    {
        let sourceFile = "hooks/api.example.com/search/POST.js"
        var route = try XCTUnwrap(match.objectValue)
        var hooks: [String: JSONValue] = [:]
        for (leg, callbacks) in [("request", request), ("response", response)] {
            var phases: [String: JSONValue] = [:]
            for phase in ["onEnter", "onLeave"] where callbacks.contains(phase + "(") {
                phases[phase] = .string(sourceFile)
            }
            if !phases.isEmpty {
                hooks[leg] = .object(phases)
            }
        }
        route["hooks"] = .object(hooks)
        let manifest: JSONValue = .object([
            "schemaVersion": .integer(2), "id": .string(id.uuidString), "name": .string("Adapter test"), "version": .string("1.0.0"),
            "matches": .array([.object(route)]),
            "read": .object(["metadata": .array(metadata.map(JSONValue.string)), "headers": .array(headers.map(JSONValue.string)),
                             "queryKeys": .array(queries.map(JSONValue.string)), "body": .object(["mode": .string(bodyMode)])]),
            "write": .object(["requestBody": .bool(requestWrite), "responseBody": .bool(responseWrite)]),
            "endpointBindings": .array([]), "settings": settings,
        ])
        let source = "Interceptor.attach({request:{\(request)},response:{\(response)}});"
        return try PluginPackage.validate(JSONValue.object(["manifest": manifest, "sourceFiles": .object([sourceFile: .string(source)])]).data())
    }

    private struct Harness {
        let processor: HTTPPluginProcessor
        let store: PluginActivationStore
        let snapshot: PluginActivationSnapshot
    }

    private func approved(_ packages: [PluginPackage], consent: @escaping @Sendable () -> Bool = { true }) async throws -> Harness {
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: packages, activationURL: directory.appendingPathComponent("active.json"))
        var snapshot = try await store.snapshot()
        for revision in revisions {
            snapshot = try await store.activate(revision.package, revisionID: revision.id,
                                                expectedGeneration: snapshot.generation)
        }
        return Harness(processor: HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: consent),
                       store: store, snapshot: snapshot)
    }

    private func request(method: String = "POST", host: String = "api.example.com", path: String = "/search",
                         headers: [String: String] = [:], query: [String: String] = [:], body: Data = Data(#"{"limit":20}"#.utf8)) -> HTTPPluginRequest
    {
        var request = HTTPPluginRequest(id: UUID(), method: method, host: host, path: path, headers: headers, body: body)
        request.query = query
        return request
    }

    private func response(status: Int = 200, headers: [String: String] = [:], body: Data = Data(#"{"maintenance":false}"#.utf8)) -> HTTPPluginResponse {
        HTTPPluginResponse(status: status, headers: headers, body: body)
    }

    private func json(_ bytes: Data?) throws -> JSONValue {
        try JSONValue(parsing: XCTUnwrap(bytes))
    }

    func testFourPhasesUseRealRuntimeAndSeparateCallbacks() async throws {
        let package = try package(
            request: "onEnter(r){r.body.limit=5;},onLeave(){throw new Error('request leave ran');}",
            response: "onEnter(r){r.body.maintenance=true;},onLeave(){throw new Error('response leave ran');}",
        )
        let processor = try await approved([package]).processor
        let req = request(), res = response()
        let requestOutput = try await processor.process(.requestEnter, request: req, response: nil)
        XCTAssertEqual(try json(requestOutput), .object(["limit": .integer(5)]))
        let responseOutput = try await processor.process(.responseEnter, request: req, response: res)
        XCTAssertEqual(try json(responseOutput), .object(["maintenance": .bool(true)]))
        for phase in [HTTPPluginPhase.requestLeave, .responseLeave] {
            do {
                _ = try await processor.process(phase, request: req, response: phase == .responseLeave ? res : nil)
                XCTFail("the selected leave callback must run")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
        }
    }

    func testResponsePhasesReadTheGrantedForwardedRequestJSON() async throws {
        let package = try package(request: "onEnter(r){r.body.limit=5;}", response: """
        onEnter(r){
          if(!r.request.body || r.request.body.limit!==5) throw new Error('forwarded request JSON missing');
          r.body.requestLimit=r.request.body.limit;
        },
        onLeave(r){
          if(!r.request.body || r.request.body.limit!==5) throw new Error('forwarded request JSON missing on leave');
          if(r.body.requestLimit!==5) throw new Error('forwarded response JSON missing on leave');
        }
        """)
        let processor = try await approved([package]).processor
        var forwardedRequest = request()
        let requestOutput = try await processor.process(.requestEnter, request: forwardedRequest, response: nil)
        forwardedRequest.body = try XCTUnwrap(requestOutput)
        XCTAssertEqual(try json(requestOutput), .object(["limit": .integer(5)]))
        var forwardedResponse = response()
        let responseOutput = try await processor.process(.responseEnter, request: forwardedRequest, response: forwardedResponse)
        XCTAssertEqual(try json(responseOutput), .object(["maintenance": .bool(false), "requestLimit": .integer(5)]))
        forwardedResponse.body = try XCTUnwrap(responseOutput)
        let leaveOutput = try await processor.process(.responseLeave, request: forwardedRequest, response: forwardedResponse)
        XCTAssertNil(leaveOutput)
    }

    func testGrantedForwardedRequestJSONIsReadOnlyInBothResponsePhases() async throws {
        for phase in [HTTPPluginPhase.responseEnter, .responseLeave] {
            let handler = phase == .responseEnter ? "onEnter" : "onLeave"
            let package = try package(response: """
            \(handler)(r){
              if(!r.request.body || r.request.body.limit!==5) throw new Error('forwarded request JSON missing');
              const body=r.request.body;
              const rejected=(()=>{try{body.limit=99;return false;}catch{return true;}})();
              if(!rejected || body.limit!==5) throw new Error('associated request must stay read-only');
            }
            """)
            let processor = try await approved([package]).processor
            let output = try await processor.process(phase, request: request(body: Data(#"{"limit":5}"#.utf8)), response: response())
            XCTAssertNil(output)
        }
    }

    func testAbsentOrNonJSONRequestBodyDoesNotPreventEligibleResponseHooks() async throws {
        let package = try package(response: """
        onEnter(r){
          if(typeof r.request.body!=='undefined') throw new Error('ineligible request JSON exposed');
          r.body.responseProcessed=true;
        },
        onLeave(r){
          if(typeof r.request.body!=='undefined') throw new Error('ineligible request JSON exposed on leave');
          if(r.body.responseProcessed!==true) throw new Error('eligible response hook was skipped');
        }
        """)
        let processor = try await approved([package]).processor
        let bodies: [(String, Data)] = [
            ("absent", Data()), ("plain text", Data("plain text".utf8)),
            ("malformed JSON", Data("{invalid".utf8)), ("non-UTF8", Data([0xff])),
            ("oversize", Data(repeating: 0x20, count: 24 * 1024 + 1)),
        ]
        for (name, body) in bodies {
            let req = request(body: body)
            var res = response()
            let output = try await processor.process(.responseEnter, request: req, response: res)
            XCTAssertEqual(try json(output), .object(["maintenance": .bool(false), "responseProcessed": .bool(true)]), name)
            res.body = try XCTUnwrap(output)
            let leaveOutput = try await processor.process(.responseLeave, request: req, response: res)
            XCTAssertNil(leaveOutput, name)
        }
    }

    func testRepeatedPhasesUseFreshVMs() async throws {
        let callback = "onEnter(r){globalThis.counter=(globalThis.counter||0)+1;r.body={counter:globalThis.counter};}"
        let package = try package(request: callback, response: callback)
        let processor = try await approved([package]).processor
        for phase in [HTTPPluginPhase.requestEnter, .requestEnter, .responseEnter] {
            let output = try await processor.process(phase, request: request(), response: phase == .responseEnter ? response() : nil)
            XCTAssertEqual(try json(output), .object(["counter": .integer(1)]))
        }
    }

    func testLeaveMutationsAreRejectedWithoutReplacement() async throws {
        let package = try package(request: "onLeave(r){r.body.limit=99;r.body={replaced:true};}",
                                  response: "onLeave(r){r.body.maintenance=true;r.body={replaced:true};}")
        let processor = try await approved([package]).processor
        for phase in [HTTPPluginPhase.requestLeave, .responseLeave] {
            do {
                _ = try await processor.process(phase, request: request(), response: phase == .responseLeave ? response() : nil)
                XCTFail("leave traffic must be read-only")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
        }
    }

    func testManifestGrantsFilterMetadataHeadersAndQueryBeforeCallback() async throws {
        let package = try package(metadata: ["host", "path"], headers: ["x-visible"], queries: ["q"], request: """
        onEnter(r){
          r.body={host:r.host,path:r.path,methodHidden:typeof r.method==='undefined',
                  header:r.headers['x-visible'],headerHidden:typeof r.headers.authorization==='undefined',
                  query:r.query.q,queryHidden:typeof r.query.secret==='undefined'};
        }
        """, response: """
        onEnter(r){
          r.body={host:r.request.host,methodHidden:typeof r.request.method==='undefined',
                  statusHidden:typeof r.status==='undefined',header:r.headers['x-visible'],
                  headerHidden:typeof r.headers['set-cookie']==='undefined'};
        }
        """)
        let processor = try await approved([package]).processor
        let req = request(headers: ["x-visible": "request value", "authorization": "captured secret"],
                          query: ["q": "visible query", "secret": "hidden query"])
        let output = try await processor.process(.requestEnter, request: req, response: nil)
        XCTAssertEqual(try json(output), .object([
            "host": .string("api.example.com"), "path": .string("/search"), "methodHidden": .bool(true),
            "header": .string("request value"), "headerHidden": .bool(true), "query": .string("visible query"), "queryHidden": .bool(true),
        ]))
        let responseOutput = try await processor.process(.responseEnter, request: req,
                                                         response: response(headers: ["x-visible": "response value", "set-cookie": "hidden cookie"]))
        XCTAssertEqual(try json(responseOutput), .object([
            "host": .string("api.example.com"), "methodHidden": .bool(true), "statusHidden": .bool(true),
            "header": .string("response value"), "headerHidden": .bool(true),
        ]))
    }

    func testHostPathAndMethodMissesNeverInvokeRuntimeCallback() async throws {
        let package = try package(request: "onEnter(){throw new Error('must not run');}",
                                  response: "onEnter(){throw new Error('must not run');}")
        let processor = try await approved([package]).processor
        for req in [request(host: "other.example.com"), request(path: "/search/child"), request(method: "GET")] {
            XCTAssertFalse(processor.matches(req))
            let output = try await processor.process(.requestEnter, request: req, response: nil)
            let responseOutput = try await processor.process(.responseEnter, request: req, response: response())
            XCTAssertNil(output)
            XCTAssertNil(responseOutput)
        }
        XCTAssertTrue(processor.matches(request()))
    }

    func testStatusQualifiedRoutesAreRejectedByFilesystemPackageValidation() throws {
        var match = try XCTUnwrap(Self.match.objectValue)
        match["status"] = .object(["min": .integer(500), "max": .integer(599)])
        XCTAssertThrowsError(try package(match: .object(match), metadata: [], response: "onEnter(){}")) { error in
            XCTAssertEqual(error as? AutomationError, .invalidManifest)
        }
    }

    func testApprovedRevisionsComposeInDeterministicRevisionOrder() async throws {
        let a = try package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")),
                            request: "onEnter(r){r.body.sequence=(r.body.sequence||'')+'A';}")
        let b = try package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000B")),
                            request: "onEnter(r){r.body.sequence=(r.body.sequence||'')+'B';}")
        let harness = try await approved([b, a])
        XCTAssertEqual(harness.snapshot.revisions.map(\.package.manifest.id), [a.manifest.id, b.manifest.id])
        let output = try await harness.processor.process(.requestEnter, request: request(body: Data("{}".utf8)), response: nil)
        XCTAssertEqual(try json(output), .object(["sequence": .string("AB")]))
    }

    func testLaterApprovedFailureDiscardsEarlierMutationForBothEnterPhases() async throws {
        let aID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000A"))
        let bID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000B"))
        let first = try package(id: aID, request: "onEnter(r){r.body.earlier=true;}",
                                response: "onEnter(r){r.body.earlier=true;}")
        let second = try package(id: bID, request: "onEnter(r){if(r.body.earlier!==true)throw new Error('order');throw new Error('later failure');}",
                                 response: "onEnter(r){if(r.body.earlier!==true)throw new Error('order');throw new Error('later failure');}")
        let processor = try await approved([second, first]).processor
        let req = request()
        let res = response()
        for phase in [HTTPPluginPhase.requestEnter, .responseEnter] {
            do {
                _ = try await processor.process(phase, request: req, response: phase == .responseEnter ? res : nil)
                XCTFail("the adapter must throw instead of returning an earlier revision's partial mutation")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
        }
        XCTAssertEqual(try json(req.body), .object(["limit": .integer(20)]))
        XCTAssertEqual(try json(res.body), .object(["maintenance": .bool(false)]))
    }

    func testRevokedStoreBeforeInvocationRejectsInsteadOfExecutingSource() async throws {
        let package = try package(request: "onEnter(){throw new Error('must not run');}")
        let harness = try await approved([package])
        _ = try await harness.store.revokeAll()
        let authorized = await harness.processor.isAuthorized()
        XCTAssertFalse(authorized)
        do {
            _ = try await harness.processor.process(.requestEnter, request: request(), response: nil)
            XCTFail("revoked grant must not execute")
        } catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .revoked) }
    }

    func testRevokedStoreAfterRealVMFinishesDiscardsMutation() async throws {
        let finished = expectation(description: "real VM returned; adapter is at its post-VM consent check")
        let gate = PostVMGate(reached: finished)
        defer { gate.release() }
        let package = try package(request: "onEnter(r){r.body.limit=5;}")
        let harness = try await approved([package], consent: { gate.consent() })
        let req = request()
        let processing = Task { try await harness.processor.process(.requestEnter, request: req, response: nil) }
        await fulfillment(of: [finished], timeout: 3)
        _ = try await harness.store.revokeAll()
        gate.release()
        do { _ = try await processing.value; XCTFail("post-VM revocation must discard the buffered mutation") }
        catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .revoked) }
        XCTAssertFalse(gate.timedOut)
    }

    func testConcurrentResponseEnterWaitsForAdmittedRequestLeave() async throws {
        try await assertConcurrentPhaseWaits(first: .requestLeave, second: .responseEnter)
    }

    func testConcurrentRequestEnterWaitsForAdmittedRequestEnter() async throws {
        try await assertConcurrentPhaseWaits(first: .requestEnter, second: .requestEnter)
    }

    func testQueuedResponsePhaseRechecksActivationBeforeEnteringRealVM() async throws {
        try await assertConcurrentPhaseWaits(first: .requestEnter, second: .responseEnter, revokeWhileQueued: true)
    }

    func testPhaseAdmissionBoundsWaitingWorkAndPreservesFIFOOrder() async throws {
        let admission = HTTPPluginPhaseAdmission(maximumWaiting: 2)
        try await admission.acquire()
        let order = AdmissionOrderProbe()
        let firstStarted = expectation(description: "first waiter started")
        let firstDone = expectation(description: "first waiter completed")
        let firstEarly = expectation(description: "first waiter completed while another phase owns admission")
        firstEarly.isInverted = true
        let first = admissionTask(admission, name: "first", order: order, started: firstStarted, done: firstDone, early: firstEarly)
        defer { first.cancel() }
        await fulfillment(of: [firstStarted], timeout: 1)
        let firstPending = await XCTWaiter.fulfillment(of: [firstEarly], timeout: 0.1)
        XCTAssertEqual(firstPending, .completed)
        let secondStarted = expectation(description: "second waiter started")
        let secondDone = expectation(description: "second waiter completed")
        let secondEarly = expectation(description: "second waiter completed while another phase owns admission")
        secondEarly.isInverted = true
        let second = admissionTask(admission, name: "second", order: order, started: secondStarted, done: secondDone, early: secondEarly)
        defer { second.cancel() }
        await fulfillment(of: [secondStarted], timeout: 1)
        let secondPending = await XCTWaiter.fulfillment(of: [secondEarly], timeout: 0.1)
        XCTAssertEqual(secondPending, .completed)
        let overflowStarted = expectation(description: "overflow waiter started")
        let overflowDone = expectation(description: "bounded overload returned")
        let overflow = admissionTask(admission, name: "overflow", order: order, started: overflowStarted, done: overflowDone)
        defer { overflow.cancel() }
        await fulfillment(of: [overflowStarted], timeout: 1)
        let overloadReturned = await XCTWaiter.fulfillment(of: [overflowDone], timeout: 1)
        XCTAssertEqual(overloadReturned, .completed, "one active + two waiting phases must reject further work promptly")
        if overloadReturned != .completed {
            overflow.cancel()
        }
        order.releaseOwner()
        await admission.release()
        let finished = await XCTWaiter.fulfillment(of: [firstDone, secondDone], timeout: 3)
        guard finished == .completed, overloadReturned == .completed else {
            XCTFail("releasing the active phase must drain the bounded queue")
            return
        }
        let firstError = await first.value
        let secondError = await second.value
        let overflowError = await overflow.value
        XCTAssertNil(firstError)
        XCTAssertNil(secondError)
        XCTAssertEqual(overflowError, .busy)
        XCTAssertEqual(order.names, ["first", "second"])
    }

    func testCancelledQueuedAdmissionReturnsItsCapacityWithoutConsumingPermit() async throws {
        let admission = HTTPPluginPhaseAdmission(maximumWaiting: 1)
        try await admission.acquire()
        let order = AdmissionOrderProbe()
        let started = expectation(description: "cancelled waiter started")
        let done = expectation(description: "cancelled waiter returned")
        let early = expectation(description: "waiter completed before cancellation or owner release")
        early.isInverted = true
        let cancelled = admissionTask(admission, name: "cancelled", order: order, started: started, done: done, early: early)
        defer { cancelled.cancel() }
        await fulfillment(of: [started], timeout: 1)
        let pending = await XCTWaiter.fulfillment(of: [early], timeout: 0.1)
        XCTAssertEqual(pending, .completed)
        cancelled.cancel()
        let cancelledReturned = await XCTWaiter.fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(cancelledReturned, .completed, "cancellation must resume a queued waiter without a release")
        let replacementStarted = expectation(description: "replacement waiter started")
        let replacementDone = expectation(description: "replacement waiter returned")
        let replacementEarly = expectation(description: "replacement completed before owner release")
        replacementEarly.isInverted = true
        let replacement = admissionTask(admission, name: "replacement", order: order, started: replacementStarted, done: replacementDone, early: replacementEarly)
        defer { replacement.cancel() }
        await fulfillment(of: [replacementStarted], timeout: 1)
        let stayedQueued = await XCTWaiter.fulfillment(of: [replacementEarly], timeout: 0.1)
        XCTAssertEqual(stayedQueued, .completed, "cancellation must free queue capacity while the original owner keeps its permit")
        order.releaseOwner()
        await admission.release()
        let replacementReturned = await XCTWaiter.fulfillment(of: [replacementDone], timeout: 3)
        guard cancelledReturned == .completed, replacementReturned == .completed else {
            XCTFail("cancelled and replacement phases must both finish within their bounds")
            return
        }
        let cancelledError = await cancelled.value
        let replacementError = await replacement.value
        XCTAssertEqual(cancelledError, .cancelled)
        XCTAssertNil(replacementError)
        XCTAssertEqual(order.names, ["replacement"])
    }

    private func admissionTask(_ admission: HTTPPluginPhaseAdmission, name: String, order: AdmissionOrderProbe,
                               started: XCTestExpectation, done: XCTestExpectation,
                               early: XCTestExpectation? = nil) -> Task<JavaScriptExecutionError?, Never>
    {
        Task {
            started.fulfill()
            defer {
                if !order.ownerWasReleased && !Task.isCancelled {
                    early?.fulfill()
                }
                done.fulfill()
            }
            do {
                try await admission.acquire()
                order.append(name)
                await admission.release()
                return nil
            } catch {
                return error as? JavaScriptExecutionError ?? .internalFailure
            }
        }
    }

    /// Gate the first phase only after real QuickJS returned. The second phase must still wait
    /// for the entire admitted phase (including post-VM authorization) to release its slot.
    private func assertConcurrentPhaseWaits(first: HTTPPluginPhase, second: HTTPPluginPhase, revokeWhileQueued: Bool = false) async throws {
        let atPostVM = expectation(description: "first real VM returned and its phase remains admitted")
        let gate = PostVMGate(reached: atPostVM)
        defer { gate.release() }
        let responseSource = revokeWhileQueued ? "onEnter(){throw new Error('revoked queued phase entered VM');}" : "onEnter(r){r.body.maintenance=true;}"
        let package = try package(request: "onEnter(r){r.body.limit=5;},onLeave(r){if(r.body.limit!==20)throw new Error('unexpected leave body');}",
                                  response: responseSource)
        let harness = try await approved([package], consent: { gate.consent() })
        let processor = harness.processor
        let req = request(), res = response()
        let firstDone = expectation(description: "first admitted phase finished")
        let firstTask = Task {
            defer { firstDone.fulfill() }
            return try await processor.process(first, request: req, response: nil)
        }
        defer { firstTask.cancel() }
        let reached = await XCTWaiter.fulfillment(of: [atPostVM], timeout: 3)
        guard reached == .completed else {
            XCTFail("first phase never reached its post-VM gate")
            gate.release()
            firstTask.cancel()
            let drained = await XCTWaiter.fulfillment(of: [firstDone], timeout: 3)
            XCTAssertEqual(drained, .completed, "the first phase must finish before its fixture is removed")
            if drained == .completed {
                _ = await firstTask.result
            }
            return
        }
        let secondStarted = expectation(description: "second task entered the adapter call")
        let secondDone = expectation(description: "second queued phase finished")
        let earlyCompletion = expectation(description: "second phase completed before first released admission")
        earlyCompletion.isInverted = true
        let secondTask = Task {
            secondStarted.fulfill()
            defer {
                if !gate.isReleased {
                    earlyCompletion.fulfill()
                }
                secondDone.fulfill()
            }
            return try await processor.process(second, request: req, response: second == .responseEnter ? res : nil)
        }
        defer { secondTask.cancel() }
        let started = await XCTWaiter.fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertEqual(started, .completed)
        let stayedQueued = await XCTWaiter.fulfillment(of: [earlyCompletion], timeout: 0.2)
        XCTAssertEqual(stayedQueued, .completed, "ordinary concurrent phases must wait, not return early or fail busy")
        var revocationError: Error?
        if revokeWhileQueued {
            do { _ = try await harness.store.revokeAll() }
            catch { revocationError = error }
        }
        gate.release()
        let finished = await XCTWaiter.fulfillment(of: [firstDone, secondDone], timeout: 3)
        guard finished == .completed else {
            XCTFail("releasing admission must allow both bounded phases to finish")
            return
        }
        if let revocationError {
            // Preserve the originating fixture/write error after both real phases have drained.
            _ = await firstTask.result
            _ = await secondTask.result
            throw revocationError
        }
        if revokeWhileQueued {
            for task in [firstTask, secondTask] {
                do {
                    _ = try await task.value
                    XCTFail("an admitted or queued revoked phase must not return a mutation")
                } catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .revoked) }
            }
        } else {
            let firstOutput = try await firstTask.value
            if first == .requestLeave {
                XCTAssertNil(firstOutput)
            } else {
                XCTAssertEqual(try json(firstOutput), .object(["limit": .integer(5)]))
            }
            let secondOutput = try await secondTask.value
            XCTAssertEqual(try json(secondOutput), second == .responseEnter
                ? .object(["maintenance": .bool(true)]) : .object(["limit": .integer(5)]))
        }
        XCTAssertFalse(gate.timedOut)
    }

    func testConsentLossAtAdmissionAndAfterVMNeverReturnsMutation() async throws {
        for deniedCheck in [1, 2, 3, 4] {
            let consent = ConsentSequence(deniedCheck: deniedCheck)
            let package = try package(request: "onEnter(r){r.body.limit=5;}")
            let url = directory.appendingPathComponent("consent-\(deniedCheck).json")
            let (store, revisions) = try await AutomationFixtures.activationContext(packages: [package], activationURL: url)
            let empty = try await store.snapshot()
            let snapshot = try await store.activate(package, revisionID: XCTUnwrap(revisions.first).id, expectedGeneration: empty.generation)
            let processor = HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: { consent.next() })
            do {
                _ = try await processor.process(.requestEnter, request: request(), response: nil)
                XCTFail("consent loss at check \(deniedCheck) must prevent output")
            } catch { XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .revoked) }
        }
    }

    func testUnchangedTreePreservesOriginalWireBytesByReturningNil() async throws {
        let package = try package(request: "onEnter(r){r.body={nested:{a:true},limit:20};}")
        let processor = try await approved([package]).processor
        let wire = Data("{ \"limit\" : 20, \"nested\" : { \"a\" : true } }\n".utf8)
        let req = request(body: wire)
        let output = try await processor.process(.requestEnter, request: req, response: nil)
        XCTAssertNil(output)
        XCTAssertEqual(req.body, wire)
    }

    func testWriteGrantsCannotCrossRequestAndResponseLegs() async throws {
        let package = try package(responseWrite: false, request: "onEnter(r){r.body.limit=5;}",
                                  response: "onEnter(r){r.body.maintenance=true;}")
        let processor = try await approved([package]).processor
        let output = try await processor.process(.requestEnter, request: request(), response: nil)
        XCTAssertEqual(try json(output), .object(["limit": .integer(5)]))
        do {
            _ = try await processor.process(.responseEnter, request: request(), response: response())
            XCTFail("request write permission cannot authorize a response edit")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError) }
    }

    func testOversizeOriginalBypassesVMAndInvalidOriginalSignalsFailure() async throws {
        let package = try package(request: "onEnter(){throw new Error('must not run for oversized traffic');}")
        let processor = try await approved([package]).processor
        let oversized = request(body: Data(repeating: 0x20, count: 24 * 1024 + 1))
        let output = try await processor.process(.requestEnter, request: oversized, response: nil)
        XCTAssertNil(output)
        do {
            _ = try await processor.process(.requestEnter, request: request(body: Data("{invalid".utf8)), response: nil)
            XCTFail("invalid JSON must signal failure to the transport")
        } catch { XCTAssertEqual(error as? AutomationError, .invalidJSON) }
    }

    func testInvalidAndOversizeMutationsAndScriptErrorsKeepFailureSignal() async throws {
        for callback in ["r.body=undefined;", "r.body={value:'x'.repeat(25000)};", "throw new Error('failed');"] {
            let package = try package(request: "onEnter(r){\(callback)}")
            let (store, revisions) = try await AutomationFixtures.activationContext(packages: [package], activationURL: directory.appendingPathComponent(UUID().uuidString + ".json"))
            let empty = try await store.snapshot()
            let snapshot = try await store.activate(package, revisionID: XCTUnwrap(revisions.first).id, expectedGeneration: empty.generation)
            let processor = HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: { true })
            do {
                _ = try await processor.process(.requestEnter, request: request(), response: nil)
                XCTFail("a failed runtime/result must remain a failure, allowing the transport to preserve original traffic")
            } catch {
                if callback.contains("25000") {
                    XCTAssertEqual(error as? HTTPPluginProcessor.Failure, .invalidResult)
                } else if callback.contains("undefined") {
                    XCTAssertEqual(error as? JavaScriptExecutionError, .invalidResult)
                } else {
                    XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError)
                }
            }
        }
    }

    func testWrappedSettingsReachRealCallbackAndOversizeConfigIsRejected() async throws {
        let package = try package(settings: .object(["tag": .string("wrapped")]),
                                  request: "onEnter(r,c){r.body={tag:c.settings.tag,endpoints:Object.keys(c.endpoints).length};}")
        let processor = try await approved([package]).processor
        let output = try await processor.process(.requestEnter, request: request(), response: nil)
        XCTAssertEqual(try json(output), .object(["tag": .string("wrapped"), "endpoints": .integer(0)]))
        let large = try self.package(settings: .object(["x": .string(String(repeating: "x", count: 8184))]),
                                     request: "onEnter(){throw new Error('oversize config must not invoke callback');}")
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: [large], activationURL: directory.appendingPathComponent("large-config.json"))
        let empty = try await store.snapshot()
        let snapshot = try await store.activate(large, revisionID: XCTUnwrap(revisions.first).id, expectedGeneration: empty.generation)
        let largeProcessor = HTTPPluginProcessor(store: store, snapshot: snapshot, hasCaptureConsent: { true })
        do {
            _ = try await largeProcessor.process(.requestEnter, request: request(), response: nil)
            XCTFail("the 8KiB total config cap includes wrapper bytes")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidInput) }
    }

    func testHugeUngrantedHeadersCannotPreventGrantedRequestOrResponseHook() async throws {
        let package = try package(headers: ["X-VISIBLE"],
                                  request: "onEnter(r){r.body={visible:r.headers['x-visible'],hidden:typeof r.headers.cookie==='undefined'};}",
                                  response: "onEnter(r){r.body={visible:r.headers['x-visible'],hidden:typeof r.headers['set-cookie']==='undefined'};}")
        let processor = try await approved([package]).processor
        let req = request(headers: ["x-visible": "request", "cookie": String(repeating: "x", count: 100_000)])
        let requestOutput = try await processor.process(.requestEnter, request: req, response: nil)
        XCTAssertEqual(try json(requestOutput), .object(["visible": .string("request"), "hidden": .bool(true)]))
        let res = response(headers: ["x-visible": "response", "set-cookie": String(repeating: "y", count: 100_000)])
        let responseOutput = try await processor.process(.responseEnter, request: req, response: res)
        XCTAssertEqual(try json(responseOutput), .object(["visible": .string("response"), "hidden": .bool(true)]))
    }

    func testThreeHundredUngrantedQueryFieldsCannotConsumeVMMapQuota() async throws {
        let package = try package(queries: ["q"], request: "onEnter(r){r.body={q:r.query.q,keys:Object.keys(r.query).join(','),upperHidden:typeof r.query.Q==='undefined'};}")
        let processor = try await approved([package]).processor
        var query = Dictionary(uniqueKeysWithValues: (0 ..< 300).map { ("ungranted\($0)", "private") })
        query["q"] = "granted"
        query["Q"] = "not granted"
        let output = try await processor.process(.requestEnter, request: request(query: query), response: nil)
        XCTAssertEqual(try json(output), .object(["q": .string("granted"), "keys": .string("q"), "upperHidden": .bool(true)]))
    }

    func testQueryGrantsUseExactUTF8BytesRatherThanCanonicalEquivalence() async throws {
        let nfc = "caf\u{00e9}", nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd) // Swift equality alone is insufficient for a byte-exact grant.
        let package = try package(queries: [nfc], request: "onEnter(r){r.body={keys:Object.keys(r.query).length};}")
        let processor = try await approved([package]).processor
        let hidden = try await processor.process(.requestEnter, request: request(query: [nfd: "private"]), response: nil)
        XCTAssertEqual(try json(hidden), .object(["keys": .integer(0)]))
        let visible = try await processor.process(.requestEnter, request: request(query: [nfc: "granted"]), response: nil)
        XCTAssertEqual(try json(visible), .object(["keys": .integer(1)]))
    }

    func testDeniedBodyIsOmittedBeforeVMAdmissionAndDoesNotReturnMutation() async throws {
        let package = try package(bodyMode: "none", requestWrite: false, responseWrite: false,
                                  request: "onEnter(r){if('body' in r) return {actions:[]}; throw new Error('body absent');}",
                                  response: "onEnter(r){if('body' in r) return {actions:[]}; throw new Error('body absent');}")
        let processor = try await approved([package]).processor
        // A valid eligible JSON body whose field count would exceed the VM event-map quota if sent.
        let largeTree = JSONValue.object(Dictionary(uniqueKeysWithValues: (0 ..< 300).map { ("private\($0)", JSONValue.integer(1)) }))
        let body = try largeTree.data()
        XCTAssertLessThan(body.count, 24 * 1024)
        let req = request(body: body), res = response(body: body)
        for phase in [HTTPPluginPhase.requestEnter, .responseEnter] {
            do {
                _ = try await processor.process(phase, request: req, response: phase == .responseEnter ? res : nil)
                XCTFail("the callback's body-absent witness must run")
            } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .scriptError, "ungranted body must not consume event parsing quota") }
        }
        let emptyRequest = request(body: Data())
        let empty = try await processor.process(.requestEnter, request: emptyRequest, response: nil)
        XCTAssertNil(empty, "bodyless traffic is not newly admitted as a metadata hook")
    }

    func testAmbiguousDeclaredHeaderGrantCannotActivate() throws {
        XCTAssertThrowsError(try package(headers: ["X-Visible", "x-visible"])) { error in
            XCTAssertEqual(error as? AutomationError, .invalidManifest)
        }
    }

    func testCompositionResettingOriginalTreePreservesOriginalWireBytes() async throws {
        let a = try package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")),
                            request: "onEnter(r){r.body.limit=5;}")
        let b = try package(id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000B")),
                            request: "onEnter(r){r.body.limit=20;}")
        let processor = try await approved([b, a]).processor
        let wire = Data("{ \"limit\" : 20 }\n".utf8)
        let output = try await processor.process(.requestEnter, request: request(body: wire), response: nil)
        XCTAssertNil(output, "mutation flags cannot replace exact final JSON-tree equality")
    }
}

/// A deterministic consent seam pauses only a test thread at the third authorization check: after
/// the real VM returned, immediately before the adapter rereads the activation generation.
private final class PostVMGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let reached: XCTestExpectation
    private var calls = 0, released = false, timeout = false
    init(reached: XCTestExpectation) {
        self.reached = reached
    }

    var timedOut: Bool {
        condition.lock(); defer { condition.unlock() }; return timeout
    }

    var isReleased: Bool {
        condition.lock(); defer { condition.unlock() }; return released
    }

    func consent() -> Bool {
        condition.lock(); defer { condition.unlock() }
        calls += 1
        if calls == 3 {
            reached.fulfill()
            let deadline = Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until: deadline) {
                    timeout = true; break
                }
            }
        }
        return true
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class AdmissionOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var released = false
    var names: [String] {
        lock.withLock { values }
    }

    var ownerWasReleased: Bool {
        lock.withLock { released }
    }

    func append(_ name: String) {
        lock.withLock { values.append(name) }
    }

    func releaseOwner() {
        lock.withLock { released = true }
    }
}

private final class ConsentSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let deniedCheck: Int
    init(deniedCheck: Int) {
        self.deniedCheck = deniedCheck
    }

    func next() -> Bool {
        lock.withLock { calls += 1; return calls < deniedCheck }
    }
}
