import Darwin
import Foundation

/// Independent loss detection, not an authority for selections or grants. Does not detect an old v2
/// rollback or simultaneous loss of this marker and the shared document. Call writers under the
/// existing activation lock; this helper never acquires another lock or repairs state on read.
enum ActivationInitialization {
    typealias Reader = @Sendable (CatalogFile) throws -> Data?
    private static let maximumBytes = 4096
    private static let bytes = Data("{\"version\":1}".utf8)

    private static func marker(_ file: CatalogFile) -> CatalogFile {
        CatalogFile(url: file.url.appendingPathExtension("initialized"))
    }

    /// Read shared bytes first: a concurrent initializer must not be missed before accepting v1/absence.
    static func read(_ file: CatalogFile, reader: Reader = {
        try $0.read(maximumBytes: PluginActivationStore.maxBytes)
    }) throws -> (bytes: Data?, initialized: Bool) {
        let shared = try reader(file)
        let initialized = try exists(file)
        // The first bytes may predate the unchanged v2 barrier whose marker we just observed.
        // Take one bounded post-marker read so initialization cannot reject unchanged live grants.
        if initialized { return (try reader(file), true) }
        return (shared, false)
    }

    static func validate(_ document: ActivationDocument, initialized: Bool) throws {
        guard !initialized || document.selections != nil else { throw AutomationError.corruptStore }
    }

    private static func exists(_ file: CatalogFile) throws -> Bool {
        let markerFile = marker(file)
        var info = stat()
        guard lstat(markerFile.url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw AutomationError.corruptStore
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              let data = try markerFile.read(maximumBytes: maximumBytes) else { throw AutomationError.corruptStore }
        do {
            let fields = try JSONFields(try StrictJSON.parse(data), required: ["version"], error: .corruptStore)
            guard try fields.int("version") == 1 else { throw AutomationError.corruptStore }
            return true
        } catch { throw AutomationError.corruptStore }
    }

    /// The unchanged v2 barrier, when needed, has already been encoded and validated by the caller.
    /// Sync both directory entries before staging or changing logical state. Nothing fallible runs
    /// here after the authoritative final publication.
    static func prepare(_ file: CatalogFile, barrier: Data? = nil,
                        writer: (CatalogFile, Data) throws -> Void) throws {
        if let barrier { try writer(file, barrier) }
        if try !exists(file) { try marker(file).replace(with: bytes) }
        try file.synchronizeParentDirectory()
    }
}
