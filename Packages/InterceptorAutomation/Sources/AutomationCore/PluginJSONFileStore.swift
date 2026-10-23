import CryptoKit
import Darwin
import Foundation

/// Durable store for original plugin JSON text, published into `<root>/<namespace>/<sha256(key)>.json`.
///
/// Every path component below the root is opened descriptor-relative with `O_NOFOLLOW`; entries that are
/// not regular files/directories fail closed. The caller prepares outside the activation fence
/// (`prepare`) and publishes inside it (`PreparedWrite.commit`). Commit takes the storage lock
/// non-blockingly and does no abandoned-temporary sweeping (that happens in `prepare`).
public struct PluginJSONFileStore: Sendable {
    public static let maxKeyBytes = 1024
    public static let maxJSONBytes = 1024 * 1024
    public static let maxNamespaceBytes = 64 * 1024 * 1024
    public static let maxNamespaceFiles = 2048
    public static let maxNamespaces = 16
    public static let maxTotalBytes = 256 * 1024 * 1024

    public enum StoreError: Error, Equatable, Sendable {
        /// Another publisher holds the storage lock; the caller may retry on a later capture.
        case busy
        /// The permission, revision or package binding is invalid.
        case notPermitted
        /// The prepared write was already committed or discarded.
        case consumed
    }

    private static let tempPrefix = ".tmp-"
    fileprivate static let chunk = 64 * 1024
    private static let abandonedAge: TimeInterval = 300

    public let directoryURL: URL
    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    /// Convenience: prepare then commit.
    public func save(revisionID: String, package: PluginPackage, key: String, jsonText: String,
                     checkAuthorization: @Sendable () throws -> Void = {}) throws {
        try prepare(revisionID: revisionID, package: package, key: key, jsonText: jsonText)
            .commit(checkAuthorization: checkAuthorization)
    }

    /// Validates, then writes a protected, fsynced temporary file. Nothing is visible to readers until commit.
    public func prepare(revisionID: String, package: PluginPackage, key: String, jsonText: String) throws -> PreparedWrite {
        guard InstallationIdentity.valid(revisionID, package: package), package.manifest.writeFiles else {
            throw StoreError.notPermitted
        }
        let keyBytes = key.utf8.count
        guard (1...Self.maxKeyBytes).contains(keyBytes), !key.utf8.contains(0) else { throw AutomationError.limitExceeded }
        let bytes = Array(jsonText.utf8)
        guard bytes.count <= Self.maxJSONBytes else { throw AutomationError.limitExceeded }
        try PluginJSONSyntax.validate(bytes)

        let family = InstallationIdentity.family(revisionID)
        let uuidPart = String(family.split(separator: "|").last ?? "").lowercased()
        let namespace = String(uuidPart.prefix(8)) + "-" + String(Digest.sha256Hex(Data(family.utf8)).prefix(40))
        let fileName = Digest.sha256Hex(Data(key.utf8)) + ".json"

        let root = try Posix.openDirectory(directoryURL, create: true, mode: 0o700)
        defer { close(root) }
        try Posix.protect(root, url: directoryURL)
        // Sweep outside the activation fence; skipped when a publisher holds the root lock.
        if flock(root, LOCK_EX | LOCK_NB) == 0 {
            sweepAbandonedTemporaries(root)
            flock(root, LOCK_UN)
        }
        let temp = try Posix.writeProtectedTemp(directoryFD: root, directoryURL: directoryURL,
                                                prefix: Self.tempPrefix, data: Data(bytes), checkCancellation: true)
        return PreparedWrite(store: self, namespace: namespace, fileName: fileName, tempName: temp.name,
                             fd: temp.fd, size: bytes.count)
    }

    /// Mirrors committed files into `directoryURL`. Source-only: never reads exported copies, never deletes.
    public func export(to destinationURL: URL) throws {
        let source: Int32
        do { source = try Posix.openDirectory(directoryURL, create: false, mode: 0o700) }
        catch is Posix.Missing { return }
        defer { close(source) }
        let destination = try Posix.openDirectory(destinationURL, create: true, mode: 0o755)
        defer { close(destination) }

        // Validate the whole source tree before writing anything.
        var plan: [(namespace: String, files: [String])] = []
        for name in try Posix.list(source) where !name.hasPrefix(Self.tempPrefix) {
            guard try Posix.kind(source, name) == S_IFDIR else { throw AutomationError.corruptStore }
            let dir = try Posix.openChild(source, name, create: false, mode: 0o700)
            defer { close(dir) }
            var files: [String] = []
            for file in try Posix.list(dir) {
                guard try Posix.kind(dir, file) == S_IFREG else { throw AutomationError.corruptStore }
                files.append(file)
            }
            plan.append((name, files))
        }
        // Per-entry failures do not stop other entries; the first one is reported at the end.
        var firstError: Error?
        func record(_ error: Error) throws {
            if error is CancellationError { throw error }
            if firstError == nil { firstError = error }
        }
        for (namespace, files) in plan {
            do {
                let from = try Posix.openChild(source, namespace, create: false, mode: 0o700)
                defer { close(from) }
                let namespaceURL = destinationURL.appendingPathComponent(namespace)
                let to = try Posix.openChild(destination, namespace, create: true, mode: 0o755)
                defer { close(to) }
                try Posix.protect(to, url: namespaceURL)
                for file in files {
                    try Task.checkCancellation()
                    do { try exportFile(file, from: from, to: to, namespaceURL: namespaceURL) }
                    catch { try record(error) }
                }
            } catch { try record(error) }
        }
        if let firstError { throw firstError }
    }

