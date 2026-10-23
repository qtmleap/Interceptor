# Authenticated outbound hooks implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement these tasks. Codex owns integration and native verification; workers own disjoint paths.

**Goal:** A captured GET response supplies credentials to a declared secondary GET, with equivalent manifest/runtime validation in the app, SDK and Rust checker.

**Architecture:** Schema-2 metadata declares fixed HTTPS destinations and allowed outgoing headers. The VM records bounded intents; a native dispatcher validates the complete phase, releases VM admission, then performs direct TLS requests with exact-revision authorization. Existing packages and dry runs never gain network access implicitly.

**Tech stack:** Swift app targets (current Swift 5 language mode), Swift 6 package, shared QuickJS JavaScript engine, existing NIO/NIOSSL HTTP transport, Python builder, TypeScript declarations, Rust simulator.

**Spec:** `docs/superpowers/specs/2026-10-22-authenticated-outbound-hooks.md`.

## Global constraints

- Four lifecycle callbacks and filesystem-generated trigger routing remain unchanged.
- GET only, no request body, no redirects, dynamic URL substitution, credential storage or automatic cookies.
- At most four outbound bindings, eight declared headers per binding, 4 KiB per value, 8 KiB values per operation.
- Two actions per VM, two HTTP intents per complete composed phase, 32 KiB result, 50 ms active JavaScript budget.
- Four concurrent native operations, no queue/retry, three-second total deadline, 64 KiB received response cap.
- Native production DNS/IP validation and normal hostname TLS trust remain mandatory; test transport injection must not weaken production defaults.
- No new Xcode dependency, shared-runner changes, public preview, secret-bearing logs or blanket resource cleanup.
- Root owns Git commits/pushes and canonical native build directories. Workers make no commits.
- Immediately convert any capture to exact lossless WebP; verify pixels, profile, dimensions, scale and hashes before review. This plan's pure unit work requires no captures.

## Contract decisions

- Optional `manifest.outbound` exists only in schema 2. Its keys use the existing binding grammar (ASCII letter followed by ASCII letters/digits/underscore, at most 32 bytes), independent of legacy `endpointBindings`' four-entry budget.
- Each declaration has exactly `url`, `method: "GET"`, `headers`. URL is at most 2,048 UTF-8 bytes, canonical ASCII HTTPS with a lowercase DNS hostname; no IP literal, userinfo or fragment. Omit the default port; non-default ports are rejected in this first increment. Use an explicit `/` path. Percent escapes must be valid; reject whitespace, controls, backslashes and ambiguous host spellings.
- Outgoing header names are unique lowercase ASCII HTTP tokens, at most 128 bytes. Reject `host`, `content-length`, `transfer-encoding`, `connection`, `upgrade`, `te`, `trailer`, `expect`, `keep-alive`, `proxy-*` and pseudo-headers. Values allow printable ASCII, space and HTAB; no other controls.
- Wire intent: `{ "type": "http", "binding": "profile", "headers": { "authorization": "Bearer ..." } }`. The native adapter resolves the URL exclusively from the validated manifest.
- `PluginOutboundEndpoint` is an immutable public `Equatable, Sendable` Core value exposing `url: String`, `method: String`, `headers: [String]`; `PluginManifest.outbound` is `[String: PluginOutboundEndpoint]` (empty when absent).
- A Core `PluginOutboundIntent` validates the exact HTTP action shape against a `PluginManifest`; it exposes `binding: String`, `endpoint: PluginOutboundEndpoint`, `headers: [String: String]`. Legacy webhook parsing stays distinct.
- The previously approved JavaScript helper is synchronous `Interceptor.send(binding, {headers})`. The fetch/CORS question was reviewed independently; native HTTP is not browser CORS, and the approved helper remains a synchronous intent recorder. Do not rename a void intent recorder to `fetch`: real fetch requires Promise/Response semantics and changes phase-commit guarantees. Manifest validation and native transport are independent of that public API decision.
- Prefer existing NIO direct `SocketAddress` TCP + NIOSSL original-hostname trust + HTTP codecs. Current capture routing is PAC-only; direct numeric-IP sockets bypass it. Resolve once, validate binary IPs (including embedded IPv4), and connect to that exact address. Recheck authorization after DNS/TLS and before writing credentials.

## Review focus

- Empty GET request bodies must not suppress an eligible JSON response hook (native integration test).
- A later revision error or a caught invalid VM send must not leak earlier intents (processor/runtime tests).
- DNS rebinding, private IPv4/IPv6 and bad TLS certificates must prevent credential transmission (transport tests).
- Revocation during DNS/TLS, shutdown and overload must finish/cancel owned work without delaying original forwarding (dispatcher tests).
- Old packages, schema 1, dry runs and Rust simulation must remain non-networking (cross-language fixtures).

## Task 1: Core declarations and validated intents

**Ownership:** `Packages/InterceptorAutomation/Sources/AutomationCore/Manifest.swift`, new `PluginOutbound.swift`, Core outbound tests only.

