import Darwin
import Foundation

/// Publishes one private `PluginFileRecord` into a user-selected File Provider root (e.g. iCloud Drive).
///
/// The caller owns the security scope and the physical-root identity string; this type only performs
/// bounded, cancellable, coordinated I/O on a dedicated serial queue and never returns while its own
/// coordination callback or file I/O is still running.
///
/// * Everything below the root is opened descriptor-relative with `O_NOFOLLOW`; the root itself must be a
///   real directory (the trusted prefix is resolved once, the final component is never followed).
/// * A private ledger at `stateURL` records which files this publisher owns (see `Ledger`). An existing file
///   is replaced only when it is regular, single-linked and matches a ledger-recorded digest of the same
///   family and exact path spelling. Unknown files, other families, aliases and edited files are rejected
///   without any ledger or filesystem change.
/// * An intent (`pending` digest) is journaled before the external rename; recovery after a crash accepts
///   only the recorded old (`published`) or new (`pending`) digest.
/// * An external temporary is journaled in the ledger (`tempName`, then `tempDevice`/`tempInode`) before any
///   payload byte is written. After a crash only that exact, stale (>= 60 s), unlocked, single-linked workfile
///   is reclaimed: an empty file before its inode was journaled, the recorded inode (including partial bytes),
///   or a rematerialized inode with the complete pending digest. The recorded inode belongs to this native
///   scratch operation; published files retain the digest/edit protection above. Replaced workfiles with
///   different bytes are preserved as conflicts. At most one bounded temporary exists per destination and
///   retries never accumulate names. No hard OS deadline is claimed for this recovery.
/// * New external files are installed with an exclusive rename, so an unknown concurrent file is never
///   clobbered. Replacements re-verify digest and inode inside the coordinated write immediately before
///   the rename. No backup exclusion or file protection is applied to external files.
public final class PluginFilePublisher: @unchecked Sendable {
    public enum PublishError: Error, Equatable, Sendable {
        /// The record failed Core re-validation (destination, size, digest, family).
        case invalidRecord
        /// The selected root is missing, not a real directory, or changed during coordination.
        case invalidRoot
        /// Unknown, cross-family, aliased, linked or externally edited file at the destination.
        case conflict
        /// The private ledger is unreadable, malformed or over its bounds. Nothing was changed.
        case corruptState
        /// The ledger would exceed its entry or byte bound.
        case ledgerFull
        /// Another publisher (this or another process) holds the ledger lock; retry later.
        case busy
        /// The operation did not finish before the deadline and was asked to cancel.
        case timedOut
        /// Any other filesystem or coordination failure.
        case io
    }

    public static let maxLedgerBytes = 16 * 1024 * 1024
    public static let maxLedgerEntries = 32_768
    static let deadline: TimeInterval = 15

    private static let chunk = 64 * 1024
    private static let tempPrefix = ".interceptor-"

    private let stateURL: URL
    private let queue = DispatchQueue(label: "com.interceptor.PluginFilePublisher", qos: .utility)

    public init(stateURL: URL) { self.stateURL = stateURL }

