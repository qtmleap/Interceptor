import Foundation

/// Tracked background runner for fetch-capable hooks. At most one job is active per processor;
/// extras are rejected without queueing. The slot is reserved before the Task exists, so shutdown
/// and an immediately finishing Task are safe in either order.
final class HTTPPluginFetchDispatcher: @unchecked Sendable {
    enum Completion: Sendable, Equatable {
        case completed
        case failed
        case cancelled
        case rejected
    }

    /// Test-only visibility; never receives bodies, tokens or secret-bearing errors.
    typealias Observer = @Sendable (Completion) -> Void

    private let lock = NSLock()
    private let observer: Observer?
    private var active: UUID?
    private var task: Task<Void, Never>?
    private var invalidated = false
    private var drainWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(observer: Observer? = nil) {
        self.observer = observer
    }

    var isActive: Bool {
        lock.withLock { !invalidated }
    }

    /// `work` returns normally on success and throws on any failure; `CancellationError` maps to `.cancelled`.
    /// It must stop its own non-Task resources (the fetch executor) when its Task is cancelled.
    @discardableResult
    func submit(_ work: @escaping @Sendable () async throws -> Void) -> Bool {
        let id = UUID()
        let admitted = lock.withLock {
            guard !invalidated, active == nil else { return false }
            active = id
            return true
        }
        guard admitted else {
            observer?(.rejected)
            return false
        }
        let job = Task { [self] in
            let completion: Completion
            do {
                try await work()
                completion = Task.isCancelled || !isLive(id) ? .cancelled : .completed
            } catch is CancellationError {
                completion = .cancelled
            } catch {
                completion = Task.isCancelled || !isLive(id) ? .cancelled : .failed
            }
            finish(id, completion)
        }
        let retained = lock.withLock {
            // The Task can finish, or shutdown can run, before this installation.
            guard !invalidated, active == id else { return false }
            task = job
            return true
        }
        if !retained {
            job.cancel()
        }
        return true
    }

    func shutdown() {
        let job = lock.withLock {
            invalidated = true
            return task
        }
        job?.cancel()
    }

    private func isLive(_ id: UUID) -> Bool {
        lock.withLock { !invalidated && active == id }
    }

    private func finish(_ id: UUID, _ completion: Completion) {
        observer?(completion)
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            if active == id {
                active = nil
                task = nil
            }
            guard invalidated, active == nil else { return [] }
            let waiters = Array(drainWaiters.values)
            drainWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    /// Bounded cleanup proof. Call after `shutdown`; a timeout is never evidence of a drain.
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
                    if Task.isCancelled {
                        return false
                    }
                    if active == nil {
                        return true
                    }
                    drainWaiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.drainWaiters.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }
}
