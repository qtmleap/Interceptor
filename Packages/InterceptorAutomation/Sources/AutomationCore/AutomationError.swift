import Foundation

public enum AutomationError: Error, Equatable, Sendable {
    case invalidURL, invalidJSON, duplicateKey, invalidBase64, limitExceeded
    case invalidSignature, hashMismatch, sizeMismatch, metadataMismatch
    case invalidManifest
    case expired, notYetValid, lifetimeTooLong
    case rollback, sameSequenceDifferentPayload
    case repositoryIdentityChanged, keyChanged, signatureRemoved, fingerprintMismatch
    case acknowledgmentRequired
    case staleGeneration, staleSnapshot
    case corruptStore, saveFailed
    case unknownRepository, unknownRevision, noChange
}

public enum Limits {
    public static let payload = 512 * 1024, envelope = 768 * 1024, package = 262_144
    public static let source = 131_072, settingsBytes = 8 * 1024, settingsDepth = 16
    public static let depth = 64, plugins = 100, maxLifetime: TimeInterval = 90 * 86_400
    public static let clockSkew: TimeInterval = 300
    public static let maxSequence: Int64 = 9_007_199_254_740_991
    public static let repositories = 16, revisions = 32
    public static let rawPackageBytes = 8 * 1024 * 1024, catalogBytes = 16 * 1024 * 1024
}
