import Foundation
import CryptoKit

/// Protected operational store. Callers validate schemas, package trust and frozen wire scopes before activation/dispatch.
/// All opaque payloads are bounded and encrypted. Methods perform no JS, network or Keychain writes.
public final class WorkflowStore: @unchecked Sendable {
    public let url: URL
    private let keys: any WorkflowKeyProvider
    private let db: SQLiteDatabase
    private let mutex = NSLock()
    private static let ttl: TimeInterval = 900
    private static let maxOperationBytes = 2 * 1024 * 1024
    private static let maxOutboxBytes = 8 * 1024 * 1024
    private static let maxPackageBytes = 256 * 1024
    private static let maxPayloadBytes = 192 * 1024
    private static let maxPlanBytes = 512 * 1024

    struct Authenticated: Codable { let grant: UUID; let bytes: Data; let tag: Data }
    struct Activation: Codable { let identity: ActivationIdentity; let package: Data; let configuration: Data }
    struct Delivery: Codable {
        let id: UUID; let payload: Data; let digest: String; let size: Int
        let created: Date; let expires: Date
        var attempts: Int = 0; var next: Date
        var lease: UUID?; var leaseEnd: Date?; var owner: UUID?
    }
    struct Operation: Codable {
        let id: UUID; let event: UUID; let activation: ActivationIdentity
        let created: Date; let expires: Date
        var state: OperationState = .planning
        var snapshot: Data
        var plan: Data?; var digest: String?; var response: Data?
        var planningStarted = false; var resultStarted = false; var owner: UUID
        var delivery: Delivery?
        var byteCount: Int
        var key: String { "\(event.uuidString)|\(activation.id.uuidString)|\(activation.epoch)" }
        var view: OperationSnapshot { .init(id: id, eventID: event, activation: activation, state: state, planDigest: digest, createdAt: created, expiresAt: expires, reason: nil) }
    }
    struct AAD: Codable {
        let domain: String; let activation: ActivationIdentity; let operation: UUID?
        let purpose: String; let digest: String?
    }