    /// A nonempty prefix binds exactly the first virtual path component to the granted folder.
    /// The remaining path is published relative to `root`; an empty prefix retains the full path.
    public func publish(_ record: PluginFileRecord, to root: URL, rootIdentity: String,
                        pathPrefix: String = "") async throws {
        try Task.checkCancellation()
        let job = Job()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                job.arm(deadline: Self.deadline)
                queue.async {
                    let result: Result<Void, Error>
                    do {
                        try self.run(record, root: root, rootIdentity: rootIdentity, pathPrefix: pathPrefix, job: job)
                        result = .success(())
                    }
                    catch { result = .failure(error) }
                    job.finish()
                    // Resumed only after all owned I/O and coordination callbacks have ended.
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: job (cancellation token)

    private final class Job: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        private let lock = NSLock()
        private var cancelled = false, timedOut = false, finished = false
        private var timer: DispatchSourceTimer?

        func arm(deadline: TimeInterval) {
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            source.schedule(deadline: .now() + deadline)
            source.setEventHandler { [weak self] in self?.expire() }
            lock.lock(); timer = source; lock.unlock()
            source.resume()
        }

        func finish() {
            lock.lock(); finished = true; let t = timer; timer = nil; lock.unlock()
            t?.cancel()
        }

        func cancel() { request(timedOut: false) }
        private func expire() { request(timedOut: true) }

        private func request(timedOut expired: Bool) {
            lock.lock()
            if finished { lock.unlock(); return }
            cancelled = true
            if expired { timedOut = true }
            lock.unlock()
            coordinator.cancel()
            // A cancel racing the start of coordination can be a no-op; repeat a bounded number of times.
            for delay in [0.25, 1.0, 3.0] {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
                    lock.lock(); let done = finished; lock.unlock()
                    if !done { coordinator.cancel() }
                }
            }
        }

        func checkpoint() throws {
            lock.lock(); let c = cancelled, t = timedOut; lock.unlock()
            if t { throw PublishError.timedOut }
            if c { throw CancellationError() }
        }
    }

    // MARK: validated request

    private struct Request {
        let record: PluginFileRecord
        let rootIdentity: String
        let key: String
        let familyHash: String
        let path: String
        /// Physical path split on U+002F scalars (never on grapheme clusters).
        let components: [String]
        let digest: String

        init(_ record: PluginFileRecord, rootIdentity: String, pathPrefix: String) throws {
            guard (1...1024).contains(rootIdentity.utf8.count) else { throw PublishError.invalidRoot }
            guard let destination = try? PluginFileDestination(storage: record.destination.storage, atPath: record.destination.atPath),
                  Array(destination.atPath.utf8) == Array(record.destination.atPath.utf8),
                  record.contents.count <= PluginFileStore.maxContentsBytes,
                  Digest.isHex64(record.digest), Digest.sha256Hex(record.contents) == record.digest,
                  InstallationIdentity.valid(record.family + "|" + String(repeating: "0", count: 64))
            else { throw PublishError.invalidRecord }
            let physicalDestination: PluginFileDestination
            if pathPrefix.isEmpty {
                physicalDestination = destination
            } else {
                guard let prefix = try? PluginFileDestination(storage: destination.storage, atPath: pathPrefix),
                      prefix.pathComponents.count == 1 else { throw PublishError.invalidRecord }
                let components = destination.pathComponents
                guard components.count >= 2, components[0].utf8.elementsEqual(pathPrefix.utf8),
                      let relative = try? PluginFileDestination(storage: destination.storage,
                                                               atPath: components.dropFirst().joined(separator: "/"))
                else { throw PublishError.invalidRecord }
                physicalDestination = relative
            }
            self.record = record
            self.rootIdentity = rootIdentity
            path = physicalDestination.atPath
            components = physicalDestination.pathComponents
            guard components.allSatisfy(PluginFilePublisher.validUserComponent) else { throw PublishError.invalidRecord }
            digest = record.digest
            familyHash = Digest.sha256Hex(Data(record.family.utf8))
            key = PluginFilePublisher.ledgerKey(rootIdentity: rootIdentity, path: physicalDestination.atPath)
        }
    }

    /// Same conservative alias identity as the private store, scoped to a physical destination root.
    static func ledgerKey(rootIdentity: String, path: String) -> String {
        let folded = PluginFileDestination.foldedKey(path)
        return Digest.sha256Hex(Data("\(rootIdentity.utf8.count):\(rootIdentity)\n\(folded)".utf8))
    }

    // MARK: ledger

