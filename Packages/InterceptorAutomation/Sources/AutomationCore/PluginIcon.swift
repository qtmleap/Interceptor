import Foundation

/// Bounded, static PNG/WebP package asset. Structural validation never decompresses image data;
/// platform decoders may still reject the compressed stream and should use their normal fallback.
public struct PluginIcon: Equatable, Sendable {
    public let data: Data
    public let path: String
    public let width: Int
    public let height: Int

    private init(data: Data, path: String, width: Int, height: Int) {
        self.data = data; self.path = path; self.width = width; self.height = height
    }

    public static func isPath(_ path: String) -> Bool {
        PluginPackage.isSourcePath(path) && (path.hasSuffix(".png") || path.hasSuffix(".webp"))
    }

    public static func validate(data: Data, path: String) throws -> PluginIcon {
        guard isPath(path), (1...65_536).contains(data.count) else { throw AutomationError.invalidManifest }
        let parser = Parser(bytes: Array(data))
        let dimensions = try path.hasSuffix(".png") ? parser.png() : parser.webp()
        return PluginIcon(data: data, path: path, width: dimensions.0, height: dimensions.1)
    }

    private struct Parser {
        let bytes: [UInt8]
        private var bad: AutomationError { .invalidManifest }
        private func be(_ at: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(bytes[at + $1]) }
        }
        private func le(_ at: Int, count: Int = 4) -> Int {
            (0..<count).reduce(0) { $0 | (Int(bytes[at + $1]) << (8 * $1)) }
        }
        private func dimensions(_ width: Int, _ height: Int) throws -> (Int, Int) {
            guard (1...1024).contains(width), (1...1024).contains(height) else { throw bad }
            return (width, height)
        }
        private func crc(_ range: Range<Int>) -> UInt32 {
            var value = UInt32.max
            for i in range {
                value ^= UInt32(bytes[i])
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
            }
            return value ^ UInt32.max
        }

        func png() throws -> (Int, Int) {
            guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw bad }
            var offset = 8, size: (Int, Int)?, color = 0, depth = 0
            var palette = false, image = false, endedImage = false, imageBytes = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 12 else { throw bad }
                let length = be(offset)
                guard length <= bytes.count - offset - 12 else { throw bad }
                let start = offset + 8, end = start + length
                let type = Array(bytes[(offset + 4)..<start])
                guard type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      (65...90).contains(type[2]), UInt32(be(end)) == crc((offset + 4)..<end) else { throw bad }
                let name = String(decoding: type, as: UTF8.self)
                guard name != "acTL", name != "fcTL", name != "fdAT", size != nil || name == "IHDR" else { throw bad }
                if image && name != "IDAT" { endedImage = true }
                switch name {
                case "IHDR":
                    guard offset == 8, size == nil, length == 13 else { throw bad }
                    size = try dimensions(be(start), be(start + 4))
                    depth = Int(bytes[start + 8]); color = Int(bytes[start + 9])
                    let depths: [Int: Set<Int>] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
                    guard depths[color]?.contains(depth) == true, bytes[start + 10] == 0,
                          bytes[start + 11] == 0, bytes[start + 12] <= 1 else { throw bad }
                case "PLTE":
                    guard !palette, !image, color != 0, color != 4, length > 0, length % 3 == 0,
                          length <= 768, color != 3 || length / 3 <= (1 << depth) else { throw bad }
                    palette = true
                case "IDAT":
                    guard !endedImage, color != 3 || palette else { throw bad }
                    image = true; imageBytes += length
                case "IEND":
                    guard length == 0, image, imageBytes > 0, end + 4 == bytes.count, let size else { throw bad }
                    return size
                default:
                    guard type[0] & 0x20 != 0 else { throw bad }
                }
                offset = end + 4
            }
            throw bad
        }

        func webp() throws -> (Int, Int) {
            guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8),
                  bytes[8..<12].elementsEqual("WEBP".utf8), le(4) == bytes.count - 8 else { throw bad }
            var offset = 12, canvas: (Int, Int)?, image: (Int, Int)?, imageKind: String?
            var flags: UInt8 = 0, metadata: Set<String> = []
            while offset < bytes.count {
                guard bytes.count - offset >= 8 else { throw bad }
                let type = Array(bytes[offset..<(offset + 4)])
                guard type.allSatisfy({ (32...126).contains($0) }) else { throw bad }
                let name = String(decoding: type, as: UTF8.self), length = le(offset + 4)
                guard length <= bytes.count - offset - 8 else { throw bad }
                let start = offset + 8, end = start + length, next = end + length % 2
                guard next <= bytes.count, length % 2 == 0 || bytes[end] == 0 else { throw bad }
                switch name {
                case "VP8X":
                    guard offset == 12, canvas == nil, length == 10, bytes[start] & 0xc3 == 0,
                          bytes[(start + 1)..<(start + 4)].allSatisfy({ $0 == 0 }) else { throw bad }
                    flags = bytes[start]
                    canvas = try dimensions(le(start + 4, count: 3) + 1, le(start + 7, count: 3) + 1)
                case "VP8 ":
                    guard image == nil, length >= 10, bytes[start] & 1 == 0,
                          bytes[(start + 3)..<(start + 6)].elementsEqual([0x9d, 1, 0x2a]),
                          bytes[start + 7] & 0xc0 == 0, bytes[start + 9] & 0xc0 == 0 else { throw bad }
                    image = try dimensions(le(start + 6, count: 2), le(start + 8, count: 2))
                    imageKind = name
                case "VP8L":
                    guard image == nil, length >= 5, bytes[start] == 0x2f, bytes[start + 4] & 0xe0 == 0 else { throw bad }
                    let packed = le(start + 1)
                    image = try dimensions((packed & 0x3fff) + 1, ((packed >> 14) & 0x3fff) + 1)
                    imageKind = name
                case "ANIM", "ANMF": throw bad
                case "ICCP", "ALPH", "EXIF", "XMP ":
                    guard canvas != nil, metadata.insert(name).inserted else { throw bad }
                    if name == "ICCP" || name == "ALPH" {
                        guard image == nil, name != "ALPH" || length >= 1 else { throw bad }
                    } else { guard image != nil else { throw bad } }
                default: break // Unknown printable ancillary chunks are ignored by WebP readers.
                }
                offset = next
            }
            guard let image else { throw bad }
            if let canvas {
                guard canvas.0 == image.0, canvas.1 == image.1,
                      metadata.contains("ICCP") == (flags & 0x20 != 0),
                      metadata.contains("EXIF") == (flags & 0x08 != 0),
                      metadata.contains("XMP ") == (flags & 0x04 != 0),
                      !metadata.contains("ALPH") || (flags & 0x10 != 0 && imageKind == "VP8 "),
                      flags & 0x10 == 0 || imageKind == "VP8L" || metadata.contains("ALPH") else { throw bad }
            }
            return image
        }
    }
}