    public init(url: URL, keys: any WorkflowKeyProvider) throws {
        guard url.isFileURL else { throw WorkflowStorageError.invalidInput }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw WorkflowStorageError.invalidInput }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath(); self.keys = keys
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The caller supplies an App Group directory; do not follow a pre-existing database symlink.
        if (try? self.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw WorkflowStorageError.invalidInput }
        db = try SQLiteDatabase(url: self.url)
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("PRAGMA secure_delete=ON")
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA wal_autocheckpoint=256")
        try db.execute("PRAGMA journal_size_limit=4194304")
        // 48 MiB database cap plus bounded WAL and SHM. No generic long-lived read transactions are exposed.
        let pageSize = try db.query("PRAGMA page_size").first?.first?.int ?? 4096
        guard pageSize >= 512, pageSize <= 65536 else { throw WorkflowStorageError.corruptStore }
        try db.execute("PRAGMA max_page_count=\(48 * 1024 * 1024 / pageSize)")
        try db.transaction {
            let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
            guard version == 0 || version == 1 else { throw WorkflowStorageError.unsupportedVersion }
            if version == 0 {
                try db.execute("CREATE TABLE epochs (plugin TEXT PRIMARY KEY, epoch INTEGER NOT NULL, active INTEGER NOT NULL)")
                try db.execute("CREATE TABLE activations (plugin TEXT PRIMARY KEY, epoch INTEGER NOT NULL, data BLOB NOT NULL)")
                try db.execute("CREATE TABLE operations (id TEXT PRIMARY KEY, unique_key TEXT NOT NULL UNIQUE, plugin TEXT NOT NULL, epoch INTEGER NOT NULL, state TEXT NOT NULL, expires REAL NOT NULL, pending_bytes INTEGER NOT NULL, delivery_bytes INTEGER NOT NULL, leased INTEGER NOT NULL, data BLOB NOT NULL)")
                try db.execute("CREATE INDEX operations_expiry ON operations(expires)")
                try db.execute("CREATE INDEX operations_plugin ON operations(plugin)")
                try db.execute("CREATE TABLE admissions (unique_key TEXT PRIMARY KEY, id TEXT NOT NULL, plugin TEXT NOT NULL, epoch INTEGER NOT NULL, created REAL NOT NULL, expires REAL NOT NULL)")
                try db.execute("CREATE INDEX admissions_epoch ON admissions(plugin,epoch)")
                try db.execute("CREATE TABLE history (id TEXT PRIMARY KEY, unique_key TEXT UNIQUE NOT NULL, time REAL NOT NULL, data BLOB NOT NULL)")
                try db.execute("CREATE TABLE rates (id TEXT PRIMARY KEY, tokens REAL NOT NULL, time REAL NOT NULL)")
                try db.execute("PRAGMA user_version=1")
            }
        }
        try protectFiles()
        let check = try db.query("PRAGMA quick_check(1)")
        guard case .text("ok")? = check.first?.first else { throw WorkflowStorageError.corruptStore }
    }

    /// Explicit activation only. Merely opening/importing a package never calls this method.
    /// Epoch must strictly increase even after revocation; immutable IDs may not be reused.
    public func activate(_ identity: ActivationIdentity, package: Data, configuration: Data, now: Date) throws {
        try locked {
            try validate(identity); try validateTime(now)
            guard !package.isEmpty, package.count <= Self.maxPackageBytes, configuration.count <= 64 * 1024 else { throw WorkflowStorageError.capacity }
            guard WorkflowDigest.sha256(package) == identity.packageRevision else { throw WorkflowStorageError.hashMismatch }
            let sealedPackage = try seal(package, identity, purpose: "package")
            let sealedConfig = try seal(configuration, identity, purpose: "configuration")
            let record = try encodeAuthenticated(Activation(identity: identity, package: sealedPackage, configuration: sealedConfig), grant: identity.grantID)
            try db.transaction {
                let epoch = try currentEpoch(identity.pluginID)
                guard identity.epoch > epoch else { throw WorkflowStorageError.staleActivation }
                // Replacing the epoch invalidates old work without needing its old grant keys.
                try db.execute("INSERT INTO epochs VALUES (?,?,1) ON CONFLICT(plugin) DO UPDATE SET epoch=excluded.epoch,active=1", [.text(identity.pluginID.uuidString), .integer(identity.epoch)])
                try db.execute("INSERT INTO activations VALUES (?,?,?) ON CONFLICT(plugin) DO UPDATE SET epoch=excluded.epoch,data=excluded.data", [.text(identity.pluginID.uuidString), .integer(identity.epoch), .blob(record)])
                try trimHistory(now)
            }
        }
    }

    public func activation(_ identity: ActivationIdentity) throws -> ActivationSnapshot {
        try locked {
            let record = try requireActivation(identity)
            let package = try open(record.package, identity, purpose: "package")
            guard WorkflowDigest.sha256(package) == identity.packageRevision else { throw WorkflowStorageError.hashMismatch }
            return ActivationSnapshot(identity: identity, package: package, configuration: try open(record.configuration, identity, purpose: "configuration"))
        }
    }

    public func revoke(pluginID: UUID, now: Date) throws {
        try locked {
            try validateTime(now)
            try db.transaction {
                let epoch = try currentEpoch(pluginID)
                guard epoch < Int64.max else { throw WorkflowStorageError.invalidInput }
                try db.execute("INSERT INTO epochs VALUES (?,?,0) ON CONFLICT(plugin) DO UPDATE SET epoch=excluded.epoch,active=0", [.text(pluginID.uuidString), .integer(epoch + 1)])
                // Retain encrypted records for deferred cleanup. Revocation never needs Keychain access.
                try trimHistory(now)
            }
        }
    }

    /// Acquiring the sole lifetime execution lock makes recovery safe against another active sender.
    /// Keep the session strongly retained for the entire worker lifetime.
    public func acquireExecutionSession(now: Date) throws -> ExecutionSession {
        try locked {
            try validateTime(now)
            let session = try ExecutionSession(path: url.path)
            try protectFiles()
            try db.transaction {
                for var op in try activeOperations() {
                    if op.state == .apiInFlight { try terminal(op, .unknownOutcome, now); continue }
                    if op.expires <= now { try terminal(op, .expired, now); continue }
                    if try !isCurrent(op.activation) { try terminal(op, .revoked, now); continue }
                    switch op.state {
                    case .planning: try terminal(op, .quarantined, now)
                    case .apiInFlight: try terminal(op, .unknownOutcome, now)
                    case .resultReady where op.resultStarted: try terminal(op, .quarantined, now)
                    default:
                        op.owner = session.id
                        if var d = op.delivery, d.lease != nil {
                            d.lease = nil; d.leaseEnd = nil; d.owner = nil
                            d.next = max(d.next, now.addingTimeInterval(Self.retryDelay(d.attempts)))
                            op.delivery = d
                        }
                        try save(op)
                    }
                }
                try trimHistory(now)
            }
            return session
        }
    }

    /// Must commit before invoking the planner. Duplicate event admission returns its existing operation.
    public func beginPlanning(eventID: UUID, activation: ActivationIdentity, snapshot: Data, session: ExecutionSession, now: Date) throws -> OperationSnapshot {
        try locked {
            try check(session); try validateTime(now)
            guard snapshot.count <= Self.maxPayloadBytes else { throw WorkflowStorageError.capacity }
            return try db.transaction {
                _ = try requireActivation(activation)
                let key = "\(eventID.uuidString)|\(activation.id.uuidString)|\(activation.epoch)"
                if let admission = try db.query("SELECT id,created,expires FROM admissions WHERE unique_key=?", [.text(key)]).first {
                    guard case .text(let rawID) = admission[0], let id = UUID(uuidString: rawID),
                          case .real(let created) = admission[1], case .real(let expires) = admission[2] else { throw WorkflowStorageError.corruptStore }
                    if let op = try load(id) { return op.view }
                    if let record = try history(id) { return record }
                    // User-visible history can expire; executable-activation replay protection cannot.
                    return OperationSnapshot(id: id, eventID: eventID, activation: activation, state: .terminal, planDigest: nil, createdAt: Date(timeIntervalSince1970: created), expiresAt: Date(timeIntervalSince1970: expires), reason: .historyExpired)
                }
                let admissions = try db.query("SELECT count(*) FROM admissions").first?.first?.int ?? 16384
                let perActivation = try db.query("SELECT count(*) FROM admissions WHERE plugin=? AND epoch=?", [.text(activation.pluginID.uuidString), .integer(activation.epoch)]).first?.first?.int ?? 4096
                guard admissions < 16384, perActivation < 4096 else { throw WorkflowStorageError.capacity }
                try expire(now)
                let pending = try db.query("SELECT count(*),coalesce(sum(pending_bytes),0) FROM operations WHERE state != 'deliveryQueued'")[0]
                guard (pending[0].int ?? 32) < 32, Int(pending[1].int ?? Int64(Self.maxOperationBytes)) + snapshot.count <= Self.maxOperationBytes else { throw WorkflowStorageError.capacity }
                let id = UUID()
                let op = Operation(id: id, event: eventID, activation: activation, created: now, expires: now.addingTimeInterval(Self.ttl), snapshot: try seal(snapshot, activation, operation: id, purpose: "snapshot"), owner: session.id, byteCount: snapshot.count)
                try db.execute("INSERT INTO admissions VALUES (?,?,?,?,?,?)", [.text(key), .text(id.uuidString), .text(activation.pluginID.uuidString), .integer(activation.epoch), .real(now.timeIntervalSince1970), .real(op.expires.timeIntervalSince1970)])
                try save(op); return op.view
            }
        }
    }

    /// Encodes nothing: the caller supplies the exact once-encoded validated native plan bytes.
    @discardableResult public func freezePlan(_ id: UUID, activation: ActivationIdentity, bytes: Data, session: ExecutionSession, now: Date) throws -> OperationSnapshot {
        try locked {
            try check(session); try validateTime(now)
            guard !bytes.isEmpty, bytes.count <= Self.maxPlanBytes else { throw WorkflowStorageError.capacity }
            return try db.transaction {
                var op = try live(id, now); try owned(op, session); try match(op, activation)
                guard op.state == .planning, op.planningStarted else { throw WorkflowStorageError.invalidTransition }
                try ensurePendingBytes(adding: bytes.count)
                let digest = WorkflowDigest.plan(bytes)
                op.plan = try seal(bytes, activation, operation: id, purpose: "plan", digest: digest)
                op.digest = digest; op.byteCount += bytes.count
                op.state = activation.mode == .automatic ? .approved : .pendingReview
                try save(op); return op.view
            }
        }
    }

    public func frozenPlan(_ id: UUID, now: Date) throws -> Data {
        try locked { try plan(live(id, now)) }
    }
    /// Claims the single planner invocation before JS. Duplicate event admission cannot replan this marker.
    public func claimPlanning(_ id: UUID, session: ExecutionSession, now: Date) throws -> Data {
        try locked {
            try check(session); try validateTime(now)
            return try db.transaction {
                var op = try live(id, now); try owned(op, session)
                guard op.state == .planning, !op.planningStarted else { throw WorkflowStorageError.invalidTransition }
                let bytes = try open(op.snapshot, op.activation, operation: id, purpose: "snapshot")
                op.planningStarted = true; try save(op); return bytes
            }
        }
    }

    /// Duplicate approvals return current status after checking the same digest and activation identity.
    public func approve(_ id: UUID, activation: ActivationIdentity, digest: String, now: Date) throws -> OperationSnapshot {
        try locked {
            try validateTime(now)
            return try db.transaction {
                if let terminal = try history(id) {
                    guard terminal.activation == activation, terminal.planDigest == digest else { throw WorkflowStorageError.digestMismatch }
                    return terminal
                }
                var op = try live(id, now); try match(op, activation)
                guard op.digest == digest else { throw WorkflowStorageError.digestMismatch }
                _ = try plan(op)
                guard op.state != .planning else { throw WorkflowStorageError.invalidTransition }
                if op.state == .pendingReview { op.state = .approved; try save(op) }
                return op.view
            }
        }
    }

    /// A nil permit means quota denial: operation remains approved and no marker/rate token was consumed.
    /// Service must revalidate strict package/schema and scope against these bytes before requesting this permit.
    public func claimAPI(_ id: UUID, activation: ActivationIdentity, digest: String, session: ExecutionSession, now: Date) throws -> APIPermit? {
        try locked {
            try check(session); try validateTime(now)
            return try db.transaction {
                var op = try live(id, now); try owned(op, session); try match(op, activation)
                guard op.state == .approved else { throw WorkflowStorageError.invalidTransition }
                guard op.digest == digest else { throw WorkflowStorageError.digestMismatch }
                let bytes = try plan(op)
                guard try consumeRate(op.activation.pluginID, now) else { return nil }
                op.state = .apiInFlight; try save(op)
                return APIPermit(operationID: id, activation: activation, frozenPlan: bytes)
            }
        }
    }

    public func recordResponse(_ id: UUID, bytes: Data, session: ExecutionSession, now: Date) throws {
        try locked {
            try check(session); try validateTime(now)
            guard bytes.count <= Self.maxPayloadBytes else { throw WorkflowStorageError.capacity }
            try db.transaction {
                var op = try live(id, now); try owned(op, session)
                guard op.state == .apiInFlight else { throw WorkflowStorageError.invalidTransition }
                try ensurePendingBytes(adding: bytes.count)
                op.response = try seal(bytes, op.activation, operation: id, purpose: "response")
                op.byteCount += bytes.count; op.state = .resultReady
                try save(op)
            }
        }
    }
    public func claimResult(_ id: UUID, session: ExecutionSession, now: Date) throws -> Data {
        try locked {
            try check(session); try validateTime(now)
            return try db.transaction {
                var op = try live(id, now); try owned(op, session)
                guard op.state == .resultReady, !op.resultStarted, let response = op.response else { throw WorkflowStorageError.invalidTransition }
                let bytes = try open(response, op.activation, operation: id, purpose: "response")
                op.resultStarted = true; try save(op); return bytes
            }
        }
    }

    /// Accepts exact native-serialized payload bytes once. Endpoint configuration is frozen in activation configuration.
    @discardableResult public func queueDelivery(_ id: UUID, bytes: Data, session: ExecutionSession, now: Date) throws -> UUID {
        try locked {
            try check(session); try validateTime(now)
            guard !bytes.isEmpty, bytes.count <= 32 * 1024 else { throw WorkflowStorageError.capacity }
            return try db.transaction {
                var op = try live(id, now); try owned(op, session)
                guard op.state == .resultReady, op.resultStarted, op.activation.endpoint != nil else { throw WorkflowStorageError.invalidTransition }
                let deliveries = try db.query("SELECT count(*),coalesce(sum(delivery_bytes),0) FROM operations WHERE state='deliveryQueued'")[0]
                guard (deliveries[0].int ?? 256) < 256, Int(deliveries[1].int ?? Int64(Self.maxOutboxBytes)) + bytes.count <= Self.maxOutboxBytes else { throw WorkflowStorageError.capacity }
                let deliveryID = UUID(), digest = WorkflowDigest.sha256(bytes)
                let payload = try seal(bytes, op.activation, operation: id, purpose: "delivery:\(deliveryID.uuidString)", digest: digest)
                op.delivery = Delivery(id: deliveryID, payload: payload, digest: digest, size: bytes.count, created: now, expires: min(op.expires, now.addingTimeInterval(Self.ttl)), next: now)
                op.state = .deliveryQueued
                // API/result material is no longer executable or needed. Outbox holds only its immutable delivery.
                op.snapshot = Data(); op.plan = nil; op.response = nil; op.byteCount = 0
                try save(op); return deliveryID
            }
        }
    }

    public func claimDelivery(_ id: UUID, session: ExecutionSession, now: Date) throws -> DeliveryAttempt? {
        try locked {
            try check(session); try validateTime(now)
            return try db.transaction {
                var op = try live(id, now); try owned(op, session)
                guard op.state == .deliveryQueued, var d = op.delivery, let endpoint = op.activation.endpoint else { throw WorkflowStorageError.invalidTransition }
                if d.expires <= now { try terminal(op, .expired, now); return nil }
                if d.lease != nil { return nil }
                guard d.attempts < 5 else { try terminal(op, .exhausted, now); return nil }
                guard d.next <= now else { return nil }
                let leasedCount = try db.query("SELECT count(*) FROM operations WHERE leased=1").first?.first?.int ?? 2
                guard leasedCount < 2 else { return nil }
                let bytes = try open(d.payload, op.activation, operation: id, purpose: "delivery:\(d.id.uuidString)", digest: d.digest)
                guard WorkflowDigest.sha256(bytes) == d.digest, bytes.count == d.size else { throw WorkflowStorageError.hashMismatch }
                guard try consumeRate(op.activation.pluginID, now) else { return nil }
                d.attempts += 1; d.lease = UUID(); d.owner = session.id; d.leaseEnd = min(d.expires, now.addingTimeInterval(10))
                op.delivery = d; try save(op)
                return DeliveryAttempt(operationID: id, deliveryID: d.id, endpoint: endpoint, bytes: bytes, payloadSHA256: d.digest, attempt: d.attempts, leaseID: d.lease!, deadline: d.leaseEnd!)
            }
        }
    }

    /// Complete/cancel the owned HTTP task before releasing its lease. A stale completion cannot finish a newer attempt.
    public func finishDelivery(_ attempt: DeliveryAttempt, outcome: DeliveryOutcome, session: ExecutionSession, now: Date) throws {
        try locked {
            try check(session); try validateTime(now)
            try db.transaction {
                var op = try live(attempt.operationID, now); try owned(op, session)
                guard op.state == .deliveryQueued, var d = op.delivery,
                      d.id == attempt.deliveryID, d.lease == attempt.leaseID, d.attempts == attempt.attempt, d.owner == session.id else { throw WorkflowStorageError.invalidTransition }
                switch outcome {
                case .success: try terminal(op, .completed, now)
                case .permanentFailure: try terminal(op, .failed, now)
                case .transientFailure:
                    if d.attempts >= 5 { try terminal(op, .exhausted, now) }
                    else {
                        d.next = now.addingTimeInterval(Self.retryDelay(d.attempts))
                        d.lease = nil; d.leaseEnd = nil; d.owner = nil; op.delivery = d
                        try save(op)
                    }
                }
            }
        }
    }

    /// No-action/failure/cancel paths erase sensitive material and retain only bounded status metadata.
    public func finish(_ id: UUID, reason: TerminalReason, session: ExecutionSession, now: Date) throws {
        try locked {
            try check(session); try validateTime(now)
            try db.transaction { let op = try live(id, now); try owned(op, session); try terminal(op, reason, now) }
        }
    }
    public func cancel(_ id: UUID, now: Date) throws {
        try locked { try validateTime(now); try db.transaction { if let op = try load(id) { try terminal(op, .cancelled, now) } } }
    }
    public func operation(_ id: UUID) throws -> OperationSnapshot? {
        try locked { if let op = try load(id) { return op.view }; return try history(id) }
    }
    public func pending(now: Date) throws -> [OperationSnapshot] {
        try locked { try validateTime(now); return try operationsWhere("state='pendingReview' AND " + Self.activePredicate).filter { try $0.expires > now && isCurrent($0.activation) }.map(\.view) }
    }
    /// Metadata needed by the sole worker to resume approved, unstarted-result and immutable outbox work.
    public func operations(session: ExecutionSession, now: Date) throws -> [OperationSnapshot] {
        try locked {
            try check(session); try validateTime(now)
            return try activeOperations().filter { try $0.expires > now && isCurrent($0.activation) }.map { op in
                try owned(op, session); return op.view
            }
        }
    }
    public func activeActivations() throws -> [ActivationIdentity] {
        try locked {
            try db.query("SELECT a.data FROM activations a JOIN epochs e ON a.plugin=e.plugin AND a.epoch=e.epoch WHERE e.active=1").map { row in
                guard let data = row.first?.data else { throw WorkflowStorageError.corruptStore }
                let a = try decodeAuthenticated(Activation.self, data)
                _ = try requireActivation(a.identity); return a.identity
            }
        }
    }
    public func deliveryStatus(_ id: UUID) throws -> DeliveryStatus? {
        try locked {
            guard let op = try load(id), let delivery = op.delivery else { return nil }
            return DeliveryStatus(operationID: id, deliveryID: delivery.id, attempts: delivery.attempts, nextAttemptAt: delivery.next, leaseDeadline: delivery.leaseEnd, expiresAt: delivery.expires)
        }
    }
    public func history() throws -> [OperationSnapshot] {
        try locked { try db.query("SELECT data FROM history ORDER BY time DESC LIMIT 1000").map { row in
            guard let data = row.first?.data else { throw WorkflowStorageError.corruptStore }; return try decode(OperationSnapshot.self, data)
        } }
    }
    public func prune(now: Date) throws {
        try locked { try validateTime(now); try db.transaction {
            // Corruption/key errors roll cleanup back. The already committed revocation epoch remains authoritative.
            for op in try operationsWhere("NOT (" + Self.activePredicate + ")") { try terminal(op, .revoked, now) }
            try expire(now); try trimHistory(now)
            // These IDs are operational replay protection, not status history. Only a revoked epoch may discard them.
            try db.execute("DELETE FROM admissions WHERE NOT EXISTS (SELECT 1 FROM epochs e WHERE e.plugin=admissions.plugin AND e.epoch=admissions.epoch AND e.active=1)")
        }; try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try body() }
    private func validateTime(_ now: Date) throws { guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw WorkflowStorageError.invalidInput } }
    private func check(_ session: ExecutionSession) throws { guard session.path == url.path else { throw WorkflowStorageError.wrongSession } }
    private func owned(_ op: Operation, _ session: ExecutionSession) throws { guard op.owner == session.id else { throw WorkflowStorageError.wrongSession } }
    private func match(_ op: Operation, _ identity: ActivationIdentity) throws { guard op.activation == identity else { throw WorkflowStorageError.staleActivation } }
    private func validate(_ identity: ActivationIdentity) throws {
        func revision(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 128 && s.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }
        guard identity.epoch > 0, identity.settingsEpoch > 0,
              identity.packageRevision.count == 64, identity.packageRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              revision(identity.settingsRevision) else { throw WorkflowStorageError.invalidInput }
        if let e = identity.endpoint { guard e.epoch > 0, revision(e.revision), revision(e.credentialRevision) else { throw WorkflowStorageError.invalidInput } }
    }
    public func currentActivationEpoch(pluginID: UUID) throws -> Int64 { try locked { try currentEpoch(pluginID) } }
    private func currentEpoch(_ plugin: UUID) throws -> Int64 { try db.query("SELECT epoch FROM epochs WHERE plugin=?", [.text(plugin.uuidString)]).first?.first?.int ?? 0 }
    private func requireActivation(_ identity: ActivationIdentity) throws -> Activation {
        guard try currentEpoch(identity.pluginID) == identity.epoch,
              try db.query("SELECT active FROM epochs WHERE plugin=?", [.text(identity.pluginID.uuidString)]).first?.first?.int == 1,
              let data = try db.query("SELECT data FROM activations WHERE plugin=?", [.text(identity.pluginID.uuidString)]).first?.first?.data else { throw WorkflowStorageError.staleActivation }
        let record = try decodeAuthenticated(Activation.self, data)
        guard record.identity == identity else { throw WorkflowStorageError.staleActivation }; return record
    }
    private func isCurrent(_ identity: ActivationIdentity) throws -> Bool {
        do { _ = try requireActivation(identity); return true }
        catch WorkflowStorageError.staleActivation { return false }
    }
    private func live(_ id: UUID, _ now: Date) throws -> Operation {
        try validateTime(now)
        // Read only nonsensitive indexed identity first, before asking for any grant key.
        guard let metadata = try db.query("SELECT plugin,epoch FROM operations WHERE id=?", [.text(id.uuidString)]).first else { throw WorkflowStorageError.notFound }
        guard case .text(let plugin) = metadata[0], let epoch = metadata[1].int else { throw WorkflowStorageError.corruptStore }
        guard try db.query("SELECT epoch FROM epochs WHERE plugin=? AND active=1", [.text(plugin)]).first?.first?.int == epoch else { throw WorkflowStorageError.staleActivation }
        guard let op = try load(id) else { throw WorkflowStorageError.notFound }
        guard op.activation.pluginID.uuidString == plugin, op.activation.epoch == epoch else { throw WorkflowStorageError.authenticationFailed }
        guard op.expires > now else { throw WorkflowStorageError.expired }
        _ = try requireActivation(op.activation); return op
    }
    private func plan(_ op: Operation) throws -> Data {
        guard let sealed = op.plan, let digest = op.digest else { throw WorkflowStorageError.invalidTransition }
        let bytes = try open(sealed, op.activation, operation: op.id, purpose: "plan", digest: digest)
        guard WorkflowDigest.plan(bytes) == digest else { throw WorkflowStorageError.digestMismatch }; return bytes
    }
    private func save(_ op: Operation) throws {
        try db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,expires=excluded.expires,pending_bytes=excluded.pending_bytes,delivery_bytes=excluded.delivery_bytes,leased=excluded.leased,data=excluded.data", [
            .text(op.id.uuidString), .text(op.key), .text(op.activation.pluginID.uuidString), .integer(op.activation.epoch), .text(op.state.rawValue), .real(op.expires.timeIntervalSince1970),
            .integer(Int64(op.byteCount)), .integer(Int64(op.delivery?.size ?? 0)), .integer(op.delivery?.lease == nil ? 0 : 1), .blob(try encodeAuthenticated(op, grant: op.activation.grantID))
        ])
    }
    private func load(_ id: UUID) throws -> Operation? {
        guard let data = try db.query("SELECT data FROM operations WHERE id=?", [.text(id.uuidString)]).first?.first?.data else { return nil }
        let op = try decodeAuthenticated(Operation.self, data)
        guard op.id == id else { throw WorkflowStorageError.authenticationFailed }; return op
    }
    private static let activePredicate = "EXISTS (SELECT 1 FROM epochs e WHERE e.plugin=operations.plugin AND e.epoch=operations.epoch AND e.active=1)"
    private func activeOperations() throws -> [Operation] { try operationsWhere(Self.activePredicate) }
    private func operationsWhere(_ predicate: String, _ bindings: [SQLiteDatabase.Value] = []) throws -> [Operation] {
        try db.query("SELECT id,data FROM operations WHERE " + predicate, bindings).map { row in
            guard case .text(let id) = row[0], let data = row[1].data else { throw WorkflowStorageError.corruptStore }
            let op = try decodeAuthenticated(Operation.self, data)
            guard op.id.uuidString == id else { throw WorkflowStorageError.authenticationFailed }; return op
        }
    }
    private func history(_ id: UUID) throws -> OperationSnapshot? {
        guard let data = try db.query("SELECT data FROM history WHERE id=?", [.text(id.uuidString)]).first?.first?.data else { return nil }
        return try decode(OperationSnapshot.self, data)
    }
    private func terminal(_ op: Operation, _ reason: TerminalReason, _ now: Date) throws {
        let view = OperationSnapshot(id: op.id, eventID: op.event, activation: op.activation, state: .terminal, planDigest: op.digest, createdAt: op.created, expiresAt: op.expires, reason: reason)
        try db.execute("INSERT INTO history VALUES (?,?,?,?)", [.text(op.id.uuidString), .text(op.key), .real(now.timeIntervalSince1970), .blob(try encode(view))])
        try db.execute("DELETE FROM operations WHERE id=?", [.text(op.id.uuidString)])
        try trimHistory(now)
    }
    private func expire(_ now: Date) throws {
        for op in try operationsWhere("expires<=?", [.real(now.timeIntervalSince1970)]) {
            try terminal(op, op.state == .apiInFlight ? .unknownOutcome : .expired, now)
        }
    }
    private func trimHistory(_ now: Date) throws {
        try db.execute("DELETE FROM history WHERE time < ?", [.real(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970)])
        try db.execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY time DESC, id DESC LIMIT 1000)")
    }
    private func ensurePendingBytes(adding bytes: Int) throws {
        let count = Int(try db.query("SELECT coalesce(sum(pending_bytes),0) FROM operations WHERE state != 'deliveryQueued'").first?.first?.int ?? Int64(Self.maxOperationBytes))
        guard count + bytes <= Self.maxOperationBytes else { throw WorkflowStorageError.capacity }
    }
    private static func retryDelay(_ attempts: Int) -> TimeInterval {
        [5.0, 30, 120, 600][min(max(attempts - 1, 0), 3)] * Double.random(in: 0.9...1.1)
    }
    private func consumeRate(_ plugin: UUID, _ now: Date) throws -> Bool {
        let time = now.timeIntervalSince1970
        let scopes: [(String, Double, Double)] = [("global", 4, 1), (plugin.uuidString, 2, 10.0 / 60)]
        var proposed: [(String, Double, Double)] = []
        for (id, burst, perSecond) in scopes {
            let row = try db.query("SELECT tokens, time FROM rates WHERE id=?", [.text(id)]).first
            func number(_ v: SQLiteDatabase.Value) throws -> Double {
                switch v { case .real(let n): return n; case .integer(let n): return Double(n); default: throw WorkflowStorageError.corruptStore }
            }
            let previous = try row.map { try number($0[1]) } ?? time
            let tokens = try row.map { try number($0[0]) } ?? burst
            let at = max(time, previous) // Clock rollback never refills tokens.
            let available = min(burst, tokens + max(0, time - previous) * perSecond)
            guard available >= 1 else { return false }; proposed.append((id, available - 1, at))
        }
        for (id, tokens, at) in proposed { try db.execute("INSERT INTO rates VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET tokens=excluded.tokens,time=excluded.time", [.text(id), .real(tokens), .real(at)]) }
        return true
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: bytes) } catch { throw WorkflowStorageError.corruptStore }
    }
    private func aad(_ identity: ActivationIdentity, operation: UUID?, purpose: String, digest: String?) throws -> Data {
        try encode(AAD(domain: "InterceptorWorkflowStorage/v1", activation: identity, operation: operation, purpose: purpose, digest: digest))
    }
    private func seal(_ bytes: Data, _ identity: ActivationIdentity, operation: UUID? = nil, purpose: String, digest: String? = nil) throws -> Data {
        let key = try keys.key(for: identity.grantID)
        guard key.bitCount == 256 else { throw WorkflowStorageError.keyUnavailable }
        return try AES.GCM.seal(bytes, using: key, authenticating: aad(identity, operation: operation, purpose: purpose, digest: digest)).combined!
    }
    private func open(_ bytes: Data, _ identity: ActivationIdentity, operation: UUID? = nil, purpose: String, digest: String? = nil) throws -> Data {
        let key = try keys.key(for: identity.grantID)
        guard key.bitCount == 256 else { throw WorkflowStorageError.keyUnavailable }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad(identity, operation: operation, purpose: purpose, digest: digest)) }
        catch { throw WorkflowStorageError.authenticationFailed }
    }
    private func encodeAuthenticated<T: Encodable>(_ value: T, grant: UUID) throws -> Data {
        let bytes = try encode(value), key = try keys.key(for: grant)
        guard key.bitCount == 256 else { throw WorkflowStorageError.keyUnavailable }
        let aad = Data("InterceptorWorkflowRecord/v1\0\(grant.uuidString)\0".utf8) + bytes
        let tag = try AES.GCM.seal(Data(), using: key, authenticating: aad).combined!
        return try encode(Authenticated(grant: grant, bytes: bytes, tag: tag))
    }
    private func decodeAuthenticated<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        let record = try decode(Authenticated.self, bytes), key = try keys.key(for: record.grant)
        guard key.bitCount == 256 else { throw WorkflowStorageError.keyUnavailable }
        let aad = Data("InterceptorWorkflowRecord/v1\0\(record.grant.uuidString)\0".utf8) + record.bytes
        do { _ = try AES.GCM.open(AES.GCM.SealedBox(combined: record.tag), using: key, authenticating: aad) }
        catch { throw WorkflowStorageError.authenticationFailed }
        return try decode(type, record.bytes)
    }
    private func protectFiles() throws {
        for suffix in ["", "-wal", "-shm", ".execution-lock"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutable = file; try mutable.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
        }
    }
}