- [x] Add failing tests for optional schema-2 declarations, schema-1 rejection, strict keys, binding/URL/header limits and exact intent validation.
- [x] Run those tests and retain the expected missing-feature failures.
- [x] Implement the public Core interfaces above without changing activation/approval identity semantics.
- [x] Run affected Core tests and the package suite using the existing native scratch path, coordinated by Codex.
- [x] Independent diff review and root integration.

## Task 2: Runtime collection and SDK/Rust contract

**Ownership:** runtime worker owns `Packages/InterceptorAutomation/Sources/CQuickJS/bridge.c` and `Tests/AutomationRuntimeTests`; SDK worker owns `/Users/devonly/Developer/interceptor-plugin-outbound-sdk` exclusively. Coordinate the public API ruling first.

- [ ] Add failing shared positive/negative fixtures for declarations and HTTP intents, top-level calls, caught errors, action ordering/combined cap and legacy rejection.
- [x] Implement C strict manifest parsing and bounded callback-only intent collection; keep all VM output side-effect free.
- [x] Implement SDK metadata/build validation, types, examples and focused reference docs. Keep matching in generated manifest and use `const` in JS/TS.
- [x] Bind Rust to the actual reviewed C revision and prove output parity; the checker reports intents without delivering them.
- [x] Run affected package, Python, type and Rust checks; retain source fingerprints and actual results.

## Task 3: Native direct transport, dispatcher and lifecycle

**Ownership:** native worker owns new `Interceptor/Automation/HTTPPluginOutbound*.swift` and corresponding tests. Root owns `HTTPPluginProcessor.swift`, `PacketTunnelProvider.swift`, Xcode membership and approval/dry-run integration.

- [ ] Add failing transport and dispatcher tests for fixed target/header delivery, DNS/TLS failures, redirects, 64 KiB cap, total deadline, concurrent limit, no queue, revocation and cancellation.
- [x] Implement direct DNS-pinned transport using existing NIO TLS trust and codecs; no CFNetwork/PAC or forgeable external marker.
- [x] Collect intents across all matching revisions, validate mutations and output, authorize whole-phase commit, release admission, then schedule bounded sends. No partial dispatch after a later failure.
- [x] Retain and invalidate owned dispatcher in PacketTunnel start-failure, stop and authorization-change paths. Recheck live consent/store generation at admission and before HTTP bytes.
- [x] Extend existing approval UI with destination, outbound header names and all granted input categories. Keep explanations concise in Section footers. Dry-run previews never dispatch.

## Task 4: Integrated delivery evidence and review

- [x] Freeze native/SDK source fingerprints before builds; use existing canonical build/cache directories and rotate only owned disposable artifacts.
- [x] Native real TCP/CONNECT/TLS integration: GET credentials JSON and Set-Cookie, then actual protected secondary endpoint receives the expected Authorization/Cookie. Include nonmatching, failed-phase and recursion controls.
- [ ] Independent Claude actual-diff review, plus LocalGPT actual-files review for this security-sensitive feature; resolve material findings and revalidate affected tests.
- [ ] Build signed Debug and install on M3. Confirm current exclusive device ownership before launch/VPN changes; prove PacketTunnel forwarding and no recursion separately from loopback/Rust.
- [ ] Verify only changed approval screens against current design; retain exact lossless WebP and perform UI-only LocalGPT review without code access where applicable.
- [ ] Guarded commits, update existing PR31 and SDK PR9, inspect exact-SHA CI. Do not merge these PRs without separate authorization.
- [ ] Save evidence, archive completed managed reviewer chats, clean only this run's disposable owned devices/artifacts. Keep Viewer running.

## Recorded verification (2026-10-23 JST)

- Core/runtime package: 399 tests passed. Shared Core/C source is committed at `fc055f8ed90c3a6b01c4b6f08d27d9a54907e79c`; GitHub publication is pending.
- SDK pin/Rust: source `5bf5d97279fe244d3614546621c6aed82179edd0c51fc8be8e3b791639ea45a7`, 239 SDK tests, 19 tools tests, 7 focused outbound tests and native/portable integrity gates passed; documentation-only readability follow-up is in progress.
- Native source `ae511ff68e9056018d9d7476f6f4ad1f88228de9a3e83738d487d7d863dafcc1`: 100 iOS 18.5 tests passed, zero failures/skips, source verified before/after and owned simulator deleted. Includes actual TCP/CONNECT/TLS credential reuse and recursion/nonmatch controls. This is not physical VPN evidence.
- Independent actual-diff Claude and LocalGPT follow-ups completed with no blocker/high finding. LocalGPT's reader-contention P2 is handled by the private helper's nonblocking/retry protocol; its focused XCTest execution remains separately tracked.
- Signed Debug device build at the same native fingerprint passed. Installation on the physical M3 was confirmed successful by devicectl at the same signed app content hash. Physical VPN proof, affected approval captures/UI-only review, exact-head CI/publication and final cleanup are tracked separately.
- RED provenance is specific: Core missing-feature/grammar failures, runtime grammar parity failures, compiler legacy rejection and type mutation checks, and native probe cancellation-schema RED were executed. Initial C implementation and some original native test cases were authored by a worker without an executable toolchain; an initial pre-implementation RED for every one of those cases was not captured. Do not claim otherwise.
