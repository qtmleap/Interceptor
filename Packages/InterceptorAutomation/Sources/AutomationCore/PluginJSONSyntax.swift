import Foundation

/// Streaming RFC 8259 syntax check over raw UTF-8 that builds no value tree. It enforces the same
/// structural rules as `StrictJSON` (no BOM, no trailing input, no duplicate keys after unescaping,
/// paired surrogates, depth <= 64) but accepts any syntactically valid number spelling, because the
/// store preserves the original bytes rather than a canonical representation.
enum PluginJSONSyntax {
    static func validate(_ bytes: [UInt8]) throws {
        var scanner = Scanner(b: bytes)
        try scanner.document()
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(b: [UInt8]) { self.b = b }

        mutating func document() throws {
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { throw AutomationError.invalidJSON }
            skipWS()
            try value(depth: 0)
            skipWS()
            guard i == b.count else { throw AutomationError.invalidJSON }
        }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value(depth: Int) throws {
            guard i < b.count else { throw AutomationError.invalidJSON }
            switch b[i] {
            case UInt8(ascii: "{"): try object(depth: depth + 1)
            case UInt8(ascii: "["): try array(depth: depth + 1)
            case UInt8(ascii: "\""): _ = try string(collect: false)
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            default: try number()
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw AutomationError.invalidJSON }
            i += u.count
        }

        mutating func array(depth: Int) throws {
            guard depth <= Limits.depth else { throw AutomationError.limitExceeded }
            i += 1
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return }
            while true {
                skipWS()
                try value(depth: depth)
                skipWS()
                guard i < b.count else { throw AutomationError.invalidJSON }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return }
                throw AutomationError.invalidJSON
            }
        }

        mutating func object(depth: Int) throws {
            guard depth <= Limits.depth else { throw AutomationError.limitExceeded }
            i += 1
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return }
            var keys = Set<[UInt8]>()
            while true {
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw AutomationError.invalidJSON }
                let key = try string(collect: true)
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw AutomationError.invalidJSON }
                i += 1
                skipWS()
                try value(depth: depth)
                guard keys.insert(key).inserted else { throw AutomationError.duplicateKey }
                skipWS()
                guard i < b.count else { throw AutomationError.invalidJSON }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return }
                throw AutomationError.invalidJSON
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw AutomationError.invalidJSON }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw AutomationError.invalidJSON
                }
                v = v << 4 | d
                i += 1
            }
            return v
        }

        /// Input originates from a Swift `String`, so raw multi-byte sequences are already valid UTF-8.
        /// Only keys are collected (unescaped) for duplicate detection.
        mutating func string(collect: Bool) throws -> [UInt8] {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw AutomationError.invalidJSON }
                let c = b[i]
                switch c {
                case UInt8(ascii: "\""):
                    i += 1
                    return out
                case 0..<0x20: throw AutomationError.invalidJSON
                case UInt8(ascii: "\\"):
                    i += 1
                    guard i < b.count else { throw AutomationError.invalidJSON }
                    let e = b[i]
                    i += 1
                    let unescaped: [UInt8]
                    switch e {
                    case UInt8(ascii: "\""): unescaped = [0x22]
                    case UInt8(ascii: "\\"): unescaped = [0x5C]
                    case UInt8(ascii: "/"): unescaped = [0x2F]
                    case UInt8(ascii: "b"): unescaped = [0x08]
                    case UInt8(ascii: "f"): unescaped = [0x0C]
                    case UInt8(ascii: "n"): unescaped = [0x0A]
                    case UInt8(ascii: "r"): unescaped = [0x0D]
                    case UInt8(ascii: "t"): unescaped = [0x09]
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if (0xD800...0xDBFF).contains(cp) {
                            guard i + 1 < b.count, b[i] == 0x5C, b[i + 1] == UInt8(ascii: "u") else { throw AutomationError.invalidJSON }
                            i += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw AutomationError.invalidJSON }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(cp) {
                            throw AutomationError.invalidJSON
                        }
                        guard let scalar = Unicode.Scalar(cp) else { throw AutomationError.invalidJSON }
                        unescaped = collect ? Array(String(Character(scalar)).utf8) : []
                    default: throw AutomationError.invalidJSON
                    }
                    if collect { out += unescaped }
                default:
                    if collect { out.append(c) }
                    i += 1
                }
            }
        }

        mutating func number() throws {
            func isDigit(_ k: Int) -> Bool { k < b.count && b[k] >= 0x30 && b[k] <= 0x39 }
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { throw AutomationError.invalidJSON }
            if b[i] == 0x30 { i += 1 } else { while isDigit(i) { i += 1 } }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                guard isDigit(i) else { throw AutomationError.invalidJSON }
                while isDigit(i) { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard isDigit(i) else { throw AutomationError.invalidJSON }
                while isDigit(i) { i += 1 }
            }
            // Same finite-Double rule as StrictJSON; the original spelling is still what gets stored.
            guard let d = Double(String(decoding: b[start..<i], as: UTF8.self)), d.isFinite
            else { throw AutomationError.invalidJSON }
        }
    }
}
