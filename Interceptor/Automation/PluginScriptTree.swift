import Foundation

/// Immediate-child projection of already validated package-relative source paths.
enum PluginScriptTree {
    struct Entry: Equatable, Identifiable {
        enum Kind: String { case directory, file }

        let name: String
        /// Full relative path: the directory prefix, or the exact source file name.
        let path: String
        let kind: Kind
        var id: String { kind.rawValue + ":" + path }
    }

    /// Folders first, then files; each sorted exactly by name. Prefixes match whole path components.
    static func entries(in files: [String], at directory: [String] = []) -> [Entry] {
        var folders = Set<String>()
        var leaves = Set<String>()
        for file in files {
            let components = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count > directory.count, components.starts(with: directory) else { continue }
            if components.count == directory.count + 1 {
                leaves.insert(file)
            } else {
                folders.insert(components[directory.count])
            }
        }
        let prefix = directory.isEmpty ? "" : directory.joined(separator: "/") + "/"
        let directories = folders.sorted().map { Entry(name: $0, path: prefix + $0, kind: .directory) }
        let documents = leaves.map { Entry(name: String($0.dropFirst(prefix.count)), path: $0, kind: .file) }
            .sorted { $0.name < $1.name }
        return directories + documents
    }
}
