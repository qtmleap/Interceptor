//
//  SSLProxyingListStore.swift
//  Interceptor
//
//  Copyright © 2026 QuantumLeap. All rights reserved.
//

import Foundation
import Mudmouth
import SwiftUI

/// User-editable, persisted list of hosts to proxy.
/// Removing a host never touches saved tokens or captured history.
@MainActor
final class SSLProxyingListStore: ObservableObject {
    static let key = "SSLProxyingList"
    static let currentVersion = 1

    enum LoadError: Error, Equatable {
        case corrupt
        case unsupportedVersion(Int)
    }

    private struct Envelope: Codable {
        var version: Int
        var options: [ProxyOption]
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    /// Hosts that were actually routed before the list became editable.
    static var defaultOptions: [ProxyOption] {
        [
            .init(host: "api.lp1.av5ja.srv.nintendo.net", paths: [
                .init(path: "/api/bullet_tokens"),
            ]),
            .init(host: "api.lp1.87abc152.srv.nintendo.net", paths: []),
            .init(host: "app.splatoon2.nintendo.net", paths: [
                .init(path: "/"),
            ]),
            .init(host: "app.smashbros.nintendo.net", paths: [
                .init(path: "/"),
            ]),
            .init(host: "web.sd.lp1.acbaa.srv.nintendo.net", paths: []),
        ]
    }

    @Published
    private(set) var options: [ProxyOption] = []
    /// Non-nil when the stored blob is unreadable; it is left untouched until `reset()`.
    @Published
    private(set) var loadError: LoadError?

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.applicationDefaults
        load()
    }

    private static var applicationDefaults: UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["INTERCEPTOR_TEST_PROXY_SUITE"],
           suite.hasPrefix("Interceptor.UITests."),
           let defaults = UserDefaults(suiteName: suite)
        {
            return defaults
        }
        #endif
        return .standard
    }

    /// Validates a user entered host. `original` is the host being edited and is excluded from the duplicate check.
    func validate(_ input: String, replacing original: String? = nil) -> Result<String, CaptureHostList.HostError> {
        guard loadError == nil else { return .failure(.unavailable) }
        return CaptureHostList.validate(input).flatMap { host in
            options.contains { $0.host == host && $0.host != original } ? .failure(.duplicate) : .success(host)
        }
    }

    func add(_ input: String) throws {
        let host = try validate(input).get()
        try commit(options + [.init(host: host, paths: [])])
    }

    /// Renames the entry whose current host is `original`, preserving every other field.
    func rename(_ original: String, to input: String) throws {
        let host = try validate(input, replacing: original).get()
        guard let index = options.firstIndex(where: { $0.host == original }) else { throw CaptureHostList.HostError.notFound }
        var updated = options
        updated[index].host = host
        try commit(updated)
    }

    func delete(at offsets: IndexSet) {
        guard loadError == nil else { return }
        var updated = options
        updated.remove(atOffsets: offsets)
        try? commit(updated)
    }

    func move(from source: IndexSet, to destination: Int) {
        guard loadError == nil else { return }
        var updated = options
        updated.move(fromOffsets: source, toOffset: destination)
        try? commit(updated)
    }

    func sort(ascending: Bool) {
        guard loadError == nil else { return }
        try? commit(options.sorted { ascending ? $0.host < $1.host : $0.host > $1.host })
    }

    /// Recovery from `loadError`: replaces the unreadable blob with the default list.
    func reset() {
        guard loadError != nil else { return }
        guard (try? persist(Self.defaultOptions)) != nil else { return }
        options = Self.defaultOptions
        loadError = nil
    }

    private func load() {
        guard let stored = defaults.object(forKey: Self.key) else {
            options = Self.defaultOptions
            try? persist(options)
            return
        }
        guard let data = stored as? Data, let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return loadError = .corrupt
        }
        guard probe.version == Self.currentVersion else { return loadError = .unsupportedVersion(probe.version) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              Set(envelope.options.map(\.host)).count == envelope.options.count,
              envelope.options.allSatisfy({ CaptureHostList.isValid($0.host) })
        else { return loadError = .corrupt }
        options = envelope.options
    }

    private func commit(_ updated: [ProxyOption]) throws {
        guard loadError == nil else { throw CaptureHostList.HostError.unavailable }
        try persist(updated)
        options = updated
    }

    private func persist(_ value: [ProxyOption]) throws {
        try defaults.set(JSONEncoder().encode(Envelope(version: Self.currentVersion, options: value)), forKey: Self.key)
    }
}
