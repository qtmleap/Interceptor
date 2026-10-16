import Foundation

public enum JSONValue: Equatable, Sendable {
    case null, bool(Bool), integer(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    /// Strict parse (see `StrictJSON`).
    public init(parsing data: Data) throws { self = try StrictJSON.parse(data) }

    /// Compact UTF-8 encoding with keys in UTF-8 byte order. Throws for non-finite numbers or depth > 64.
    public func data() throws -> Data {
        var out = [UInt8]()
        try write(into: &out, depth: 0)
        return Data(out)
    }

    public func jsonString() throws -> String { String(decoding: try data(), as: UTF8.self) }

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Maximum container nesting (scalars 0, `{}` 1).
    var nesting: Int {
        switch self {
        case .array(let a): return 1 + (a.map(\.nesting).max() ?? 0)
        case .object(let o): return 1 + (o.values.map(\.nesting).max() ?? 0)
        default: return 0
        }
    }

    private func write(into out: inout [UInt8], depth: Int) throws {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .integer(let n): out += Array(String(n).utf8)
        case .double(let d):
            guard d.isFinite else { throw AutomationError.invalidJSON }
            out += Array(String(d).utf8)
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let a):
            guard depth < Limits.depth else { throw AutomationError.limitExceeded }
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try v.write(into: &out, depth: depth + 1)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            guard depth < Limits.depth else { throw AutomationError.limitExceeded }
            out.append(UInt8(ascii: "{"))
            let keys = o.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (i, k) in keys.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSONValue.writeString(k, into: &out)
                out.append(UInt8(ascii: ":"))
                try o[k]!.write(into: &out, depth: depth + 1)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out += Array(#"\""#.utf8)
            case UInt8(ascii: "\\"): out += Array(#"\\"#.utf8)
            case 0x08: out += Array(#"\b"#.utf8)
            case 0x09: out += Array(#"\t"#.utf8)
            case 0x0A: out += Array(#"\n"#.utf8)
            case 0x0C: out += Array(#"\f"#.utf8)
            case 0x0D: out += Array(#"\r"#.utf8)
            case 0..<0x20: out += Array(String(format: "\\u%04x", UInt32(b)).utf8)
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
