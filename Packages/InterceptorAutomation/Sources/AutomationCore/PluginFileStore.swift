import CryptoKit
import Darwin
import Foundation

/// One immutable, validated private record read back from `PluginFileStore`.
public struct PluginFileRecord: Sendable {
    public let identifier: String
    public let family: String
    public let destination: PluginFileDestination
    public let contents: Data
    public let digest: String
}

/// Durable private store for plugin-created files: `<root>/<namespace>/<sha256(storage, folded path)>.rec`.
///
/// Each record is a single versioned file (routing header + raw payload) published with one atomic rename,
/// so the latest commit wins and route/payload can never disagree. Payload bytes are opaque (never parsed).
/// All I/O below the root is descriptor-relative with `O_NOFOLLOW`. Prepare happens outside the activation
/// fence; commit publishes inside it under a non-blocking root lock.
public struct PluginFileStore: Sendable {
    public static let maxContentsBytes = 1024 * 1024
    public static let maxFamilyBytes = 64 * 1024 * 1024
    public static let maxFamilyFiles = 2048
    public static let maxFamilies = 16
    public static let maxTotalBytes = 256 * 1024 * 1024
    static let maxHeaderBytes = 4096
    private static let maxPendingTemporaries = 256
    private static let maxRootEntries = maxFamilies + maxPendingTemporaries

    public enum StoreError: Error, Equatable, Sendable {
        /// Another publisher holds the storage lock; the caller may retry later.
        case busy
        /// The permission, revision or package binding is invalid.
        case notPermitted
        /// The prepared write was already committed or discarded.
        case consumed
        /// Another family (or a differently spelled alias) already owns this destination.
        case conflict
    }

    private static let tempPrefix = ".tmp-"
    private static let recordSuffix = ".rec"
    private static let magic = Array("IPFREC01".utf8)
    private static let prefixBytes = 12
    private static let abandonedAge: TimeInterval = 300

    public let directoryURL: URL
    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    // MARK: naming

    private static func namespace(for family: String) -> String {
        let uuidPart = String(family.split(separator: "|").last ?? "").lowercased()
        return String(uuidPart.prefix(8)) + "-" + String(Digest.sha256Hex(Data(family.utf8)).prefix(40))
    }

    private static func fileName(for destination: PluginFileDestination) -> String {
        Digest.sha256Hex(Data(destination.canonicalIdentity.utf8)) + recordSuffix
    }

    private static func isHex(_ s: Substring) -> Bool {
        s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func validNamespace(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].utf8.count == 8 && parts[1].utf8.count == 40 && isHex(parts[0]) && isHex(parts[1])
    }

    private static func validFileName(_ s: String) -> Bool {
        guard s.hasSuffix(recordSuffix) else { return false }
        let stem = s.dropLast(recordSuffix.count)
        return stem.utf8.count == 64 && isHex(stem)
    }

    // MARK: record format

    private struct Header {
        let family: String
        let destination: PluginFileDestination
        let size: Int
        let digest: String

        func data() throws -> Data {
            try JSONValue.object([
                "family": .string(family), "storage": .string(destination.storage.rawValue),
                "atPath": .string(destination.atPath), "size": .integer(Int64(size)), "digest": .string(digest),
            ]).data()
        }
    }

