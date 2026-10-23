import AutomationCore
import Foundation

/// A synchronous, bounded admission boundary. An overload never queues work behind the original traffic.
final class HTTPPluginOutboundDispatcher: @unchecked Sendable {
    typealias Observer = @Sendable (String, HTTPPluginOutboundOutcome) -> Void
    private struct Entry { var task: Task<Void, Never>? }
    private let lock = NSLock()
    private let transport: any HTTPPluginOutboundTransport
    private let observer: Observer?
    private var entries: [UUID: Entry] = [:]
    private var invalidated = false
    private var pendingCallbacks = 0
    private var drainWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private static let capacity = 4

    init(transport: any HTTPPluginOutboundTransport = HTTPPluginDirectTransport(), observer: Observer? = nil) {
        self.transport = transport
        self.observer = observer
    }

    var isActive: Bool { lock.withLock { !invalidated } }

    /// Reserves slots before creating tasks; suspended DNS/TLS work can never create an unbounded mailbox.
    @discardableResult
    func submit(_ intents: [PluginOutboundIntent], isAuthorized: @escaping @Sendable () async -> Bool) -> Int {
        var admitted = 0
        for intent in intents {
            let decision: (id: UUID?, notify: Bool) = lock.withLock {
                // No new callbacks after shutdown can extend an already completed drain.
                guard !invalidated else { return (nil, false) }
                guard entries.count < Self.capacity else {
                    pendingCallbacks += 1
                    return (nil, true)
                }
                let id = UUID()
                entries[id] = Entry()
                return (id, false)
            }
            guard let id = decision.id else {
                if decision.notify {
                    observer?(intent.binding, .rejected)
                    callbackFinished()
                }
                continue
            }
            admitted += 1
            let task = Task { [self] in
                let authorization: @Sendable () async -> Bool = { [self] in
                    guard !Task.isCancelled, isLive(id), await isAuthorized() else { return false }
                    return !Task.isCancelled && isLive(id)
                }
                let outcome: HTTPPluginOutboundOutcome
                if await authorization() {
                    outcome = await transport.perform(
                        HTTPPluginOutboundRequest(host: intent.endpoint.host, path: intent.endpoint.path, headers: intent.headers),
                        isAuthorized: authorization,
                    )
                } else {
                    outcome = Task.isCancelled || !isLive(id) ? .cancelled : .rejected
                }
                finish(id, binding: intent.binding, outcome: outcome)
            }
            let retained = lock.withLock {
                // The task can finish, or shutdown can run, before this installation.
                guard !invalidated, entries[id] != nil else { return false }
                entries[id]?.task = task
                return true
            }
            if !retained { task.cancel() }
        }
        return admitted
    }

    /// Permanent invalidation also covers tasks whose reserved slot has not installed its Task yet.
    func shutdown() {
        let tasks = lock.withLock {
            invalidated = true
            let tasks = entries.values.compactMap(\.task)
            return tasks
        }
        for task in tasks { task.cancel() }
    }

    private func isLive(_ id: UUID) -> Bool { lock.withLock { !invalidated && entries[id] != nil } }

    private func finish(_ id: UUID, binding: String, outcome: HTTPPluginOutboundOutcome) {
        let cancelled = lock.withLock {
            entries.removeValue(forKey: id)
            pendingCallbacks += 1
            return invalidated
        }
        observer?(binding, cancelled ? .cancelled : outcome)
        callbackFinished()
    }

    /// Bounded cleanup proof: cancellation alone does not mean the Task or its observer finished.
    /// Call after shutdown. A timeout/cancelled waiter is never evidence of a completed drain.
    func waitUntilStopped(timeoutNanoseconds: UInt64 = 4_000_000_000) async -> Bool {
        guard lock.withLock({ invalidated }) else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForDrain() }
            group.addTask {
                do { try await Task.sleep(nanoseconds: min(timeoutNanoseconds, 4_000_000_000)) }
                catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func waitForDrain() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if Task.isCancelled { return false }
                    if entries.isEmpty, pendingCallbacks == 0 { return true }
                    drainWaiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.drainWaiters.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }

    private func callbackFinished() {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            pendingCallbacks -= 1
            guard invalidated, entries.isEmpty, pendingCallbacks == 0 else { return [] }
            let waiters = Array(drainWaiters.values)
            drainWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }
}
