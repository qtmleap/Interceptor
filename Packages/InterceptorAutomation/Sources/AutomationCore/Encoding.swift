import CryptoKit
import Foundation

public enum Digest {
    /// Lowercase 64-hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let table = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in bytes { out.append(table[Int(b >> 4)]); out.append(table[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// Standard padded RFC 4648 base64 only: no whitespace, no URL alphabet, no non-zero trailing bits.
enum StrictBase64 {
    static func decode(_ s: String) throws -> Data {
        guard s.utf8.count % 4 == 0, let d = Data(base64Encoded: s), d.base64EncodedString() == s else {
            throw AutomationError.invalidBase64
        }
        return d
    }
}

/// Second-resolution UTC RFC 3339: yyyy-MM-ddTHH:mm:ssZ.
enum DateCodec {
    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count == 20 else { return nil }
        let seps: [(Int, UInt8)] = [(4, 0x2D), (7, 0x2D), (10, 0x54), (13, 0x3A), (16, 0x3A), (19, 0x5A)]
        for (i, c) in seps where u[i] != c { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for k in r { guard u[k] >= 0x30, u[k] <= 0x39 else { return nil }; v = v * 10 + Int(u[k] - 0x30) }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19),
              y >= 1, (1...12).contains(mo), h < 24, mi < 60, sec < 60 else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
        guard (1...dim).contains(d) else { return nil }
        let days = daysFromCivil(y, mo, d)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + h * 3600 + mi * 60 + sec))
    }

    static func string(_ date: Date) -> String {
        let t = Int(date.timeIntervalSince1970.rounded(.down))
        let days = Int((Double(t) / 86_400).rounded(.down))
        let rem = t - days * 86_400
        let (y, m, d) = civilFromDays(days)
        func p(_ v: Int, _ w: Int) -> String { let s = String(v); return String(repeating: "0", count: max(0, w - s.count)) + s }
        return "\(p(y, 4))-\(p(m, 2))-\(p(d, 2))T\(p(rem / 3600, 2)):\(p(rem % 3600 / 60, 2)):\(p(rem % 60, 2))Z"
    }

    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Exact-key object reader: unknown or missing keys are errors.
struct JSONFields {
    let d: [String: JSONValue]
    let error: AutomationError

    init(_ v: JSONValue, required: Set<String>, optional: Set<String> = [], error: AutomationError = .invalidJSON) throws {
        guard case .object(let o) = v else { throw error }
        let keys = Set(o.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw error }
        d = o
        self.error = error
    }

    func has(_ k: String) -> Bool { d[k] != nil }
    func value(_ k: String) throws -> JSONValue { guard let v = d[k] else { throw error }; return v }
    func string(_ k: String) throws -> String { guard case .string(let s)? = d[k] else { throw error }; return s }
    func int(_ k: String) throws -> Int64 { guard case .integer(let n)? = d[k] else { throw error }; return n }
    func bool(_ k: String) throws -> Bool { guard case .bool(let b)? = d[k] else { throw error }; return b }
    func array(_ k: String) throws -> [JSONValue] { guard case .array(let a)? = d[k] else { throw error }; return a }
    func strings(_ k: String) throws -> [String] {
        try array(k).map { guard case .string(let s) = $0 else { throw error }; return s }
    }
    func uuid(_ k: String) throws -> UUID { guard let u = UUID(uuidString: try string(k)) else { throw error }; return u }
}

enum Text {
    /// 1...max characters, no control characters.
    static func isOptionalText(_ s: String, maxCharacters: Int, maxBytes: Int) -> Bool {
        guard !s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { return false }
        return isDisplayName(s, max: maxCharacters, maxBytes: maxBytes)
    }

    static func isDisplayName(_ s: String, max: Int = 80, maxBytes: Int = 256) -> Bool {
        guard !s.isEmpty, s.utf8.count <= maxBytes, s.count <= max else { return false }
        return !s.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}
