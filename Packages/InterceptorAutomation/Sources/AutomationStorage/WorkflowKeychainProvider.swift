import Foundation
import CryptoKit
import Security

/// Grant-scoped, device-only keys shared by the app and its PacketTunnel extension.
/// Reads never generate replacement keys for existing ciphertext.
public final class WorkflowKeychainProvider: WorkflowKeyProvider {
    private let backend: any WorkflowKeychainAccess

    public init() { backend = SystemWorkflowKeychainAccess() }
    init(backend: any WorkflowKeychainAccess) { self.backend = backend }

    public func key(for grantID: UUID) throws -> SymmetricKey {
        var query = attributes(for: grantID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = backend.copy(query)
        guard status == errSecSuccess, let bytes = item as? Data, bytes.count == 32 else {
            throw WorkflowStorageError.keyUnavailable
        }
        return SymmetricKey(data: bytes)
    }

    /// Call only while preparing explicit app activation, before committing that grant to SQLite.
    /// A failed activation retains this key; retry the same grant ID. Never replace a duplicate item.
    @discardableResult public func createKey(for grantID: UUID) throws -> SymmetricKey {
        var random = [UInt8](repeating: 0, count: 32)
        guard backend.random(&random) == errSecSuccess, random.count == 32 else {
            throw WorkflowStorageError.keyUnavailable
        }
        let bytes = Data(random)
        var item = attributes(for: grantID)
        item[kSecValueData as String] = bytes
        switch backend.add(item) {
        case errSecSuccess: return SymmetricKey(data: bytes)
        case errSecDuplicateItem: return try key(for: grantID)
        default: throw WorkflowStorageError.keyUnavailable
        }
    }

    private func attributes(for grantID: UUID) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: "group.jp.qleap.intrcptr",
            kSecAttrService as String: "jp.qleap.intrcptr.workflow-keys.v2",
            kSecAttrAccount as String: grantID.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = true
        #endif
        return attributes
    }
}

/// Internal seam for deterministic policy/failure tests; never exposes a JS-accessible key API.
protocol WorkflowKeychainAccess: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ query: [String: Any]) -> OSStatus
    func random(_ bytes: inout [UInt8]) -> OSStatus
}

private struct SystemWorkflowKeychainAccess: WorkflowKeychainAccess {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func random(_ bytes: inout [UInt8]) -> OSStatus {
        let count = bytes.count
        return bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
    }
}
