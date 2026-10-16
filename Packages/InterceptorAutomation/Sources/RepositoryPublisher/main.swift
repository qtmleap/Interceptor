import AutomationCore
import CryptoKit
import Foundation

struct Fail: Error { let message: String }

let usage = """
usage: interceptor-repository --help
       interceptor-repository keygen EXTERNAL_KEY_PATH
       interceptor-repository publish DIRECTORY --id UUID --name NAME --sequence N [--key EXTERNAL_KEY_PATH]

keygen   writes a raw 32-byte Ed25519 private key (mode 0600, never overwrites) outside any Git checkout or
         public directory, and prints only the public key's SHA-256 fingerprint.
publish  reads DIRECTORY/plugins/*.json and atomically writes DIRECTORY/repository.json (30 day expiry).
         Without --key the repository is unsigned. Nothing is uploaded or executed.

"""

func errno_(_ what: String) -> Fail { Fail(message: "\(what): \(String(cString: strerror(errno)))") }

/// Resolves the existing parent directory; rejects Git checkouts and public/web directories.
func checkedKeyPath(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { throw Fail(message: "invalid key path") }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    var dir = parent
    while true {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { throw Fail(message: "key path is inside a Git checkout") }
        if ["public", "www", "htdocs", "_site"].contains(dir.lastPathComponent.lowercased()) { throw Fail(message: "key path is inside a public directory") }
        let up = dir.deletingLastPathComponent()
        if up.path == dir.path { break }
        dir = up
    }
    return parent.appendingPathComponent(name).path
}

func keygen(_ path: String) throws {
    let target = try checkedKeyPath(path)
    let key = Curve25519.Signing.PrivateKey()
    let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw errno_("cannot create key") }
    defer { close(fd) }
    let raw = [UInt8](key.rawRepresentation)
    guard write(fd, raw, raw.count) == raw.count else { unlink(target); throw errno_("cannot write key") }
    print(Digest.sha256Hex(key.publicKey.rawRepresentation))
}

/// Opens without following symlinks, requires a regular file within `limit` bytes, then reads at most that many.
func readRegular(_ path: String, limit: Int, mode: Bool = false) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw errno_("cannot open \(path)") }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw Fail(message: "\(path): not a regular file") }
    guard st.st_size <= limit else { throw Fail(message: "\(path): larger than \(limit) bytes") }
    if mode, st.st_mode & 0o077 != 0 { throw Fail(message: "\(path): key must not be group/world accessible") }
    var out = Data(), buf = [UInt8](repeating: 0, count: 16384)
    while out.count <= limit {
        let n = read(fd, &buf, buf.count)
        if n < 0 { throw errno_("cannot read \(path)") }
        if n == 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    guard out.count <= limit else { throw Fail(message: "\(path): larger than \(limit) bytes") }
    return out
}

func isPackageFilename(_ n: String) -> Bool {
    n.hasSuffix(".json") && n.utf8.count <= 128 && n.first != "." && n.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F
    }
}

func timestamp(_ d: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
}

