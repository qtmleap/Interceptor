import CryptoKit
import Foundation

public struct SemVer: Equatable, Sendable {
    public let text: String

    /// Strict SemVer 2.0.0 (<= 64 bytes).
    public init(parsing s: String) throws {
        guard s.utf8.count <= 64, !s.isEmpty else { throw AutomationError.invalidManifest }
        var rest = Substring(s)
        var build: Substring?
        if let plus = rest.firstIndex(of: "+") { build = rest[rest.index(after: plus)...]; rest = rest[..<plus] }
        var pre: Substring?
        if let dash = rest.firstIndex(of: "-") { pre = rest[rest.index(after: dash)...]; rest = rest[..<dash] }
        func alnum(_ x: Substring) -> Bool { x.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D } }
        func numeric(_ x: Substring) -> Bool { !x.isEmpty && x.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy({ numeric($0) && $0.count <= 10 && ($0 == "0" || $0.first != "0") }) else { throw AutomationError.invalidManifest }
        if let pre {
            let ids = pre.split(separator: ".", omittingEmptySubsequences: false)
            guard ids.allSatisfy({ !$0.isEmpty && alnum($0) && (!numeric($0) || $0 == "0" || $0.first != "0") }) else { throw AutomationError.invalidManifest }
        }
        if let build {
            let ids = build.split(separator: ".", omittingEmptySubsequences: false)
            guard ids.allSatisfy({ !$0.isEmpty && alnum($0) }) else { throw AutomationError.invalidManifest }
        }
        text = s
    }
}

public struct IndexEntry: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let version: String
    public let packagePath: String
    public let sha256: String
    public let size: Int
}

public struct RepositoryIndex: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let sequence: Int64
    public let issuedAt: Date
    public let expiresAt: Date
    public let plugins: [IndexEntry]
}

public struct PublicKeyFingerprint: Equatable, Hashable, Sendable {
    /// Full lowercase SHA-256 hex of the raw 32-byte key.
    public let hex: String
    public let rawKey: Data

    init?(rawKey: Data) {
        guard rawKey.count == 32 else { return nil }
        self.rawKey = rawKey
        hex = Digest.sha256Hex(rawKey)
    }
}

public enum SignatureStatus: Equatable, Sendable { case unsigned, signed(PublicKeyFingerprint) }

/// A fully validated, immutable view of one fetched envelope. Only `RepositoryEnvelope.verify` (and the
/// store's validated loader) can create one.
public struct VerifiedSnapshot: Equatable, Sendable {
    public let url: RepositoryURL
    public let index: RepositoryIndex
    public let payloadDigest: String
    public let signature: SignatureStatus
    let envelope: Data
}

public enum RepositoryEnvelope {
    static let signatureDomain = Data("InterceptorRepository/v1".utf8) + [0]

    /// Validates sizes, strict JSON, base64, signature (if present), index fields, issuedAt/expiresAt.
    public static func verify(envelope: Data, url: RepositoryURL, now: Date) throws -> VerifiedSnapshot {
        let s = try verifyStructure(envelope: envelope, url: url)
        try checkTime(s.index, now: now)
        return s
    }

    /// Time rules: expired, issued too far ahead, lifetime bounds.
    static func checkTime(_ i: RepositoryIndex, now: Date) throws {
        guard i.expiresAt > now else { throw AutomationError.expired }
        guard i.issuedAt <= now.addingTimeInterval(Limits.clockSkew) else { throw AutomationError.notYetValid }
        let life = i.expiresAt.timeIntervalSince(i.issuedAt)
        guard life > 0 else { throw AutomationError.invalidJSON }
        guard life <= Limits.maxLifetime else { throw AutomationError.lifetimeTooLong }
    }

    /// Everything except wall-clock checks (used when reloading persisted snapshots).
    static func verifyStructure(envelope: Data, url: RepositoryURL) throws -> VerifiedSnapshot {
        guard envelope.count <= Limits.envelope else { throw AutomationError.limitExceeded }
        let top = try JSONFields(try StrictJSON.parse(envelope), required: ["schemaVersion", "payload"], optional: ["signature"])
        guard try top.int("schemaVersion") == 1 else { throw AutomationError.invalidJSON }
        let payload = try StrictBase64.decode(try top.string("payload"))
        guard payload.count <= Limits.payload else { throw AutomationError.limitExceeded }

        var status = SignatureStatus.unsigned
        if top.has("signature") {
            let sig = try JSONFields(try top.value("signature"), required: ["algorithm", "publicKey", "value"], error: .invalidSignature)
            guard try sig.string("algorithm") == "ed25519",
                  let key = try? StrictBase64.decode(try sig.string("publicKey")), key.count == 32,
                  let value = try? StrictBase64.decode(try sig.string("value")), value.count == 64,
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
                  pub.isValidSignature(value, for: signatureDomain + payload),
                  let fp = PublicKeyFingerprint(rawKey: key) else { throw AutomationError.invalidSignature }
            status = .signed(fp)
        }
        let index = try parseIndex(try StrictJSON.parse(payload))
        return VerifiedSnapshot(url: url, index: index, payloadDigest: Digest.sha256Hex(payload), signature: status, envelope: envelope)
    }

    private static func parseIndex(_ v: JSONValue) throws -> RepositoryIndex {
        let f = try JSONFields(v, required: ["schemaVersion", "id", "name", "sequence", "issuedAt", "expiresAt", "plugins"])
        guard try f.int("schemaVersion") == 1 else { throw AutomationError.invalidJSON }
        let name = try f.string("name")
        let seq = try f.int("sequence")
        guard Text.isDisplayName(name), (1...Limits.maxSequence).contains(seq),
              let issued = DateCodec.parse(try f.string("issuedAt")), let expires = DateCodec.parse(try f.string("expiresAt")) else {
            throw AutomationError.invalidJSON
        }
        let raw = try f.array("plugins")
        guard raw.count <= Limits.plugins else { throw AutomationError.limitExceeded }
        var entries = [IndexEntry](), seen = Set<UUID>()
        for p in raw {
            let e = try JSONFields(p, required: ["id", "name", "version", "packagePath", "sha256", "size"])
            let id = try e.uuid("id"), size = try e.int("size")
            let version = try e.string("version"), path = try e.string("packagePath"), sha = try e.string("sha256")
            guard Text.isDisplayName(try e.string("name")), (1...Int64(Limits.package)).contains(size),
                  RepositoryURL.isValidRelativePath(path), Digest.isHex64(sha), seen.insert(id).inserted,
                  (try? SemVer(parsing: version)) != nil else { throw AutomationError.invalidJSON }
            entries.append(IndexEntry(id: id, name: try e.string("name"), version: version, packagePath: path, sha256: sha, size: Int(size)))
        }
        return RepositoryIndex(id: try f.uuid("id"), name: name, sequence: seq, issuedAt: issued, expiresAt: expires, plugins: entries)
    }
}
