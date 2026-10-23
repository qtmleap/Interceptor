@testable import Interceptor
import XCTest

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private actor Log {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func hit() { lock.lock(); count += 1; lock.unlock() }
}

final class TunnelLifecycleTests: XCTestCase {
    func testStopBeforeInstallInvalidatesTicketAndShutsDownLateProcessor() async {
        let lifecycle = TunnelLifecycle()
        let ticket = lifecycle.start { _ in }.ticket
        let stop = lifecycle.stop { }
        XCTAssertFalse(lifecycle.isCurrent(ticket))
        let shutdowns = Flag()
        XCTAssertFalse(lifecycle.attach(ticket) { shutdowns.hit() })
        XCTAssertEqual(shutdowns.calls, 1)
        await stop?.value
    }

    func testStartsRunInInvocationOrderAndOldFailureCleansUpBeforeNewGlobalStart() async {
        let lifecycle = TunnelLifecycle()
        let log = Log()
        let gate = Gate()
        let startA = lifecycle.start { a in
            await log.add("A.start")
            await gate.wait()
            lifecycle.invalidate(a)
            await log.add("A.cleanup")
            throw CancellationError()
        }
        let a = startA.ticket
        let startB = lifecycle.start { _ in await log.add("B.start") }
        let b = startB.ticket
        XCTAssertFalse(lifecycle.isCurrent(a))
        XCTAssertTrue(lifecycle.isCurrent(b))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let beforeRelease = await log.events
        XCTAssertEqual(beforeRelease, ["A.start"])
        await gate.release()
        _ = await startA.task.result
        try? await startB.task.value
        let events = await log.events
        XCTAssertEqual(events, ["A.start", "A.cleanup", "B.start"])
        XCTAssertTrue(lifecycle.isCurrent(b), "stale failure cleanup must not invalidate the newer ticket")
    }

    func testSupersedingStartShutsDownOldProcessorImmediately() {
        let lifecycle = TunnelLifecycle()
        let a = lifecycle.start { _ in }.ticket
        let shutdowns = Flag()
        XCTAssertTrue(lifecycle.attach(a) { shutdowns.hit() })
        _ = lifecycle.start { _ in }.ticket
        XCTAssertEqual(shutdowns.calls, 1)
    }

    func testOnlyCurrentTicketCanInstallProcessorOrMonitor() async {
        let lifecycle = TunnelLifecycle()
        let old = lifecycle.start { _ in }.ticket
        let current = lifecycle.start { _ in }.ticket
        let installs = Flag()
        XCTAssertFalse(lifecycle.installIfCurrent(old) { installs.hit() })
        XCTAssertTrue(lifecycle.installIfCurrent(current) { installs.hit() })
        let stop = lifecycle.stop { }
        XCTAssertFalse(lifecycle.installIfCurrent(current) { installs.hit() })
        XCTAssertEqual(installs.calls, 1)
        await stop?.value
    }

    func testStopShutsDownProcessorWhileStartupIsStalledAndDeniesDelivery() async {
        let lifecycle = TunnelLifecycle()
        let gate = Gate()
        let start = lifecycle.start { _ in await gate.wait() }
        let ticket = start.ticket
        let consent: @Sendable () -> Bool = { lifecycle.isCurrent(ticket) }
        let shutdowns = Flag()
        lifecycle.attach(ticket) { shutdowns.hit() }
        XCTAssertTrue(consent())
        let stop = lifecycle.stop { }
        XCTAssertEqual(shutdowns.calls, 1)
        XCTAssertFalse(consent())
        await gate.release()
        try? await start.task.value
        await stop?.value
        XCTAssertEqual(shutdowns.calls, 1)
    }

    func testStaleExpectedStopIsIgnored() async {
        let lifecycle = TunnelLifecycle()
        let old = lifecycle.start { _ in }.ticket
        let new = lifecycle.start { _ in }.ticket
        let ran = Flag()
        XCTAssertNil(lifecycle.stop(expected: old) { ran.hit() })
        XCTAssertTrue(lifecycle.isCurrent(new))
        let stop = lifecycle.stop(expected: new) { ran.hit() }
        XCTAssertNotNil(stop)
        await stop?.value
        XCTAssertEqual(ran.calls, 1)
        XCTAssertFalse(lifecycle.isCurrent(new))
    }

    func testStopCleanupRunsAfterStartBodyAndBeforeNewerStart() async {
        let lifecycle = TunnelLifecycle()
        let log = Log()
        let gate = Gate()
        let a = lifecycle.start { _ in await gate.wait(); await log.add("A") }
        let stop = lifecycle.stop { await log.add("stop") }
        let b = lifecycle.start { _ in await log.add("B") }
        await gate.release()
        await stop?.value
        try? await a.task.value
        try? await b.task.value
        let events = await log.events
        XCTAssertEqual(events, ["A", "stop", "B"])
    }
}