func publish(directory: String, id: UUID, name: String, sequence: Int64, keyPath: String?) throws {
    let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
    var signer: Curve25519.Signing.PrivateKey?
    if let keyPath {
        let resolved = try checkedKeyPath(keyPath)
        guard !(resolved + "/").hasPrefix(root.path + "/") else { throw Fail(message: "key must be outside the published directory") }
        signer = try Curve25519.Signing.PrivateKey(rawRepresentation: try readRegular(resolved, limit: 32, mode: true))
    }
    let pluginsDir = root.appendingPathComponent("plugins").path
    var st = stat()
    guard lstat(pluginsDir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw Fail(message: "plugins/ must be a real directory") }
    let names = try FileManager.default.contentsOfDirectory(atPath: pluginsDir).sorted()
    guard names.count <= Limits.plugins else { throw Fail(message: "more than \(Limits.plugins) packages") }
    guard names.allSatisfy(isPackageFilename) else { throw Fail(message: "plugins/ may contain only NAME.json files ([A-Za-z0-9._-])") }

    var entries = [JSONValue](), ids = Set<UUID>(), packages = [String: Data]()
    for file in names {
        let bytes = try readRegular(pluginsDir + "/" + file, limit: Limits.package)
        let package = try PluginPackage.validate(bytes)
        guard ids.insert(package.manifest.id).inserted else { throw Fail(message: "duplicate plugin id \(package.manifest.id)") }
        packages["plugins/" + file] = bytes
        entries.append(.object([
            "id": .string(package.manifest.id.uuidString), "name": .string(package.manifest.name), "version": .string(package.manifest.version),
            "packagePath": .string("plugins/" + file), "sha256": .string(Digest.sha256Hex(bytes)), "size": .integer(Int64(bytes.count)),
        ]))
    }
    let issued = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let payload = try JSONValue.object([
        "schemaVersion": .integer(1), "id": .string(id.uuidString), "name": .string(name), "sequence": .integer(sequence),
        "issuedAt": .string(timestamp(issued)), "expiresAt": .string(timestamp(issued.addingTimeInterval(30 * 86_400))), "plugins": .array(entries),
    ]).data()
    var envelope: [String: JSONValue] = ["schemaVersion": .integer(1), "payload": .string(payload.base64EncodedString())]
    if let signer {
        let sig = try signer.signature(for: Data("InterceptorRepository/v1".utf8) + [0] + payload)
        envelope["signature"] = .object(["algorithm": .string("ed25519"), "publicKey": .string(signer.publicKey.rawRepresentation.base64EncodedString()), "value": .string(sig.base64EncodedString())])
    }
    let data = try JSONValue.object(envelope).data()

    // Verify exactly what a client would, then re-validate every package against the verified entries.
    let snapshot = try RepositoryEnvelope.verify(envelope: data, url: try RepositoryURL(parsing: "https://repository.example/repository.json"), now: Date())
    for entry in snapshot.index.plugins { _ = try PluginPackage.validate(packages[entry.packagePath]!, against: entry) }

    let output = root.appendingPathComponent("repository.json").path
    if lstat(output, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG { throw Fail(message: "repository.json exists and is not a regular file") }
    let temp = root.appendingPathComponent(".repository-\(UUID().uuidString).tmp").path
    let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw errno_("cannot create temp file") }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    guard close(fd) == 0, written == data.count, rename(temp, output) == 0 else { unlink(temp); throw errno_("cannot write repository.json") }
    print("wrote \(output) (sequence \(sequence), \(entries.count) plugins, \(signer == nil ? "unsigned" : "signed"))")
    if let signer { print("fingerprint \(Digest.sha256Hex(signer.publicKey.rawRepresentation))") }
}

func run(_ args: [String]) throws {
    switch args.first {
    case "--help", "-h": print(usage, terminator: "")
    case "keygen" where args.count == 2: try keygen(args[1])
    case "publish" where args.count >= 2:
        var opts = [String: String](), i = 2
        while i < args.count {
            guard ["--id", "--name", "--sequence", "--key"].contains(args[i]), i + 1 < args.count, opts[args[i]] == nil else { throw Fail(message: "bad argument \(args[i])") }
            opts[args[i]] = args[i + 1]; i += 2
        }
        guard let idText = opts["--id"], let id = UUID(uuidString: idText), let name = opts["--name"],
              let seqText = opts["--sequence"], let seq = Int64(seqText), (1...Limits.maxSequence).contains(seq) else {
            throw Fail(message: "publish needs --id UUID --name NAME --sequence 1...\(Limits.maxSequence)")
        }
        try publish(directory: args[1], id: id, name: name, sequence: seq, keyPath: opts["--key"])
    default: throw Fail(message: "unknown or incomplete command (try --help)")
    }
}

do { try run(Array(CommandLine.arguments.dropFirst())) } catch {
    let text = (error as? Fail)?.message ?? "\(error)"
    FileHandle.standardError.write(Data("error: \(text)\n".utf8))
    exit(1)
}
