// Interceptor plugin repository signer (documentation example). Needs only Bun; no dependencies.
//   bun repository.ts keygen PRIVATE.pem
//   bun repository.ts publish DIRECTORY --id UUID --name NAME --sequence N --key PRIVATE.pem
// Signs DIRECTORY/plugins/*.json into DIRECTORY/repository.json. Nothing is uploaded or executed.
// This is NOT a full manifest validator: it checks the package shape, id, name and version it needs to build
// the index. Import each package into the Interceptor app first so the app validates the rest of the manifest.
import { constants as C, closeSync, fstatSync, fsyncSync, lstatSync, openSync, readSync, readdirSync, realpathSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomUUID, sign, verify } from "node:crypto";
import { basename, dirname, join, resolve, sep } from "node:path";

const USAGE = `usage: bun repository.ts --help
       bun repository.ts keygen PRIVATE.pem
       bun repository.ts publish DIRECTORY --id UUID --name NAME --sequence N --key PRIVATE.pem

keygen   creates an Ed25519 private key (mode 0600, never overwrites) outside any Git checkout or public folder,
         and prints only the SHA-256 fingerprint of the public key.
publish  reads DIRECTORY/plugins/NAME.json files and atomically writes a signed DIRECTORY/repository.json (30 day expiry).
`;
const DOMAIN = Buffer.concat([Buffer.from("InterceptorRepository/v1"), Buffer.from([0])]);
const MAX = { package: 256 * 1024, source: 128 * 1024, key: 4096, payload: 512 * 1024, envelope: 768 * 1024, plugins: 100, sequence: 9007199254740991 };
const NOFOLLOW = C.O_NOFOLLOW ?? 0;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class Fail extends Error {}
const fail = (message: string): never => { throw new Fail(message); };
const sha256 = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const sameKeys = (o: object, keys: string[]) => Object.keys(o).sort().join() === [...keys].sort().join();

function validName(s: unknown, what: string): string {
  const ok = typeof s === "string" && s.length > 0 && Buffer.byteLength(s) <= 256 && !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(s)
    && [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].length <= 80;
  return ok ? (s as string) : fail(`${what} must be 1-80 characters (256 bytes) without control or invisible format characters`);
}

function validSemVer(v: unknown): string {
  const num = /^(0|[1-9][0-9]{0,9})$/, pre = /^(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)$/, build = /^[0-9A-Za-z-]+$/;
  if (typeof v === "string" && Buffer.byteLength(v) <= 64) {
    const m = /^([^+-]*)(?:-([^+]*))?(?:\+(.*))?$/s.exec(v), core = m?.[1].split(".") ?? [];
    if (m && core.length === 3 && core.every((c) => num.test(c))
      && (m[2] === undefined || m[2].split(".").every((p) => pre.test(p)))
      && (m[3] === undefined || m[3].split(".").every((p) => build.test(p)))) return v;
  }
  return fail("manifest.version must be strict SemVer 2.0.0 (at most 64 bytes)");
}

/** Resolves the existing parent directory; refuses Git checkouts, public/web folders and a symlink leaf. */
function checkedKeyPath(path: string): string {
  const name = basename(path);
  if (!name || name === "." || name === "..") fail("invalid key path");
  let dir: string;
  try { dir = realpathSync(dirname(resolve(path))); } catch { return fail("key directory must already exist"); }
  const target = join(dir, name);
  try { if (lstatSync(target).isSymbolicLink()) fail("key path must not be a symbolic link"); } catch (e) { if (e instanceof Fail) throw e; }
  for (let d = dir, up = ""; d !== up; up = d, d = dirname(d)) {
    try { lstatSync(join(d, ".git")); fail("key path is inside a Git checkout"); } catch (e) { if (e instanceof Fail) throw e; }
    if (["public", "www", "htdocs", "_site"].includes(basename(d).toLowerCase())) fail("key path is inside a public folder");
  }
  return target;
}

