//
//  CaptureHostList.swift
//  Interceptor
//
//  Shared by the app and the PacketTunnel extension so the certificate SANs,
//  CONNECT allow-list and routing are always derived from the same host list.
//

import Foundation
import Mudmouth
import NetworkExtension

enum CaptureHostList {
    /// Mudmouth's start option key carrying the JSON encoded `[ProxyOption]`.
    static let startOptionKey = "ProxyTargets"
    static let proxyPort = 6_836

    enum HostError: LocalizedError, Equatable {
        case empty
        case invalid
        case duplicate
        case notFound
        case unavailable

        var errorDescription: String? {
            switch self {
                case .empty, .invalid: String(localized: "SSL_HOST_ERROR_INVALID")
                case .duplicate: String(localized: "SSL_HOST_ERROR_DUPLICATE")
                case .notFound: String(localized: "SSL_HOST_ERROR_NOT_FOUND")
                case .unavailable: String(localized: "SSL_HOST_ERROR_UNAVAILABLE")
            }
        }
    }

    enum Failure: LocalizedError {
        case invalidTargets
        case noEnabledTargets

        var errorDescription: String? {
            switch self {
                case .invalidTargets: String(localized: "SSL_LIST_ERROR_INVALID_TARGETS")
                case .noEnabledTargets: String(localized: "SSL_LIST_ERROR_NO_ENABLED_HOSTS")
            }
        }
    }

    /// Trims, lowercases and removes ONE trailing dot.
    static func canonicalize(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    /// Validates user input and returns the canonical host.
    static func validate(_ input: String) -> Result<String, HostError> {
        let host = canonicalize(input)
        if host.isEmpty {
            return .failure(.empty)
        }
        return isValid(host) ? .success(host) : .failure(.invalid)
    }

    /// `true` only for canonical ASCII LDH DNS names with at least two labels.
    static func isValid(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host == canonicalize(host),
              host != "localhost", !host.hasSuffix(".local") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1 ... 63).contains(label.utf8.count),
                  label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 })
            else { return false }
        }
        // A purely numeric last label would be an IP address.
        return labels.last?.utf8.contains { $0 >= 97 && $0 <= 122 } ?? false
    }

    /// Fails closed unless every host is canonical and unique and at least one target is enabled.
    static func enabledTargets(in options: [ProxyOption]) throws -> [ProxyOption] {
        var seen = Set<String>()
        for option in options {
            guard isValid(option.host), seen.insert(option.host).inserted else { throw Failure.invalidTargets }
        }
        let enabled = options.filter(\.capture)
        guard !enabled.isEmpty else { throw Failure.noEnabledTargets }
        return enabled
    }

    /// Decodes the exact bytes passed to `startVPNTunnel`.
    static func decodeTargets(from options: [String: NSObject]?) throws -> [ProxyOption] {
        guard let data = options?[startOptionKey] as? Data,
              let decoded = try? JSONDecoder().decode([ProxyOption].self, from: data)
        else { throw Failure.invalidTargets }
        return try enabledTargets(in: decoded)
    }

    /// Static PAC that proxies only HTTPS (port 443) requests to an exact host in the list.
    static func pacScript(hosts: [String]) -> String {
        let list = (try? JSONEncoder().encode(hosts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return #"""
        function FindProxyForURL(url, host) {
            var hosts = \#(list);
            var match = /^https:\/\/([^\/?#@:]+)(?::(\d+))?(?:[\/?#]|$)/i.exec(url);
            if (!match || (match[2] && match[2] !== "443")) return "DIRECT";
            var target = host.toLowerCase();
            if (match[1].toLowerCase() !== target) return "DIRECT";
            return hosts.indexOf(target) >= 0 ? "PROXY 127.0.0.1:\#(proxyPort)" : "DIRECT";
        }
        """#
    }

    static func tunnelSettings(hosts: [String]) throws -> NEPacketTunnelNetworkSettings {
        guard !hosts.isEmpty else { throw Failure.noEnabledTargets }
        guard hosts.allSatisfy(isValid), Set(hosts).count == hosts.count else { throw Failure.invalidTargets }
        let proxySettings = NEProxySettings()
        proxySettings.autoProxyConfigurationEnabled = true
        proxySettings.proxyAutoConfigurationJavaScript = pacScript(hosts: hosts)
        proxySettings.matchDomains = hosts
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        networkSettings.mtu = 1_500
        networkSettings.proxySettings = proxySettings
        networkSettings.ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        return networkSettings
    }
}
