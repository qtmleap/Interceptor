import Foundation

/// Versioned catalog file <-> validated `Catalog`. Decoding re-validates everything (snapshots, packages,
/// trust consistency, counts, bytes); nothing in the file can set `enabled` true or bypass checks.
enum CatalogCodec {
    static let version: Int64 = 1

    static func encode(_ c: Catalog) throws -> Data {
        let repos: [JSONValue] = c.repositories.map { r in
            var o: [String: JSONValue] = [
                "url": .string(r.url.canonical), "repositoryID": .string(r.repositoryID.uuidString), "trust": trust(r.trust),
                "sequence": .integer(r.sequence), "payloadDigest": .string(r.payloadDigest), "visible": .bool(r.visible),
                "generation": .string(r.generation.uuidString),
            ]
            if let s = r.snapshot { o["envelope"] = .string(s.envelope.base64EncodedString()) }
            return .object(o)
        }
        let revs: [JSONValue] = c.revisions.map { r in
            var o: [String: JSONValue] = ["package": .string(r.package.bytes.base64EncodedString()), "enabled": .bool(r.enabled)]
            switch r.provenance.origin {
            case .repository(let url, let seq): o["origin"] = .string("repository"); o["originURL"] = .string(url.canonical); o["originSequence"] = .integer(seq)
            case .localEdit(let parent): o["origin"] = .string("localEdit"); o["parent"] = .string(parent)
            case .localImport: o["origin"] = .string("localImport")
            }
            if let t = r.provenance.trustAtImport { o["trustAtImport"] = trust(t) }
            return .object(o)
        }
        let data = try JSONValue.object(["version": .integer(version), "repositories": .array(repos), "revisions": .array(revs)]).data()
        guard data.count <= Limits.catalogBytes else { throw AutomationError.limitExceeded }
        return data
    }

    static func decode(_ data: Data) throws -> Catalog {
        guard data.count <= Limits.catalogBytes else { throw AutomationError.corruptStore }
        do { return try decodeUnchecked(data) } catch { throw AutomationError.corruptStore }
    }

    private static func decodeUnchecked(_ data: Data) throws -> Catalog {
        let top = try JSONFields(try StrictJSON.parse(data), required: ["version", "repositories", "revisions"], error: .corruptStore)
        guard try top.int("version") == version else { throw AutomationError.corruptStore }
        var cat = Catalog()
        var urls = Set<String>()
        for v in try top.array("repositories") {
            let r = try repository(v)
            guard urls.insert(r.url.canonical).inserted else { throw AutomationError.corruptStore }
            cat.repositories.append(r)
        }
        var ids = Set<String>(), bytes = 0
        for v in try top.array("revisions") {
            let r = try revision(v)
            guard ids.insert(r.id).inserted else { throw AutomationError.corruptStore }
            bytes += r.package.bytes.count
            cat.revisions.append(r)
        }
        guard cat.repositories.count <= Limits.repositories, cat.revisions.count <= Limits.revisions, bytes <= Limits.rawPackageBytes else {
            throw AutomationError.corruptStore
        }
        return cat
    }

    private static func trust(_ t: TrustState) -> JSONValue {
        switch t {
        case .unsignedAcknowledged: return .object(["kind": .string("unsignedAcknowledged")])
        case .signedUnverified(let k): return .object(["kind": .string("signedUnverified"), "key": .string(k.rawKey.base64EncodedString())])
        case .pinned(let k): return .object(["kind": .string("pinned"), "key": .string(k.rawKey.base64EncodedString())])
        }
    }

    private static func trust(_ v: JSONValue) throws -> TrustState {
        let bad = AutomationError.corruptStore
        let f = try JSONFields(v, required: ["kind"], optional: ["key"], error: bad)
        let kind = try f.string("kind")
        if kind == "unsignedAcknowledged" { guard !f.has("key") else { throw bad }; return .unsignedAcknowledged }
        guard let fp = PublicKeyFingerprint(rawKey: try StrictBase64.decode(try f.string("key"))) else { throw bad }
        switch kind {
        case "signedUnverified": return .signedUnverified(fp)
        case "pinned": return .pinned(fp)
        default: throw bad
        }
    }

    private static func repository(_ v: JSONValue) throws -> RepositoryRecord {
        let bad = AutomationError.corruptStore
        let f = try JSONFields(v, required: ["url", "repositoryID", "trust", "sequence", "payloadDigest", "visible", "generation"], optional: ["envelope"], error: bad)
        let url = try RepositoryURL(parsing: try f.string("url"))
        let t = try trust(try f.value("trust"))
        let seq = try f.int("sequence"), digest = try f.string("payloadDigest"), visible = try f.bool("visible")
        let urlText = try f.string("url"), repoID = try f.uuid("repositoryID")
        guard url.canonical == urlText, (1...Limits.maxSequence).contains(seq), Digest.isHex64(digest),
              f.has("envelope") == visible else { throw bad }
        var snapshot: VerifiedSnapshot?
        if visible {
            let s = try RepositoryEnvelope.verifyStructure(envelope: try StrictBase64.decode(try f.string("envelope")), url: url)
            let consistent: Bool
            switch (t, s.signature) {
            case (.unsignedAcknowledged, .unsigned): consistent = true
            case (.signedUnverified(let a), .signed(let b)), (.pinned(let a), .signed(let b)): consistent = a == b
            default: consistent = false
            }
            guard consistent, s.index.id == repoID, s.index.sequence == seq, s.payloadDigest == digest else { throw bad }
            snapshot = s
        }
        return RepositoryRecord(url: url, repositoryID: repoID, trust: t, sequence: seq, payloadDigest: digest,
                                visible: visible, generation: try f.uuid("generation"), snapshot: snapshot)
    }

    private static func revision(_ v: JSONValue) throws -> InstalledRevision {
        let bad = AutomationError.corruptStore
        let f = try JSONFields(v, required: ["package", "enabled", "origin"], optional: ["originURL", "originSequence", "parent", "trustAtImport"], error: bad)
        guard try f.bool("enabled") == false else { throw bad }
        let package = try PluginPackage.validate(try StrictBase64.decode(try f.string("package")))
        let origin: Provenance.Origin
        switch try f.string("origin") {
        case "repository":
            guard f.has("originURL"), f.has("originSequence"), !f.has("parent") else { throw bad }
            let seq = try f.int("originSequence")
            guard (1...Limits.maxSequence).contains(seq) else { throw bad }
            origin = .repository(url: try RepositoryURL(parsing: try f.string("originURL")), sequence: seq)
        case "localEdit":
            guard f.has("parent"), !f.has("originURL"), !f.has("originSequence"), Digest.isHex64(try f.string("parent")) else { throw bad }
            origin = .localEdit(parent: try f.string("parent"))
        case "localImport":
            guard !f.has("originURL"), !f.has("originSequence"), !f.has("parent") else { throw bad }
            origin = .localImport
        default: throw bad
        }
        let t: TrustState? = try f.has("trustAtImport") ? trust(try f.value("trustAtImport")) : nil
        if case .repository = origin {} else { guard t == nil else { throw bad } }
        return InstalledRevision(package: package, provenance: Provenance(origin: origin, trustAtImport: t), enabled: false)
    }
}
