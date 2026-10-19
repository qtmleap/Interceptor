import Foundation

/// One validated v2 match: hosts OR, methods OR, path exact/prefix, optional response status range.
/// Fields combine with AND. No globs or regular expressions.
public struct PluginMatch: Equatable, Sendable {
    public let hosts: [String]
    public let methods: [String]?
    public let path: PluginSubscription.PathMatch?
    public let status: ClosedRange<Int>?
    /// The exact validated match object, used to compare source registrations against the manifest.
    public let json: JSONValue

    init(validating v: JSONValue) throws {
        let bad = AutomationError.invalidManifest
        let m = try JSONFields(v, required: ["hosts"], optional: ["methods", "path", "status"], error: bad)
        let hosts = try m.strings("hosts")
        guard (1...32).contains(hosts.count), Set(hosts).count == hosts.count, hosts.allSatisfy(PluginManifest.isMatchHost) else { throw bad }
        var methods: [String]?
        if m.has("methods") {
            let ms = try m.strings("methods")
            guard (1...16).contains(ms.count), Set(ms).count == ms.count,
                  ms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 && $0.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A } }) else { throw bad }
            methods = ms
        }
        var path: PluginSubscription.PathMatch?
        if m.has("path") {
            let p = try JSONFields(try m.value("path"), required: ["kind", "value"], error: bad)
            let value = try p.string("value")
            guard PluginManifest.isEncodedPath(value) else { throw bad }
            switch try p.string("kind") {
            case "exact": path = .exact(value)
            case "prefix": path = .prefix(value)
            default: throw bad
            }
        }
        var status: ClosedRange<Int>?
        if m.has("status") {
            let s = try JSONFields(try m.value("status"), required: ["min", "max"], error: bad)
            let lo = try s.int("min"), hi = try s.int("max")
            guard (100...599).contains(lo), (100...599).contains(hi), lo <= hi else { throw bad }
            status = Int(lo)...Int(hi)
        }
        self.hosts = hosts
        self.methods = methods
        self.path = path
        self.status = status
        json = v
    }

    /// `host` and `path` must already be canonical (lowercase host, request path without query).
    /// A status constraint never matches a leg without a status.
    public func matches(method: String, host: String, path requestPath: String, status code: Int?) -> Bool {
        guard hosts.contains(host) else { return false }
        if let methods, !methods.contains(method) { return false }
        switch path {
        case .exact(let p)?: guard requestPath == p else { return false }
        case .prefix(let p)?: guard requestPath.hasPrefix(p) else { return false }
        case nil: break
        }
        if let status {
            guard let code, status.contains(code) else { return false }
        }
        return true
    }
}
