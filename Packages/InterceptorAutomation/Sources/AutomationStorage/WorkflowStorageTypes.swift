import Foundation
import CryptoKit
import Darwin

/// Production implementations retrieve device-only shared Keychain keys. The store never creates or exports keys.
public protocol WorkflowKeyProvider: Sendable {
    func key(for grantID: UUID) throws -> SymmetricKey
}

public enum WorkflowStorageError: Error, Equatable, Sendable {
    case invalidInput, hashMismatch, keyUnavailable, authenticationFailed, corruptStore
    case sqlite(Int32), unsupportedVersion, staleActivation, invalidTransition, digestMismatch
    case notFound, expired, capacity, executionOwnerBusy, wrongSession
}

public enum WorkflowMode: String, Codable, Sendable { case notify, automatic }
public struct EndpointIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: String
    public let epoch: Int64
    public let credentialRevision: String
    public init(id: UUID, revision: String, epoch: Int64, credentialRevision: String) {
        self.id = id; self.revision = revision; self.epoch = epoch; self.credentialRevision = credentialRevision
    }
}
public struct ActivationIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let pluginID: UUID
    public let grantID: UUID
    public var epoch: Int64
    public var packageRevision: String
    public let settingsRevision: String
    public let settingsEpoch: Int64
    public let mode: WorkflowMode
    public let endpoint: EndpointIdentity?
    public init(id: UUID = UUID(), pluginID: UUID, grantID: UUID, epoch: Int64, packageRevision: String, settingsRevision: String, settingsEpoch: Int64, mode: WorkflowMode, endpoint: EndpointIdentity? = nil) {
        self.id = id; self.pluginID = pluginID; self.grantID = grantID; self.epoch = epoch
        self.packageRevision = packageRevision; self.settingsRevision = settingsRevision; self.settingsEpoch = settingsEpoch
        self.mode = mode; self.endpoint = endpoint
    }
}
public struct ActivationSnapshot: Sendable {
    public let identity: ActivationIdentity
    public let package: Data
    /// Opaque frozen permission/configuration/optional endpoint snapshot; validated by the service.
    public let configuration: Data
}
public enum OperationState: String, Codable, Sendable {
    case planning, pendingReview, approved, apiInFlight, resultReady, deliveryQueued, terminal
}
public enum TerminalReason: String, Codable, Sendable {
    case completed, cancelled, expired, revoked, quarantined, unknownOutcome, failed, exhausted, historyExpired
}
public struct OperationSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let eventID: UUID
    public let activation: ActivationIdentity
    public let state: OperationState
    public let planDigest: String?
    public let createdAt: Date
    public let expiresAt: Date
    public let reason: TerminalReason?
}
public struct APIPermit: Sendable {
    public let operationID: UUID
    public let activation: ActivationIdentity
    public let frozenPlan: Data
}
public struct DeliveryAttempt: Sendable {
    public let operationID: UUID
    public let deliveryID: UUID
    public let endpoint: EndpointIdentity
    public let bytes: Data
    public let payloadSHA256: String
    public let attempt: Int
    public let leaseID: UUID
    public let deadline: Date
    public var idempotencyKey: String { deliveryID.uuidString }
}
public struct DeliveryStatus: Sendable {
    public let operationID: UUID
    public let deliveryID: UUID
    public let attempts: Int
    public let nextAttemptAt: Date
    public let leaseDeadline: Date?
    public let expiresAt: Date
}
public enum DeliveryOutcome: Sendable { case success, permanentFailure, transientFailure }
public enum WorkflowDigest {
    public static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func plan(_ bytes: Data) -> String { sha256(Data("InterceptorFrozenPlan/v2\0".utf8) + bytes) }
}

/// A lifetime lock held only by the extension execution worker. App/UI readers do not acquire one.
/// Releasing this object marks the entire worker stopped. Finish/cancel owned JS/HTTP before release.
public final class ExecutionSession: @unchecked Sendable {
    let id = UUID()
    let path: String
    private let descriptor: Int32
    init(path: String) throws {
        self.path = path
        descriptor = open(path + ".execution-lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkflowStorageError.executionOwnerBusy }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw WorkflowStorageError.executionOwnerBusy
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
