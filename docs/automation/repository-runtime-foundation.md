# Plugin repository and JavaScript foundation — 2026-10-16

Status: implementation in progress; independent plan reviews completed and material findings resolved. Actual-source review and integration verification are in progress. This is the first usable foundation of the next major update, separate from the 1.0.1 (34) review submissions.

## Scope and baseline

- User chose plugin-specific JSON distribution hosted on GitHub raw, GitHub Pages or any HTTPS static server, rather than APT/Sileo compatibility.
- Base app: 6c3b8cc2a802ddb5f4555229603821c9ddd9d334; Mudmouth: be4cc787669fdfebead90aba197a3501ebdd0063. Preserve the shared SSL Proxying List.
- Deliver a local Swift package, repository management/import UI, immutable installed revisions, source inspection/editing and synthetic request/response dry-run with a real bounded JavaScript engine.
- Downloads/import/edit/save never execute code, enable automation, add capture hosts, grant captured-data access or send webhooks.
- Live HTTP hooks, grants, PacketTunnel execution, webhook delivery/outbox and signed-device/Apple publication gates remain later tasks in the full 2026-10-15 plan. This foundation must not claim those are implemented. No automatic publishing to develop.
- iOS 17 product floor, macOS 14 package tests, en/ja, iPhone/iPad and Light/Dark at standard text size.

## Distribution v1

Repository URL identifies an HTTPS JSON envelope (suggested filename repository.json). No git clone, archive extraction, native binaries or server API credentials.

Envelope: schemaVersion=1, payload=base64 of the exact UTF-8 index JSON bytes, optional signature object {algorithm:"ed25519", publicKey:base64(32 bytes), value:base64(64 bytes)}. A supplied malformed/invalid signature is always fatal. Ed25519 signs UTF-8 "InterceptorRepository/v1" followed by a NUL byte and the exact decoded payload bytes. No JSON canonicalization for signatures.

Index: schemaVersion=1, id=UUID, name=1..80 characters, sequence=positive integer, expiresAt=RFC3339 UTC, plugins=array (0..100) of {id:UUID,name:1..80,version:SemVer,packagePath:relative path,sha256:64 lowercase hex,size:1..262144}. IDs unique; supported fields only; duplicate JSON keys rejected. Payload max 512 KiB, envelope max 768 KiB, JSON depth max 64. Expired metadata rejected; expiry more than 90 days ahead rejected. Same sequence with different payload and lower sequence rejected after a successful persisted import.

Package paths are confined to the repository directory and same origin: conservative ASCII path segments [A-Za-z0-9._-]+, no empty / dot / dot-dot segments, slash at start, percent encoding, backslash, query or fragment. Every request uses ephemeral URLSession, HTTPS/TLS defaults, no cookies/cache/credentials, no redirect following, 15 second total timeout and bounded streaming response before decoding. Only successful HTTP 200 accepted. Explicitly entered HTTPS repository hosts may include self-hosted servers; webhook SSRF policy is a later separate component.

Packages are UTF-8 JSON {manifest, source} (manifest contract in the existing design). Verify exact response byte count and SHA-256 before decoding; cross-check index/package id, name and version. Plugin revision is SHA-256 of the exact package bytes; source edits are encoded into a new immutable package/revision. No ambiguous normalized JSON digest. Hashes detect mismatch against metadata; a compromised unsigned server can replace both, so a hash alone never labels a publisher authenticated.

## Trust and install state

Repository identity is canonical HTTPS envelope URL + index UUID. A signature with a newly offered key is cryptographically valid but publisher-unverified. Do not trust a key simply because it came from the same server. Show full SHA-256 fingerprint of the public key; explicit trust requires the user to confirm comparison with an independently obtained fingerprint. An unsigned repository can be added after a clear warning and is always marked unverified.

