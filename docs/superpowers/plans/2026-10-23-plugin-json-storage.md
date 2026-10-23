# Plugin JSON Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Save original Salmon Run API response JSON and verify nonempty history and real details on M3.
**Architecture:** A bounded response.onLeave save callback publishes into an app-group store, fenced by current activation. The foreground app mirrors committed files into Documents/Plugins; the Plugin saves original fetch response text.
**Tech Stack:** Swift 6, QuickJS C, TypeScript, Python/Bun, iPadOS.
**Spec:** ../specs/2026-10-23-plugin-json-storage-design.md

## Global Constraints

- User clarified: save only original response JSON, with no wrapper or authentication data.
- Latest user update supersedes the spec's initial empty-history test assumption: real nonempty history and details are now available and must be verified.
- Logical keys are 1–1024 UTF-8 bytes, no NUL (increased from draft's 512 so a 512-byte result ID plus prefix fits). JSON <= 1 MiB, depth <= 64; preserve original bytes.
- Schema 2 optional write.files defaults false; no schema 1 permission. Existing fetch ABI stays compatible.
- Per invocation: 64 saves / 16 MiB submitted, separate fetch budget, same 120s wall; cumulative CPU1000ms for a files grant plus trusted save callback, otherwise250ms, excluding callbacks. Namespace: 64 MiB / 2048 files.
- Activation lock precedes storage lock. Recheck cancellation/consent before atomic publication; already published files survive cancellation/revocation.
- No new screens. Only existing activation permission row/footer and Files exposure.
- Workers own disjoint files, make no commits, and do not capture screens. Codex runs tools on the verified Mac and owns integration/device evidence.

## Review Focus

- Revocation between validation and rename must prevent the write while retaining prior files.
- Untrusted filenames and symlink ancestors must never redirect reads/writes outside owned roots.
- Repeated same-key saves, partial failures and quota replacement must preserve committed data.
- One-MiB Unicode/escaped responses must fit actual QuickJS heap without envelope duplication.
- Foreground export must tolerate user edits without importing content or deleting unrelated Files content.

### Task 1: Permission and QuickJS bridge

Files: AutomationCore/Manifest.swift; CQuickJS/bridge.c and include/CQuickJS.h; AutomationRuntime/JavaScriptFetchExecutor.swift; associated package tests.
Interfaces: `public typealias SaveJSON = @Sendable (String, String) async throws -> Void`; `runV2(... configJSON: Data, saveJSON: SaveJSON? = nil, transport: @escaping Transport)`.
C: add qjs_run_v2_fetch_save (old fetch arguments plus QJSSaveJSONCallback and save opaque before package). Callback receives raw key/text pointers, lengths, timeout_ms; status 0/1/2 means success/reject/cancel. Preserve old qjs_run_v2_fetch wrapper.
- [ ] Write tests first: optional/denied files permission, old fetch, exact text/UTF8 callback, invalid key/JSON, limits, phase/probe/no IO, cancellation and Promise errors.
- [ ] Codex runs focused tests and records expected failure, then worker implements the contract.
- [ ] Run affected Swift tests and shared C validation on resulting content; expect zero failures.

### Task 2: Durable storage and activation fence

Files: new AutomationCore/PluginJSONFileStore.swift; PluginActivationStore.swift; core tests.
Interfaces: `public struct PluginJSONFileStore: Sendable { init(directoryURL: URL); func save(revisionID: String, package: PluginPackage, key: String, jsonText: String, checkAuthorization: @Sendable () throws -> Void = {}) throws; func export(to directoryURL: URL) throws }`.
Fence: `PluginActivationStore.withCurrentActivation(admitted: PluginActivationSnapshot, revisionID: String, _ operation: @Sendable (ActivatedPlugin) throws -> Void) throws`, holds existing activation lock across operation, verifies snapshot and exact granted revision. Store validates revision/package and permission, derives namespace with trusted InstallationIdentity family + digest, file SHA256(key).json.
- [ ] Write tests first for exact bytes, invalid/large/deep JSON/key, no permission, namespace isolation, atomic replace/noop, quotas, symlinks/special files, IO errors, cancellation before publication, stale activation, export behavior.
- [ ] Codex runs tests red; worker implements descriptor-relative no-follow storage, 0600 atomic temp/rename/fsync, bounded quotas, source-only export.
- [ ] Run relevant core tests; expect zero failures.

### Task 3: SDK and Salmon Run integration

Files: types/interceptor.d.ts; tools/compile.mjs and repository_config.py; Plugin metadata/hook; authoring/compiler/hook tests; canonical API docs/templates where applicable. Native bridge simulator copy is coordinated by Codex after Task 1.
- [ ] Add tests first for saveJSON types, direct-call placement in response.onLeave, aliases/shadowing, optional boolean files permission, original history/detail text and no token persistence.
- [ ] Run tests red, then implement SDK contract and Plugin 1.1.0 with write.files true. Fetch text once; validate parsed history/detail before saving original text; retain IDs only. Stop on save errors.
- [ ] Run affected tests, check script and manifest from `bun run build`, then required repository check; verify generated package hashes and permission.

### Task 4: App integration and Files

Files: HTTPPluginProcessor.swift; AutomationSharedConfiguration.swift; ContentView.swift; new foreground exporter helper; Info.plist; PluginPackageApprovalView.swift; Localizable.xcstrings; integration tests.
- [ ] Add processor tests for admitted revision binding, save callback authority and no write after revocation; observe failure before integration.
- [ ] Inject trusted store URL into processor, retain revisionID in deferred run, bind SaveJSON closure to admitted activation fence and consent/cancellation checks. Export on launch/foreground with cancellable ~5s loop away from main actor.
- [ ] Enable UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace. Add only conditional files permission in existing approval section/footer, localized Japanese/English.
- [ ] Run affected tests and required format/check gates. Build device app against immutable recorded source using existing owned DerivedData/SourcePackages.

### Task 5: Independent review and M3 verification

- [ ] Fresh read-only Claude review of exact diff/files. LocalGPT actual-files review for native storage risk, using its verified studio LocalMCP access. Resolve material findings with affected tests.
- [ ] Install app preserving data, import/enable canonical 1.1.0 package, trigger Nintendo Switch App's actual BulletToken request with live history.
- [ ] Read back app-group saved JSON and exported Documents JSON; verify nonempty history/detail, exact response bytes/hashes, package and source fingerprints, and Files visibility. Never print credentials/raw player data.
- [ ] UI comparisons use Mock Diff when matching adopted state is available. Captures immediately become lossless exact WebP with RGBA/profile/dimension/scale/hash verification; retain required originals only.
- [ ] Clean owned streams/windows/test devices and superseded disposable artifacts. Preserve private real-data evidence and pending/unknown reviewer jobs; archive completed managed LocalGPT chats only after results saved and no continuation remains.

## Review resolutions / execution ledger

LocalGPT Pro actual-files plan review completed (studio connection, original spec hash verified), plus independent Claude native and SDK feasibility reviews. Additional Claude Opus plan review is pending; no implementation yet.

- Commit boundary: authorization must hold when a publication is admitted at its final synchronous check. A cancellation after that boundary may leave the committed file. Shutdown's drain acknowledgement must wait until every admitted publication has finished. No claim of retroactive rollback or atomic UserDefaults/rename across processes is made.
- Keep activation lock work bounded: validate JSON before entering the fence; storage lock must be nonblocking when called under activation, reject contention so caller can retry on a later capture. No Documents export under activation lock. For the bounded 1MiB synchronous write, check cancellation during chunked writes and before publication; don't detach I/O that can outlive callback drain. This intentionally favors rejecting a contended save over holding up revocation.
- File and directory fsync required. If post-rename sync fails, report failure with committed bytes left intact; identical-byte retry still fsyncs file/directory. Creation ancestors are synchronized.
- Private and Documents copies use completeUntilFirstUserAuthentication and backup exclusion, applied before publication. Save success acknowledges private persistence; Files export retries only while app foreground. Existing approval footer explains Files visibility and retention after disabling.
- Aggregate retained store limit: at most16 namespaces, 256MiB total; no automatic eviction of raw data and no JS deletion. Full store rejects new writes; existing-key replacement remains possible within bounds. Native app removal reclaims its storage; deleting a public copy does not erase the authoritative response and the next export restores it. Export never deletes unrelated user files.
- Retain acquired IDs only, never all parsed detail bodies. Actual bridge batch verification must exceed8MiB cumulative replies within16MiB budget; preserve 8MiB VM heap.
- SDK Rust fixture adapter and immutable upstreamRevision pin must be updated to native storage commit; never mutate the cached upstream checkout. Pin change follows native commit and precedes final SDK build/test evidence.

### Final plan amendments before implementation

- Storage gains `prepare(revisionID:package:key:jsonText:) throws -> PluginJSONFileStore.PreparedWrite`; prepared write owns a protected, fsynced temporary file and cleanup. `PreparedWrite.commit(checkAuthorization: @Sendable () throws -> Void = {}) throws` acquires storage lock nonblocking and publishes. `save(...)` is convenience prepare+commit. Processor prepares outside activation fence and commits inside withCurrentActivation. Export has separate IO and never blocks activation. No hard deadline is promised for OS rename/fsync; drain waits for admitted callback completion.
- Final sync check is exactly Task.checkCancellation(), hasCaptureConsent(), outbound.isActive, fetchDispatcher.isActive; activation snapshot/revision equality is checked by withCurrentActivation. No async isAuthorized call inside the fence.
- Native store accounting uses stat sizes and chunked comparisons, not loading the whole retained store. Sweep only abandoned owned temporary files, never an active publisher's temp; lock/temp ownership must be explicit. Same-key concurrent publishers remain atomic.
- QuickJS heap stays8MiB. One-MiB text is the API byte maximum, not a promise that any caller's parsed object graph fits. Dense tiny-value JSON may exhaust the existing bounded VM; fail without host writes instead of raising heap. Test near-limit Unicode/escaped text success and dense parsed input controlled failure, plus realistic multi-detail cumulative batch >8MiB.
- Save JSON syntax validation must avoid constructing another complete JS object tree; native streaming/bounded parser validates raw UTF8. Preserve original text even when number spelling differs from canonical representation. Reject invalid text/depth/duplicate keys consistently with native parser.
- Update spec to reflect final1024 key cap, staging and actual nonempty-history M3 test. Live pass requires history count>0, validated IDs/principal, at least one real detail (multiple when present), each persisted copy hash equal to original response. If history unexpectedly unavailable, report the failed live criterion; synthetic evidence cannot replace it.

### Execution evidence and review fix pass

- Task1 committed f9e6b117aa02a1901e5fcdeeb366944dfbe44a17 after runtime35save+21fetch tests passed; native commit policy verified and branch pushed. SDK runtime pin and Rust adapter now match that immutable commit; actual C fixture tests7 pass including >8MiB cumulative saved responses.
- SDK schema/compiler11 and hook24 tests passed. Full bun run check is running against unchanged SDK source.
- Native package suite passed before review fixes (core282, runtime/repository counts in private log); app build succeeded. Initial simulator app-host test could not access app group because signing was disabled; rebuilt with ad-hoc signing and the10processor tests passed. Both owned simulator devices were deleted and no Simulator windows were opened.
- Native review completed independently by Claude; LocalGPT actual-files review remains pending on original source. Original changed-source files/hashes retained under private review-original for delta comparison. Current fixes will require an actual-files delta review.
- RED confirmed for backup exclusion repair on identical saves/exports, partial export with a blocked first file, nonfinite numeric parity, and rejected first publication consuming a namespace. Fix worker owns Core store/parser/tests; Codex owns foreground retry/cache and preserving the existing webhook footer. No new product screens.
- Test fixture corrections: supplied raw old/new strings were invalid JSON and now correctly quoted; invalid JSON never creates a namespace. A local helper merely named saveJSON is not a host API alias. The first valid detail establishes principal; the mismatch test now checks a second detail. These corrections preserve production contracts.
