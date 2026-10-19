import Darwin
import Foundation

/// Per-path advisory lock and an atomic, bounded catalog file.
struct CatalogFile: Sendable {
    let url: URL
    private var lockURL: URL { url.appendingPathExtension("lock") }

    func locked<T>(_ body: () throws -> T) throws -> T {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw AutomationError.saveFailed }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationError.saveFailed }
        defer { flock(fd, LOCK_UN); close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AutomationError.saveFailed }
        var tries = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            tries += 1
            guard errno == EWOULDBLOCK, tries < 200 else { throw AutomationError.saveFailed }
            usleep(10_000)
        }
        return try body()
    }

    /// Checks the open file before allocation, and also caps reads if it grows after fstat.
    func read(maximumBytes: Int = Limits.catalogBytes) throws -> Data? {
        guard (0...Limits.catalogBytes).contains(maximumBytes) else { throw AutomationError.corruptStore }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw AutomationError.corruptStore
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw AutomationError.corruptStore }
        do {
            var result = Data()
            while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - result.count)), !chunk.isEmpty {
                result.append(chunk)
                guard result.count <= maximumBytes else { throw AutomationError.corruptStore }
            }
            return result
        } catch { throw AutomationError.corruptStore }
    }

    /// All fallible preparation happens before rename; the protected inode keeps its attributes.
    func replace(with data: Data) throws {
        guard data.count <= Limits.catalogBytes else { throw AutomationError.saveFailed }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AutomationError.saveFailed }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try CatalogFile(url: tmp).protect()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw AutomationError.saveFailed }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AutomationError.saveFailed
        }
    }

    func protect() throws {
        do {
            var candidate = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try candidate.setResourceValues(values)
            #if os(iOS) || os(tvOS) || os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
        } catch { throw AutomationError.saveFailed }
    }
}
