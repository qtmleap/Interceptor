import AutomationCore
import Foundation

/// Presentation-only JSON layout. Validates with the strict parser, then rewrites only the whitespace outside
/// strings, so number lexemes, key order and string escapes survive byte for byte. Anything that is not valid,
/// or that would exceed `maxBytes` once indented, comes back unchanged.
enum JSONPrettyPrinter {
    static func format(_ text: String, maxBytes: Int, objectOnly: Bool = true) -> String {
        let raw = Array(text.utf8)
        guard raw.count <= maxBytes, let value = try? JSONValue(parsing: Data(raw)),
              !objectOnly || value.objectValue != nil
        else { return text }
        let output = layout(raw)
        return output.count <= maxBytes ? String(decoding: output, as: UTF8.self) : text
    }

    /// `raw` is known to be strictly valid JSON.
    private static func layout(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8](), depth = 0, index = 0
        out.reserveCapacity(raw.count * 2)
        func newline() {
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while index < raw.count {
            let byte = raw[index]
            switch byte {
                case 0x22:
                    out.append(byte); index += 1
                    while raw[index] != 0x22 {
                        if raw[index] == 0x5C { out.append(raw[index]); index += 1 }
                        out.append(raw[index]); index += 1
                    }
                    out.append(0x22); index += 1
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    var next = index + 1
                    while isSpace(raw[next]) { next += 1 }
                    if raw[next] == (byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                        out.append(byte); out.append(raw[next]); index = next + 1
                    } else {
                        out.append(byte); depth += 1; newline(); index += 1
                    }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1; newline(); out.append(byte); index += 1
                case UInt8(ascii: ","):
                    out.append(byte); newline(); index += 1
                case UInt8(ascii: ":"):
                    out.append(byte); out.append(0x20); index += 1
                case _ where isSpace(byte):
                    index += 1
                default:
                    out.append(byte); index += 1
            }
        }
        return out
    }
}
