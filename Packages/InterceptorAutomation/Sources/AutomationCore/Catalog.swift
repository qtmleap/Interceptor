import Foundation

public enum TrustState: Equatable, Sendable {
    case unsignedAcknowledged, signedUnverified(PublicKeyFingerprint), pinned(PublicKeyFingerprint)
}

/// One repository identity (visible, or a hidden tombstone retaining trust and high-water state).
/// `generation` is the token an install must present; it changes on every accept/pin/remove.
public struct RepositoryRecord: Equatable, Sendable {
    public let url: RepositoryURL
    public let repositoryID: UUID
    public let trust: TrustState
    public let sequence: Int64
    public let payloadDigest: String
    public let visible: Bool
    public let generation: UUID
    /// The accepted snapshot the user reviewed (nil for hidden tombstones).
    public let snapshot: VerifiedSnapshot?
}

public struct Provenance: Equatable, Sendable {
    public enum Origin: Equatable, Sendable { case repository(url: RepositoryURL, sequence: Int64), localEdit(parent: String), localImport }
    public let origin: Origin
    public let trustAtImport: TrustState?
}

public struct InstalledRevision: Equatable, Sendable {
    public let package: PluginPackage
    public let provenance: Provenance
    /// Always false in this foundation; nothing can enable execution here.
    public let enabled: Bool

    /// Stable unique key: source identity + plugin ID + revision digest.
    public var id: String {
        let source: String
        if case .repository(let url, _) = provenance.origin { source = url.canonical } else { source = "local" }
        return "\(source)|\(package.manifest.id.uuidString)|\(package.revision)"
    }
}

public struct Catalog: Equatable, Sendable {
    public internal(set) var repositories: [RepositoryRecord] = []   // includes hidden tombstones
    public internal(set) var revisions: [InstalledRevision] = []

    public init() {}

    public var visibleRepositories: [RepositoryRecord] { repositories.filter(\.visible) }
    public func record(for url: RepositoryURL) -> RepositoryRecord? { repositories.first { $0.url == url } }
    public func revision(id: String) -> InstalledRevision? { revisions.first { $0.id == id } }
}

/// What an Add/Refresh would do, for the acknowledgment screen. Mutates nothing.
public struct AcceptancePreview: Equatable, Sendable {
    public let resultingTrust: TrustState
    public let requiresAcknowledgment: Bool
    public let isNewRepository: Bool
}

/// Admission state captured before an asynchronous repository ingestion.
public enum RepositoryAcceptanceExpectation: Equatable, Sendable {
    case absent
    case generation(UUID)
}

enum TrustPlanner {
    struct Plan { let trust: TrustState; let requiresAck: Bool }

    static func plan(existing r: RepositoryRecord?, snapshot s: VerifiedSnapshot, now: Date) throws -> Plan {
        try RepositoryEnvelope.checkTime(s.index, now: now)
        let incoming: TrustState
        switch s.signature {
        case .unsigned: incoming = .unsignedAcknowledged
        case .signed(let k): incoming = .signedUnverified(k)
        }
        guard let r else { return Plan(trust: incoming, requiresAck: true) }
        guard r.repositoryID == s.index.id else { throw AutomationError.repositoryIdentityChanged }

        let trust: TrustState, ack: Bool
        switch (r.trust, s.signature) {
        case (.pinned, .unsigned), (.signedUnverified, .unsigned): throw AutomationError.signatureRemoved
        case (.pinned(let k), .signed(let n)):
            guard k == n else { throw AutomationError.keyChanged }
            trust = r.trust; ack = false
        case (.signedUnverified(let k), .signed(let n)):
            guard k == n else { throw AutomationError.keyChanged }
            trust = r.trust; ack = !r.visible
        case (.unsignedAcknowledged, .unsigned): trust = r.trust; ack = !r.visible
        case (.unsignedAcknowledged, .signed): trust = incoming; ack = true
        }
        if s.index.sequence < r.sequence { throw AutomationError.rollback }
        if s.index.sequence == r.sequence, s.payloadDigest != r.payloadDigest { throw AutomationError.sameSequenceDifferentPayload }
        return Plan(trust: trust, requiresAck: ack)
    }
}
