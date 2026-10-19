import { afterEach, expect, test } from "bun:test";
import { createHash, createPrivateKey, createPublicKey, verify } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const cli = resolve(import.meta.dir, "../docs/site/public/tools/repository.ts");
const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "interceptor-bun-publisher-")); roots.push(root);
  const repo = join(root, "feed"); mkdirSync(join(repo, "plugins"), { recursive: true });
  const key = join(root, "private.pem");
  const pkg = JSON.parse(readFileSync(resolve(import.meta.dir, "../docs/site/public/examples/request-alert.json"), "utf8"));
  pkg.manifest.name = "通信の例 e\u0301";
  const packagePath = join(repo, "plugins", "first.json"); writeFileSync(packagePath, JSON.stringify(pkg));
  const run = (...args: string[]) => Bun.spawnSync([process.execPath, cli, ...args], { stdout: "pipe", stderr: "pipe" });
  const publish = (...extra: string[]) => run("publish", repo, "--id", "3b0f9f3e-0f55-4f5c-9d5e-5a1c2b7d8e90", "--name", "My repository", "--sequence", "1", "--key", key, ...extra);
  return { root, repo, key, pkg, packagePath, run, publish };
}

test("keygen creates an exclusive private PEM and prints only its public fingerprint", () => {
  const f = fixture(); const result = f.run("keygen", f.key);
  expect(result.exitCode).toBe(0);
  const pem = readFileSync(f.key, "utf8"); expect(pem).toContain("PRIVATE KEY");
  if (process.platform !== "win32") expect(lstatSync(f.key).mode & 0o777).toBe(0o600);
  const publicKey = createPublicKey(createPrivateKey(pem));
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x!, "base64url");
  expect(result.stdout.toString().trim()).toBe(createHash("sha256").update(raw).digest("hex"));
  expect(result.stdout.toString() + result.stderr.toString()).not.toContain("PRIVATE KEY");
  const before = readFileSync(f.key); expect(f.run("keygen", f.key).exitCode).not.toBe(0);
  expect(readFileSync(f.key)).toEqual(before);
});

test("signed feed authenticates the exact UTF8 package bytes with the v1 domain", () => {
  const f = fixture(); expect(f.run("keygen", f.key).exitCode).toBe(0); expect(f.publish().exitCode).toBe(0);
  const envelope = JSON.parse(readFileSync(join(f.repo, "repository.json"), "utf8"));
  const payload = Buffer.from(envelope.payload, "base64"); const index = JSON.parse(payload.toString("utf8"));
  const domain = Buffer.from("InterceptorRepository/v1\0"); expect(domain.length).toBe(25); expect(domain[24]).toBe(0);
  const publicKey = createPublicKey(createPrivateKey(readFileSync(f.key)));
  expect(Buffer.from(envelope.signature.publicKey, "base64").length).toBe(32);
  expect(Buffer.from(envelope.signature.value, "base64").length).toBe(64);
  expect(verify(null, Buffer.concat([domain, payload]), publicKey, Buffer.from(envelope.signature.value, "base64"))).toBe(true);
  const tampered = Buffer.from(payload); tampered[0] ^= 1;
  expect(verify(null, Buffer.concat([domain, tampered]), publicKey, Buffer.from(envelope.signature.value, "base64"))).toBe(false);
  const entry = index.plugins[0]; const bytes = readFileSync(f.packagePath);
  expect(entry).toMatchObject({ id: f.pkg.manifest.id, name: f.pkg.manifest.name, version: f.pkg.manifest.version, packagePath: "plugins/first.json", size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
  expect(index.issuedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  expect(Date.parse(index.expiresAt) - Date.parse(index.issuedAt)).toBe(30 * 86400 * 1000);
});

test("rejects duplicate plugin IDs, including different UUID letter case", () => {
  const f = fixture(); f.run("keygen", f.key); const other = structuredClone(f.pkg); other.manifest.id = other.manifest.id.toUpperCase();
  writeFileSync(join(f.repo, "plugins", "second.json"), JSON.stringify(other)); expect(f.publish().exitCode).not.toBe(0); expect(existsSync(join(f.repo, "repository.json"))).toBe(false);
});

for (const kind of ["unexpected file", "symlink", "invalid UTF8", "oversize", "invalid SemVer", "zero-width name"] as const) test(`rejects ${kind}`, () => {
  const f = fixture(); f.run("keygen", f.key);
  if (kind === "unexpected file") writeFileSync(join(f.repo, "plugins", "notes.txt"), "not a package");
  if (kind === "symlink") symlinkSync(f.packagePath, join(f.repo, "plugins", "second.json"));
  if (kind === "invalid UTF8") writeFileSync(f.packagePath, Buffer.from([0xff]));
  if (kind === "oversize") writeFileSync(f.packagePath, Buffer.alloc(256 * 1024 + 1));
  if (kind === "invalid SemVer") { f.pkg.manifest.version = "01.0.0"; writeFileSync(f.packagePath, JSON.stringify(f.pkg)); }
  if (kind === "zero-width name") { f.pkg.manifest.name = "a\u200bb"; writeFileSync(f.packagePath, JSON.stringify(f.pkg)); }
  expect(f.publish().exitCode).not.toBe(0); expect(existsSync(join(f.repo, "repository.json"))).toBe(false);
});

test("key paths in Git and public folders are refused without writing", () => {
  const f = fixture();
  for (const dir of [join(f.root, "checkout"), join(f.root, "public")]) {
    mkdirSync(dir); if (dir.endsWith("checkout")) mkdirSync(join(dir, ".git"));
    const key = join(dir, "secret.pem"); expect(f.run("keygen", key).exitCode).not.toBe(0); expect(existsSync(key)).toBe(false);
  }
});

test("refuses a key inside the feed, an exposed key, and a linked key", () => {
  const f = fixture(); f.run("keygen", f.key);
  const publishedKey = join(f.repo, "private.pem"); writeFileSync(publishedKey, readFileSync(f.key), { mode: 0o600 });
  const linkedKey = join(f.root, "linked.pem"); symlinkSync(f.key, linkedKey);
  for (const key of [publishedKey, linkedKey]) {
    expect(f.run("publish", f.repo, "--id", crypto.randomUUID(), "--name", "N", "--sequence", "1", "--key", key).exitCode).not.toBe(0);
  }
  if (process.platform !== "win32") { chmodSync(f.key, 0o644); expect(f.publish().exitCode).not.toBe(0); }
});

test("sequence accepts safe integer maximum and rejects ambiguous forms", () => {
  const f = fixture(); f.run("keygen", f.key);
  const run = (value: string) => f.run("publish", f.repo, "--id", crypto.randomUUID(), "--name", "N", "--sequence", value, "--key", f.key);
  for (const value of ["0", "-1", "1.5", "1e3", "0x10", "+5", " 1", "9007199254740992"]) expect(run(value).exitCode).not.toBe(0);
  expect(run("9007199254740991").exitCode).toBe(0);
});

test("does not replace a symlink output or modify its target", () => {
  const f = fixture(); f.run("keygen", f.key); const target = join(f.root, "keep.txt"); writeFileSync(target, "keep");
  symlinkSync(target, join(f.repo, "repository.json")); expect(f.publish().exitCode).not.toBe(0); expect(readFileSync(target, "utf8")).toBe("keep");
});
