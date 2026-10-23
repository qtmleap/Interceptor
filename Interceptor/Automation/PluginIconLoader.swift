import AutomationCore
import Foundation
import ImageIO
import UIKit

/// Display-only input. Repository reads use accepted local content; this closure never fetches a URL.
struct PluginIconSource: Sendable {
    let id: String
    let cacheKey: String
    let load: @Sendable () async throws -> PluginIcon?

    static func bundled(_ package: PluginPackage) -> PluginIconSource? {
        guard let icon = package.icon else { return nil }
        let key = Digest.sha256Hex(icon.data)
        return .init(id: key, cacheKey: key, load: { icon })
    }
}

/// UIImage is immutable after construction; decoding happens away from the UI actor.
struct DecodedPluginIcon: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}

/// Bounded thumbnails shared by list, hero and queue. Missing catalog content is not negatively cached.
actor PluginIconLoader {
    static let shared = PluginIconLoader()
    private struct Loaded: Sendable {
        let available: Bool
        let image: DecodedPluginIcon?
    }
    private var entries: [String: Loaded] = [:]
    private var order: [String] = []
    private var absent = Set<String>()
    private var absentOrder: [String] = []
    private let absentLimit = Limits.plugins * Limits.repositories
    private struct PendingKey: Hashable { let revision: String; let generation: String }
    private var pending: [PendingKey: (id: UUID, task: Task<Loaded, Never>)] = [:]
    private var cost = 0
    private let countLimit: Int
    private let costLimit: Int

    init(countLimit: Int = 64, costLimit: Int = 8 * 1024 * 1024) {
        self.countLimit = max(1, countLimit)
        self.costLimit = max(0, costLimit)
    }

    func image(for source: PluginIconSource) async -> DecodedPluginIcon? {
        if absent.contains(source.cacheKey) { return nil }
        if let hit = entries[source.cacheKey] {
            touch(source.cacheKey)
            return hit.image
        }
        let pendingKey = PendingKey(revision: source.cacheKey, generation: source.id)
        let task: Task<Loaded, Never>
        let taskID: UUID
        if let existing = pending[pendingKey] {
            task = existing.task
            taskID = existing.id
        } else {
            taskID = UUID()
            task = Task.detached(priority: .utility) {
                do {
                    let icon = try await source.load()
                    return Loaded(available: true, image: icon.flatMap(Self.decode))
                } catch {
                    return Loaded(available: false, image: nil)
                }
            }
            pending[pendingKey] = (taskID, task)
        }
        let loaded = await task.value
        // Only the first waiter inserts this result.
        guard pending[pendingKey]?.id == taskID else { return loaded.image }
        pending.removeValue(forKey: pendingKey)
        if loaded.available, loaded.image == nil {
            absent.insert(source.cacheKey)
            absentOrder.removeAll { $0 == source.cacheKey }
            absentOrder.append(source.cacheKey)
            if absentOrder.count > absentLimit { absent.remove(absentOrder.removeFirst()) }
        } else if loaded.available {
            cost -= entries[source.cacheKey]?.image?.cost ?? 0
            entries[source.cacheKey] = loaded
            cost += loaded.image?.cost ?? 0
            touch(source.cacheKey)
            while order.count > countLimit || cost > costLimit {
                let key = order.removeFirst()
                cost -= entries.removeValue(forKey: key)?.image?.cost ?? 0
            }
        }
        return loaded.image
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    nonisolated private static func decode(_ icon: PluginIcon) -> DecodedPluginIcon? {
        guard let source = CGImageSourceCreateWithData(icon.data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 192,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return DecodedPluginIcon(image: UIImage(cgImage: image), cost: image.bytesPerRow * image.height)
    }
}
