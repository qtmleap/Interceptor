import Foundation
import XCTest
@testable import AutomationCore

final class CatalogFileBoundaryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("InterceptorCatalogBoundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCatalogSymlinkIsRejectedAndTargetPreserved() throws {
        let target = directory.appendingPathComponent("original.json")
        let bytes = try CatalogCodec.encode(Catalog())
        try bytes.write(to: target)
        let link = directory.appendingPathComponent("catalog.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CatalogFile(url: link).read()) {
            XCTAssertEqual($0 as? AutomationError, .corruptStore)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testSidecarSymlinkIsRejectedAndTargetPreserved() throws {
        let target = directory.appendingPathComponent("target")
        let bytes = Data("untouched".utf8)
        try bytes.write(to: target)
        let file = directory.appendingPathComponent("catalog.json")
        try FileManager.default.createSymbolicLink(at: file.appendingPathExtension("lock"), withDestinationURL: target)
        XCTAssertThrowsError(try CatalogFile(url: file).locked { true }) {
            XCTAssertEqual($0 as? AutomationError, .saveFailed)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testOversizedSparseCatalogIsRejectedBeforeDecoding() throws {
        let file = directory.appendingPathComponent("catalog.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(Limits.catalogBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try CatalogFile(url: file).read()) {
            XCTAssertEqual($0 as? AutomationError, .corruptStore)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, Limits.catalogBytes + 1)
    }
}