States: unsigned/unverified, signed/unverified, signed/trusted (exact manually pinned key). The UI never says Apple-verified or safe. Trusted repositories losing signatures, changing keys, changing repository UUID, failing hashes/signatures or rolling back stop refresh/import. No silent trust reset. Removing a repository does not change installed immutable revisions or run code; re-adding creates a fresh warning boundary.

Store trust, accepted sequence + payload digest, repository metadata and installed package revisions atomically with backup exclusion. Loading corrupt state yields an error and preserves data, never silently resets to trusted/empty. A failed/cancelled fetch cannot overwrite good state. Repository preview and fetch do not mutate trust/high-water state until the explicit add/refresh transaction succeeds. Import only from the validated snapshot the user reviewed; do not refetch mutable index implicitly. Repository and local imports create disabled revisions. Updates and edits remain explicit; no inherited execution grants.

## Runtime v1

Pin official QuickJS 2026-06-04 source archive with recorded SHA-256, license and an explicit local-patches record. The two-line native-work limits patch records original/patched whole-file hashes and is independently reversed and checked by the verifier. Compile core engine statically into a C SwiftPM target; do not include quickjs-libc, std/os, module loaders, qjsc bytecode, executable memory or SPI.

C bridge accepts validated source and JSON fixture/config; one fresh runtime/context per call on a dedicated serial DispatchQueue. Cooperative evaluation/validation budget 50 ms from call setup through source evaluation, handler invocation and result serialization; cleanup is measured separately and is not forcibly interruptible; heap 8 MiB; stack 256 KiB; BigInt storage capped to 8192 bits including intermediate allocations by one audited two-line upstream patch; cancellation via lifetime-safe thread-safe token. Test pathological loop, allocation, recursion, regex, getters and toJSON; do not infer built-in interruption from loop alone. No fetch, XMLHttpRequest, filesystem, native bridge or timers exposed. Promise/thenable, cycles, functions, BigInt, non-finite numbers and invalid action results rejected. Native result parse/validation rechecks depth, bytes and max 2 actions. Do not call arbitrary exception toString outside the budget.

onRequest(event,config) / onResponse(event,config) return {actions:[{type:"webhook",endpointId:UUID,json:JSONValue}]}. In this foundation actions are displayed only. Synthetic fixtures are explicit and clearly labelled; no saved Record body getter or VPN hooks are read. A dry-run invocation is explicit, serialized, cancellable and cannot enqueue/deliver actions. Source evaluation never happens in preview/import/editor save.

## Implementation sequence and evidence

1. Independent LocalGPT conceptual and Claude source-aware plan reviews; resolve material findings.
2. Test-first core/schema/repository validation and trust transitions; Codex runs failing/passing Swift tests on studio. Claude Linux can edit but cannot claim Swift execution.
3. Test-first pinned QuickJS bridge/runtime in isolated package files, with host latency/limits evidence; maintain exact vendor checksums.
4. Repository storage/HTTPS streaming and app UI integration. Source viewer/editor with real synthetic dry-run, provenance and warning/trust confirmation. Include a static sample repository and a small publisher tool to hash/sign the exact payload; no secret/private signing key committed.
5. Independent actual-diff review, native package tests and Xcode app/extension build; owned iPhone/iPad simulator screenshots and cleanup.
6. Record test/physical/publication limitations. Keep next-major work on its own branch; do not change the queued 1.0.1 release.

## Plan-review resolutions (before implementation)

## Resolved source-review findings

Claude Sonnet completed a local source-aware plan review after the unsupported WebFetch attempt failed. It identified ignored package paths, target/link ownership, vendor/intrinsic configuration, transition/snapshot detail, editor integration and license gaps. Resolutions:

