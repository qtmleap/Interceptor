import Foundation

/// Serializes tunnel start/stop work and owns start-ticket validity.
///
/// A ticket is issued synchronously, before any suspension, so a later stop or newer start
/// invalidates it immediately. Global operations run strictly in invocation order on a tail
/// task chain; there is no check-then-await window between them. Registered shutdown actions
/// are always invoked outside the lock.
final class TunnelLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    private var shutdown: (@Sendable () -> Void)?
    private var tail: Task<Void, Never>?

    func isCurrent(_ ticket: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == ticket
    }

    /// Synchronous installation and invalidation cannot pass one another.
    /// The action must not call back into this coordinator or suspend.
    func installIfCurrent(_ ticket: UUID, _ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == ticket else { return false }
        action()
        return true
    }

    struct Start: Sendable {
        let ticket: UUID
        let task: Task<Void, Error>
    }

    /// Ticket admission and queue insertion share one lock: a stop cannot be
    /// reordered between them, even when framework callbacks use different threads.
    func start(_ operation: @escaping @Sendable (UUID) async throws -> Void) -> Start {
        let ticket = UUID()
        lock.lock()
        let old = shutdown
        current = ticket
        shutdown = nil
        let previous = tail
        let task = Task<Void, Error> {
            await previous?.value
            try await operation(ticket)
        }
        tail = Task { _ = await task.result }
        lock.unlock()
        old?()
        return Start(ticket: ticket, task: task)
    }

    /// Registers the processor shutdown for the ticket only if it is still current.
    /// A stale ticket runs `shutdown` immediately and returns false.
    @discardableResult
    func attach(_ ticket: UUID, shutdown action: (@Sendable () -> Void)?) -> Bool {
        lock.lock()
        let valid = current == ticket
        if valid { shutdown = action }
        lock.unlock()
        if !valid { action?() }
        return valid
    }

    /// Invalidates `ticket` only if it is still current (failed-start cleanup).
    func invalidate(_ ticket: UUID) {
        lock.lock()
        let old: (@Sendable () -> Void)?
        if current == ticket { old = shutdown; current = nil; shutdown = nil } else { old = nil }
        lock.unlock()
        old?()
    }

    /// Synchronously invalidates, then enqueues `cleanup` after all earlier operations.
    /// With `expected`, a stale ticket is ignored and nil is returned without enqueuing.
    func stop(expected: UUID? = nil, cleanup: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.lock()
        if let expected, current != expected {
            lock.unlock()
            return nil
        }
        let old = shutdown
        current = nil
        shutdown = nil
        let previous = tail
        let task = Task<Void, Never> {
            await previous?.value
            await cleanup()
        }
        tail = task
        lock.unlock()
        old?()
        return task
    }
}
