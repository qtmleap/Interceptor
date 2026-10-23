import Foundation
import XCTest
@testable import AutomationCore

final class PluginIconTests: XCTestCase {
    func testSharedSDKVectorsAndPublicValidatedMetadata() throws {
        struct Vector: Decodable {
            let name: String, path: String, base64: String
            let expectedValid: Bool
            let width: Int, height: Int
        }
        for vector in try JSONDecoder().decode([Vector].self, from: Data(pluginIconVectorJSON.utf8)) {
            let bytes = try XCTUnwrap(Data(base64Encoded: vector.base64))
            if vector.expectedValid {
                let icon = try PluginIcon.validate(data: bytes, path: vector.path)
                XCTAssertEqual(icon.data, bytes, vector.name)
                XCTAssertEqual(icon.path, vector.path, vector.name)
                XCTAssertEqual(icon.width, vector.width, vector.name)
                XCTAssertEqual(icon.height, vector.height, vector.name)
                XCTAssertEqual(try PluginPackage.validate(package(path: vector.path, bytes: bytes)).icon, icon)
            } else {
                XCTAssertThrowsError(try PluginIcon.validate(data: bytes, path: vector.path), vector.name)
            }
        }
    }

    func testStaticPNGAndWebPVariantsAreAccepted() throws {
        for (path, bytes) in [("art/icon.png", png()), ("icon.webp", webp([("VP8L", lossless())])),
                              ("icon.webp", webp([("VP8 ", lossy())])),
                              ("icon.webp", webp([("VP8X", extended()), ("VP8L", lossless())]))] {
            let input = try package(path: path, bytes: bytes)
            XCTAssertEqual(try PluginPackage.validate(input).bytes, input)
        }
    }