- Package lives inside the committed app repository at Packages/InterceptorAutomation. Add narrow .gitignore exceptions for that directory (existing tracked pbxproj remains tracked). Codex owns Package.swift and project integration. AutomationCore contains schema/repository/store; AutomationRuntime depends on CQuickJS and validates its byte boundary independently; the app rechecks output through AutomationCore. Only app links the foundation now; PacketTunnel retains current dependency graph and is still built for regressions.
- Vendor only quickjs.c/dtoa.c/libregexp.c/libunicode.c/cutils.c and their required headers, VERSION and LICENSE. Explicit source list, per-file SHA-256 and archive hash; no quickjs-libc/qjs/qjsc. CONFIG_VERSION=2026-06-04 and _GNU_SOURCE. Use JS_NewContextRaw and explicitly selected intrinsics; no typed-array/shared-memory/Atomics exposure, JS_SetCanBlock(false). No CONFIG_BIGNUM flag assumed for this version.
- Canonical URL: ASCII DNS host or localhost (for explicitly selected self-hosted HTTPS), IPv4/IPv6 literals rejected; trailing host dot rejected; path case preserved; ports 1...65535 except normalized 443 are part of identity. Identity key is the full canonical HTTPS URL string, equivalent to its parsed components because scheme is fixed.
- Store limits: 16 repository identities including tombstones; 32 installed revisions, 8 MiB total raw packages, serialized catalog 16 MiB. Apply backup exclusion and iOS completeUntilFirstUserAuthentication file protection to each staged inode before atomic replacement; rename preserves those attributes without a fallible operation after commit. Catalog versioned and read/validated before mutation; use an advisory per-path lock plus reload-before-write to avoid multiple store instances losing updates.
- Every accepted index receives a generation UUID; pin/remove/refresh changes generation. Install requires the exact accepted generation in addition to snapshot digest/identity, verified inside the store transaction. Concurrent re-import is idempotent by source identity + plugin ID + revision, never overwrites another source.
- Installed edits keep parent revision digest and localEdit provenance; publisher status is not inherited. Source editor is separate from the captured-body CodeView, with binding and edit-dirty handling; preserve the existing viewer behavior and theme scaling. QuickJS MIT license appears explicitly in app Licenses, not inferred from Package.resolved.
- Runtime caps: source128KiB (correcting initial test-worker guess), event JSON64KiB, config JSON8KiB, result32KiB/depth32/max2 actions. Deadline50ms covers user-code evaluation/validation/serialization; cleanup is measured as part of total observed call latency, but cannot itself be forcibly interrupted. 150ms host reclamation is a test target, not a process isolation/RSS guarantee.

### Trust transition table (all rows also check UUID, sequence/digest and expiry)

| Stored identity | Fetched metadata | Result |
| --- | --- | --- |
| None | unsigned | explicit unverified acknowledgment; persist unsignedAcknowledged |
| None | valid signed key K | explicit acknowledgment; persist signedUnverified(K), never auto-pin |
| unsignedAcknowledged, visible | unsigned | refresh allowed; remains unverified |
| unsignedAcknowledged | valid signed K | new acknowledgment; signedUnverified(K) |
| signedUnverified(K) | valid signed K | refresh allowed; remains unverified |
| signedUnverified(K) | unsigned or signed different key | refuse continuity change; key rotation/reset is later explicit functionality |
| pinned(K) | valid signed K | refresh allowed, preserve pin |
| pinned(K) | unsigned or different key | refuse, no warning-based bypass |
| Any removed identity | same valid continuity | retain pin/high-water; unverified sources require acknowledgment again |
| Any | invalid supplied signature / UUID change / lower sequence / same sequence changed digest | refuse and preserve prior state |
| Any | same sequence and identical payload | idempotent acceptance; no plugin/grant activation |
| Same repository UUID at a different canonical URL | any valid metadata | separate new identity, no inherited pin; normal initial warning |

### Manifest compatibility

Use the existing v1 {manifest,source} package contract, not an unversioned id/name/version-only manifest. Required manifest keys: schemaVersion=1,id,name,version,subscriptions,read,endpointBindings,settings. Validate subscription phases/match hosts+optional methods/path/status and read metadata/header/query/body declarations according to the earlier specification. Foundation permits 0...4 endpoint binding names (rather than requiring a webhook binding for a no-action script). No declaration grants real data or execution. Store the full validated manifest so editing source preserves declarations. Source128KiB, package256KiB, settings object8KiB/depth16. New template uses metadata-only read/body:none and example.com, no live capture.


