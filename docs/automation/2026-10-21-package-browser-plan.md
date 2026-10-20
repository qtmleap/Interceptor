# Package browser implementation

> Implementation follows the user's current Sileo-style mocks and subsequent corrections.
> Mock source: /Users/devonly/Developer/interceptor-live-scripts-20261018/Interceptor/docs/mock-diff/SPEC.md
> Native worktree: codex/http-hooks at f2a95a8c62aecda758bb79f22c11b1a4df019575, including preserved pre-existing working changes.
> Evidence: build/http-hooks/live-completion/remaining-verification/native-browser-implementation/

## Goal

Implement Sources / Packages / Scripts, category browsing, a batch install queue and installed-package management. A package has one installed revision, which is exactly the revision executed when enabled. Match conditions and code belong to individual files; package detail begins with all target hosts. Source and JSON viewers are full-screen and read-only.

## Global constraints

- Preserve source-qualified identity (repository URL or local, manifest UUID, digest), trust, high-water marks, explicit consent, activation review, stale-review CAS and exact-byte permission bindings.
- Get queues an immutable candidate. Confirm commits all valid entries or none; failure preserves installations and queue. Initial installation is disabled. Reinstall only accepts the exact currently selected bytes and does not rotate grants.
- Update replaces the selected revision and, if enabled, its active bytes in one durable commit after reviewing the new bytes. Failure keeps the old selection and grant; no pending-switch UI.
- Refresh updates repository metadata only, coalesces duplicates and keeps cache on error. Removing a source preserves installed packages.
- Apple system typography, 2x mock captures, affected screens only. Native simulator captures remain native evidence with recorded scale.
- No production publication, branch merge, upload or release in this plan.

## Architecture

Catalog revisions become validated immutable cache/history; user-visible installation selection and exact active bytes share one authoritative version-2 activation document. Selection has its own generation. Grant snapshots and their generation change only when grants change, so disabled installs do not interrupt hooks or invalidate unrelated reviews. Read legacy version 1; derive migration selection without writing on load, preferring the active exact revision and then the last legacy catalog revision per family.

A Core coordinator locks catalog then activation synchronously without actor awaits or recursive store calls, revalidates source generation and snapshot, stages cache bytes, then atomically publishes selection plus grants. A failure before publication leaves only unselected cache bytes. Actor reads reload durable state; no cached projection may turn those bytes into an installation. A missing shared activation URL blocks installation mutations rather than creating a second authority. Catalog schema stays unchanged.

Optional metadata is author, summary and one category string. Old metadata-free feeds remain valid; new strict fields require reader-first rollout. Host aggregates come from the fetched manifest, not Index. Category has explicit Unicode-scalar and UTF-8 bounds; do not silently tighten existing persisted author/summary validation. Native C validation and SDK parity must match before category-bearing packages are claimed runnable.

## Tasks and interfaces

1. Metadata: optional category in authored/validated manifest, optional author/summary/category in Index and publishing; cross-check present Index fields. Preserve absent-field bytes. Native Swift/C and SDK Python tests. Native owner does not edit SDK files; SDK owner does not edit native files. Runtime pin change waits for reviewed native commit.
2. Durable installation state: version-2 document, pure legacy projection, source-qualified family helper and coordinator state/batch/update/delete/activate operations. Keep grant-only snapshot equality. Tests cover failed writer after cache staging, restart, revoke, concurrent stale state, exact reinstall, all-or-nothing batch, legacy migration and corrupt documents.
3. App model: injected coordinator seam, one installed projection, immutable bounded queue, single-flight confirm and update, busy/dismiss locks, retryable errors. Preserve trust/consent review and remove source-editing UI. Unit tests consume the Core contract.
4. Native browser: adaptive phone tabs / iPad sidebar; Sources -> Categories -> searchable Packages -> detail; installed list and file-only Scripts list; host-first detail; explicit read-only code/JSON destinations; separate Test. Short JA/EN copy; search uses パッケージを検索 / Search for Packages. Canonical mocks define spacing and hierarchy.
5. Integration and verification: update focused repository fixture and UI tests for new flow, fix current PR31 CI reachability failures. Freeze exact app/transport source and toolchain. Run focused Core/SDK tests, app units, affected iOS18.5 and26.5 phone/iPad native tests/captures; cleanup owned devices.
6. Review: fresh independent Claude actual-diff review, LocalGPT actual-files review if available and verified. Separate image-only UI review from code review. Native comparison and first-baseline approval remain explicit; screenshots alone are not a visual pass. Inspect required CI after an authorized checked commit/push.

## Review focus

Cross-file commit boundaries, restart/cancellation after durable commit, same UUID across sources, permission expansion during enabled Update, cache-only revisions becoming installed, legacy migration and downgrade behavior, stale queue/source/approval generations, active grant revocation while a screen is open, single-flight reentrancy, corrupt/missing state and maximum sizes. Native accessibility navigation and back origin must match the mock.

## Planning evidence and rulings

