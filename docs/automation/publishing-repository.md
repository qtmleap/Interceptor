# Publishing a plugin repository

A repository is one static HTTPS file, `repository.json`, plus package files next to it. Any static host works (GitHub Pages, raw GitHub, your own server). No API token, clone, upload or code execution is involved: `interceptor-repository` only reads local files and writes `repository.json`. Importing in the app creates disabled revisions; the app only does dry runs of plugin code with synthetic fixtures.

## Layout

```
my-repo/
  plugins/<name>.json     one package per file, name matches [A-Za-z0-9._-]+, max 100 files
  repository.json         generated
```

## Package contract

Each file is a v1 package, UTF-8 JSON with exactly `{manifest, source}`, at most 256 KiB (`source` at most 128 KiB). `manifest` requires `schemaVersion` (1), `id` (UUID), `name`, `version` (SemVer), `subscriptions` (1–8, each `phase` + `match.hosts`, optional `methods`/`path`/`status`), `read` (`metadata`, `headers`, `queryKeys`, `body`: `none`, `jsonPointers` or `raw`), `endpointBindings` (0–4 names) and `settings` (object). See `examples/plugin-repository/plugins/request-summary.json`, which reads metadata only and has `body: none`. The tool runs the same validator as the app and rejects duplicate plugin ids, symlinks, non-regular and oversized files.

## Envelope

```json
{"schemaVersion":1,"payload":"<base64 of index JSON>","signature":{"algorithm":"ed25519","publicKey":"<base64 32 bytes>","value":"<base64 64 bytes>"}}
```

`signature` is optional. The index (the decoded payload) has `schemaVersion`, `id` (repository UUID), `name`, `sequence` (1…2^53−1, increase it on every publish), `issuedAt`, `expiresAt` (UTC seconds; 30 days after issue) and `plugins`: `id`, `name`, `version`, `packagePath` (`plugins/<file>`), `sha256` and `size` of the exact package bytes. Keys are sorted. The Ed25519 signature covers `InterceptorRepository/v1`, a NUL byte, then the exact decoded payload bytes.

## Integrity is not authentication

SHA-256 hashes only detect a package that differs from the index. Whoever controls an unsigned server can replace both. A signature proves the index came from the holder of a key, but a key first seen from the same server is not trusted: the app shows the full SHA-256 fingerprint of the public key, and a person must compare it with one obtained another way before pinning. Unsigned repositories need an explicit acknowledgment and stay marked unverified. Key rotation is not implemented yet; a pinned repository that changes key is refused. Provenance is shown in the app, along with the full script source before anything can be enabled.

## Commands

```
$ swift run --package-path Packages/InterceptorAutomation interceptor-repository keygen ~/.config/interceptor/repo.key
4b1e…(64 hex chars: SHA-256 of the public key)
$ swift run --package-path Packages/InterceptorAutomation interceptor-repository publish examples/plugin-repository \
    --id 3b0f9f3e-0f55-4f5c-9d5e-5a1c2b7d8e90 --name "Example repository" --sequence 1 \
    --key ~/.config/interceptor/repo.key
wrote …/repository.json (sequence 1, 1 plugins, signed)
fingerprint 4b1e…
```

- `keygen` writes a raw 32-byte private key with mode 0600, never overwrites, refuses symlinks, and refuses paths inside any Git checkout or a directory named `public`. Only the fingerprint is printed. Keep a backup somewhere safe; publish the fingerprint through a separate channel.
- `publish` refuses a key inside the published directory. Omit `--key` for an unsigned repository. It verifies its own output with the app's verifier (using a placeholder URL `https://repository.example/repository.json`) and checks every package against the verified entries before atomically replacing `repository.json`.
- Do not commit the generated `repository.json` (it expires) or any private key. Regenerate it with a higher `--sequence` before deploying, e.g. in your Pages build step.
