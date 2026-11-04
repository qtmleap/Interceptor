import XCTest
import CryptoKit
import Security
@testable import AutomationStorage

final class WorkflowKeychainProviderTests: XCTestCase {
    private let grant = UUID(uuidString: "84AE18A7-A359-47DE-AED6-27B1A185A895")!

    func testReadUsesSharedDeviceOnlyPolicyAndNeverCreates() throws {
        let backend = KeychainFixture()
        backend.readResult = (errSecSuccess, Data(repeating: 42, count: 32) as CFData)
        let provider = WorkflowKeychainProvider(backend: backend)
        let key = try provider.key(for: grant)
        XCTAssertEqual(key.bitCount, 256)
        XCTAssertEqual(backend.addCount, 0)
        XCTAssertEqual(backend.randomCount, 0)
        assertPolicy(try XCTUnwrap(backend.lastRead), grant: grant)
    }

    func testExplicitCreationUsesSecureRandomAndDoesNotReplaceWinningKey() throws {
        let backend = KeychainFixture()
        let provider = WorkflowKeychainProvider(backend: backend)
        let first = try provider.createKey(for: grant)
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, backend.randomBytes)
        assertPolicy(try XCTUnwrap(backend.lastAdd), grant: grant)
        XCTAssertEqual(backend.lastAdd?[kSecValueData as String] as? Data, backend.randomBytes)

        backend.addStatus = errSecDuplicateItem
        let winner = Data(repeating: 99, count: 32)
        backend.readResult = (errSecSuccess, winner as CFData)
        let second = try provider.createKey(for: grant)
        XCTAssertEqual(second.withUnsafeBytes { Data($0) }, winner)
        XCTAssertEqual(backend.addCount, 2)
        assertPolicy(try XCTUnwrap(backend.lastRead), grant: grant)
    }

    func testUnavailableReadsFailClosedWithoutRandomOrWrites() throws {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecMissingEntitlement, errSecAuthFailed] {
            let backend = KeychainFixture()
            backend.readResult = (status, nil)
            XCTAssertThrowsError(try WorkflowKeychainProvider(backend: backend).key(for: grant)) {
                XCTAssertEqual($0 as? WorkflowStorageError, .keyUnavailable)
            }
            XCTAssertEqual(backend.addCount, 0)
            XCTAssertEqual(backend.randomCount, 0)
        }
    }

    func testMalformedReadAndDuplicateReadbackNeverRegenerateOrOverwrite() throws {
        let invalid: [(OSStatus, CFTypeRef?)] = [
            (errSecSuccess, nil), (errSecSuccess, "not-data" as CFString),
            (errSecSuccess, Data(repeating: 1, count: 31) as CFData),
            (errSecSuccess, Data(repeating: 1, count: 33) as CFData),
            (errSecInteractionNotAllowed, nil),
        ]
        for result in invalid {
            let backend = KeychainFixture()
            backend.addStatus = errSecDuplicateItem
            backend.readResult = result
            XCTAssertThrowsError(try WorkflowKeychainProvider(backend: backend).createKey(for: grant))
            XCTAssertEqual(backend.addCount, 1)
            XCTAssertEqual(backend.randomCount, 1)
        }
    }

    func testRandomAndAddFailuresDoNotRetryOrReadUnexpectedValues() throws {
        let randomFailure = KeychainFixture()
        randomFailure.randomStatus = errSecNotAvailable
        XCTAssertThrowsError(try WorkflowKeychainProvider(backend: randomFailure).createKey(for: grant))
        XCTAssertEqual(randomFailure.addCount, 0)
        XCTAssertNil(randomFailure.lastRead)
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable] {
            let backend = KeychainFixture()
            backend.addStatus = status
            XCTAssertThrowsError(try WorkflowKeychainProvider(backend: backend).createKey(for: grant))
            XCTAssertEqual(backend.addCount, 1)
            XCTAssertNil(backend.lastRead)
        }
    }

    func testGrantAccountsAreIsolated() throws {
        let backend = KeychainFixture()
        backend.readResult = (errSecSuccess, Data(repeating: 42, count: 32) as CFData)
        let provider = WorkflowKeychainProvider(backend: backend)
        _ = try provider.key(for: grant)
        let first = backend.lastRead?[kSecAttrAccount as String] as? String
        let other = UUID()
        _ = try provider.key(for: other)
        XCTAssertNotEqual(first, backend.lastRead?[kSecAttrAccount as String] as? String)
        XCTAssertEqual(backend.lastRead?[kSecAttrAccount as String] as? String, other.uuidString)
    }

    private func assertPolicy(_ query: [String: Any], grant: UUID) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "group.jp.qleap.intrcptr")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "jp.qleap.intrcptr.workflow-keys.v2")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, grant.uuidString)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        #if os(macOS)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
    }
}

/// No test touches Security or the user's Keychain.
private final class KeychainFixture: WorkflowKeychainAccess, @unchecked Sendable {
    var readResult: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    var addStatus: OSStatus = errSecSuccess
    var randomStatus: OSStatus = errSecSuccess
    let randomBytes = Data(repeating: 7, count: 32)
    var lastRead: [String: Any]?
    var lastAdd: [String: Any]?
    var addCount = 0
    var randomCount = 0
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        lastRead = query; return readResult
    }
    func add(_ query: [String: Any]) -> OSStatus {
        lastAdd = query; addCount += 1; return addStatus
    }
    func random(_ bytes: inout [UInt8]) -> OSStatus {
        randomCount += 1
        if randomStatus == errSecSuccess { bytes = Array(randomBytes) }
        return randomStatus
    }
}