    func testIconAssetsMustBeAnExactPair() throws {
        let encoded = png().base64EncodedString()
        let variants: [(String?, JSONValue?)] = [
            ("icon.png", nil), (nil, .object([:])), (nil, .object(["icon.png": .string(encoded)])),
            ("icon.png", .object([:])), ("icon.png", .object(["other.png": .string(encoded)])),
            ("icon.png", .object(["icon.png": .string(encoded), "extra.png": .string(encoded)])),
            ("icon.png", .null), ("icon.png", .object(["icon.png": .integer(1)]))
        ]
        for (path, assets) in variants {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: path, assets: assets)))
        }
    }

    func testSchemaOneRejectsIconAndAssets() throws {
        let legacy = try StrictJSON.parse(packageBytes())
        var object = try XCTUnwrap(legacy.objectValue)
        object["assets"] = .object(["icon.png": .string(png().base64EncodedString())])
        XCTAssertThrowsError(try PluginPackage.validate(JSONValue.object(object).data()))
        var manifest = try XCTUnwrap(object["manifest"]?.objectValue)
        manifest["icon"] = .string("icon.png")
        object["manifest"] = .object(manifest)
        object.removeValue(forKey: "assets")
        XCTAssertThrowsError(try PluginPackage.validate(JSONValue.object(object).data()))
    }

    func testIconPathsAndSourceCollisionAreRejected() throws {
        for path in ["", "/icon.png", "../icon.png", "a//icon.png", "a/./icon.png", "a\\icon.png",
                     "https://example.com/a.png", "é.png", "icon.PNG", "icon.jpg", String(repeating: "a", count: 253) + ".png"] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: path, bytes: png())), path)
        }
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: png(), sourcePath: "icon.png")))
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.webp", bytes: png())))
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: webp([("VP8L", lossless())]))))
    }

    func testBase64MustBeCanonical() throws {
        let encoded = png().base64EncodedString()
        for value in [encoded + "\n", " " + encoded, "!!!!", "", "AB=="] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", assets: .object(["icon.png": .string(value)]))))
        }
    }

    func testRawBytesAndDimensionsAreBounded() throws {
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: Data())))
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: png(extra: [("tEXt", Data(repeating: 0, count: 65_536))]))))
        for (w, h) in [(0, 1), (1, 0), (1025, 1), (1, 1025)] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: png(width: w, height: h))))
        }
        _ = try PluginPackage.validate(package(path: "icon.png", bytes: png(width: 1024, height: 1024)))
        XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.webp", bytes: webp([("VP8L", lossless(width: 1025))]))))
    }

    func testMalformedAndAnimatedPNGIsRejected() throws {
        let header = ihdr()
        var badCRC = png(); badCRC[badCRC.count - 1] ^= 1
        let variants = [Data(png().dropLast()), png() + Data([0]), badCRC,
                        pngChunks([("IHDR", header), ("IEND", Data())]),
                        pngChunks([("IDAT", Data([1])), ("IHDR", header), ("IEND", Data())]),
                        pngChunks([("IHDR", header), ("IHDR", header), ("IDAT", Data([1])), ("IEND", Data())]),
                        png(extra: [("acTL", Data(repeating: 0, count: 8))]),
                        png(extra: [("fcTL", Data())]), png(extra: [("fdAT", Data())]),
                        png(extra: [("ABCD", Data())]),
                        pngChunks([("IHDR", header), ("IDAT", Data([1])), ("tEXt", Data()), ("IDAT", Data([2])), ("IEND", Data())])]
        for bytes in variants { XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: bytes))) }
    }

    func testPNGPaletteRules() throws {
        let indexed = ihdr(color: 3, depth: 1)
        let tail: [(String, Data)] = [("IDAT", Data([1])), ("IEND", Data())]
        _ = try PluginPackage.validate(package(path: "icon.png", bytes: pngChunks([("IHDR", indexed), ("PLTE", Data([1, 2, 3]))] + tail)))
        for chunks in [[("IHDR", indexed)] + tail,
                       [("IHDR", indexed), ("PLTE", Data(repeating: 0, count: 9))] + tail,
                       [("IHDR", ihdr(color: 0)), ("PLTE", Data([1, 2, 3]))] + tail,
                       [("IHDR", indexed), ("PLTE", Data([1, 2, 3])), ("PLTE", Data([1, 2, 3]))] + tail] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.png", bytes: pngChunks(chunks))))
        }
    }

    func testMalformedAndAnimatedWebPIsRejected() throws {
        let image = ("VP8L", lossless())
        var wrongLength = webp([image]); wrongLength[4] ^= 2
        var badPadding = webp([image]); badPadding[badPadding.count - 1] = 1
        for bytes in [wrongLength, badPadding, Data(webp([image]).dropLast()), webp([image]) + Data([0]),
                      webp([]), webp([image, image]), webp([("ANIM", Data()), image]),
                      webp([("VP8X", extended(flags: 2)), image]), webp([("VP8X", extended(width: 2)), image]),
                      webp([image, ("VP8X", extended())]), webp([("VP8L", Data([0x2f]))])] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.webp", bytes: bytes)))
        }
    }

    func testWebPExtendedMetadataFlagsAndOrdering() throws {
        _ = try PluginPackage.validate(package(path: "icon.webp", bytes: webp([
            ("VP8X", extended(flags: 0x2c)), ("ICCP", Data([1])), ("VP8L", lossless()),
            ("EXIF", Data([1])), ("XMP ", Data([1]))])))
        for chunks in [[("VP8X", extended(flags: 0x20)), ("VP8L", lossless())],
                       [("VP8X", extended()), ("ICCP", Data([1])), ("VP8L", lossless())],
                       [("VP8X", extended(flags: 8)), ("EXIF", Data([1])), ("VP8L", lossless())],
                       [("VP8X", extended(flags: 0x10)), ("ALPH", Data([0])), ("VP8L", lossless())]] {
            XCTAssertThrowsError(try PluginPackage.validate(package(path: "icon.webp", bytes: webp(chunks))))
        }
    }

    func testSourceEditsRetainBundledIconAndChangeRevision() throws {
        let original = try PluginPackage.validate(package(path: "icon.png", bytes: png()))
        let edited = try original.replacingSource("// changed", file: "main.js")
        let originalObject = try XCTUnwrap(StrictJSON.parse(original.bytes).objectValue)
        let editedObject = try XCTUnwrap(StrictJSON.parse(edited.bytes).objectValue)
        XCTAssertEqual(originalObject["assets"], editedObject["assets"])
        XCTAssertEqual(original.manifest.json, edited.manifest.json)
        XCTAssertEqual(edited.sourceFiles["main.js"], "// changed")
        XCTAssertNotEqual(original.revision, edited.revision)
    }

    func testLegacyPackagesRemainByteIdenticalAndOmitAssets() throws {
        for bytes in [packageBytes(), try package(path: nil, assets: nil)] {
            let validated = try PluginPackage.validate(bytes)
            XCTAssertEqual(validated.bytes, bytes)
            XCTAssertNil(try StrictJSON.parse(bytes).objectValue?["assets"])
        }
    }

    private func package(path: String?, bytes: Data, sourcePath: String = "main.js") throws -> Data {
        try package(path: path, assets: .object([path ?? "icon.png": .string(bytes.base64EncodedString())]), sourcePath: sourcePath)
    }

    private func package(path: String?, assets: JSONValue?, sourcePath: String = "main.js") throws -> Data {
        var manifest: [String: JSONValue] = [
            "schemaVersion": .integer(2), "id": .string(pluginID.uuidString), "name": .string("Icon test"), "version": .string("1.0.0"),
            "matches": .array([.object(["hosts": .array([.string("example.com")]), "methods": .array([.string("GET")]),
                "path": .object(["kind": .string("exact"), "value": .string("/")]),
                "hooks": .object(["request": .object(["onLeave": .string(sourcePath)])])])]),
            "read": .object(["metadata": .array([]), "headers": .array([]), "queryKeys": .array([]), "body": .object(["mode": .string("none")])]),
            "write": .object(["requestBody": .bool(false), "responseBody": .bool(false)]), "endpointBindings": .array([]), "settings": .object([:])
        ]
        if let path { manifest["icon"] = .string(path) }
        var object: [String: JSONValue] = ["manifest": .object(manifest), "sourceFiles": .object([sourcePath: .string("// source")])]
        if let assets { object["assets"] = assets }
        return try JSONValue.object(object).data()
    }

    private func be(_ value: Int) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func le(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return value ^ UInt32.max
    }
    private func ihdr(width: Int = 1, height: Int = 1, color: UInt8 = 6, depth: UInt8 = 8) -> Data {
        be(width) + be(height) + Data([depth, color, 0, 0, 0])
    }
    private func png(width: Int = 1, height: Int = 1, extra: [(String, Data)] = []) -> Data {
        pngChunks([("IHDR", ihdr(width: width, height: height))] + extra + [("IDAT", Data([1])), ("IEND", Data())])
    }
    private func pngChunks(_ chunks: [(String, Data)]) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        for (name, payload) in chunks {
            let body = Data(name.utf8) + payload
            data += be(payload.count) + body + be(Int(crc(body)))
        }
        return data
    }
    private func lossless(width: Int = 1, height: Int = 1) -> Data {
        Data([0x2f]) + le((width - 1) | ((height - 1) << 14))
    }
    private func lossy() -> Data { Data([0x10, 0, 0, 0x9d, 1, 0x2a, 1, 0, 1, 0]) }
    private func extended(flags: UInt8 = 0, width: Int = 1) -> Data {
        Data([flags, 0, 0, 0, UInt8(width - 1), 0, 0, 0, 0, 0])
    }
    private func webp(_ chunks: [(String, Data)]) -> Data {
        var data = Data("WEBP".utf8)
        for (name, payload) in chunks {
            data += Data(name.utf8) + le(payload.count) + payload
            if payload.count % 2 == 1 { data.append(0) }
        }
        return Data("RIFF".utf8) + le(data.count) + data
    }
}
