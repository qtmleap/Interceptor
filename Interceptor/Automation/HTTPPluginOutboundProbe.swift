#if DEBUG
import AutomationCore
import Darwin
import Foundation

/// DEBUG-only physical-delivery receipt for the outbound dispatcher. It records only binding, outcome and status
/// into a file this run created exclusively under a harness-owned directory; it never changes permissions or network.
final class HTTPPluginOutboundProbe: @unchecked Sendable {
    static let optionKey = "InterceptorOutboundProbeRunID"
    static let maxEvents = 8, maxBytes = 4096, maxOwnershipBytes = 512
    enum Failure: Error, Equatable { case invalidRun, ownership, mismatch, io }

    /// Completion-only flush/close operations; defaults are the real Darwin calls. Tests inject failures per instance.
    struct CompletionIO: Sendable {
        var sync: @Sendable (Int32) -> Int32 = { fsync($0) }
        var close: @Sendable (Int32) -> Int32 = { Darwin.close($0) }
    }

    private struct FileID: Equatable { let dev: dev_t, ino: ino_t }
    private struct Event { let binding: String, outcome: String, status: Int? }

    private let queue = DispatchQueue(label: "HTTPPluginOutboundProbe")
    private let isCurrent: @Sendable () -> Bool
    private let runID: String, nonce: String, packageSHA256: String
    private let autoFD: Int32, probeFD: Int32, runFD: Int32
    private let probeName = "OutboundProbe"
    private static let stageName = ".completion.json.stage"
    private let ids: [FileID], ownershipID: FileID
    private let completionIO: CompletionIO
    private var receiptFD: Int32, receiptID: FileID
    // Confined to `queue`.
    private var events: [Event] = [], overflow = false, failed = false, closed = false, completed: Bool?

    /// Returns nil when the option, ownership or approved package does not match exactly.
    static func make(options: [String: NSObject]?, snapshot: PluginActivationSnapshot?, activationURL: URL,
                     isCurrent: @escaping @Sendable () -> Bool) -> HTTPPluginOutboundProbe? {
        guard let run = (options?[optionKey] as? NSString) as String?, let snapshot else { return nil }
        return try? open(runID: run, snapshot: snapshot, activationURL: activationURL, isCurrent: isCurrent)
    }