/** Opens without following symlinks, requires a regular file within `limit` bytes, and reads at most limit+1 bytes. */
function readRegular(path: string, limit: number, privateKey = false): Buffer {
  if (!NOFOLLOW) fail("this example requires O_NOFOLLOW file protection (macOS/Linux)");
  let fd: number;
  try { fd = openSync(path, C.O_RDONLY | NOFOLLOW | (C.O_NONBLOCK ?? 0)); } catch { return fail(`cannot open ${basename(path)} (missing or symbolic link)`); }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) fail(`${basename(path)} is not a regular file`);
    if (st.size > limit) fail(`${basename(path)} is larger than ${limit} bytes`);
    if (privateKey && process.platform !== "win32" && (st.mode & 0o077) !== 0) fail("key file must not be group or world accessible (chmod 600)");
    const buf = Buffer.alloc(limit + 1);
    let n = 0;
    for (let r = 1; r > 0 && n < buf.length;) { r = readSync(fd, buf, n, buf.length - n, null); n += r; }
    if (n > limit) fail(`${basename(path)} is larger than ${limit} bytes`);
    return buf.subarray(0, n);
  } finally { closeSync(fd); }
}

const rawPublicKey = (priv: ReturnType<typeof createPrivateKey>) => Buffer.from(createPublicKey(priv).export({ format: "jwk" }).x!, "base64url");

function keygen(path: string) {
  const target = checkedKeyPath(path);
  const { privateKey } = generateKeyPairSync("ed25519");
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;
  let fd: number;
  try { fd = openSync(target, C.O_WRONLY | C.O_CREAT | C.O_EXCL | NOFOLLOW, 0o600); } catch { return fail("cannot create key file (it may already exist)"); }
  try {
    const bytes = Buffer.from(pem);
    for (let n = 0; n < bytes.length;) {
      const count = writeSync(fd, bytes, n);
      if (count <= 0) fail("cannot finish writing key file");
      n += count;
    }
    fsyncSync(fd);
  } catch { closeSync(fd); try { unlinkSync(target); } catch {} return fail("cannot write key file"); }
  closeSync(fd);
  console.log(sha256(rawPublicKey(privateKey)));
}

function loadPackage(file: string, bytes: Buffer) {
  let pkg: unknown;
  try { pkg = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes)); } catch { return fail(`${file}: not valid UTF-8 JSON`); }
  if (!isObject(pkg) || !sameKeys(pkg, ["manifest", "source"]) || typeof pkg.source !== "string" || Buffer.byteLength(pkg.source) > MAX.source
    || !isObject(pkg.manifest)) return fail(`${file}: must be {"manifest": {...}, "source": "..."} with source at most 128 KiB`);
  const m = pkg.manifest;
  if (m.schemaVersion !== 1 || typeof m.id !== "string" || !UUID.test(m.id)) return fail(`${file}: manifest needs schemaVersion 1 and a UUID id`);
  try { return { id: m.id, name: validName(m.name, "manifest.name"), version: validSemVer(m.version) }; }
  catch (e) { return fail(`${file}: ${(e as Error).message}`); }
}

