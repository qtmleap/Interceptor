import Foundation

/// An exact schema 2 route. The manifest alone selects the source for each lifecycle phase.
public struct PluginMatch: Equatable, Sendable {
    public let hosts: [String]
    public let methods: [String]?
    public let path: PluginSubscription.PathMatch?
    public let status: ClosedRange<Int>?
    /// Dotted lifecycle phase to relative source filename.
    public let hooks: [String: String]
    public let json: JSONValue

    init(validating v: JSONValue) throws {
        let bad = AutomationError.invalidManifest
        let m = try JSONFields(v, required: ["hosts", "methods", "path", "hooks"], error: bad)
        let hosts = try m.strings("hosts"), methods = try m.strings("methods")
        guard hosts.count == 1, hosts.allSatisfy(PluginManifest.isMatchHost), methods.count == 1,
              methods.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 && $0.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A } }) else { throw bad }
        let p = try JSONFields(try m.value("path"), required: ["kind", "value"], error: bad)
        let value = try p.string("value")
        guard try p.string("kind") == "exact", PluginManifest.isEncodedPath(value) else { throw bad }
        let h = try JSONFields(try m.value("hooks"), required: [], optional: ["request", "response"], error: bad)
        var hooks: [String: String] = [:]
        for leg in ["request", "response"] where h.has(leg) {
            let phases = try JSONFields(try h.value(leg), required: [], optional: ["onEnter", "onLeave"], error: bad)
            var count = 0
            for phase in ["onEnter", "onLeave"] where phases.has(phase) {
                let file = try phases.string(phase)
                guard PluginPackage.isSourcePath(file) else { throw bad }
                hooks[leg + "." + phase] = file
                count += 1
            }
            guard count > 0 else { throw bad }
        }
        guard !hooks.isEmpty else { throw bad }
        self.hosts = hosts
        self.methods = methods
        path = .exact(value)
        status = nil
        self.hooks = hooks
        json = v
    }

    public func matches(method: String, host: String, path requestPath: String, status code: Int?) -> Bool {
        guard hosts.contains(host), methods?.contains(method) == true, case .exact(let value) = path else { return false }
        return requestPath == value
    }
}
