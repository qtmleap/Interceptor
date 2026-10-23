import XCTest
@testable import AutomationCore

final class SemVerPrecedenceTests: XCTestCase {
    private func v(_ s: String) -> SemVer { try! SemVer(parsing: s) }

    func testOfficialSpecSequenceIsStrictlyIncreasing() {
        let seq = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                   "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "2.0.0", "2.1.0", "2.1.1"]
        for i in seq.indices {
            for j in seq.indices {
                let expected: ComparisonResult = i == j ? .orderedSame : (i < j ? .orderedAscending : .orderedDescending)
                XCTAssertEqual(v(seq[i]).comparePrecedence(to: v(seq[j])), expected, "\(seq[i]) vs \(seq[j])")
            }
        }
    }

    func testCoreIsNumericNotLexical() {
        XCTAssertEqual(v("1.10.0").comparePrecedence(to: v("1.9.0")), .orderedDescending)
        XCTAssertEqual(v("9999999999.0.0").comparePrecedence(to: v("999999999.9.9")), .orderedDescending)
    }

    func testBuildMetadataIgnoredByPrecedenceButNotEquality() {
        let a = v("1.0.0+a"), b = v("1.0.0+b"), c = v("1.0.0")
        XCTAssertEqual(a.comparePrecedence(to: b), .orderedSame)
        XCTAssertEqual(a.comparePrecedence(to: c), .orderedSame)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(v("1.0.0-rc.1+x").comparePrecedence(to: v("1.0.0-rc.1+y")), .orderedSame)
        XCTAssertEqual(v("1.0.0-rc.1+zzz").comparePrecedence(to: v("1.0.0")), .orderedAscending)
    }

    func testPrereleaseNumericVersusAlphanumeric() {
        XCTAssertEqual(v("1.0.0-1").comparePrecedence(to: v("1.0.0-a")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-a").comparePrecedence(to: v("1.0.0-1")), .orderedDescending)
        XCTAssertEqual(v("1.0.0-2").comparePrecedence(to: v("1.0.0-10")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-0").comparePrecedence(to: v("1.0.0-0")), .orderedSame)
        // Lexical ASCII: uppercase before lowercase, no locale collation; hyphen-bearing identifiers.
        XCTAssertEqual(v("1.0.0-B").comparePrecedence(to: v("1.0.0-a")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-a-b").comparePrecedence(to: v("1.0.0-a")), .orderedDescending)
        XCTAssertEqual(v("1.0.0-alpha").comparePrecedence(to: v("1.0.0-alpha.0")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-1a").comparePrecedence(to: v("1.0.0-1b")), .orderedAscending)
    }

    func testNumericPrereleaseBeyondUInt64DoesNotOverflow() {
        let big = "18446744073709551616"   // UInt64.max + 1
        let bigger = "18446744073709551617"
        let huge = "100000000000000000000000"
        XCTAssertEqual(v("1.0.0-\(big)").comparePrecedence(to: v("1.0.0-\(bigger)")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-\(huge)").comparePrecedence(to: v("1.0.0-\(big)")), .orderedDescending)
        XCTAssertEqual(v("1.0.0-\(big)").comparePrecedence(to: v("1.0.0-\(big)")), .orderedSame)
        XCTAssertEqual(v("1.0.0-\(big)").comparePrecedence(to: v("1.0.0-9")), .orderedDescending)
        XCTAssertEqual(v("1.0.0-\(big)").comparePrecedence(to: v("1.0.0-a")), .orderedAscending)
    }
}