    private func exportFile(_ file: String, from: Int32, to: Int32, namespaceURL: URL) throws {
        let fd = openat(from, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationError.saveFailed }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= off_t(Self.maxJSONBytes) else { throw AutomationError.corruptStore }
        let size = Int(info.st_size)
        if try Posix.existingSize(to, file) == size {
            let current = openat(to, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if current >= 0 {
                defer { close(current) }
                if try Posix.equal(current, fd, size: size) {
                    try Posix.protect(current, url: namespaceURL.appendingPathComponent(file))
                    return
                }
            }
        }
        let data = try Posix.readAll(fd, size: size)
        let temp = try Posix.writeProtectedTemp(directoryFD: to, directoryURL: namespaceURL,
                                                prefix: Self.tempPrefix, data: data, checkCancellation: false)
        defer { close(temp.fd) }
        guard renameat(to, temp.name, to, file) == 0 else {
            unlinkat(to, temp.name, 0)
            throw AutomationError.saveFailed
        }
        guard fsync(to) == 0 else { throw AutomationError.saveFailed }
    }

    /// A validated, protected, fsynced temporary file owned by this object. Commit or discard exactly once;
    /// dropping it removes the temporary file. Holds an exclusive `flock` on the temp so a concurrent
    /// publisher's sweep never removes it.
    public final class PreparedWrite: @unchecked Sendable {
        fileprivate let store: PluginJSONFileStore
        fileprivate let namespace: String, fileName: String, tempName: String, size: Int
        private let lock = NSLock()
        private var fd: Int32

        fileprivate init(store: PluginJSONFileStore, namespace: String, fileName: String,
                         tempName: String, fd: Int32, size: Int) {
            self.store = store; self.namespace = namespace; self.fileName = fileName
            self.tempName = tempName; self.fd = fd; self.size = size
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

        /// `checkAuthorization` runs once, after every fallible preparation step and immediately before
        /// publication. Once it returns, a later cancellation may leave the committed file in place.
        public func commit(checkAuthorization: @Sendable () throws -> Void = {}) throws {
            lock.lock(); defer { lock.unlock() }
            guard fd >= 0 else { throw StoreError.consumed }
            defer { releaseLocked() }
            try store.publish(self, fd: fd, checkAuthorization: checkAuthorization)
        }
    }

    fileprivate func publish(_ write: PreparedWrite, fd tempFD: Int32,
                             checkAuthorization: @Sendable () throws -> Void) throws {
        let root = try Posix.openDirectory(directoryURL, create: false, mode: 0o700)
        defer { close(root) }
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else {
            let contended = errno == EWOULDBLOCK
            if contended { throw StoreError.busy }
            throw AutomationError.saveFailed
        }
        defer { flock(root, LOCK_UN) }
        guard Posix.sameFile(root, write.tempName, tempFD) else { throw AutomationError.saveFailed }

        var namespaces: [String] = []
        for name in try Posix.list(root) where !name.hasPrefix(Self.tempPrefix) {
            guard try Posix.kind(root, name) == S_IFDIR else { throw AutomationError.corruptStore }
            namespaces.append(name)
        }
        var total = 0
        var own = (files: 0, bytes: 0)
        for name in namespaces {
            let dir = try Posix.openChild(root, name, create: false, mode: 0o700)
            defer { close(dir) }
            let usage = try Self.usage(dir)
            total += usage.bytes
            if name == write.namespace { own = usage }
        }
        let exists = namespaces.contains(write.namespace)
        guard exists || namespaces.count < Self.maxNamespaces else { throw AutomationError.limitExceeded }

        var previousSize: Int?
        if exists {
            let dir = try Posix.openChild(root, write.namespace, create: false, mode: 0o700)
            defer { close(dir) }
            previousSize = try Posix.existingSize(dir, write.fileName)
        }
        let newFiles = own.files + (previousSize == nil ? 1 : 0)
        let ownBytes = own.bytes - (previousSize ?? 0) + write.size
        let totalBytes = total - (previousSize ?? 0) + write.size
        guard newFiles <= Self.maxNamespaceFiles, ownBytes <= Self.maxNamespaceBytes,
              totalBytes <= Self.maxTotalBytes else { throw AutomationError.limitExceeded }

        // A denied save must not leave an empty namespace that consumes quota.
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

    private static func usage(_ dir: Int32) throws -> (files: Int, bytes: Int) {
        var files = 0, bytes = 0
        for name in try Posix.list(dir) {
            var info = stat()
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG
            else { throw AutomationError.corruptStore }
            files += 1
            bytes += Int(info.st_size)
        }
        return (files, bytes)
    }

    /// Removes only temporaries whose owner released its lock and that are old enough to rule out the
    /// create-then-lock window of a live publisher. Only `.tmp-` regular files are ever removed.
    private func sweepAbandonedTemporaries(_ root: Int32) {
        guard let names = try? Posix.list(root) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
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

/// Descriptor-relative POSIX helpers.
enum Posix {
    struct Missing: Error {}

    static func list(_ dir: Int32) throws -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw AutomationError.saveFailed
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// File type bits of `name` without following links.
    static func kind(_ dir: Int32, _ name: String) throws -> mode_t {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw AutomationError.corruptStore }
        return info.st_mode & S_IFMT
    }

    /// Size of a regular file, nil when absent; anything else fails closed.
    static func existingSize(_ dir: Int32, _ name: String) throws -> Int? {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw AutomationError.saveFailed
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AutomationError.corruptStore }
        return Int(info.st_size)
    }

    static func sameFile(_ dir: Int32, _ name: String, _ fd: Int32) -> Bool {
        var a = stat(), b = stat()
        return fstatat(dir, name, &a, AT_SYMLINK_NOFOLLOW) == 0 && fstat(fd, &b) == 0
            && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == S_IFREG
    }

    /// Apply attributes to the opened inode; `url` is retained only for caller compatibility.
    static func protect(_ fd: Int32, url _: URL) throws {
        try PluginJSONFileProtection.apply(to: fd)
    }

    static func openChild(_ parent: Int32, _ name: String, create: Bool, mode: mode_t) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(parent, name, flags)
        if fd < 0, errno == ENOENT {
            guard create else { throw Missing() }
            if mkdirat(parent, name, mode) == 0 { guard fsync(parent) == 0 else { throw AutomationError.saveFailed } }
            else if errno != EEXIST { throw AutomationError.saveFailed }
            fd = openat(parent, name, flags)
        }
        guard fd >= 0 else { throw AutomationError.saveFailed }
        return fd
    }

    /// The trusted prefix of `url` (app-provided, may traverse system links) is resolved once; the final
    /// component and anything created below it are never followed.
    static func openDirectory(_ url: URL, create: Bool, mode: mode_t) throws -> Int32 {
        let target = url.standardizedFileURL
        var base = target.deletingLastPathComponent()
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: base.path), base.path != "/" {
            missing.insert(base.lastPathComponent, at: 0)
            base = base.deletingLastPathComponent()
        }
        guard missing.isEmpty || create else { throw Missing() }
        guard let resolved = realpath(base.path, nil) else { throw AutomationError.saveFailed }
        defer { free(resolved) }
        var fd = open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationError.saveFailed }
        for name in missing + [target.lastPathComponent] {
            let next: Int32
            do { next = try openChild(fd, name, create: create, mode: mode) } catch { close(fd); throw error }
            close(fd)
            fd = next
        }
        return fd
    }

