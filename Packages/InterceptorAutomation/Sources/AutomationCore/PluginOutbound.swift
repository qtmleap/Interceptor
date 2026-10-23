import Foundation

/// Limits and grammar for schema-2 `outbound` declarations and HTTP intents. Pure validation; no networking.
public enum PluginOutboundPolicy {
    public static let maxBindings = 4
    public static let maxURLBytes = 2048
    public static let maxPathBytes = 1024
    public static let maxBindingNameBytes = 32
    public static let maxDeclaredHeaders = 8
    public static let maxHeaderNameBytes = 128
    public static let maxHeaderValueBytes = 4096
    public static let maxTotalHeaderValueBytes = 8192

    private static let denied: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer", "expect", "keep-alive", "set-cookie",
    ]

    /// Lowercase ASCII HTTP token, at most 128 bytes, not hop-by-hop, framing, `proxy-*` or a pseudo-header.
    public static func isAllowedHeaderName(_ s: String) -> Bool {
        let extra = Array("!#$%&'*+-.^_`|~".utf8)
        guard !s.isEmpty, s.utf8.count <= maxHeaderNameBytes, s.utf8.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || extra.contains($0)
        }) else { return false }
        return !denied.contains(s) && !s.hasPrefix("proxy-")
    }

    /// Printable ASCII, space and HTAB only.
    public static func isAllowedHeaderValue(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 <= 0x7E) }
    }

    static func isBindingName(_ s: String) -> Bool {
        guard let first = s.utf8.first, s.utf8.count <= maxBindingNameBytes,
              (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }

    /// Canonical `https://<lowercase DNS host>/<encoded path>`: default port only, no userinfo, query or fragment.
    public static func isAllowedURL(_ s: String) -> Bool {
        guard s.utf8.count <= maxURLBytes, s.hasPrefix("https://") else { return false }
        let rest = s.dropFirst("https://".count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let host = String(rest[..<slash]), path = String(rest[slash...])
        guard PluginManifest.isMatchHost(host), isPublicDNSName(host), isSafePath(path) else { return false }
        return true
    }

    static func hostAndPath(of url: String) -> (host: String, path: String)? {
        let rest = url.dropFirst("https://".count)
        guard url.hasPrefix("https://"), let slash = rest.firstIndex(of: "/") else { return nil }
        return (String(rest[..<slash]), String(rest[slash...]))
    }

    private static func isPublicDNSName(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last,
              tld.utf8.contains(where: { $0 >= 0x61 && $0 <= 0x7A }) else { return false }
        return !["local", "localhost"].contains(String(tld))
    }

    private static func isSafePath(_ p: String) -> Bool {
        guard PluginManifest.isEncodedPath(p) else { return false }
        let u = Array(p.utf8)
        func hex(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10 }
        var i = 0
        while i < u.count {
            if u[i] == 0x25 {
                let v = hex(u[i + 1]) << 4 | hex(u[i + 2])
                if v < 0x20 || v == 0x7F || v == 0x5C { return false }
                i += 3
            } else { i += 1 }
        }
        return true
    }
}

/// A validated fixed GET destination and the header names a hook may supply for it.
public struct PluginOutboundEndpoint: Equatable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String]

    public init(url: String, method: String, headers: [String]) {
        self.url = url
        self.method = method
        self.headers = headers
    }

    public var host: String { PluginOutboundPolicy.hostAndPath(of: url)?.host ?? "" }
    public var path: String { PluginOutboundPolicy.hostAndPath(of: url)?.path ?? "" }

    static func validating(_ v: JSONValue) throws -> PluginOutboundEndpoint {
        let bad = AutomationError.invalidManifest
        let f = try JSONFields(v, required: ["url", "method", "headers"], error: bad)
        let url = try f.string("url"), method = try f.string("method"), headers = try f.strings("headers")
        guard method == "GET", PluginOutboundPolicy.isAllowedURL(url),
              headers.count <= PluginOutboundPolicy.maxDeclaredHeaders, Set(headers).count == headers.count,
              headers.allSatisfy(PluginOutboundPolicy.isAllowedHeaderName) else { throw bad }
        return PluginOutboundEndpoint(url: url, method: method, headers: headers)
    }

    static func validatingAll(_ v: JSONValue) throws -> [String: PluginOutboundEndpoint] {
        guard case .object(let o) = v, o.count <= PluginOutboundPolicy.maxBindings,
              o.keys.allSatisfy(PluginOutboundPolicy.isBindingName) else { throw AutomationError.invalidManifest }
        return try o.mapValues(validating)
    }
}

public enum PluginOutboundIntentError: Error, Equatable, Sendable {
    case malformed, unknownBinding, undeclaredHeader, invalidHeaderValue, limitExceeded
}

/// An HTTP action `{type, binding, headers}` checked against a manifest. The URL comes only from the manifest.
public struct PluginOutboundIntent: Equatable, Sendable {
    public let binding: String
    public let endpoint: PluginOutboundEndpoint
    public let headers: [String: String]

    public static func validating(_ action: JSONValue, manifest: PluginManifest) throws -> PluginOutboundIntent {
        guard case .object(let o) = action, Set(o.keys) == ["type", "binding", "headers"],
              case .string("http")? = o["type"], case .string(let binding)? = o["binding"],
              case .object(let raw)? = o["headers"] else { throw PluginOutboundIntentError.malformed }
        guard let endpoint = manifest.outbound[binding] else { throw PluginOutboundIntentError.unknownBinding }
        var headers: [String: String] = [:], total = 0
        for (name, value) in raw {
            guard endpoint.headers.contains(name) else { throw PluginOutboundIntentError.undeclaredHeader }
            guard case .string(let s) = value else { throw PluginOutboundIntentError.malformed }
            guard PluginOutboundPolicy.isAllowedHeaderValue(s) else { throw PluginOutboundIntentError.invalidHeaderValue }
            guard s.utf8.count <= PluginOutboundPolicy.maxHeaderValueBytes else { throw PluginOutboundIntentError.limitExceeded }
            total += s.utf8.count
            headers[name] = s
        }
        guard total <= PluginOutboundPolicy.maxTotalHeaderValueBytes else { throw PluginOutboundIntentError.limitExceeded }
        return PluginOutboundIntent(binding: binding, endpoint: endpoint, headers: headers)
    }
}