    /// Private ledger, compact UTF-8 JSON with sorted keys:
    ///
    ///     {"entries":[{"device":Int?,"family":"<sha256 hex of family>","inode":Int?,"key":"<hex>",
    ///                  "path":"<exact NFC path>","pending":"<hex>"|null,"published":"<hex>"|null,
    ///                  "tempName":"<.interceptor-UUID.tmp>"?,"tempDevice":Int?,"tempInode":Int?}],"version":1}
    ///
    /// `tempName` requires `pending`; `tempDevice`/`tempInode` appear together and require `tempName`.
    /// `device`/`inode` appear together or not at all. `key` = sha256(len(rootIdentity) ":" rootIdentity
    /// "\n" Core-folded path). Limits: 16 MiB, 32768 entries, unique keys, no other fields.
    struct FileIdentity: Equatable { let device: Int64, inode: Int64 }

    struct Entry: Equatable {
        var key: String, family: String, path: String
        var published: String?, pending: String?
        var identity: FileIdentity?
        /// Journaled external temporary (exact `.interceptor-<UUID>.tmp`) and, once created, its inode.
        var tempName: String?
        var tempIdentity: FileIdentity?
    }

    private struct Ledger {
        var entries: [String: Entry] = [:]

        static func load(parent: Int32, name: String) throws -> Ledger {
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return Ledger() }
                throw PublishError.corruptState
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0,
                  info.st_size <= off_t(PluginFilePublisher.maxLedgerBytes) else { throw PublishError.corruptState }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PublishError.corruptState }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
                  opened.st_size == info.st_size, let data = try? Posix.readAll(fd, size: Int(opened.st_size))
            else { throw PublishError.corruptState }
            return try decode(data)
        }

        static func decode(_ data: Data) throws -> Ledger {
            do {
                let root = try JSONFields(try StrictJSON.parse(data), required: ["version", "entries"], error: .corruptStore)
                guard try root.int("version") == 1 else { throw PublishError.corruptState }
                let list = try root.array("entries")
                guard list.count <= PluginFilePublisher.maxLedgerEntries else { throw PublishError.corruptState }
                var ledger = Ledger()
                for item in list {
                    let f = try JSONFields(item, required: ["key", "family", "path", "published", "pending"],
                                           optional: ["device", "inode", "tempName", "tempDevice", "tempInode"],
                                           error: .corruptStore)
                    func optionalDigest(_ k: String) throws -> String? {
                        if case .null = try f.value(k) { return nil }
                        let s = try f.string(k)
                        guard Digest.isHex64(s) else { throw PublishError.corruptState }
                        return s
                    }
                    let path = try f.string("path")
                    let destination = try PluginFileDestination(storage: .local, atPath: path)
                    let key = try f.string("key"), family = try f.string("family")
                    guard Digest.isHex64(key), Digest.isHex64(family), ledger.entries[key] == nil else {
                        throw PublishError.corruptState
                    }
                    let published = try optionalDigest("published"), pending = try optionalDigest("pending")
                    guard published != nil || pending != nil, f.has("device") == f.has("inode") else {
                        throw PublishError.corruptState
                    }
                    let identity = f.has("device") ? FileIdentity(device: try f.int("device"), inode: try f.int("inode")) : nil
                    guard f.has("tempDevice") == f.has("tempInode"),
                          !f.has("tempDevice") || f.has("tempName"),
                          !f.has("tempName") || pending != nil else { throw PublishError.corruptState }
                    var tempName: String?
                    if f.has("tempName") {
                        let name = try f.string("tempName")
                        guard PluginFilePublisher.validTempName(name) else { throw PublishError.corruptState }
                        tempName = name
                    }
                    let tempIdentity = f.has("tempDevice")
                        ? FileIdentity(device: try f.int("tempDevice"), inode: try f.int("tempInode")) : nil
                    ledger.entries[key] = Entry(key: key, family: family, path: destination.atPath,
                                                published: published, pending: pending, identity: identity,
                                                tempName: tempName, tempIdentity: tempIdentity)
                }
                return ledger
            } catch let error as PublishError {
                throw error
            } catch {
                throw PublishError.corruptState
            }
        }

        func encode() throws -> Data {
            let items: [JSONValue] = entries.values.sorted { $0.key < $1.key }.map { e in
                var o: [String: JSONValue] = [
                    "key": .string(e.key), "family": .string(e.family), "path": .string(e.path),
                    "published": e.published.map(JSONValue.string) ?? .null,
                    "pending": e.pending.map(JSONValue.string) ?? .null,
                ]
                if let id = e.identity { o["device"] = .integer(id.device); o["inode"] = .integer(id.inode) }
                if let name = e.tempName { o["tempName"] = .string(name) }
                if let id = e.tempIdentity { o["tempDevice"] = .integer(id.device); o["tempInode"] = .integer(id.inode) }
                return .object(o)
            }
            guard items.count <= PluginFilePublisher.maxLedgerEntries else { throw PublishError.ledgerFull }
            let data = try JSONValue.object(["version": .integer(1), "entries": .array(items)]).data()
            guard data.count <= PluginFilePublisher.maxLedgerBytes else { throw PublishError.ledgerFull }
            return data
        }

        /// Protected temp + fsync + atomic rename + directory fsync. Private ledger only.
        func save(parent: Int32, parentURL: URL, name: String) throws {
            let data = try encode()
            let temp: (fd: Int32, name: String)
            do {
                temp = try Posix.writeProtectedTemp(directoryFD: parent, directoryURL: parentURL,
                                                    prefix: ".ledger-tmp-", data: data, checkCancellation: false)
            } catch { throw PublishError.io }
            defer { close(temp.fd) }
            guard renameat(parent, temp.name, parent, name) == 0 else {
                unlinkat(parent, temp.name, 0)
                throw PublishError.io
            }
            guard fsync(parent) == 0 else { throw PublishError.io }
        }
    }

    // MARK: run

    private func run(_ record: PluginFileRecord, root: URL, rootIdentity: String, pathPrefix: String, job: Job) throws {
        try job.checkpoint()                       // before any ledger or directory side effect
        let request = try Request(record, rootIdentity: rootIdentity, pathPrefix: pathPrefix)
        var rootStat = stat()
        guard root.isFileURL, stateURL.isFileURL, lstat(root.path, &rootStat) == 0,
              rootStat.st_mode & S_IFMT == S_IFDIR else { throw PublishError.invalidRoot }
        let stateName = stateURL.lastPathComponent
        let parentURL = stateURL.deletingLastPathComponent()
        guard !stateName.isEmpty, stateName != ".", stateName != ".." else { throw PublishError.corruptState }

        let parent: Int32
        do { parent = try Posix.openDirectory(parentURL, create: true, mode: 0o700) } catch { throw PublishError.io }
        defer { close(parent) }
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? PublishError.busy : PublishError.io
        }
        defer { flock(parent, LOCK_UN) }

        var ledger = try Ledger.load(parent: parent, name: stateName)
        try job.checkpoint()
        try sweepLedgerTemporaries(parent: parent, stateName: stateName, job: job)

        // A directory write does not coordinate concurrent writers of its descendants. Prepare only
        // the containing directories here, then release this coordination before requesting the leaf.
        // Nesting write coordination inside a write accessor is prohibited by NSFileCoordinator.
        let coordinatedRoot = try coordinated(root, options: [], job: job) { url in
            let rootFD = try self.openRoot(url, expected: rootStat)
            defer { close(rootFD) }
            if let e = ledger.entries[request.key] {
                guard e.family == request.familyHash, Array(e.path.utf8) == Array(request.path.utf8)
                else { throw PublishError.conflict }
            }
            try job.checkpoint()
            let directories = Array(request.components.dropLast())
            guard let parentFD = try self.openDirectories(rootFD, directories, create: true) else {
                throw PublishError.io
            }
            close(parentFD)
            return url
        }
        let directoryComponents = Array(request.components.dropLast())
        // An unresolved journaled temporary is resolved (or reported) before any new temporary exists.
        if let tempName = ledger.entries[request.key]?.tempName {
            let tempURL = (directoryComponents + [tempName]).reduce(coordinatedRoot) { $0.appendingPathComponent($1) }
            try coordinated(tempURL, options: .forDeleting, job: job) { url in
                let accessorRoot = try self.accessorRoot(url, suffix: directoryComponents + [tempName])
                try self.recoverTemp(request, rootURL: accessorRoot, rootStat: rootStat, ledger: &ledger,
                                     parent: parent, parentURL: parentURL, stateName: stateName, job: job)
            }
        }
        let requestedLeaf = request.components.reduce(coordinatedRoot) { $0.appendingPathComponent($1) }
        try coordinated(requestedLeaf, options: .forReplacing, job: job) { leafURL in
            // Use the accessor URL, even when the provider changed the trusted prefix. Its exact
            // relative suffix must still be the requested path; the reopened root inode is checked.
            let accessorRoot = try self.accessorRoot(leafURL, suffix: request.components)
            try self.transact(request, rootURL: accessorRoot, rootStat: rootStat, ledger: &ledger,
                              parent: parent, parentURL: parentURL, stateName: stateName, job: job)
        }
    }

    private func accessorRoot(_ url: URL, suffix: [String]) throws -> URL {
        var root = url
        for component in suffix.reversed() {
            guard Array(root.lastPathComponent.utf8) == Array(component.utf8) else { throw PublishError.invalidRoot }
            root.deleteLastPathComponent()
        }
        return root
    }

    private func clearTemp(_ r: Request, ledger: inout Ledger, parent: Int32, parentURL: URL, stateName: String) throws {
        guard var e = ledger.entries[r.key] else { return }
        e.tempName = nil; e.tempIdentity = nil
        ledger.entries[r.key] = e
        try ledger.save(parent: parent, parentURL: parentURL, name: stateName)
    }

    /// Resolves only this destination's native scratch workfile. A journaled inode is owned even during a
    /// partial write. Before its inode is recorded only an empty file is reclaimable; a rematerialized
    /// inode must match the full pending digest. Published file edit protection is separate from scratch.
    private func recoverTemp(_ r: Request, rootURL: URL, rootStat: stat, ledger: inout Ledger, parent: Int32,
                             parentURL: URL, stateName: String, job: Job) throws {
        try job.checkpoint()
        guard let entry = ledger.entries[r.key], let name = entry.tempName, Self.validTempName(name) else { return }
        let rootFD = try openRoot(rootURL, expected: rootStat)
        defer { close(rootFD) }
        guard let dir = try openDirectories(rootFD, Array(r.components.dropLast()), create: false) else {
            try clearTemp(r, ledger: &ledger, parent: parent, parentURL: parentURL, stateName: stateName)
            return
        }
        defer { close(dir) }
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw PublishError.io }
            try clearTemp(r, ledger: &ledger, parent: parent, parentURL: parentURL, stateName: stateName)
            return
        }
        func plain(_ s: stat) -> Bool {
            s.st_mode & S_IFMT == S_IFREG && s.st_nlink == 1 && s.st_size >= 0
                && s.st_size <= off_t(PluginFileStore.maxContentsBytes)
        }
        guard let pending = entry.pending, plain(info) else { throw PublishError.conflict }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? PublishError.conflict : PublishError.io }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, plain(opened), opened.st_ino == info.st_ino, opened.st_dev == info.st_dev
        else { throw PublishError.conflict }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? PublishError.busy : PublishError.io
        }
        let modified = Double(opened.st_mtimespec.tv_sec) + Double(opened.st_mtimespec.tv_nsec) / 1_000_000_000
        guard Date().timeIntervalSince1970 - modified >= 60 else { throw PublishError.busy }
        if let identity = entry.tempIdentity {
            let current = FileIdentity(device: Int64(opened.st_dev), inode: Int64(truncatingIfNeeded: opened.st_ino))
            if current != identity {
                guard let data = try? Posix.readAll(fd, size: Int(opened.st_size)) else { throw PublishError.io }
                guard Digest.sha256Hex(data) == pending else { throw PublishError.conflict }
            }
        } else {
            // The intent name was durable before O_EXCL, and no payload is written before inode save.
            guard opened.st_size == 0 else { throw PublishError.conflict }
        }
        try job.checkpoint()
        var again = stat()
        guard Posix.sameFile(dir, name, fd), fstat(fd, &again) == 0, plain(again),
              again.st_size == opened.st_size, again.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              again.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { throw PublishError.conflict }
        guard unlinkat(dir, name, 0) == 0 else { throw PublishError.io }
        guard fsync(dir) == 0 else { throw PublishError.io }
        try clearTemp(r, ledger: &ledger, parent: parent, parentURL: parentURL, stateName: stateName)
    }

    static func validTempName(_ name: String) -> Bool {
        guard name.utf8.count == tempPrefix.utf8.count + 36 + 4, name.hasPrefix(tempPrefix), name.hasSuffix(".tmp")
        else { return false }
        return UUID(uuidString: String(name.dropFirst(tempPrefix.count).dropLast(4))) != nil
    }

    /// A user-export path component: nonempty, no separator or NUL scalar, not `.`/`..`, no leading dot.
    static func validUserComponent(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !scalars.isEmpty && name.utf8.count <= 255 && scalars.first != "."
            && !scalars.contains("/") && !scalars.contains("\0")
    }

    /// Every ledger writer holds this same directory lock before creating its temporary. Once the
    /// lock is acquired, unlocked regular files with our exact UUID name are abandoned writes. The
    /// committed ledger (including its intent) remains authoritative; no response or export is removed.
    private func sweepLedgerTemporaries(parent: Int32, stateName: String, job: Job) throws {
        let prefix = ".ledger-tmp-"
        var removed = false
        for name in try Posix.list(parent) where name != stateName && name.hasPrefix(prefix) {
            try job.checkpoint()
            let suffix = String(name.dropFirst(prefix.count))
            guard suffix.utf8.count == 36, UUID(uuidString: suffix) != nil else { continue }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw PublishError.io
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= off_t(Self.maxLedgerBytes) else { continue }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT { continue }
                throw PublishError.io
            }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK { continue }
                throw PublishError.io
            }
            guard Posix.sameFile(parent, name, fd) else { continue }
            guard unlinkat(parent, name, 0) == 0 else { throw PublishError.io }
            removed = true
        }
        if removed, fsync(parent) != 0 { throw PublishError.io }
    }

    /// Each write accessor finishes before another write is requested on this coordinator.
    private func coordinated<T>(_ url: URL, options: NSFileCoordinator.WritingOptions, job: Job,
                                accessor: (URL) throws -> T) throws -> T {
        try job.checkpoint()
        var outcome: Result<T, Error> = .failure(PublishError.io)
        var coordinationError: NSError?
        job.coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            do { outcome = .success(try accessor(coordinatedURL)) }
            catch { outcome = .failure(error) }
        }
        if coordinationError != nil {
            try job.checkpoint()
            if (coordinationError as NSError?)?.code == NSUserCancelledError { throw CancellationError() }
            throw PublishError.io
        }
        return try outcome.get()
    }

    private func openRoot(_ url: URL, expected: stat) throws -> Int32 {
        guard url.isFileURL else { throw PublishError.invalidRoot }
        // The OS-selected prefix resolves naturally (inside the caller's security scope); the final
        // component is never followed and must be the verified directory.
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PublishError.invalidRoot }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino else {
            close(fd)
            throw PublishError.invalidRoot
        }
        return fd
    }

    // MARK: coordinated transaction

    private func transact(_ r: Request, rootURL: URL, rootStat: stat, ledger: inout Ledger, parent: Int32,
                          parentURL: URL, stateName: String, job: Job) throws {
        try job.checkpoint()
        let rootFD = try openRoot(rootURL, expected: rootStat)
        defer { close(rootFD) }

        let components = r.components
        let fileName = components[components.count - 1]
        let directories = Array(components.dropLast())

        // Decide using only non-creating traversal.
        var existing: Existing = .missing
        if let dir = try openDirectories(rootFD, directories, create: false) {
            defer { close(dir) }
            existing = try inspect(dir, fileName)
        }
        var entry = ledger.entries[r.key]
        if let e = entry {
            guard e.family == r.familyHash, Array(e.path.utf8) == Array(r.path.utf8) else { throw PublishError.conflict }
        }
        var replacing: Existing? = nil
        switch (entry, existing) {
        case (nil, .file): throw PublishError.conflict
        case (_, .missing): break
        case (let e?, .file(let identity, let digest)):
            let owned = digest == e.published || digest == e.pending
            guard owned else { throw PublishError.conflict }
            // File Providers can re-materialize an unchanged document on a different inode. Persistent
            // ownership is bound to the family, exact path and known bytes. Inodes only guard races
            // during this coordinated operation, where `replacing` is inspected again before rename.
            if digest == r.digest {
                // Already the desired bytes: no external rewrite, just finalize the ledger.
                var done = e
                done.published = digest; done.pending = nil; done.identity = identity
                if done != e { ledger.entries[r.key] = done; try ledger.save(parent: parent, parentURL: parentURL, name: stateName) }
                return
            }
            replacing = existing
            entry = e
            entry?.published = digest
            entry?.identity = identity
        }

        guard (entry != nil) || ledger.entries.count < Self.maxLedgerEntries else { throw PublishError.ledgerFull }
        try job.checkpoint()

        // Journal the intent before publishing any external file contents.
        var intent = entry ?? Entry(key: r.key, family: r.familyHash, path: r.path, published: nil, pending: nil, identity: nil)
        // An unresolved journaled temporary must be recovered first; never mint a second name.
        guard intent.tempName == nil, intent.tempIdentity == nil else { throw PublishError.conflict }
        let tempName = Self.tempPrefix + UUID().uuidString + ".tmp"
        intent.pending = r.digest
        intent.tempName = tempName
        ledger.entries[r.key] = intent
        try ledger.save(parent: parent, parentURL: parentURL, name: stateName)

        try job.checkpoint()
        // Parent creation was separately coordinated. If a parent was removed in between, retry
        // from that phase instead of mutating an uncoordinated directory while holding the leaf.
        guard let dir = try openDirectories(rootFD, directories, create: false) else { throw PublishError.io }
        defer { close(dir) }
        let temp = try writeTemp(dir, tempName, r.record.contents, job: job) { identity in
            // Durable inode metadata before any payload byte exists.
            intent.tempIdentity = identity
            ledger.entries[r.key] = intent
            try ledger.save(parent: parent, parentURL: parentURL, name: stateName)
        }
        defer { close(temp.fd) }
        var installed = false
        defer { if !installed && Posix.sameFile(dir, temp.name, temp.fd) { unlinkat(dir, temp.name, 0) } }
        try job.checkpoint()
        guard Posix.sameFile(dir, temp.name, temp.fd) else { throw PublishError.conflict }

        if let replacing, case .file(let identity, let digest) = replacing {
            // Recheck inside the coordinated write, immediately before the replacing rename.
            guard case .file(let nowIdentity, let nowDigest) = try inspect(dir, fileName),
                  nowIdentity == identity, nowDigest == digest else { throw PublishError.conflict }
            guard renameat(dir, temp.name, dir, fileName) == 0 else { throw PublishError.io }
        } else {
            try installExclusively(dir, temp.name, fileName)
        }
        installed = true
        // Past this point the bytes are visible: always finalize the ledger, ignoring cancellation.
        let synced = fsync(dir) == 0
        var done = intent
        var info = stat()
        guard fstat(temp.fd, &info) == 0 else { throw PublishError.io }
        done.published = r.digest; done.pending = nil
        done.tempName = nil; done.tempIdentity = nil
        done.identity = FileIdentity(device: Int64(info.st_dev), inode: Int64(truncatingIfNeeded: info.st_ino))
        ledger.entries[r.key] = done
        try ledger.save(parent: parent, parentURL: parentURL, name: stateName)
        guard synced else { throw PublishError.io }
    }

    private enum Existing { case missing, file(FileIdentity, String) }

    /// Descriptor-relative no-follow walk. `nil` when a component is absent and `create` is false.
    private func openDirectories(_ root: Int32, _ names: [String], create: Bool) throws -> Int32? {
        guard names.allSatisfy(Self.validUserComponent) else { throw PublishError.invalidRecord }
        var fd = dup(root)
        guard fd >= 0 else { throw PublishError.io }
        for name in names {
            let next: Int32
            do { next = try Posix.openChild(fd, name, create: create, mode: 0o755) }
            catch is Posix.Missing { close(fd); return nil }
            catch {
                let kind = try? Posix.kind(fd, name)
                close(fd)
                throw (kind != nil && kind != S_IFDIR) ? PublishError.conflict : PublishError.io
            }
            close(fd)
            fd = next
        }
        return fd
    }

    private func inspect(_ dir: Int32, _ name: String) throws -> Existing {
        guard Self.validUserComponent(name) else { throw PublishError.invalidRecord }
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .missing }
            throw PublishError.io
        }
        func plain(_ s: stat) -> Bool {
            s.st_mode & S_IFMT == S_IFREG && s.st_nlink == 1 && s.st_size >= 0
                && s.st_size <= off_t(PluginFileStore.maxContentsBytes)
        }
        guard plain(info) else { throw PublishError.conflict }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? PublishError.conflict : PublishError.io }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, plain(opened), opened.st_ino == info.st_ino, opened.st_dev == info.st_dev
        else { throw PublishError.conflict }
        guard let data = try? Posix.readAll(fd, size: Int(opened.st_size)) else { throw PublishError.io }
        return .file(FileIdentity(device: Int64(opened.st_dev), inode: Int64(truncatingIfNeeded: opened.st_ino)),
                     Digest.sha256Hex(data))
    }

    private func writeTemp(_ dir: Int32, _ name: String, _ data: Data, job: Job,
                           onCreated: (FileIdentity) throws -> Void) throws -> (fd: Int32, name: String) {
        guard Self.validTempName(name) else { throw PublishError.io }
        let fd = openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PublishError.io }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PublishError.io }
            var created = stat()
            guard fstat(fd, &created) == 0 else { throw PublishError.io }
            try onCreated(FileIdentity(device: Int64(created.st_dev), inode: Int64(truncatingIfNeeded: created.st_ino)))
            var offset = 0
            while offset < data.count {
                try job.checkpoint()
                let n = min(Self.chunk, data.count - offset)
                let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, n) }
                guard written > 0 else { throw PublishError.io }
                offset += written
            }
            guard fsync(fd) == 0 else { throw PublishError.io }
            return (fd, name)
        } catch {
            if Posix.sameFile(dir, name, fd) { unlinkat(dir, name, 0) }
            close(fd)
            throw error
        }
    }

    /// Atomic no-clobber install: exclusive rename, with an exclusive hard link where unsupported.
    private func installExclusively(_ dir: Int32, _ temp: String, _ name: String) throws {
        guard Self.validUserComponent(name) else { throw PublishError.invalidRecord }
        if renameatx_np(dir, temp, dir, name, UInt32(RENAME_EXCL)) == 0 { return }
        switch errno {
        case EEXIST: throw PublishError.conflict
        case ENOTSUP, EINVAL:
            guard linkat(dir, temp, dir, name, 0) == 0 else { throw errno == EEXIST ? PublishError.conflict : PublishError.io }
            unlinkat(dir, temp, 0)
        default: throw PublishError.io
        }
    }
}