    /// Creates `<prefix><uuid>` exclusively in `directoryFD` (0600), locks it, applies protection and backup
    /// exclusion before any bytes are written, then writes in chunks and fsyncs. Returns the locked fd.
    static func writeProtectedTemp(directoryFD: Int32, directoryURL: URL, prefix: String, data: Data,
                                   checkCancellation: Bool) throws -> (fd: Int32, name: String) {
        let name = prefix + UUID().uuidString
        let fd = openat(directoryFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationError.saveFailed }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, fchmod(fd, 0o600) == 0 else { throw AutomationError.saveFailed }
            try protect(fd, url: directoryURL.appendingPathComponent(name))
            var offset = 0
            while offset < data.count {
                if checkCancellation { try Task.checkCancellation() }
                let n = min(PluginJSONFileStore.chunkBytes, data.count - offset)
                let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, n) }
                guard written > 0 else { throw AutomationError.saveFailed }
                offset += written
            }
            guard fsync(fd) == 0 else { throw AutomationError.saveFailed }
            return (fd, name)
        } catch {
            unlinkat(directoryFD, name, 0)
            close(fd)
            throw error
        }
    }

    static func readAll(_ fd: Int32, size: Int) throws -> Data {
        var out = Data(count: size)
        var offset = 0
        try out.withUnsafeMutableBytes { buffer in
            while offset < size {
                let n = pread(fd, buffer.baseAddress! + offset, size - offset, off_t(offset))
                guard n > 0 else { throw AutomationError.corruptStore }
                offset += n
            }
        }
        return out
    }

    /// Chunked comparison of two regular files of known `size` without loading either whole.
    static func equal(_ a: Int32, _ b: Int32, size: Int) throws -> Bool {
        var one = [UInt8](repeating: 0, count: PluginJSONFileStore.chunkBytes)
        var two = one
        var info = stat()
        guard fstat(a, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) == size else { return false }
        var offset = 0
        while offset < size {
            let want = min(one.count, size - offset)
            let x = pread(a, &one, want, off_t(offset)), y = pread(b, &two, want, off_t(offset))
            guard x == want, y == want else { return false }
            if one[0..<want] != two[0..<want] { return false }
            offset += want
        }
        return true
    }
}

extension PluginJSONFileStore {
    static var chunkBytes: Int { chunk }
}