- Claude independent feasibility: job_94ed99593d35386534205ded86944bc1; state-contract follow-up job_6998b7e0486891af304356e25f9b2d59.
- LocalGPT actual-files plan review completed in job52e908eb-6bde-4d03-a80f-acd56e52a5c1 using its verified studio LocalMCP connection. Report and source fingerprints are retained with the evidence. Its independent recommendation agrees with one authoritative selection/grant commit and separate installation/runtime generations.
- Ruling: reject a separately installed-but-not-switched state because it violates the user's single-version rule; selection and active bytes commit together.
- Ruling: no Index hosts field; fetched package detail provides complete target hosts.
- Ruling: internal history can remain temporarily after failed staging, but never counts as installed or consumes a grant.
- Ruling: prefer focused affected checks; leave required full CI to the actual workflows and retain mandatory repository hooks.
- Ruling: explicit revoke, including revoke before any grant exists, rotates the approval generation. This preserves cancellation of pending approval; disabled install and exact-byte reinstall still leave runtime admission unchanged. Native regression tests reproduced the unsafe no-op behavior before the correction.
- Ruling: legacy disabled families select the last archived revision in existing catalog order. An active exact revision takes precedence. This deterministic migration never enables a disabled family; it avoids an extra migration-choice screen for historical disabled imports.
- Snapshot-1 actual-file reviews completed independently: Claude job_338ebd66de792944d479ad4a2e2c99f0 and LocalGPT jobe0d4b92b-5ff5-4388-965e-c2a1f2e95011. Material findings remain open until source-bound regressions and follow-up reviews pass.
- Initialization refinement: an independent, strict protected marker distinguishes genuine legacy absence from loss of initialized shared state. Before staging, persist an unchanged v2 projection and marker; missing or v1 shared bytes with a marker fail closed, including cached grant reads. This does not promise protection against simultaneous marker/shared loss or restoration of older valid v2 bytes.
- Approval refinement: delete invalidates pending approvals even for disabled revisions. Every supplied update approval is checked against current persisted grant generation and exact bytes before a same-revision no-op return.
- Archive refinement: installation selection remains limited to 32 revisions and 8 MiB. Coordinator staging may retain at most 33 archived revisions and 8 MiB plus one maximum package. Before staging, prune only unreferenced history using the locked current projection; both current and proposed selections/grants must resolve against staged bytes. Failed batches can leave several bounded unselected candidates. Exact reinstalls remain write-free; no fallible cleanup follows authoritative publication.
- Claude capacity-plan follow-up job_2721641c274421116cab073bf02c7adb accepted that bounded approach with additional validation/testing conditions. LocalGPT capacity-plan follow-up job655f5f58-bddf-4efb-93e7-86f87d6ee55d failed with native_existing_parent_invalid and an unconfirmed request; no duplicate was sent and no completed capacity-plan review is claimed.


## Current verification

- Frozen source2 package checks: 352 passed (Core 210, Repository 26, Runtime 116); SDK metadata checks: 86 passed. The category-only C Unicode classifier matches native Swift for all valid Unicode scalar values and preserves legacy author/summary rules.
- Source2 actual-file reviews completed independently in Claude job_2d0d03290b23cb3355c26dbf1fde236b and LocalGPT job2b704168-6e52-4077-b796-e4c91ae01769. The remaining controller finding was a delayed Delete clearing a newer failed revocation after an exact-byte reinstall.
- Retained per-pending-revision intent receipts and independent delete result ownership fix that finding. Three source-bound regressions reproduced the pre-fix failures. Fixed snapshot582602e6 passed all49 PluginBrowserModelTests and AutomationActivationControllerTests. Source, dependencies and toolchain remained unchanged; the owned simulator was deleted.
- Independent fix reviews completed: Claude job_de3e268516d0ca49879d7df7f0537dfa and LocalGPT Thinking jobb9ea2a2e-8109-4bcd-adb3-1f3d8953d04a, with no material findings. The LocalGPT worker verified both actual-file hashes before and after review; its completed conversation was archived and verified absent from fresh Recents.
- Native UI checks: iPhone18.5 batch install/reopen, four-Hook test/approval, exact file viewing, JSON read-only formatting and unsigned/import/manage flows passed in their retained source-bound runs. iPad18.5 batch install/reopen and iPad26.5 batch install/reopen plus exact-file viewing passed. The combined iPhone26.5 run ended unverified after disk exhaustion; individual earlier passing log entries are not an all-green run. Owned simulators from the completed runs were deleted.
- The LocalGPT review completed for all14 approved screenshots and six revised images. Review requests supplied only authorized images and prohibited tools/code access. The response adapter hardcodes tools=[] and tool_choice=none, so those compatibility fields do not establish upstream tool disablement. The latest three-image request failed with a conversation-history rate limit and was not resent; that follow-up remains unverified.
- User corrections compact the action capsule, remove the gradient/count rows/redundant Enabled footer, use body-sized unsigned warnings, and give Manifest JSON, Sample traffic, Plugin configuration and Source Code standard native row heights. Equal file conditions share a single target group. Source25 product bytes built successfully; focused phone18.5 and iPad26.5 capture flows each passed one selected test with zero skips. One Source24 file capture is retained from a failed flow whose next navigation exceeded its wait; its image is native evidence, not a test pass.
- Source-bound Claude review of the small row/footer changes found no material issues. Mechanical source24 equivalence confirms the package352, controller49 and named native55 evidence scopes; dependency manifests and recorded native toolchains match. This reuses their original execution scopes rather than claiming new source24 runs.
- A new M3 Debug build freezes source25 base e32e90bf and preserves existing app data. Its build/signature/install outcome is tracked separately. The private physical probe has not run on the current build: Foundation fixed3 logic passed29 Swift6 cases, while independent reviews found additional import/session ownership checks to resolve before a device run. Historical VPN/Rust proof does not certify this installation-state migration.
- Disk exhaustion interrupted a capture build and a new snapshot. Regenerable task-owned caches were cleaned; source pairs, dependency manifests, captures and results were retained. The interrupted iPad workspace has a separate read-only recovery audit, not a fabricated successful build receipt.
- Captures, design-mock comparison, approved regression-baseline comparison and UI-only review are separate gates. The completed image-only review does not adopt a regression baseline. No native visual pass, baseline adoption, current physical VPN pass, new CI pass or release readiness is claimed yet.
