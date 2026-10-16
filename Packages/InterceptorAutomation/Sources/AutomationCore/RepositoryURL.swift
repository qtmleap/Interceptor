import Foundation

public struct RepositoryURL: Equatable, Hashable, Sendable {
    public let envelopeURL: URL
    let host: String
    let port: Int?
    let segments: [String]

    /// Canonical HTTPS envelope URL: lowercase ASCII DNS host or localhost, no :443, directory URLs
    /// (trailing "/") append repository.json. Rejects userinfo/query/fragment/percent/backslash/non-ASCII/IP/dot segments.
    public init(parsing string: String) throws {
        let u = Array(string.utf8)
        guard !u.isEmpty, u.count <= 2048, u.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              !u.contains(where: { [0x25, 0x3F, 0x23, 0x40, 0x5C].contains($0) }) else { throw AutomationError.invalidURL }
        let prefix = "https://"
        guard string.count >= prefix.count, string.prefix(prefix.count).lowercased() == prefix else { throw AutomationError.invalidURL }
        let rest = string.dropFirst(prefix.count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<slash])
        let path = String(rest[slash...])

        var hostPart = authority
        var port: Int?
        if let colon = authority.firstIndex(of: ":") {
            hostPart = String(authority[..<colon])
            let p = authority[authority.index(after: colon)...]
            guard !p.isEmpty, p.count <= 5, p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), p.first != "0",
                  let n = Int(p), (1...65_535).contains(n) else { throw AutomationError.invalidURL }
            port = n == 443 ? nil : n
        }
        let host = hostPart.lowercased()
        guard RepositoryURL.isValidHost(host) else { throw AutomationError.invalidURL }

        var segs: [String]
        if path.isEmpty || path == "/" {
            segs = ["repository.json"]
        } else {
            segs = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if path.hasSuffix("/") { segs.removeLast(); segs.append("repository.json") }
        }
        guard segs.allSatisfy(RepositoryURL.isValidSegment) else { throw AutomationError.invalidURL }
        let canonical = RepositoryURL.build(host: host, port: port, segments: segs)
        guard canonical.utf8.count <= 1024, let url = URL(string: canonical) else { throw AutomationError.invalidURL }
        self.envelopeURL = url
        self.host = host
        self.port = port
        self.segments = segs
    }

    public var canonical: String { envelopeURL.absoluteString }

    /// Same-origin, confined package URL for a relative index `packagePath`.
    public func packageURL(path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count <= 256, !parts.isEmpty, parts.allSatisfy(RepositoryURL.isValidSegment) else { throw AutomationError.invalidURL }
        let s = RepositoryURL.build(host: host, port: port, segments: Array(segments.dropLast()) + parts)
        guard s.utf8.count <= 1024, let url = URL(string: s) else { throw AutomationError.invalidURL }
        return url
    }

    static func isValidRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return path.utf8.count <= 256 && !parts.isEmpty && parts.allSatisfy(isValidSegment)
    }

    static func isValidSegment(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.utf8.count <= 128 && s.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// Lowercase ASCII DNS name (>= 2 labels, alphabetic-leading TLD so numeric/IP forms fail) or localhost.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 || host == "localhost", !labels.contains(where: \.isEmpty), host.last != "." else { return false }
        for l in labels {
            guard l.utf8.count <= 63, l.first != "-", l.last != "-",
                  l.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }) else { return false }
        }
        guard let tld = labels.last?.utf8.first, tld >= 0x61 && tld <= 0x7A else { return false }
        return true
    }

    private static func build(host: String, port: Int?, segments: [String]) -> String {
        "https://" + host + (port.map { ":\($0)" } ?? "") + "/" + segments.joined(separator: "/")
    }
}