LocalGPT Thinking conceptual review completed (Pro unavailable, no source access). Its material findings were trust bootstrap/downgrade identity, URL/parser rules, atomic acceptance and runtime/native boundary. These are accepted and resolved as follows:

- Canonical envelope URL alone is the persistent lookup key; a different UUID at the same URL is rejected. Normalize HTTPS scheme and ASCII DNS host to lowercase, remove explicit port 443; reject userinfo/query/fragment/percent/backslash/non-ASCII input and dot/empty path segments. Directory URLs ending in slash append repository.json; other paths identify the envelope. Punycode ASCII hosts are supported, automatic Unicode-host conversion is not. Compare URL components and final confined path, never string-prefix origin checks.
- Keep trust/high-water tombstones when a source is removed from the visible list. Ordinary remove/re-add cannot erase a pin or bypass downgrade/rollback checks. A separate explicit trust reset is not part of this foundation.
- State transitions distinguish unsignedAcknowledged, signedUnverified(key) and pinned(key). Unverified-to-signed promotion requires another review/acknowledgment; a pinned source can never fall back through a warning. Pinning requires entering the independently obtained full 64-hex SHA-256 fingerprint and matching the offered key. New keys are never automatically trusted. Trust cancellation persists nothing.
- Standard padded canonical RFC4648 base64 only; UTF-8 without BOM, strict surrogate pairing, duplicate keys (including escaped-equivalent keys), trailing input/unknown fields rejected. Sequence is an integer in 1...9007199254740991, size an exact integer; manifest numeric settings must be finite.
- Add mandatory issuedAt and expiresAt in UTC second-resolution RFC3339 (yyyy-MM-ddTHH:mm:ssZ). issuedAt <= verificationTime+300s, expiresAt > verificationTime, 0 < lifetime <=90d. New import rechecks expiry. Local immutable installed revisions remain inspectable/editable/dry-runnable offline. Device time is not an absolute authenticity/freshness guarantee.
- An explicit repository Add/Refresh commits only a fully verified index acceptance (identity/key/state/high-water/digest/metadata) as one transaction; it is independent of installing packages. A plugin import stages complete verified package bytes first, then atomically commits its immutable revision and provenance, using the already accepted exact index snapshot. Revalidate identity/pin/high-water/expiry at commit so a stale screen cannot overwrite newer state. Failures preserve the last good complete state.
- Bound installed raw package bytes, repository count and store size. State is actor-serialized; atomic single-file replacement commits the full bounded catalog and trust state. Disk/save failures do not mutate the in-memory authoritative state. Corrupt data is preserved and blocks mutation until resolved explicitly.
- Local edited revisions have parent digest and local-edit provenance; they do not inherit publisher signature/trust or grants. Plugin IDs from different sources do not overwrite each other. Versions are strict SemVer metadata; sequence+digest decides metadata freshness, no automatic semver-based update.
- Downloader explicitly sets cookie store=nil, credential storage=nil, URLCache=nil, accepts no credential challenges other than normal system TLS trust, rejects redirects/304, and caps received decoded data independently of Content-Length. Cancellation and absolute monotonic total deadline stop staging and prohibit late commits.
- Runtime installs limits/interrupt before evaluating any user code, uses monotonic time and fresh VM, disables Atomics blocking/shared memory, does not drain Promise jobs, and rejects asynchronous results. Capture intrinsic validation functions before user source, validate under the same deadline, return bounded primitive bytes only, and revalidate DTO natively. Never stringify arbitrary exceptions. C allocations/copies are independently bounded; the heap limit is not total process RSS. Host pathological latency measurements do not replace physical-device G1.