    private static func encode(_ header: Header, payload: Data) throws -> Data {
        let head = try header.data()
        guard head.count <= maxHeaderBytes else { throw AutomationError.limitExceeded }
        var out = Data(magic)
        let n = UInt32(head.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(head)
        out.append(payload)
        return out
    }

    /// Length of the header declared by a 12-byte prefix.
    private static func headerLength(_ prefix: [UInt8]) throws -> Int {
        guard prefix.count == prefixBytes, Array(prefix[0..<8]) == magic else { throw AutomationError.corruptStore }
        let n = (Int(prefix[8]) << 24) | (Int(prefix[9]) << 16) | (Int(prefix[10]) << 8) | Int(prefix[11])
        guard (1...maxHeaderBytes).contains(n) else { throw AutomationError.corruptStore }
        return n
    }

    private static func parseHeader(_ bytes: Data) throws -> Header {
        do {
            let value = try JSONValue(parsing: bytes)
            let f = try JSONFields(value, required: ["family", "storage", "atPath", "size", "digest"], error: .corruptStore)
            guard let storage = PluginFileStorage(rawValue: try f.string("storage")) else { throw AutomationError.corruptStore }
            let family = try f.string("family")
            guard InstallationIdentity.valid(family + "|" + String(repeating: "0", count: 64)) else { throw AutomationError.corruptStore }
            let size = try f.int("size")
            let digest = try f.string("digest")
            guard (0...Int64(maxContentsBytes)).contains(size), Digest.isHex64(digest) else { throw AutomationError.corruptStore }
            let header = Header(family: family, destination: try PluginFileDestination(storage: storage, atPath: try f.string("atPath")),
                                size: Int(size), digest: digest)
            guard try header.data() == bytes else { throw AutomationError.corruptStore }
            return header
        } catch { throw AutomationError.corruptStore }
    }

    private static func readHeader(fd: Int32, fileSize: Int) throws -> Header {
        var prefix = [UInt8](repeating: 0, count: prefixBytes)
        guard fileSize >= prefixBytes, pread(fd, &prefix, prefixBytes, 0) == prefixBytes else { throw AutomationError.corruptStore }
        let n = try headerLength(prefix)
        guard fileSize >= prefixBytes + n else { throw AutomationError.corruptStore }
        var head = [UInt8](repeating: 0, count: n)
        guard pread(fd, &head, n, off_t(prefixBytes)) == n else { throw AutomationError.corruptStore }
        let header = try parseHeader(Data(head))
        guard fileSize == prefixBytes + n + header.size else { throw AutomationError.corruptStore }
        return header
    }

    // MARK: prepare

    /// Validates, then writes a protected, fsynced temporary file. Nothing is visible to readers until commit.
    public func prepare(revisionID: String, package: PluginPackage, destination: PluginFileDestination,
                        contents: Data) throws -> PreparedWrite {
        guard InstallationIdentity.valid(revisionID, package: package), package.manifest.writeFiles else {
            throw StoreError.notPermitted
        }
        guard contents.count <= Self.maxContentsBytes else { throw AutomationError.limitExceeded }
        let family = InstallationIdentity.family(revisionID)
        let record = try Self.encode(Header(family: family, destination: destination, size: contents.count,
                                            digest: Digest.sha256Hex(contents)), payload: contents)
        try Task.checkCancellation()

        let root = try Posix.openDirectory(directoryURL, create: true, mode: 0o700)
        defer { close(root) }
        try Posix.protect(root, url: directoryURL)
        // Sweep outside the activation fence; skipped when a publisher holds the root lock.
        if flock(root, LOCK_EX | LOCK_NB) == 0 {
            sweepAbandonedTemporaries(root)
            flock(root, LOCK_UN)
        }
        let entries = try Self.boundedEntries(root, limit: Self.maxRootEntries)
        guard entries.lazy.filter({ $0.hasPrefix(Self.tempPrefix) }).count < Self.maxPendingTemporaries else {
            throw AutomationError.limitExceeded
        }
        let temp = try Posix.writeProtectedTemp(directoryFD: root, directoryURL: directoryURL,
                                                prefix: Self.tempPrefix, data: record, checkCancellation: true)
        return PreparedWrite(store: self, namespace: Self.namespace(for: family), fileName: Self.fileName(for: destination),
                             destination: destination, tempName: temp.name, fd: temp.fd, size: record.count)
    }

    /// A protected, fsynced temporary file owned by this object. Commit or discard exactly once; dropping it
    /// removes the temporary. It holds an exclusive `flock` so a concurrent sweep never removes it.
    public final class PreparedWrite: @unchecked Sendable {
        fileprivate let store: PluginFileStore
        fileprivate let namespace: String, fileName: String, tempName: String, size: Int
        fileprivate let destination: PluginFileDestination
        private let lock = NSLock()
        private var fd: Int32

        fileprivate init(store: PluginFileStore, namespace: String, fileName: String, destination: PluginFileDestination,
                         tempName: String, fd: Int32, size: Int) {
            self.store = store; self.namespace = namespace; self.fileName = fileName
            self.destination = destination; self.tempName = tempName; self.fd = fd; self.size = size
        }
        deinit { discard() }

        /// Removes the temporary file. Safe to call repeatedly.
        public func discard() {
            lock.lock(); defer { lock.unlock() }
            releaseLocked()
        }

        private func releaseLocked() {
            guard fd >= 0 else { return }
            if let root = try? Posix.openDirectory(store.directoryURL, create: false, mode: 0o700) {
                if Posix.sameFile(root, tempName, fd) { unlinkat(root, tempName, 0) }
                close(root)
            }
            close(fd)
            fd = -1
        }

        /// `checkAuthorization` runs after every fallible preparation step and immediately before publication.
        /// Once it returns, a later cancellation may leave the committed record in place.
        public func commit(checkAuthorization: @Sendable () throws -> Void = {}) throws {
            lock.lock(); defer { lock.unlock() }
            guard fd >= 0 else { throw StoreError.consumed }
            defer { releaseLocked() }
            try store.publish(self, fd: fd, checkAuthorization: checkAuthorization)
        }
    }

    // MARK: commit

    fileprivate func publish(_ write: PreparedWrite, fd tempFD: Int32,
                             checkAuthorization: @Sendable () throws -> Void) throws {
        let root: Int32
        do { root = try Posix.openDirectory(directoryURL, create: false, mode: 0o700) }
        catch is Posix.Missing { throw AutomationError.saveFailed }
        defer { close(root) }
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw StoreError.busy }
            throw AutomationError.saveFailed
        }
        defer { flock(root, LOCK_UN) }
        guard Posix.sameFile(root, write.tempName, tempFD) else { throw AutomationError.saveFailed }