function publish(directory: string, id: string, name: string, sequence: string, keyPath: string) {
  if (!UUID.test(id)) fail("--id must be a hyphenated UUID");
  validName(name, "--name");
  if (!/^[1-9][0-9]*$/.test(sequence) || !Number.isSafeInteger(Number(sequence))) fail(`--sequence must be a decimal integer from 1 to ${MAX.sequence}`);
  for (const p of [directory, join(directory, "plugins")]) {
    let st; try { st = lstatSync(p); } catch { return fail(`${basename(p)}: missing`); }
    if (st.isSymbolicLink() || !st.isDirectory()) fail(`${basename(p)}: must be a real directory, not a symbolic link`);
  }
  const root = realpathSync(directory), pluginsDir = join(root, "plugins");
  const key = checkedKeyPath(keyPath);
  if (key === root || key.startsWith(root + sep)) fail("key must be outside the published directory");
  let priv;
  try { priv = createPrivateKey(readRegular(key, MAX.key, true)); } catch (e) { if (e instanceof Fail) throw e; return fail("key is not a readable PKCS8 PEM private key"); }
  if (priv.asymmetricKeyType !== "ed25519") fail("key must be an Ed25519 private key");
  const publicKey = rawPublicKey(priv);

  const names = readdirSync(pluginsDir).sort();
  if (names.length > MAX.plugins) fail(`more than ${MAX.plugins} packages`);
  if (!names.every((n) => /^[A-Za-z0-9._-]+\.json$/.test(n) && !n.startsWith(".") && Buffer.byteLength(n) <= 128)) fail("plugins/ may contain only NAME.json files ([A-Za-z0-9._-], no leading dot)");
  const ids = new Set<string>(), plugins: object[] = [], bytesOf = new Map<string, Buffer>();
  for (const file of names) {
    const bytes = readRegular(join(pluginsDir, file), MAX.package);
    if (bytes.length === 0) fail(`${file}: empty`);
    const p = loadPackage(file, bytes);
    if (ids.has(p.id.toLowerCase())) fail(`duplicate plugin id ${p.id}`);
    ids.add(p.id.toLowerCase());
    bytesOf.set(`plugins/${file}`, bytes);
    plugins.push({ id: p.id, name: p.name, version: p.version, packagePath: `plugins/${file}`, sha256: sha256(bytes), size: bytes.length });
  }
  const issued = Math.floor(Date.now() / 1000), stamp = (s: number) => new Date(s * 1000).toISOString().replace(".000Z", "Z");
  const payload = Buffer.from(JSON.stringify({ schemaVersion: 1, id, name, sequence: Number(sequence), issuedAt: stamp(issued), expiresAt: stamp(issued + 30 * 86400), plugins }));
  if (payload.length > MAX.payload) fail("payload is larger than 512 KiB");
  const signature = sign(null, Buffer.concat([DOMAIN, payload]), priv);
  const data = Buffer.from(JSON.stringify({ schemaVersion: 1, payload: payload.toString("base64"), signature: { algorithm: "ed25519", publicKey: publicKey.toString("base64"), value: signature.toString("base64") } }));
  if (data.length > MAX.envelope) fail("repository.json would be larger than 768 KiB");

  // Verify what a client would check before anything is written.
  if (!verify(null, Buffer.concat([DOMAIN, payload]), createPublicKey(priv), signature)) fail("internal error: signature check failed");
  for (const e of JSON.parse(payload.toString()).plugins) {
    const b = bytesOf.get(e.packagePath)!;
    if (b.length !== e.size || sha256(b) !== e.sha256) fail("internal error: package hash check failed");
  }

  const output = join(root, "repository.json");
  try { const st = lstatSync(output); if (!st.isFile()) fail("repository.json exists and is not a regular file"); } catch (e) { if (e instanceof Fail) throw e; }
  const temp = join(root, `.repository-${randomUUID()}.tmp`);
  let fd: number;
  try { fd = openSync(temp, C.O_WRONLY | C.O_CREAT | C.O_EXCL | NOFOLLOW, 0o644); } catch { return fail("cannot create temporary file"); }
  try {
    for (let n = 0; n < data.length;) {
      const count = writeSync(fd, data, n);
      if (count <= 0) fail("cannot finish writing repository.json");
      n += count;
    }
    fsyncSync(fd); closeSync(fd); fd = -1;
    renameSync(temp, output);
  } catch { if (fd >= 0) closeSync(fd); try { unlinkSync(temp); } catch {} return fail("cannot write repository.json"); }
  console.log(`wrote ${output} (sequence ${sequence}, ${plugins.length} plugins, signed)`);
  console.log(`fingerprint ${sha256(publicKey)}`);
}

function main(args: string[]) {
  if (args[0] === "--help" || args[0] === "-h") return void process.stdout.write(USAGE);
  if (args[0] === "keygen" && args.length === 2) return keygen(args[1]);
  if (args[0] === "publish" && args.length >= 2 && !args[1].startsWith("--")) {
    const opts = new Map<string, string>();
    for (let i = 2; i < args.length; i += 2) {
      if (!["--id", "--name", "--sequence", "--key"].includes(args[i]) || i + 1 >= args.length || opts.has(args[i])) fail(`bad or duplicate option ${args[i]}`);
      opts.set(args[i], args[i + 1]);
    }
    for (const o of ["--id", "--name", "--sequence", "--key"]) if (!opts.has(o)) fail(`missing ${o}`);
    return publish(args[1], opts.get("--id")!, opts.get("--name")!, opts.get("--sequence")!, opts.get("--key")!);
  }
  fail("unknown or incomplete command (try --help)");
}

try { main(process.argv.slice(2)); } catch (e) {
  console.error(`error: ${e instanceof Fail ? e.message : "unexpected failure"}`);
  process.exit(1);
}
