import Foundation

/// Strict RFC 8259 parser: no BOM, no trailing input, no duplicate keys (compared after unescaping),
/// strict UTF-8, paired surrogates only, integers kept exact as Int64, finite numbers only, depth <= 64.
public enum StrictJSON {
    public static func parse(_ data: Data) throws -> JSONValue {
        var scanner = Scanner(bytes: [UInt8](data))
        return try scanner.document()
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { b = bytes }

        mutating func document() throws -> JSONValue {
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { throw AutomationError.invalidJSON }
            skipWS()
            let v = try value(depth: 0)
            skipWS()
            guard i == b.count else { throw AutomationError.invalidJSON }
            return v
        }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard i < b.count else { throw AutomationError.invalidJSON }
            switch b[i] {
            case UInt8(ascii: "{"): return try object(depth: depth + 1)
            case UInt8(ascii: "["): return try array(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw AutomationError.invalidJSON }
            i += u.count
        }

        mutating func array(depth: Int) throws -> JSONValue {
            guard depth <= Limits.depth else { throw AutomationError.limitExceeded }
            i += 1
            skipWS()
            var items = [JSONValue]()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value(depth: depth))
                skipWS()
                guard i < b.count else { throw AutomationError.invalidJSON }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw AutomationError.invalidJSON
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            guard depth <= Limits.depth else { throw AutomationError.limitExceeded }
            i += 1
            skipWS()
            var dict = [String: JSONValue]()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(dict) }
            while true {
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw AutomationError.invalidJSON }
                let key = try string()
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw AutomationError.invalidJSON }
                i += 1
                skipWS()
                let v = try value(depth: depth)
                guard dict.updateValue(v, forKey: key) == nil else { throw AutomationError.duplicateKey }
                skipWS()
                guard i < b.count else { throw AutomationError.invalidJSON }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(dict) }
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

        func cont(_ at: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) throws {
            guard at < b.count, range.contains(b[at]) else { throw AutomationError.invalidJSON }
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw AutomationError.invalidJSON }
                let c = b[i]
                switch c {
                case UInt8(ascii: "\""):
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                case 0..<0x20: throw AutomationError.invalidJSON
                case UInt8(ascii: "\\"):
                    i += 1
                    guard i < b.count else { throw AutomationError.invalidJSON }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
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
                        out += Array(String(Character(scalar)).utf8)
                    default: throw AutomationError.invalidJSON
                    }
                case 0x20..<0x80:
                    out.append(c)
                    i += 1
                default:
                    let n: Int
                    switch c {
                    case 0xC2...0xDF: n = 2; try cont(i + 1)
                    case 0xE0: n = 3; try cont(i + 1, 0xA0...0xBF); try cont(i + 2)
                    case 0xE1...0xEC, 0xEE...0xEF: n = 3; try cont(i + 1); try cont(i + 2)
                    case 0xED: n = 3; try cont(i + 1, 0x80...0x9F); try cont(i + 2)
                    case 0xF0: n = 4; try cont(i + 1, 0x90...0xBF); try cont(i + 2); try cont(i + 3)
                    case 0xF1...0xF3: n = 4; try cont(i + 1); try cont(i + 2); try cont(i + 3)
                    case 0xF4: n = 4; try cont(i + 1, 0x80...0x8F); try cont(i + 2); try cont(i + 3)
                    default: throw AutomationError.invalidJSON
                    }
                    out += b[i..<i + n]
                    i += n
                }
            }
        }

        mutating func number() throws -> JSONValue {
            let start = i
            func isDigit(_ k: Int) -> Bool { k < b.count && b[k] >= 0x30 && b[k] <= 0x39 }
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { throw AutomationError.invalidJSON }
            if b[i] == 0x30 { i += 1 } else { while isDigit(i) { i += 1 } }
            var integral = true
            if i < b.count, b[i] == UInt8(ascii: ".") {
                integral = false
                i += 1
                guard isDigit(i) else { throw AutomationError.invalidJSON }
                while isDigit(i) { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                integral = false
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard isDigit(i) else { throw AutomationError.invalidJSON }
                while isDigit(i) { i += 1 }
            }
            let text = String(decoding: b[start..<i], as: UTF8.self)
            if integral {
                guard let n = Int64(text), n >= -Limits.maxSequence, n <= Limits.maxSequence else { throw AutomationError.invalidJSON }
                return .integer(n)
            }
            guard let d = Double(text), d.isFinite else { throw AutomationError.invalidJSON }
            return .double(d)
        }
    }
}
