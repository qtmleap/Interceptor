import AutomationCore
import Foundation

/// Files is a one-way export. Failures leave authoritative responses for a foreground retry.
actor PluginFilesExporter {
    static let shared = PluginFilesExporter()
    private var lastExport: [String: Signature]?
    private var failedState: [String: Signature]?
    private var retryAfter: ContinuousClock.Instant?
    private var retryDelay = 5

    private struct Signature: Equatable {
        let size: Int?
        let modified: Date?
        let attributesModified: Date?
        let identity: String
    }

    func synchronize() {
        guard !Task.isCancelled, let source = AutomationSharedConfiguration.pluginFilesURL(),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destination = documents.appending(path: "Plugins", directoryHint: .isDirectory)
        do {
            let current = try signatures(source: source, destination: destination)
            guard current != lastExport else { return }
            if current == failedState, let retryAfter, ContinuousClock.now < retryAfter { return }
            try PluginJSONFileStore(directoryURL: source).export(to: destination)
            let after = try signatures(source: source, destination: destination)
            // A response published during export must get another pass rather than enter the cache.
            let beforeSources = current.filter { $0.key.hasPrefix("source/") }
            let afterSources = after.filter { $0.key.hasPrefix("source/") }
            lastExport = beforeSources == afterSources ? after : nil
            failedState = nil
            retryAfter = nil
            retryDelay = 5
        } catch {
            // Retry after a failure; never log response bodies or private paths.
            failedState = try? signatures(source: source, destination: destination)
            retryAfter = ContinuousClock.now.advanced(by: .seconds(retryDelay))
            retryDelay = min(60, retryDelay * 2)
            lastExport = nil
        }
    }

    /// Compare metadata only between successful exports. User edits/deletions invalidate the mirror cache.
    private func signatures(source: URL, destination: URL) throws -> [String: Signature] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                                       .contentModificationDateKey, .attributeModificationDateKey, .fileResourceIdentifierKey]
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys)) else { return [:] }
        var result: [String: Signature] = [:]
        for case let file as URL in entries {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw AutomationError.corruptStore }
            guard values.isRegularFile == true, file.pathExtension == "json" else { continue }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            result["source/" + relative] = Signature(size: values.fileSize, modified: values.contentModificationDate,
                                                    attributesModified: values.attributeModificationDate, identity: String(describing: values.fileResourceIdentifier))
            let exported = destination.appending(path: relative)
            if let visible = try? exported.resourceValues(forKeys: keys) {
                guard visible.isSymbolicLink != true else { throw AutomationError.corruptStore }
                result["export/" + relative] = Signature(size: visible.fileSize, modified: visible.contentModificationDate,
                                                        attributesModified: visible.attributeModificationDate, identity: String(describing: visible.fileResourceIdentifier))
            }
        }
        return result
    }
}
