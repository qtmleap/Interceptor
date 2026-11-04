import Foundation
import XCTest
import AutomationCore
@testable import AutomationRuntime

final class WorkflowExecutorTests: XCTestCase {
    let operation = UUID()
    let event = Data(#"{"id":"11111111-1111-1111-1111-111111111111","exchangeID":"22222222-2222-2222-2222-222222222222","phase":"request.completed","time":"2026-10-18T10:00:00Z","request":{}}"#.utf8)
    let config = Data(#"{"settings":{},"endpoints":{}}"#.utf8)
    func testSeparatePlanningAndResultStages() async throws {
        let runner = WorkflowJavaScriptExecutor()
        let source = "function onRequest(){return {actions:[{type:'sameOrigin',method:'POST',path:'/api',body:{mode:'raw',base64:'" + Data(repeating: 1, count: 32768).base64EncodedString() + "',contentType:'application/octet-stream'}}]}}"
        let output = try await runner.run(source: source, stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: operation)
        XCTAssertEqual(try WorkflowPlanningResult(parsing: output).intent?.wireBody?.count, 32768)
        do {
            _ = try await JavaScriptExecutor().run(source: source, hook: .request, eventJSON: Data("{}".utf8), configJSON: Data("{}".utf8))
            XCTFail("v1 must reject sameOrigin")
        } catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidResult) }
        let resultEvent = Data(#"{"operationID":"11111111-1111-1111-1111-111111111111","eventID":"11111111-1111-1111-1111-111111111111","exchangeID":"22222222-2222-2222-2222-222222222222","phase":"http.result","time":"2026-10-18T10:00:00Z","request":{},"response":{"status":500}}"#.utf8)
        let endpoint = UUID()
        let cfg = Data("{\"settings\":{},\"endpoints\":{\"result\":\"\(endpoint.uuidString)\"}}".utf8)
        let result = try await runner.run(source: "function onHTTPResult(event,config){return {actions:[{type:'webhook',endpointId:config.endpoints.result,json:{status:event.response.status}}]}}", stage: .httpResult, inputJSON: resultEvent, configJSON: cfg, operationID: operation)
        XCTAssertEqual(try WorkflowResult(parsing: result, endpointID: endpoint).delivery?.json, .object(["status": .integer(500)]))
        let local = try await runner.run(source: "function onHTTPResult(e,c){if(Object.keys(c.endpoints).length) throw Error();return {actions:[]}}", stage: .httpResult, inputJSON: resultEvent, configJSON: config, operationID: operation)
        XCTAssertNil(try WorkflowResult(parsing: local, endpointID: nil).delivery)
    }
    func testRejectsUnknownAndAccessorProxyPromiseShapes() async throws {
        let runner = WorkflowJavaScriptExecutor()
        for value in ["{actions:[],extra:1}", "{get actions(){while(true){}}}", "new Proxy({actions:[]},{ownKeys(){while(true){}}})", "Promise.resolve({actions:[]})", "{actions:[{type:'sameOrigin',method:'GET',path:'/',callback:'evil'}]}"] {
            do { _ = try await runner.run(source: "function onRequest(){return \(value)}", stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: operation); XCTFail(value) }
            catch { XCTAssertEqual(error as? JavaScriptExecutionError, .invalidResult, value) }
        }
    }
}

extension WorkflowExecutorTests {
    func testOperationCancellationAndBoundedAdmission() async throws {
        let runner = WorkflowJavaScriptExecutor(), firstID = UUID(), secondID = UUID()
        let event = event, config = config
        let first = Task { try await runner.run(source: "function onRequest(){while(true){}}", stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: firstID) }
        try await Task.sleep(for: .milliseconds(5))
        let second = Task { try await runner.run(source: "function onRequest(){return {actions:[]}}", stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: secondID) }
        try await Task.sleep(for: .milliseconds(5))
        do { _ = try await runner.run(source: "function onRequest(){return {actions:[]}}", stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: UUID()); XCTFail("third admission must reject") }
        catch { XCTAssertEqual(error as? JavaScriptExecutionError, .busy) }
        runner.cancel(operationID: UUID()) // Unrelated cancellation cannot stop either owner.
        runner.cancel(operationID: firstID)
        do { _ = try await first.value; XCTFail("cancelled owner") }
        catch { XCTAssertEqual(error as? JavaScriptExecutionError, .cancelled) }
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, Data(#"{"actions":[]}"#.utf8))
        // A late cancellation cannot poison the next stage of the same operation.
        runner.cancel(operationID: firstID)
        _ = try await runner.run(source: "function onRequest(){return {actions:[]}}", stage: .requestPlanning, inputJSON: event, configJSON: config, operationID: firstID)
    }

    func testInputAndResultEnvelopeBoundaries() async throws {
        let runner = WorkflowJavaScriptExecutor()
        let prefix = #"{"id":"11111111-1111-1111-1111-111111111111","exchangeID":"22222222-2222-2222-2222-222222222222","phase":"request.completed","time":"2026-10-18T10:00:00Z","request":{"body":{"state":"complete","mode":"jsonPointers","values":[{"pointer":"/a","found":true,"value":""#
        let suffix = #""}]}}}"#
        for delta in [-1, 0, 1] {
            let length = WorkflowLimits.inputBytes + delta
            let input = Data((prefix + String(repeating: "a", count: length - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
            XCTAssertEqual(input.count, length)
            do {
                _ = try await runner.run(source: "function onRequest(){return {actions:[]}}", stage: .requestPlanning, inputJSON: input, configJSON: config, operationID: UUID())
                XCTAssertLessThanOrEqual(delta, 0)
            } catch { XCTAssertEqual(delta, 1, "\(error)") }
        }
        let endpoint = UUID()
        let cfg = Data("{\"settings\":{},\"endpoints\":{\"result\":\"\(endpoint.uuidString)\"}}".utf8)
        let input = Data(#"{"operationID":"11111111-1111-1111-1111-111111111111","eventID":"11111111-1111-1111-1111-111111111111","exchangeID":"22222222-2222-2222-2222-222222222222","phase":"http.result","time":"2026-10-18T10:00:00Z","request":{},"response":{}}"#.utf8)
        let overhead = "{\"actions\":[{\"type\":\"webhook\",\"endpointId\":\"\(endpoint.uuidString)\",\"json\":\"\"}]}".utf8.count
        for delta in [-1, 0, 1] {
            let count = WorkflowLimits.resultBytes + delta - overhead
            let src = "function onHTTPResult(e,c){return {actions:[{type:'webhook',endpointId:c.endpoints.result,json:'a'.repeat(\(count))}]}}"
            do {
                let result = try await runner.run(source: src, stage: .httpResult, inputJSON: input, configJSON: cfg, operationID: UUID())
                XCTAssertEqual(result.count, WorkflowLimits.resultBytes + delta); XCTAssertLessThanOrEqual(delta, 0)
            } catch { XCTAssertEqual(delta, 1, "\(error)") }
        }
    }
}
