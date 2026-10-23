import Foundation
@testable import Interceptor
import XCTest

final class PluginPublicationDateFormattingTests: XCTestCase {
    // 2026-10-19T23:59:59Z and 2026-10-20T00:00:00Z straddle a UTC day boundary.
    private let lateUTC = Date(timeIntervalSince1970: 1_792_454_399)
    private let nextUTC = Date(timeIntervalSince1970: 1_792_454_400)

    func testEnglishUsesUTCDay() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(PluginPublicationDate.string(lateUTC, locale: en), "Oct 19, 2026")
        XCTAssertEqual(PluginPublicationDate.string(nextUTC, locale: en), "Oct 20, 2026")
    }

    func testJapaneseLocalized() {
        let ja = Locale(identifier: "ja_JP")
        XCTAssertEqual(PluginPublicationDate.string(lateUTC, locale: ja), "2026年10月19日")
        XCTAssertEqual(PluginPublicationDate.string(nextUTC, locale: ja), "2026年10月20日")
    }
}
