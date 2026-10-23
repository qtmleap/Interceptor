import AutomationCore
import CryptoKit
import Mudmouth
import SwiftUI
import UniformTypeIdentifiers

/// UI-only folder authority. The tunnel can enqueue file records, but cannot obtain or use a bookmark.
@MainActor
final class PluginFileDestinationController: ObservableObject {
    struct FolderRequest: Identifiable {
        let family: String
        let prefix: String
        var id: String { family + "\n" + prefix }
    }
    @Published var folderRequest: FolderRequest?
    @Published var showError = false
    private var presentedRequest: String?
    private var isActive = false
    private var canPrompt = true
    private var synchronizing = false
    private var delivered: [String: String] = [:]
    private var failures: [String: (attempt: Int, after: Date)] = [:]
    private var reportedFailures = Set<String>()

    private let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appending(path: "Interceptor/FileDestinations", directoryHint: .isDirectory)
    private var grants: PluginFolderGrantStore { PluginFolderGrantStore(url: base.appending(path: "grants.json")) }
    private lazy var publisher = PluginFilePublisher(stateURL: base.appending(path: "ownership.json"))

    func becameActive() {
        isActive = true
        canPrompt = true
    }

    func becameInactive() { isActive = false }

    func cancelFolderSelection() {
        canPrompt = false
        presentedRequest = nil
        folderRequest = nil
    }

    func folderSheetDismissed() {
        if presentedRequest != nil { cancelFolderSelection() }
    }

    func selectedFolder(_ url: URL, for request: FolderRequest) {
        presentedRequest = nil
        folderRequest = nil
        Task {
            guard url.startAccessingSecurityScopedResource() else { showError = true; canPrompt = false; return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let store = grants
                try await Task.detached {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey,
                                                                 .fileResourceIdentifierKey, .volumeUUIDStringKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                          values.isUbiquitousItem == true,
                          request.prefix.isEmpty || Data(url.lastPathComponent.utf8) == Data(request.prefix.utf8) else { throw AutomationError.invalidURL }
                    let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    var identity = Data((values.volumeUUIDString ?? "").utf8)
                    identity.append(0)
                    if let fileID = values.fileResourceIdentifier as? Data { identity.append(fileID) }
                    else { identity.append(contentsOf: url.standardizedFileURL.path.utf8) }
                    let grant = PluginFolderGrant(bookmark: bookmark,
                                                 rootIdentity: SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined(),
                                                 pathPrefix: request.prefix)
                    try store.set(grant, for: request.family)
                }.value
                delivered.removeAll()
                failures.removeAll()
                await synchronize()
            } catch {
                canPrompt = false
                showError = true
            }
        }
    }

    func synchronize() async {
        guard isActive, CaptureAuthorization.isGranted, !synchronizing, !Task.isCancelled,
              let source = AutomationSharedConfiguration.pluginFileRecordsURL() else { return }
        synchronizing = true
        defer { synchronizing = false }
        let records = PluginFileStore(directoryURL: source)
        do {
            let versions = try await Task.detached { try records.recordVersions() }.value
            for identifier in versions.keys.sorted() {
                guard isActive, CaptureAuthorization.isGranted, !Task.isCancelled else { return }
                if delivered[identifier] == versions[identifier] { continue }
                if let failure = failures[identifier], failure.after > Date() { continue }
                do {
                    let record = try await Task.detached { try records.readRecord(identifier) }.value
                    guard delivered[identifier] != record.digest else { continue }
                    switch record.destination.storage {
                    case .local:
                        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                            .appending(path: "Plugins/Files", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        try await publisher.publish(record, to: root, rootIdentity: String(repeating: "0", count: 64))
                    case .icloud:
                        let store = grants
                        let components = record.destination.pathComponents
                        let prefix = components.count > 1 ? components[0] : ""
                        guard let grant = try await Task.detached(operation: { try store.grant(for: record.family, prefix: prefix) }).value else {
                            requestFolder(for: record.family, prefix: prefix)
                            continue
                        }
                        let root: URL
                        let stale: Bool
                        do {
                            (root, stale) = try await Task.detached {
                                var isStale = false
                                let resolved = try URL(resolvingBookmarkData: grant.bookmark, options: .withoutUI,
                                                       relativeTo: nil, bookmarkDataIsStale: &isStale)
                                return (resolved, isStale)
                            }.value
                        } catch {
                            requestFolder(for: record.family, prefix: prefix)
                            continue
                        }
                        guard root.startAccessingSecurityScopedResource() else {
                            requestFolder(for: record.family, prefix: prefix)
                            continue
                        }
                        defer { root.stopAccessingSecurityScopedResource() }
                        let validRoot = try await Task.detached {
                            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
                            return values.isDirectory == true && values.isSymbolicLink != true && values.isUbiquitousItem == true
                                && (grant.pathPrefix.isEmpty || Data(root.lastPathComponent.utf8) == Data(grant.pathPrefix.utf8))
                        }.value
                        guard validRoot else {
                            requestFolder(for: record.family, prefix: prefix)
                            continue
                        }
                        if stale {
                            try await Task.detached {
                                let refreshed = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                                try store.set(.init(bookmark: refreshed, rootIdentity: grant.rootIdentity, pathPrefix: grant.pathPrefix), for: record.family)
                            }.value
                        }
                        try await publisher.publish(record, to: root, rootIdentity: grant.rootIdentity, pathPrefix: grant.pathPrefix)
                    }
                    // A newer private record keeps a different digest and will be delivered on the next pass.
                    delivered[identifier] = record.digest
                    failures[identifier] = nil
                } catch is CancellationError { return }
                catch {
                    let count = min(4, (failures[identifier]?.attempt ?? 0) + 1)
                    failures[identifier] = (count, Date().addingTimeInterval(min(60, 5 * pow(2, Double(count - 1)))))
                    if reportedFailures.insert(identifier).inserted { showError = true }
                }
            }
        } catch {
            if reportedFailures.insert("scan").inserted { showError = true }
        }
    }

    private func requestFolder(for family: String, prefix: String) {
        guard isActive, canPrompt, presentedRequest == nil, folderRequest == nil else { return }
        let request = FolderRequest(family: family, prefix: prefix)
        presentedRequest = request.id
        folderRequest = request
    }
}

/// iOS owns the selection UI; no custom file-browser or destination-management screen.
struct PluginStorageFolderPicker: UIViewControllerRepresentable {
    let prefix: String
    let onSelect: (URL) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.title = prefix.isEmpty ? String(localized: "AUTO_FILES_SELECT_ICLOUD_ROOT")
            : String(format: String(localized: "AUTO_FILES_SELECT_ICLOUD_FOLDER %@"), prefix)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void
        let onCancel: () -> Void
        init(onSelect: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }
        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onSelect(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_: UIDocumentPickerViewController) { onCancel() }
    }
}