    static func open(runID: String, snapshot: PluginActivationSnapshot, activationURL: URL,
                     isCurrent: @escaping @Sendable () -> Bool,
                     completionIO: CompletionIO = CompletionIO()) throws -> HTTPPluginOutboundProbe {
        guard UUID(uuidString: runID)?.uuidString.lowercased() == runID else { throw Failure.invalidRun }
        guard snapshot.revisions.count == 1, let package = snapshot.revisions.first?.package else { throw Failure.mismatch }
        var fds: [Int32] = []
        do {
            let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let auto = Darwin.open(activationURL.deletingLastPathComponent().path, dirFlags)
            guard auto >= 0 else { throw Failure.io }
            fds.append(auto)
            let probe = openat(auto, "OutboundProbe", dirFlags)
            guard probe >= 0 else { throw Failure.io }
            fds.append(probe)
            let run = openat(probe, runID, dirFlags)
            guard run >= 0 else { throw Failure.io }
            fds.append(run)
            let ids = try fds.map { try identity($0, directory: true) }

            let own = openat(run, "ownership.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard own >= 0 else { throw Failure.ownership }
            defer { close(own) }
            let ownID = try identity(own, directory: false, maxSize: maxOwnershipBytes)
            let owner = try parseOwnership(readAll(own, limit: maxOwnershipBytes), runID: runID)
            guard owner.sha == package.revision, package.manifest.settings.objectValue?["probeNonce"] == .string(owner.nonce) else {
                throw Failure.mismatch
            }

            let receipt = openat(run, "receipt.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard receipt >= 0 else { throw Failure.io }
            fds.append(receipt)
            let probeObject = HTTPPluginOutboundProbe(runID: runID, nonce: owner.nonce, sha: owner.sha, fds: fds, ids: ids,
                                                      ownershipID: ownID, receiptID: try identity(receipt, directory: false, maxSize: 0),
                                                      isCurrent: isCurrent, completionIO: completionIO)
            // Ownership moved to the object; a failed initial write must not close
            // these descriptors again after its deinitializer has already closed them.
            fds.removeAll()
            try probeObject.queue.sync { try probeObject.persist() }
            return probeObject
        } catch {
            fds.forEach { close($0) }
            throw error
        }
    }

    private init(runID: String, nonce: String, sha: String, fds: [Int32], ids: [FileID], ownershipID: FileID,
                 receiptID: FileID, isCurrent: @escaping @Sendable () -> Bool, completionIO: CompletionIO) {
        self.runID = runID
        self.nonce = nonce
        packageSHA256 = sha
        autoFD = fds[0]; probeFD = fds[1]; runFD = fds[2]; receiptFD = fds[3]
        self.ids = ids
        self.ownershipID = ownershipID
        self.receiptID = receiptID
        self.isCurrent = isCurrent
        self.completionIO = completionIO
    }

    deinit {
        for fd in [autoFD, probeFD, runFD, receiptFD] where fd >= 0 { close(fd) }
    }

    /// Never blocks the caller: the ticket is sampled synchronously and I/O happens on the private queue.
    var observer: HTTPPluginOutboundDispatcher.Observer {
        { [self] binding, outcome in
            let current = isCurrent()
            queue.async { [self] in record(binding: binding, outcome: current ? outcome : .cancelled) }
        }
    }

    /// Writes the completion proof once, only for a fully drained dispatcher and a flushed, error-free writer.
    func finish(drained: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: complete(drained: drained)) }
        }
    }

    /// Shared-lock read for harnesses. An empty result is a pending file; only a full payload is evidence.
    static func readPayload(at url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        let id = try identity(fd, directory: false, maxSize: maxBytes)
        while flock(fd, LOCK_SH | LOCK_NB) != 0 { guard errno == EINTR else { throw Failure.io } }
        defer { flock(fd, LOCK_UN) }
        let data = try readAll(fd, limit: maxBytes)
        var st = stat()
        guard lstat(url.path, &st) == 0, FileID(dev: st.st_dev, ino: st.st_ino) == id else { throw Failure.io }
        return data
    }

    // MARK: Queue-confined

    private func record(binding: String, outcome: HTTPPluginOutboundOutcome) {
        guard !closed, !failed else { return }
        if !Self.isBinding(binding) {
            overflow = true
        } else if events.count >= Self.maxEvents {
            overflow = true
        } else {
            switch outcome {
            case .response(let status) where (100 ... 599).contains(status):
                events.append(Event(binding: binding, outcome: "response", status: status))
            case .response, .failed: events.append(Event(binding: binding, outcome: "failed", status: nil))
            case .rejected: events.append(Event(binding: binding, outcome: "rejected", status: nil))
            case .cancelled: events.append(Event(binding: binding, outcome: "cancelled", status: nil))
            case .timedOut: events.append(Event(binding: binding, outcome: "timedOut", status: nil))
            case .tooLarge: events.append(Event(binding: binding, outcome: "tooLarge", status: nil))
            }
        }
        do { try persist() } catch { failed = true }
    }

    private func complete(drained: Bool) -> Bool {
        if let completed { return completed }
        closed = true
        var ok = false
        if drained, !failed { ok = (try? writeCompletion()) != nil }
        if !ok { failed = true }
        completed = ok
        close(receiptFD)
        receiptFD = -1
        return ok
    }

    private func payload() throws -> Data {
        let list: [JSONValue] = events.map {
            var fields: [String: JSONValue] = ["binding": .string($0.binding), "outcome": .string($0.outcome)]
            if let status = $0.status { fields["status"] = .integer(Int64(status)) }
            return .object(fields)
        }
        let data = try JSONValue.object([
            "schemaVersion": .integer(1), "runID": .string(runID), "nonce": .string(nonce),
            "packageSHA256": .string(packageSHA256), "events": .array(list), "overflow": .bool(overflow),
        ]).data()
        guard data.count <= Self.maxBytes else { throw Failure.io }
        return data
    }

    private func verifyAnchors() throws {
        let checks: [(Int32, String, FileID)] = [(autoFD, probeName, ids[1]), (probeFD, runID, ids[2]),
                                                 (runFD, "receipt.json", receiptID), (runFD, "ownership.json", ownershipID)]
        for (dir, name, id) in checks {
            var st = stat()
            guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, FileID(dev: st.st_dev, ino: st.st_ino) == id,
                  st.st_nlink == 1 || (name == probeName || name == runID) else { throw Failure.io }
        }
    }

    private func persist() throws {
        try verifyAnchors()
        try Self.writeLocked(receiptFD, try payload())
    }

    /// Publishes completion.json only after the staged payload is written, flushed and its one close succeeded.
    /// The exclusive rename is the final failable step; a failure does not publish or replace a final proof.
    private func writeCompletion() throws {
        try verifyAnchors()
        let data = try payload()
        var fd = openat(runFD, Self.stageName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        var stageID: FileID?
        do {
            let id = try Self.identity(fd, directory: false, maxSize: 0)
            stageID = id
            try Self.writeLocked(fd, data, sync: completionIO.sync)
            _ = try Self.identity(fd, directory: false, exactSize: data.count)
            let closing = fd
            fd = -1 // ownership is consumed by the single close attempt, whatever it returns
            guard completionIO.close(closing) == 0 else { throw Failure.io }
            try checkStage(id, size: data.count)
            try verifyAnchors()
            guard renameatx_np(runFD, Self.stageName, runFD, "completion.json", UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
        } catch {
            if fd >= 0 { _ = completionIO.close(fd) }
            if let stageID { removeStage(matching: stageID) }
            throw error
        }
    }

    private func checkStage(_ id: FileID, size: Int) throws {
        var st = stat()
        guard fstatat(runFD, Self.stageName, &st, AT_SYMLINK_NOFOLLOW) == 0, FileID(dev: st.st_dev, ino: st.st_ino) == id,
              (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1, Int(st.st_size) == size else { throw Failure.io }
    }

    /// Removes only the staging name this writer created, and only while it still names the same regular file.
    private func removeStage(matching id: FileID) {
        var st = stat()
        guard fstatat(runFD, Self.stageName, &st, AT_SYMLINK_NOFOLLOW) == 0, FileID(dev: st.st_dev, ino: st.st_ino) == id,
              (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { return }
        _ = unlinkat(runFD, Self.stageName, 0)
    }

    // MARK: Darwin helpers

    private static func identity(_ fd: Int32, directory: Bool, maxSize: Int = .max, exactSize: Int? = nil) throws -> FileID {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid() else { throw Failure.io }
        if directory {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.io }
        } else {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= maxSize,
                  exactSize.map({ Int(st.st_size) == $0 }) ?? true else { throw Failure.ownership }
        }
        return FileID(dev: st.st_dev, ino: st.st_ino)
    }

    private static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: limit + 1)
        while data.count <= limit {
            let n = read(fd, &buffer, limit + 1 - data.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw Failure.io }
            if n == 0 { break }
            data.append(contentsOf: buffer[0 ..< n])
        }
        guard data.count <= limit else { throw Failure.ownership }
        return data
    }

    private static func writeLocked(_ fd: Int32, _ data: Data, sync: (Int32) -> Int32 = { fsync($0) }) throws {
        while flock(fd, LOCK_EX) != 0 { guard errno == EINTR else { throw Failure.io } }
        defer { flock(fd, LOCK_UN) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < data.count {
                let n = pwrite(fd, raw.baseAddress! + offset, data.count - offset, off_t(offset))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw Failure.io }
                offset += n
            }
        }
        guard ftruncate(fd, off_t(data.count)) == 0, sync(fd) == 0 else { throw Failure.io }
    }

    private static func parseOwnership(_ data: Data, runID: String) throws -> (nonce: String, sha: String) {
        guard let value = try? JSONValue(parsing: data), let object = value.objectValue,
              Set(object.keys) == ["schemaVersion", "runID", "nonce", "packageSHA256"],
              object["schemaVersion"] == .integer(1), object["runID"] == .string(runID),
              let nonce = object["nonce"]?.stringValue, (16 ... 64).contains(nonce.utf8.count),
              nonce.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) ||
                                    (48 ... 57).contains($0) || $0 == 45 || $0 == 95 }),
              let sha = object["packageSHA256"]?.stringValue, sha.utf8.count == 64,
              sha.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { throw Failure.ownership }
        return (nonce, sha)
    }

    private static func isBinding(_ s: String) -> Bool {
        guard let first = s.utf8.first, s.utf8.count <= 32, (first | 0x20) >= 0x61, (first | 0x20) <= 0x7A else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || $0 == 0x5F }
    }
}
#endif
