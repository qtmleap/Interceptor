import XCTest
import CryptoKit
import SQLite3
@testable import AutomationStorage

final class TestKeys: WorkflowKeyProvider, @unchecked Sendable {
    let lock = NSLock()
    private var locked = false
    private var keys: [UUID: SymmetricKey] = [:]
    func setLocked(_ value: Bool) { lock.lock(); locked = value; lock.unlock() }
    func key(for grantID: UUID) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if locked { throw WorkflowStorageError.keyUnavailable }; let key = keys[grantID] ?? SymmetricKey(size: .bits256); keys[grantID] = key; return key
    }
}

final class WorkflowStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func fixture(mode: WorkflowMode = .notify, endpoint: Bool = false) throws -> (WorkflowStore, TestKeys, ActivationIdentity) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.sqlite")
        let keys = TestKeys()
        let store = try WorkflowStore(url: url, keys: keys)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let package = Data("immutable-package-secret".utf8)
        let identity = ActivationIdentity(pluginID: UUID(), grantID: UUID(), epoch: 1, packageRevision: WorkflowDigest.sha256(package), settingsRevision: "settings-1", settingsEpoch: 1, mode: mode, endpoint: endpoint ? EndpointIdentity(id: UUID(), revision: "endpoint-1", epoch: 1, credentialRevision: "credential-1") : nil)
        try store.activate(identity, package: package, configuration: Data("secret-config".utf8), now: now)
        return (store, keys, identity)
    }
    func approved(_ s: WorkflowStore, _ session: ExecutionSession, _ a: ActivationIdentity, time: Date? = nil) throws -> OperationSnapshot {
        let time = time ?? now
        let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data("secret-capture".utf8), session: session, now: time)
        let plan = Data("frozen-plan-secret".utf8)
        _ = try s.claimPlanning(op.id, session: session, now: time)
        _ = try s.freezePlan(op.id, activation: a, bytes: plan, session: session, now: time)
        return try s.approve(op.id, activation: a, digest: WorkflowDigest.plan(plan), now: time)
    }
    func testPlannerClaimedOnceBeforeExecution() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let bytes = Data("snapshot".utf8)
        let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: bytes, session: session, now: now)
        XCTAssertThrowsError(try s.freezePlan(op.id, activation: a, bytes: Data("plan".utf8), session: session, now: now))
        XCTAssertEqual(try s.claimPlanning(op.id, session: session, now: now), bytes)
        XCTAssertThrowsError(try s.claimPlanning(op.id, session: session, now: now))
    }
    func testApprovalCASAndDigestMismatch() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let event = UUID(); let op = try s.beginPlanning(eventID: event, activation: a, snapshot: Data(), session: session, now: now)
        XCTAssertEqual(try s.beginPlanning(eventID: event, activation: a, snapshot: Data(), session: session, now: now).id, op.id)
        let plan = Data("plan".utf8)
        _ = try s.claimPlanning(op.id, session: session, now: now)
        _ = try s.freezePlan(op.id, activation: a, bytes: plan, session: session, now: now)
        XCTAssertThrowsError(try s.approve(op.id, activation: a, digest: String(repeating: "0", count: 64), now: now))
        XCTAssertEqual(try s.approve(op.id, activation: a, digest: WorkflowDigest.plan(plan), now: now).state, .approved)
        XCTAssertEqual(try s.approve(op.id, activation: a, digest: WorkflowDigest.plan(plan), now: now).state, .approved)
        XCTAssertEqual(try s.frozenPlan(op.id, now: now), plan)
    }
    func testSoleOwnerAcrossInstancesAndCrashBoundaries() throws {
        let (s, keys, a) = try fixture(); let other = try WorkflowStore(url: s.url, keys: keys)
        var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        XCTAssertThrowsError(try other.acquireExecutionSession(now: now))
        let planned = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session!, now: now)
        let op = try approved(s, session!, a)
        XCTAssertNotNil(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session!, now: now))
        session = nil
        let next = try other.acquireExecutionSession(now: now)
        XCTAssertEqual(try other.operation(op.id)?.reason, .unknownOutcome)
        XCTAssertEqual(try other.operation(planned.id)?.reason, .quarantined)
        XCTAssertThrowsError(try other.claimAPI(op.id, activation: a, digest: op.planDigest!, session: next, now: now))
    }
    func testRevocationAndReplacementCannotReviveStaleEpoch() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session, a)
        try s.revoke(pluginID: a.pluginID, now: now)
        try s.prune(now: now)
        XCTAssertEqual(try s.operation(op.id)?.reason, .revoked)
        XCTAssertThrowsError(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now))
        XCTAssertThrowsError(try s.activate(a, package: Data("immutable-package-secret".utf8), configuration: Data(), now: now))
    }
    func testResultClaimedOnceAndInterruptedInvocationQuarantined() throws {
        let (s, _, a) = try fixture(); var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session!, a)
        _ = try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session!, now: now)
        try s.recordResponse(op.id, bytes: Data("response".utf8), session: session!, now: now)
        XCTAssertEqual(try s.claimResult(op.id, session: session!, now: now), Data("response".utf8))
        XCTAssertThrowsError(try s.claimResult(op.id, session: session!, now: now))
        session = nil; let next = try s.acquireExecutionSession(now: now); _ = next
        XCTAssertEqual(try s.operation(op.id)?.reason, .quarantined)
    }
    func testDeliveryRetriesKeepBytesUUIDAndEndpoint() throws {
        let (s, _, a) = try fixture(endpoint: true); let session = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session, a)
        _ = try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now)
        try s.recordResponse(op.id, bytes: Data(), session: session, now: now)
        _ = try s.claimResult(op.id, session: session, now: now)
        let bytes = Data("{\"secret\": 1}".utf8)
        let delivery = try s.queueDelivery(op.id, bytes: bytes, session: session, now: now)
        let first = try XCTUnwrap(s.claimDelivery(op.id, session: session, now: now))
        try s.finishDelivery(first, outcome: .transientFailure, session: session, now: now)
        let second = try XCTUnwrap(s.claimDelivery(op.id, session: session, now: now.addingTimeInterval(31)))
        XCTAssertEqual(first.deliveryID, second.deliveryID); XCTAssertEqual(delivery, second.deliveryID)
        XCTAssertEqual(second.bytes, bytes); XCTAssertEqual(second.endpoint, a.endpoint)
        XCTAssertEqual(second.idempotencyKey, delivery.uuidString)
        XCTAssertThrowsError(try s.finishDelivery(first, outcome: .success, session: session, now: now))
    }
    func testSharedRatesApplyToLocalOnlyAPIAndExternalAttempts() throws {
        let (s, _, a) = try fixture(mode: .automatic); let session = try s.acquireExecutionSession(now: now)
        let ops = try (0..<3).map { _ in try approved(s, session, a) }
        for op in ops.prefix(2) { XCTAssertNotNil(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now)) }
        XCTAssertNil(try s.claimAPI(ops[2].id, activation: a, digest: ops[2].planDigest!, session: session, now: now))
        XCTAssertEqual(try s.operation(ops[2].id)?.state, .approved)
        XCTAssertNotNil(try s.claimAPI(ops[2].id, activation: a, digest: ops[2].planDigest!, session: session, now: now.addingTimeInterval(6)))
    }
    func testPendingLimitsExpiryAndNoPlaintextOnDisk() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        for _ in 0..<32 {
            let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session, now: now)
            _ = try s.claimPlanning(op.id, session: session, now: now)
            _ = try s.freezePlan(op.id, activation: a, bytes: Data("plan-secret".utf8), session: session, now: now)
        }
        XCTAssertThrowsError(try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session, now: now))
        try s.prune(now: now.addingTimeInterval(901))
        XCTAssertTrue(try s.pending(now: now.addingTimeInterval(901)).isEmpty)
        let db = try Data(contentsOf: s.url)
        XCTAssertNil(db.range(of: Data("secret".utf8)))
    }
    func testLockedKeysAndWrongDigestLeaveActivationUnchanged() throws {
        let (s, keys, a) = try fixture()
        keys.setLocked(true)
        XCTAssertThrowsError(try s.activation(a))
        keys.setLocked(false)
        XCTAssertEqual(try s.activation(a).package, Data("immutable-package-secret".utf8))
        var bad = a; bad.epoch = 2; bad.packageRevision = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try s.activate(bad, package: Data("different".utf8), configuration: Data(), now: now))
        XCTAssertEqual(try s.activation(a).identity, a)
    }
    func testRecoveryEnumerationAndPendingReviewSurviveRestart() throws {
        let (s, _, a) = try fixture(); var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session!, now: now)
        let bytes = Data("review-plan".utf8)
        _ = try s.claimPlanning(op.id, session: session!, now: now)
        _ = try s.freezePlan(op.id, activation: a, bytes: bytes, session: session!, now: now)
        session = nil; session = try s.acquireExecutionSession(now: now)
        XCTAssertEqual(try s.activeActivations(), [a])
        XCTAssertEqual(try s.operations(session: session!, now: now).map(\.id), [op.id])
        XCTAssertEqual(try s.pending(now: now).map(\.id), [op.id])
        XCTAssertEqual(try s.frozenPlan(op.id, now: now), bytes)
    }
    func testDeliveryStatusExposesSchedulingWithoutPayload() throws {
        let (s, _, a) = try fixture(endpoint: true); let session = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session, a)
        _ = try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now)
        try s.recordResponse(op.id, bytes: Data(), session: session, now: now)
        _ = try s.claimResult(op.id, session: session, now: now)
        let id = try s.queueDelivery(op.id, bytes: Data("{}".utf8), session: session, now: now)
        let first = try XCTUnwrap(s.claimDelivery(op.id, session: session, now: now))
        XCTAssertEqual(try s.deliveryStatus(op.id)?.leaseDeadline, now.addingTimeInterval(10))
        try s.finishDelivery(first, outcome: .transientFailure, session: session, now: now)
        let status = try XCTUnwrap(s.deliveryStatus(op.id))
        XCTAssertEqual(status.deliveryID, id); XCTAssertEqual(status.attempts, 1)
        XCTAssertTrue((4.5...5.5).contains(status.nextAttemptAt.timeIntervalSince(now)))
        XCTAssertNil(status.leaseDeadline)
    }

    func testHistoryBoundAndSevenDayRetention() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        for i in 0..<1002 {
            let time = now.addingTimeInterval(Double(i))
            let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session, now: time)
            try s.finish(op.id, reason: .completed, session: session, now: time)
        }
        XCTAssertEqual(try s.history().count, 1000)
        try s.prune(now: now.addingTimeInterval(8 * 86400))
        XCTAssertTrue(try s.history().isEmpty)
    }
    func testOutboxCountAndBytesBound() throws {
        let (s, _, _) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let package = Data("small-package".utf8)
        for i in 0...256 {
            let time = now.addingTimeInterval(Double(i))
            let a = ActivationIdentity(pluginID: UUID(), grantID: UUID(), epoch: 1, packageRevision: WorkflowDigest.sha256(package), settingsRevision: "s1", settingsEpoch: 1, mode: .automatic, endpoint: EndpointIdentity(id: UUID(), revision: "e1", epoch: 1, credentialRevision: "c1"))
            try s.activate(a, package: package, configuration: Data(), now: time)
            let op = try approved(s, session, a, time: time)
            XCTAssertNotNil(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: time))
            try s.recordResponse(op.id, bytes: Data(), session: session, now: time)
            _ = try s.claimResult(op.id, session: session, now: time)
            if i == 256 {
                XCTAssertThrowsError(try s.queueDelivery(op.id, bytes: Data([1]), session: session, now: time))
                XCTAssertEqual(try s.operation(op.id)?.state, .resultReady)
            } else {
                _ = try s.queueDelivery(op.id, bytes: Data(repeating: 0x61, count: 32 * 1024), session: session, now: time)
            }
        }
    }
    func testLockedStartupAndWrongKeysCannotChangeState() throws {
        let (s, keys, a) = try fixture(); var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session!, a); session = nil
        keys.setLocked(true)
        XCTAssertThrowsError(try s.acquireExecutionSession(now: now))
        keys.setLocked(false)
        XCTAssertEqual(try s.operation(op.id)?.state, .approved)
        let wrongKeys = try WorkflowStore(url: s.url, keys: TestKeys())
        XCTAssertThrowsError(try wrongKeys.activation(a))
        XCTAssertThrowsError(try wrongKeys.acquireExecutionSession(now: now))
        XCTAssertEqual(try s.operation(op.id)?.state, .approved)
    }

    func testRevocationIsDurableWhileKeysLockedAndDeferredCleanup() throws {
        let (s, keys, a) = try fixture(endpoint: true); let session = try s.acquireExecutionSession(now: now)
        let pending = try approved(s, session, a)
        let ready = try approved(s, session, a)
        _ = try s.claimAPI(ready.id, activation: a, digest: ready.planDigest!, session: session, now: now)
        try s.recordResponse(ready.id, bytes: Data(), session: session, now: now)
        _ = try s.claimResult(ready.id, session: session, now: now)
        _ = try s.queueDelivery(ready.id, bytes: Data("{}".utf8), session: session, now: now)
        keys.setLocked(true)
        try s.revoke(pluginID: a.pluginID, now: now)
        XCTAssertEqual(try s.currentActivationEpoch(pluginID: a.pluginID), 2)
        XCTAssertThrowsError(try s.activation(a)) { XCTAssertEqual($0 as? WorkflowStorageError, .staleActivation) }
        XCTAssertThrowsError(try s.claimAPI(pending.id, activation: a, digest: pending.planDigest!, session: session, now: now)) { XCTAssertEqual($0 as? WorkflowStorageError, .staleActivation) }
        XCTAssertThrowsError(try s.claimDelivery(ready.id, session: session, now: now)) { XCTAssertEqual($0 as? WorkflowStorageError, .staleActivation) }
        XCTAssertThrowsError(try s.prune(now: now))
        keys.setLocked(false)
        XCTAssertThrowsError(try s.approve(pending.id, activation: a, digest: pending.planDigest!, now: now))
        XCTAssertThrowsError(try s.claimAPI(pending.id, activation: a, digest: pending.planDigest!, session: session, now: now))
        XCTAssertThrowsError(try s.claimDelivery(ready.id, session: session, now: now))
        XCTAssertEqual(try s.operation(pending.id)?.state, .approved) // Ciphertext retained until authorized cleanup.
        XCTAssertTrue(try s.activeActivations().isEmpty)
        try s.prune(now: now)
        XCTAssertEqual(try s.operation(pending.id)?.reason, .revoked)
        XCTAssertEqual(try s.operation(ready.id)?.reason, .revoked)
    }

    func testHistoryEvictionNeverMakesAnEventExecutableAgain() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let event = UUID()
        let original = try s.beginPlanning(eventID: event, activation: a, snapshot: Data(), session: session, now: now)
        try s.finish(original.id, reason: .completed, session: session, now: now)
        for i in 1...1001 {
            let time = now.addingTimeInterval(Double(i))
            let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session, now: time)
            try s.finish(op.id, reason: .completed, session: session, now: time)
        }
        let replay = try s.beginPlanning(eventID: event, activation: a, snapshot: Data(), session: session, now: now.addingTimeInterval(1002))
        XCTAssertEqual(replay.id, original.id)
        XCTAssertEqual(replay.state, .terminal)
        XCTAssertThrowsError(try s.claimPlanning(replay.id, session: session, now: now.addingTimeInterval(1002)))
    }

    func raw(_ s: WorkflowStore, _ sql: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(s.url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK)
    }
    func testConcurrentApprovalAndAPIPermitAcrossInstances() throws {
        let (s, keys, a) = try fixture(); let other = try WorkflowStore(url: s.url, keys: keys)
        let session = try s.acquireExecutionSession(now: now)
        let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: Data(), session: session, now: now)
        let plan = Data("plan".utf8)
        _ = try s.claimPlanning(op.id, session: session, now: now)
        _ = try s.freezePlan(op.id, activation: a, bytes: plan, session: session, now: now)
        let result = LockedResults()
        let time = now
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            do {
                let store = i.isMultiple(of: 2) ? s : other
                _ = try store.approve(op.id, activation: a, digest: WorkflowDigest.plan(plan), now: time)
                if try store.claimAPI(op.id, activation: a, digest: WorkflowDigest.plan(plan), session: session, now: time) != nil { result.addPermit() }
            } catch { result.addError(error) }
        }
        XCTAssertEqual(result.permits, 1)
        XCTAssertEqual(try s.operation(op.id)?.state, .apiInFlight)
    }
    func testConcurrentRevocationWinsAgainstFutureDispatch() throws {
        let (s, keys, a) = try fixture(); let other = try WorkflowStore(url: s.url, keys: keys)
        let session = try s.acquireExecutionSession(now: now); let op = try approved(s, session, a)
        try other.revoke(pluginID: a.pluginID, now: now)
        try other.prune(now: now)
        XCTAssertThrowsError(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now))
        XCTAssertEqual(try s.operation(op.id)?.reason, .revoked)
    }
    func testTransactionFailureRollsBackRateAndMarker() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session, a)
        try raw(s, "CREATE TRIGGER fail_write BEFORE UPDATE ON operations BEGIN SELECT RAISE(ABORT, 'test'); END")
        XCTAssertThrowsError(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now))
        XCTAssertEqual(try s.operation(op.id)?.state, .approved)
        try raw(s, "DROP TRIGGER fail_write")
        XCTAssertNotNil(try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session, now: now))
        let second = try approved(s, session, a)
        XCTAssertNotNil(try s.claimAPI(second.id, activation: a, digest: second.planDigest!, session: session, now: now))
    }
    func testTamperedActivationFailsClosedWithoutDeletingOperations() throws {
        let (s, _, a) = try fixture(); var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session!, a)
        // Corrupt ciphertext/metadata authentication, not a simulated key-provider failure.
        try raw(s, "UPDATE activations SET data=x'7b7d'")
        session = nil
        XCTAssertThrowsError(try s.acquireExecutionSession(now: now))
        XCTAssertEqual(try s.operation(op.id)?.state, .approved)
    }
    func testTamperedOperationFailsClosedAndNoResetOnReopen() throws {
        let (s, keys, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session, a)
        try raw(s, "UPDATE operations SET data=x'7b7d'")
        XCTAssertThrowsError(try s.operation(op.id))
        let reopened = try WorkflowStore(url: s.url, keys: keys)
        XCTAssertThrowsError(try reopened.operation(op.id))
    }
    func testGlobalBucketAndSharedDeliveryBucket() throws {
        let (s, _, a) = try fixture(endpoint: true); let session = try s.acquireExecutionSession(now: now)
        let first = try approved(s, session, a)
        _ = try s.claimAPI(first.id, activation: a, digest: first.planDigest!, session: session, now: now)
        try s.recordResponse(first.id, bytes: Data(), session: session, now: now)
        _ = try s.claimResult(first.id, session: session, now: now)
        _ = try s.queueDelivery(first.id, bytes: Data("{}".utf8), session: session, now: now)
        XCTAssertNotNil(try s.claimDelivery(first.id, session: session, now: now))
        let second = try approved(s, session, a)
        XCTAssertNil(try s.claimAPI(second.id, activation: a, digest: second.planDigest!, session: session, now: now))
        for i in 0..<3 {
            let package = Data("another-package".utf8)
            let b = ActivationIdentity(pluginID: UUID(), grantID: UUID(), epoch: 1, packageRevision: WorkflowDigest.sha256(package), settingsRevision: "s1", settingsEpoch: 1, mode: .automatic)
            try s.activate(b, package: package, configuration: Data(), now: now)
            let op = try approved(s, session, b)
            let permit = try s.claimAPI(op.id, activation: b, digest: op.planDigest!, session: session, now: now)
            if i < 2 { XCTAssertNotNil(permit) } else { XCTAssertNil(permit) }
        }
    }
    func testMaximumFiveDeliveryAttemptsAndRecoveryKeepsIdentity() throws {
        let (s, _, a) = try fixture(endpoint: true); var session: ExecutionSession? = try s.acquireExecutionSession(now: now)
        let op = try approved(s, session!, a)
        _ = try s.claimAPI(op.id, activation: a, digest: op.planDigest!, session: session!, now: now)
        try s.recordResponse(op.id, bytes: Data(), session: session!, now: now)
        _ = try s.claimResult(op.id, session: session!, now: now)
        let id = try s.queueDelivery(op.id, bytes: Data("immutable".utf8), session: session!, now: now)
        let first = try XCTUnwrap(s.claimDelivery(op.id, session: session!, now: now))
        session = nil
        session = try s.acquireExecutionSession(now: now.addingTimeInterval(11))
        var time = try XCTUnwrap(s.deliveryStatus(op.id)).nextAttemptAt
        for attempt in 2...5 {
            let delivery = try XCTUnwrap(s.claimDelivery(op.id, session: session!, now: time))
            XCTAssertEqual(delivery.deliveryID, id); XCTAssertEqual(delivery.bytes, first.bytes); XCTAssertEqual(delivery.attempt, attempt)
            try s.finishDelivery(delivery, outcome: .transientFailure, session: session!, now: time)
            if attempt < 5 { time = try XCTUnwrap(s.deliveryStatus(op.id)).nextAttemptAt }
        }
        XCTAssertEqual(try s.operation(op.id)?.reason, .exhausted)
    }
    func testPendingByteCapAndPlanDigestDomain() throws {
        let (s, _, a) = try fixture(); let session = try s.acquireExecutionSession(now: now)
        let bytes = Data(repeating: 0x71, count: 192 * 1024)
        for _ in 0..<5 {
            let op = try s.beginPlanning(eventID: UUID(), activation: a, snapshot: bytes, session: session, now: now)
            _ = try s.claimPlanning(op.id, session: session, now: now)
            _ = try s.freezePlan(op.id, activation: a, bytes: bytes, session: session, now: now)
        }
        XCTAssertThrowsError(try s.beginPlanning(eventID: UUID(), activation: a, snapshot: bytes, session: session, now: now))
        XCTAssertNotEqual(WorkflowDigest.plan(bytes), WorkflowDigest.sha256(bytes))
    }

}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var errors: [Error] = []
    var permits: Int { lock.lock(); defer { lock.unlock() }; return count }
    func addPermit() { lock.lock(); count += 1; lock.unlock() }
    func addError(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
}