        // Metadata-only scan: names and sizes, never payloads.
        var namespaces: [String] = []
        for name in try Self.boundedEntries(root, limit: Self.maxRootEntries) where !name.hasPrefix(Self.tempPrefix) {
            guard Self.validNamespace(name), try Posix.kind(root, name) == S_IFDIR else { throw AutomationError.corruptStore }
            namespaces.append(name)
        }
        guard namespaces.count <= Self.maxFamilies else { throw AutomationError.corruptStore }
        var total = 0
        var own = (files: 0, bytes: 0)
        var previousSize: Int?
        for name in namespaces {
            let dir = try Posix.openChild(root, name, create: false, mode: 0o700)
            defer { close(dir) }
            let entries = try Self.boundedEntries(dir, limit: Self.maxFamilyFiles)
            var files = 0, bytes = 0
            for entry in entries {
                var info = stat()
                guard Self.validFileName(entry), fstatat(dir, entry, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_size >= off_t(Self.prefixBytes),
                      info.st_size <= off_t(Self.prefixBytes + Self.maxHeaderBytes + Self.maxContentsBytes)
                else { throw AutomationError.corruptStore }
                files += 1
                bytes += Int(info.st_size)
                if entry == write.fileName {
                    // Same stable name means the same folded destination: only the owning family may replace it.
                    guard name == write.namespace else { throw StoreError.conflict }
                    previousSize = Int(info.st_size)
                }
            }
            total += bytes
            if name == write.namespace { own = (files, bytes) }
        }
        let exists = namespaces.contains(write.namespace)
        guard exists || namespaces.count < Self.maxFamilies else { throw AutomationError.limitExceeded }

        if previousSize != nil {
            let dir = try Posix.openChild(root, write.namespace, create: false, mode: 0o700)
            defer { close(dir) }
            let current = openat(dir, write.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard current >= 0 else { throw AutomationError.corruptStore }
            defer { close(current) }
            let header = try Self.readHeader(fd: current, fileSize: previousSize!)
            guard Self.namespace(for: header.family) == write.namespace,
                  Self.fileName(for: header.destination) == write.fileName else { throw AutomationError.corruptStore }
            // A differently spelled alias must be rejected, not renamed.
            guard header.destination == write.destination,
                  Data(header.destination.atPath.utf8) == Data(write.destination.atPath.utf8) else { throw StoreError.conflict }
        }
        let newFiles = own.files + (previousSize == nil ? 1 : 0)
        let ownBytes = own.bytes - (previousSize ?? 0) + write.size
        let totalBytes = total - (previousSize ?? 0) + write.size
        guard newFiles <= Self.maxFamilyFiles, ownBytes <= Self.maxFamilyBytes,
              totalBytes <= Self.maxTotalBytes else { throw AutomationError.limitExceeded }

        // A denied first publish must not leave an empty family directory consuming quota.
        if !exists { try checkAuthorization() }
        let dir = try Posix.openChild(root, write.namespace, create: true, mode: 0o700)
        defer { close(dir) }
        var committed = false
        defer { if !exists && !committed { unlinkat(root, write.namespace, AT_REMOVEDIR) } }
        let namespaceURL = directoryURL.appendingPathComponent(write.namespace)
        if !exists {
            try Posix.protect(dir, url: namespaceURL)
            guard fsync(root) == 0 else { throw AutomationError.saveFailed }
        }

        if previousSize == write.size {
            let current = openat(dir, write.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if current >= 0 {
                defer { close(current) }
                if try Posix.equal(current, tempFD, size: write.size) {
                    // Identical retry: still restore protection and make the visible bytes durable.
                    try checkAuthorization()
                    try Posix.protect(current, url: namespaceURL.appendingPathComponent(write.fileName))
                    committed = true
                    guard fsync(current) == 0, fsync(dir) == 0 else { throw AutomationError.saveFailed }
                    return
                }
            }
        }
        try checkAuthorization()
        guard renameat(root, write.tempName, dir, write.fileName) == 0 else { throw AutomationError.saveFailed }
        committed = true
        // Bytes are now visible; a sync failure is reported without rolling them back.
        guard fsync(dir) == 0, fsync(root) == 0 else { throw AutomationError.saveFailed }
    }

    // MARK: read

    /// Identifiers (`namespace/filename`) of every committed record; `[]` when the store does not exist yet.
    public func recordIdentifiers() throws -> [String] {
        let root: Int32
        do { root = try Posix.openDirectory(directoryURL, create: false, mode: 0o700) }
        catch is Posix.Missing { return [] }
        defer { close(root) }
        var namespaces: [String] = []
        for name in try Self.boundedEntries(root, limit: Self.maxRootEntries) where !name.hasPrefix(Self.tempPrefix) {
            guard Self.validNamespace(name), try Posix.kind(root, name) == S_IFDIR else { throw AutomationError.corruptStore }
            namespaces.append(name)
        }
        guard namespaces.count <= Self.maxFamilies else { throw AutomationError.corruptStore }
        var ids: [String] = []
        for name in namespaces.sorted() {
            let dir = try Posix.openChild(root, name, create: false, mode: 0o700)
            defer { close(dir) }
            let entries = try Self.boundedEntries(dir, limit: Self.maxFamilyFiles)
            for entry in entries.sorted() {
                guard Self.validFileName(entry), try Posix.kind(dir, entry) == S_IFREG else { throw AutomationError.corruptStore }
                ids.append(name + "/" + entry)
            }
        }
        return ids
    }

    /// Reads only bounded routing headers to report declared content versions. This does not
    /// read or verify payload bytes; `readRecord` must still validate contents before delivery.
    public func recordVersions() throws -> [String: String] {
        let identifiers = try recordIdentifiers()
        guard !identifiers.isEmpty else { return [:] }
        let root = try Posix.openDirectory(directoryURL, create: false, mode: 0o700)
        defer { close(root) }
        var versions: [String: String] = [:]
        for identifier in identifiers {
            try Task.checkCancellation()
            // Identifiers were constructed from the validated ASCII namespace and record names above.
            let parts = identifier.split(separator: "/").map(String.init)
            let dir = try Posix.openChild(root, parts[0], create: false, mode: 0o700)
            defer { close(dir) }
            let fd = openat(dir, parts[1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw AutomationError.corruptStore }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= off_t(Self.prefixBytes),
                  info.st_size <= off_t(Self.prefixBytes + Self.maxHeaderBytes + Self.maxContentsBytes)
            else { throw AutomationError.corruptStore }
            let header = try Self.readHeader(fd: fd, fileSize: Int(info.st_size))
            guard parts[0] == Self.namespace(for: header.family),
                  parts[1] == Self.fileName(for: header.destination) else { throw AutomationError.corruptStore }
            versions[identifier] = header.digest
        }
        return versions
    }

    /// Reads one record through a single descriptor and revalidates its binding, size and digest.
    public func readRecord(_ identifier: String) throws -> PluginFileRecord {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard identifier.utf8.count <= 128, parts.count == 2, Self.validNamespace(parts[0]), Self.validFileName(parts[1]) else {
            throw AutomationError.corruptStore
        }
        let root: Int32
        do { root = try Posix.openDirectory(directoryURL, create: false, mode: 0o700) }
        catch is Posix.Missing { throw AutomationError.corruptStore }
        defer { close(root) }
        let dir: Int32
        do { dir = try Posix.openChild(root, parts[0], create: false, mode: 0o700) }
        catch is Posix.Missing { throw AutomationError.corruptStore }
        defer { close(dir) }
        let fd = openat(dir, parts[1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationError.corruptStore }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= off_t(Self.prefixBytes + Self.maxHeaderBytes + Self.maxContentsBytes) else {
            throw AutomationError.corruptStore
        }
        let data = try Posix.readAll(fd, size: Int(info.st_size))
        guard data.count >= Self.prefixBytes else { throw AutomationError.corruptStore }
        let n = try Self.headerLength(Array(data.prefix(Self.prefixBytes)))
        guard data.count >= Self.prefixBytes + n else { throw AutomationError.corruptStore }
        let header = try Self.parseHeader(data.subdata(in: Self.prefixBytes..<(Self.prefixBytes + n)))
        let payload = data.subdata(in: (Self.prefixBytes + n)..<data.count)
        guard payload.count == header.size, Digest.sha256Hex(payload) == header.digest,
              parts[0] == Self.namespace(for: header.family), parts[1] == Self.fileName(for: header.destination) else {
            throw AutomationError.corruptStore
        }
        return PluginFileRecord(identifier: identifier, family: header.family, destination: header.destination,
                                contents: payload, digest: header.digest)
    }

    // MARK: cleanup

    /// Bound allocation while reading an untrusted directory, before accumulating its names.
    private static func boundedEntries(_ dir: Int32, limit: Int) throws -> [String] {
        let copy = dup(dir)
        guard copy >= 0 else { throw AutomationError.saveFailed }
        guard let stream = fdopendir(copy) else { close(copy); throw AutomationError.saveFailed }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw AutomationError.saveFailed }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < limit else { throw AutomationError.corruptStore }
            names.append(name)
        }
    }

    /// Removes only temporaries whose owner released its lock and that are old enough to rule out the
    /// create-then-lock window of a live publisher. Only `.tmp-` regular files are ever removed.
    private func sweepAbandonedTemporaries(_ root: Int32) {
        let copy = dup(root)
        guard copy >= 0 else { return }
        guard let stream = fdopendir(copy) else { close(copy); return }
        defer { closedir(stream) }
        rewinddir(stream)
        // Stream only a bounded number of entries: do not allocate an unbounded name list to recover a corrupt root.
        for _ in 0..<4096 {
            guard !Task.isCancelled, let entry = readdir(stream) else { return }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix(Self.tempPrefix) else { continue }
            let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > Self.abandonedAge,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            unlinkat(root, name, 0)
        }
    }
}
