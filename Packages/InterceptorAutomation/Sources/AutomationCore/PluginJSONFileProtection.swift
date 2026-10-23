import Darwin
import Foundation

/// Learn Foundation's backup attributes on a private empty inode, then apply them by descriptor.
/// Response bytes and mutable Documents paths never participate in attribute discovery.
enum PluginJSONFileProtection {
    private final class Template: @unchecked Sendable {
        let attributes: [String: Data]
        #if os(iOS) && !targetEnvironment(simulator)
        let protectionClass: Int32
        #endif

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Interceptor-JSON-Protection-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("template")
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AutomationError.saveFailed }
            defer { close(fd) }
            let original = try Self.readAttributes(fd)
            try CatalogFile(url: url).protect()
            attributes = try Self.readAttributes(fd).filter { original[$0.key] != $0.value }
            guard !attributes.isEmpty else { throw AutomationError.saveFailed }
            #if os(iOS) && !targetEnvironment(simulator)
            let applied = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? String
            guard applied == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else { throw AutomationError.saveFailed }
            protectionClass = fcntl(fd, F_GETPROTECTIONCLASS)
            guard protectionClass > 0 else { throw AutomationError.saveFailed }
            #endif
        }

        static func readAttributes(_ fd: Int32) throws -> [String: Data] {
            let length = flistxattr(fd, nil, 0, 0)
            guard length >= 0, length <= 16 * 1024 else { throw AutomationError.saveFailed }
            if length == 0 { return [:] }
            var names = [CChar](repeating: 0, count: length)
            guard flistxattr(fd, &names, names.count, 0) == length else { throw AutomationError.saveFailed }
            var result: [String: Data] = [:]
            for raw in names.split(separator: 0) {
                let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let count = fgetxattr(fd, name, nil, 0, 0, 0)
                guard count >= 0, count <= 64 * 1024 else { throw AutomationError.saveFailed }
                var data = Data(count: count)
                let read = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, count, 0, 0) }
                guard read == count else { throw AutomationError.saveFailed }
                result[name] = data
            }
            return result
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedTemplate: Template?

    private static func template() throws -> Template {
        try lock.withLock {
            if let cachedTemplate { return cachedTemplate }
            let created = try Template()
            cachedTemplate = created
            return created
        }
    }

    static func apply(to fd: Int32) throws {
        let template = try template()
        for (name, bytes) in template.attributes {
            let result = bytes.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, bytes.count, 0, 0) }
            guard result == 0 else { throw AutomationError.saveFailed }
        }
        #if os(iOS) && !targetEnvironment(simulator)
        guard fcntl(fd, F_SETPROTECTIONCLASS, template.protectionClass) == 0,
              fcntl(fd, F_GETPROTECTIONCLASS) == template.protectionClass else { throw AutomationError.saveFailed }
        #endif
        let actual = try Template.readAttributes(fd)
        guard template.attributes.allSatisfy({ actual[$0.key] == $0.value }) else { throw AutomationError.saveFailed }
    }
}
