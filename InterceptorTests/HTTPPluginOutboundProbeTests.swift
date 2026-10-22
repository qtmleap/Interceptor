#if DEBUG
import AutomationCore
import Darwin
import Foundation
@testable import Interceptor
import XCTest

private final class TicketFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var current: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class CloseObservation: @unchecked Sendable {
    var sawFinal = true, stagedBytes = Data()
}

final class HTTPPluginOutboundProbeTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var automation: URL { root.appendingPathComponent("Automation") }
    private let runID = UUID().uuidString.lowercased()
    private let nonce = "nonce-" + UUID().uuidString
    private var run: URL { automation.appendingPathComponent("OutboundProbe/\(runID)") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OutboundProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func snapshot(nonce: String? = nil, count: Int = 1) async throws -> PluginActivationSnapshot {
        let packages = try (0 ..< count).map { n in
            try OutboundAppFixtures.package(id: XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n + 1))))
        }.map { package -> PluginPackage in
            guard let nonce else { return package }
            var json = try JSONValue(parsing: package.bytes).objectValue!
            var manifest = json["manifest"]!.objectValue!
            manifest["settings"] = .object(["probeNonce": .string(nonce)])
            json["manifest"] = .object(manifest)
            return try PluginPackage.validate(JSONValue.object(json).data())
        }
        let (store, revisions) = try await AutomationFixtures.activationContext(packages: packages, activationURL: automation.appendingPathComponent("active.json"))
        var snapshot = try await store.snapshot()
        for r in revisions { snapshot = try await store.activate(r.package, revisionID: r.id, expectedGeneration: snapshot.generation) }
        return snapshot
    }

    private func writeOwnership(_ snapshot: PluginActivationSnapshot, extra: [String: JSONValue] = [:], runID: String? = nil) throws {
        var o: [String: JSONValue] = ["schemaVersion": .integer(1), "runID": .string(runID ?? self.runID), "nonce": .string(nonce),
                                      "packageSHA256": .string(snapshot.revisions[0].package.revision)]
        o.merge(extra) { $1 }
        try JSONValue.object(o).data().write(to: run.appendingPathComponent("ownership.json"))
    }

    private func make(_ snapshot: PluginActivationSnapshot?, id: String? = nil,
                      current: @escaping @Sendable () -> Bool = { true }) -> HTTPPluginOutboundProbe? {
        HTTPPluginOutboundProbe.make(options: [HTTPPluginOutboundProbe.optionKey: (id ?? runID) as NSString], snapshot: snapshot,
                                     activationURL: automation.appendingPathComponent("active.json"), isCurrent: current)
    }

    private func ready() async throws -> (PluginActivationSnapshot, HTTPPluginOutboundProbe) {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        return (s, try XCTUnwrap(make(s)))
    }

    private func receipt(_ name: String = "receipt.json") throws -> [String: JSONValue] {
        try XCTUnwrap(JSONValue(parsing: HTTPPluginOutboundProbe.readPayload(at: run.appendingPathComponent(name))).objectValue)
    }
    private func flush(_ p: HTTPPluginOutboundProbe, drained: Bool = true) async -> Bool { await p.finish(drained: drained) }

    private func readyInjecting(_ io: HTTPPluginOutboundProbe.CompletionIO) async throws -> HTTPPluginOutboundProbe {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        return try HTTPPluginOutboundProbe.open(runID: runID, snapshot: s, activationURL: automation.appendingPathComponent("active.json"),
                                                isCurrent: { true }, completionIO: io)
    }

    func testCompletionFsyncFailureLeavesNoFinalCompletion() async throws {
        let syncs = CallCounter()
        var io = HTTPPluginOutboundProbe.CompletionIO()
        io.sync = { _ in syncs.increment(); errno = EIO; return -1 }
        let p = try await readyInjecting(io)
        p.observer("profile", .response(200))
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(syncs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("completion.json").path))
        let before = try receipt()
        XCTAssertEqual(before["events"]?.arrayValue?.count, 1)
        let again = await flush(p)
        XCTAssertFalse(again)
        XCTAssertEqual(syncs.count, 1)
        XCTAssertEqual(try receipt(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("completion.json").path))
    }

    func testCompletionCloseFailureAfterClosingLeavesNoFinalCompletionAndIsNotRetried() async throws {
        let closes = CallCounter()
        var io = HTTPPluginOutboundProbe.CompletionIO()
        io.close = { fd in closes.increment(); _ = Darwin.close(fd); errno = EIO; return -1 }
        let p = try await readyInjecting(io)
        p.observer("profile", .response(200))
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(closes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("completion.json").path))
        let before = try receipt()
        XCTAssertEqual(before["events"]?.arrayValue?.count, 1)
        let again = await flush(p)
        XCTAssertFalse(again)
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(try receipt(), before)
    }

    private var stage: URL { run.appendingPathComponent(".completion.json.stage") }
    private var finalFile: URL { run.appendingPathComponent("completion.json") }
    private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    func testCompletionIsPublishedOnlyAfterCheckedCloseWithIdenticalBytesAndNoStageLeft() async throws {
        let closes = CallCounter()
        let seen = CloseObservation()
        var io = HTTPPluginOutboundProbe.CompletionIO()
        let stageURL = stage, finalURL = finalFile
        io.close = { fd in
            closes.increment()
            seen.sawFinal = FileManager.default.fileExists(atPath: finalURL.path)
            seen.stagedBytes = (try? Data(contentsOf: stageURL)) ?? Data()
            return Darwin.close(fd)
        }
        let p = try await readyInjecting(io)
        p.observer("profile", .response(200))
        let finished = await flush(p)
        XCTAssertTrue(finished)
        XCTAssertEqual(closes.count, 1)
        XCTAssertFalse(seen.sawFinal)
        XCTAssertFalse(seen.stagedBytes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: finalFile), seen.stagedBytes)
        XCTAssertFalse(exists(stage))
    }

    func testForeignStagingFileIsNeverModifiedAndBlocksCompletion() async throws {
        let p = try await readyInjecting(HTTPPluginOutboundProbe.CompletionIO())
        try Data("foreign".utf8).write(to: stage)
        let first = await flush(p)
        XCTAssertFalse(first)
        XCTAssertEqual(try Data(contentsOf: stage), Data("foreign".utf8))
        XCTAssertFalse(exists(finalFile))

    }

    func testStagingSymlinkIsNeverModifiedAndBlocksCompletion() async throws {
        let q = try await readyInjecting(HTTPPluginOutboundProbe.CompletionIO())
        let target = root.appendingPathComponent("target")
        try Data("t".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: target)
        let second = await flush(q)
        XCTAssertFalse(second)
        XCTAssertEqual(try Data(contentsOf: target), Data("t".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stage.path), target.path)
        XCTAssertFalse(exists(finalFile))
    }

    func testPreexistingFinalFailsExclusiveRenameAndOnlyOwnStageIsRemoved() async throws {
        let p = try await readyInjecting(HTTPPluginOutboundProbe.CompletionIO())
        try Data("foreign".utf8).write(to: finalFile)
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: finalFile), Data("foreign".utf8))
        XCTAssertFalse(exists(stage))
    }

    func testStageReplacedDuringSyncPreservesForeignFileAndPublishesNothing() async throws {
        var io = HTTPPluginOutboundProbe.CompletionIO()
        let stageURL = stage
        io.sync = { fd in
            _ = unlink(stageURL.path)
            try? Data("foreign".utf8).write(to: stageURL)
            return fsync(fd)
        }
        let p = try await readyInjecting(io)
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: stage), Data("foreign".utf8))
        XCTAssertFalse(exists(finalFile))
    }

    func testStageHardLinkedDuringCloseIsRejectedAndLinkPreserved() async throws {
        var io = HTTPPluginOutboundProbe.CompletionIO()
        let stageURL = stage, alias = root.appendingPathComponent("alias")
        io.close = { fd in _ = link(stageURL.path, alias.path); return Darwin.close(fd) }
        let p = try await readyInjecting(io)
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertFalse(exists(finalFile))
        XCTAssertTrue(exists(alias))
        XCTAssertTrue(exists(stage))
    }

    func testAnchorReplacedDuringSyncPublishesNothingAndKeepsForeignReceipt() async throws {
        var io = HTTPPluginOutboundProbe.CompletionIO()
        let receiptURL = run.appendingPathComponent("receipt.json")
        io.sync = { fd in
            _ = unlink(receiptURL.path)
            try? Data("foreign".utf8).write(to: receiptURL)
            return fsync(fd)
        }
        let p = try await readyInjecting(io)
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: receiptURL), Data("foreign".utf8))
        XCTAssertFalse(exists(finalFile))
        XCTAssertFalse(exists(stage))
    }

    func testInitialReceiptHasExactSchemaAndEventsAreOrderedStatusOnly() async throws {
        let (s, p) = try await ready()
        var r = try receipt()
        XCTAssertEqual(Set(r.keys), ["schemaVersion", "runID", "nonce", "packageSHA256", "events", "overflow"])
        XCTAssertEqual(r["events"], .array([]))
        XCTAssertEqual(r["overflow"], .bool(false))
        XCTAssertEqual(r["packageSHA256"], .string(s.revisions[0].package.revision))
        p.observer("profile", .response(200))
        p.observer("profile", .response(200))
        let finished = await flush(p)
        XCTAssertTrue(finished)
        r = try receipt()
        XCTAssertEqual(r["events"]?.arrayValue?.count, 2)
        XCTAssertEqual(r["events"]?.arrayValue?[0], .object(["binding": .string("profile"), "outcome": .string("response"), "status": .integer(200)]))
        XCTAssertEqual(try receipt("completion.json"), r)
        let permissions = try FileManager.default.attributesOfItem(atPath: run.appendingPathComponent("receipt.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testOverflowIsStickyAndBoundedAndInvalidInputsNeverBecomeSuccess() async throws {
        let (_, p) = try await ready()
        for _ in 0 ..< 12 { p.observer("profile", .response(200)) }
        p.observer("bad binding!", .response(200))
        p.observer("profile", .response(999))
        _ = await flush(p)
        let r = try receipt()
        XCTAssertEqual(r["events"]?.arrayValue?.count, 8)
        XCTAssertEqual(r["overflow"], .bool(true))
        XCTAssertLessThanOrEqual(try HTTPPluginOutboundProbe.readPayload(at: run.appendingPathComponent("receipt.json")).count, 4096)
    }

    func testInvalidStatusRecordsFailedNotSuccess() async throws {
        let (_, p) = try await ready()
        p.observer("profile", .response(99))
        _ = await flush(p)
        XCTAssertEqual(try receipt()["events"]?.arrayValue?.first?.objectValue?["outcome"], .string("failed"))
    }

    func testCancellationPayloadOmitsStatusField() async throws {
        let (_, p) = try await ready()
        p.observer("profile", .cancelled)
        _ = await flush(p)
        XCTAssertEqual(try receipt()["events"]?.arrayValue?.first,
                       .object(["binding": .string("profile"), "outcome": .string("cancelled")]))
    }

    func testPayloadIsSecretFree() async throws {
        let (_, p) = try await ready()
        p.observer("profile", .response(200))
        _ = await flush(p)
        let text = String(decoding: try HTTPPluginOutboundProbe.readPayload(at: run.appendingPathComponent("receipt.json")), as: UTF8.self)
        for forbidden in ["Bearer", "cookie", "authorization", "secondary.example.com", "http"] { XCTAssertFalse(text.contains(forbidden)) }
    }

    func testExpiredStartTicketMapsToCancelled() async throws {
        let flag = TicketFlag()
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        let p = try XCTUnwrap(make(s, current: { flag.current }))
        flag.current = false
        p.observer("profile", .response(200))
        _ = await flush(p)
        XCTAssertEqual(try receipt()["events"]?.arrayValue?.first?.objectValue?["outcome"], .string("cancelled"))
    }

    func testFinishCompletesOnceAndDropsLateCallbacks() async throws {
        let (_, p) = try await ready()
        p.observer("profile", .response(200))
        p.observer("profile", .response(204))
        let first = await flush(p), second = await flush(p, drained: false)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        p.observer("profile", .response(500))
        let again = await flush(p)
        XCTAssertTrue(again)
        XCTAssertEqual(try receipt()["events"]?.arrayValue?.count, 2)
        XCTAssertEqual(try receipt("completion.json")["events"]?.arrayValue?.count, 2)
        XCTAssertEqual(try receipt(), try receipt("completion.json"))
    }

    func testUndrainedFinishWritesNoCompletion() async throws {
        let (_, p) = try await ready()
        p.observer("profile", .response(200))
        let finished = await flush(p, drained: false)
        XCTAssertFalse(finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("completion.json").path))
    }

    func testPreexistingCompletionMakesFinishFailWithoutOverwrite() async throws {
        let (_, p) = try await ready()
        let completion = run.appendingPathComponent("completion.json")
        try Data("foreign".utf8).write(to: completion)
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: completion), Data("foreign".utf8))
    }

    func testReceiptReplacedByForeignInodeIsNeverOverwrittenAndPoisonsProof() async throws {
        let (_, p) = try await ready()
        let url = run.appendingPathComponent("receipt.json")
        try FileManager.default.removeItem(at: url)
        try Data("foreign".utf8).write(to: url)
        p.observer("profile", .response(200))
        let finished = await flush(p)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: url), Data("foreign".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("completion.json").path))
    }

    func testPreexistingReceiptRefused() async throws {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        let url = run.appendingPathComponent("receipt.json")
        try Data("old".utf8).write(to: url)
        XCTAssertNil(make(s))
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }

    func testSymlinkedReceiptOwnershipAndRunDirectoryRefused() async throws {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: run.appendingPathComponent("receipt.json"), withDestinationURL: target)
        XCTAssertNil(make(s))
        XCTAssertEqual(try Data(contentsOf: target), Data())
        try FileManager.default.removeItem(at: run.appendingPathComponent("receipt.json"))

        let ownership = run.appendingPathComponent("ownership.json")
        let real = root.appendingPathComponent("real-ownership.json")
        try FileManager.default.moveItem(at: ownership, to: real)
        try FileManager.default.createSymbolicLink(at: ownership, withDestinationURL: real)
        XCTAssertNil(make(s))
        try FileManager.default.removeItem(at: ownership)
        try FileManager.default.moveItem(at: real, to: ownership)

        let moved = root.appendingPathComponent("moved-run")
        try FileManager.default.moveItem(at: run, to: moved)
        try FileManager.default.createSymbolicLink(at: run, withDestinationURL: moved)
        XCTAssertNil(make(s))
    }

    func testHardLinkedOwnershipRefused() async throws {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        XCTAssertEqual(link(run.appendingPathComponent("ownership.json").path, root.appendingPathComponent("alias").path), 0)
        XCTAssertNil(make(s))
    }

    func testOwnershipMismatchesUnknownKeysAndOversizeRefused() async throws {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s, extra: ["nonce": .string("other")])
        XCTAssertNil(make(s))
        try writeOwnership(s, extra: ["packageSHA256": .string(String(repeating: "a", count: 64))])
        XCTAssertNil(make(s))
        try writeOwnership(s, extra: ["extra": .bool(true)])
        XCTAssertNil(make(s))
        try writeOwnership(s, extra: ["schemaVersion": .integer(2)])
        XCTAssertNil(make(s))
        try writeOwnership(s, extra: ["runID": .string(UUID().uuidString.lowercased())])
        XCTAssertNil(make(s))
        try writeOwnership(s, extra: ["nonce": .string(String(repeating: "n", count: 600))])
        XCTAssertNil(make(s))
        try Data("{".utf8).write(to: run.appendingPathComponent("ownership.json"))
        XCTAssertNil(make(s))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("receipt.json").path))
    }

    func testSettingsNonceMustMatchAndExactlyOneApprovedPackage() async throws {
        let wrong = try await snapshot(nonce: "different")
        try writeOwnership(wrong)
        XCTAssertNil(make(wrong))
        let none = try await snapshot()
        XCTAssertNil(make(none))
        let two = try await snapshot(nonce: nonce, count: 2)
        try writeOwnership(two)
        XCTAssertNil(make(two))
        XCTAssertNil(make(nil))
    }

    func testOptionMustBeCanonicalLowercaseUUIDString() async throws {
        let s = try await snapshot(nonce: nonce)
        try writeOwnership(s)
        XCTAssertNil(make(s, id: runID.uppercased()))
        XCTAssertNil(make(s, id: "../" + runID))
        XCTAssertNil(HTTPPluginOutboundProbe.make(options: nil, snapshot: s, activationURL: automation.appendingPathComponent("active.json"), isCurrent: { true }))
        XCTAssertNil(HTTPPluginOutboundProbe.make(options: [HTTPPluginOutboundProbe.optionKey: NSNumber(value: 1)], snapshot: s,
                                                  activationURL: automation.appendingPathComponent("active.json"), isCurrent: { true }))
    }
}
#endif
