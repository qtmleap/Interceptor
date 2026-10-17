---
name: ios-development
description: >-
  Use for native iOS/iPadOS app work (and associated macOS targets) built from
  Xcode projects: implementing features, debugging, reviewing, testing, verifying,
  or preparing releases. Not for pure web work or generic documentation.
---

# Native iOS / iPadOS development

Instruction-only: no runners, scripts, CI jobs or dependencies. Shared parallel-work,
verification, Tailscale preview, UI design, screenshot and App Store Connect rules
live in the root `AGENTS.md` (`development-orchestration`); apply them, do not
restate them. Scope choices and the release matrix:
[references/testing-policy.md](references/testing-policy.md). This template
itself installs no jobs. Review routing (LocalGPT / Claude Code / LocalMCP /
Codex) is in the root `AGENTS.md`. On packaging, TestFlight, submission or
launch, read [references/release-policy.md](references/release-policy.md).
App Review submission and follow-up route to
[references/app-review-followup.md](references/app-review-followup.md).

## 1. Discover, never guess

- Find the execution host first. Linux containers (including `swift-ios-app`)
  have no Xcode, Apple SDKs or simulators: do only SDK-independent checks there
  (available format/lint tools and supported pure-Swift logic) and run the rest on
  a reachable Mac. Discover that Mac from the environment; do not assume one exists.
- Find workspaces/projects, shared schemes, test plans and destinations from the
  repository and `xcodebuild -list` / `-showdestinations`. Take app, scheme, OS
  versions and device names from that output, not from memory.
- Read the CI workflows and hooks before assigning a check to CI. The
  `swift-ios-app` template's CI is commitlint + swift-format only; it is not
  Xcode build or test evidence.
- Record the command / CI / host mapping in existing project docs only when it
  helps later work. Do not add a file for it with every edit.

## 2. Work loop

1. Implement with the project's conventions and design system. New screens or
   substantial flow changes: reuse existing spec, component catalog and mocks,
   and use an available mock-first or UI design/prototyping capability first
   (root policy). Small fixes need none.
2. Local edit checks: the smallest relevant regression for the change, plus
   mandatory hooks. Broaden only for the change's risk or explicit project policy.
   For native UI-test runs, read the screenshot-comparison and supported-OS
   rules in `references/testing-policy.md`.
3. Before a PR: scope checks by changed behavior. Full required CI then runs on
   the exact pushed source; do not substitute a local run or bypass it with
   local caches. If CI is lint-only, affected Xcode behavior still needs Mac
   build/test evidence; that is additional coverage, not a duplicate CI run.
4. Report PR gate status and release readiness separately.

## 3. Long runs and snapshots

- Start builds/tests asynchronously against an immutable snapshot (commit plus
  relevant dirty/untracked files, locked dependencies, toolchain, config).
  Record job ID, source fingerprint, host, tests selected, result artifacts and
  state. Keep authorized independent work going; do not edit the inputs of an
  active run.
- If a run uses the live writable tree, pause edits to its inputs, or confirm you
  own it and stop or wait for it before starting a fresh isolated run. Never
  claim a running job can be moved to a snapshot.
- Reuse `build-for-testing` / `test-without-building` products only for the same
  snapshot, SDK and configuration, through the project's existing runner. Keep
  DerivedData, result bundles and devices separate per run; cap heavy concurrency.
- After inputs change, repeat only the affected checks. Expired, stale, skipped,
  interrupted or unknown results are not passes.

## 4. Simulator lifecycle

Before creating, booting or opening anything, record: host, device-set path,
UDIDs already booted, and existing Simulator windows/processes. Register cleanup
**before** the first create/boot/open so success, failure and interruption all
run it. Track every owned resource, including clones Xcode creates for parallel
testing.

Cleanup, after confirming workers have stopped:
- shut down only devices this run booted;
- delete only disposable devices/clones this run created;
- close only windows this run opened;
- quit Simulator only if this run launched it and no other session needs it.

No blanket `killall` or `shutdown all`; other sessions may be using them. Keep
evidence, and report any cleanup you could not confirm. Leave an owned simulator
open only when the user asks to inspect it, then close it after inspection.

## 5. Real devices and services

Choose device/service checks for the changed behavior and required release scope
using the testing policy. Local StoreKit and simulator fixtures are useful for
regressions; hardware and end-to-end service claims need suitable device/sandbox
evidence. Report required missing evidence as "not verified".

## 6. UI previews, screenshots, App Store

- Web previews: follow the root Tailscale-only policy; discover the address
  yourself instead of asking. A web prototype does not replace simulator/device
  UI checks.
- Adopted mocks: compare simulator/device captures at the matching state and size
  to the adopted mock (root policy); record only actual human design selections.
- Store screenshots and metadata: look for a suitable available skill (for
  example `app-store-screenshots`, `prepare-localized-app-store`) and read it on
  the host. Do not require installing it for unrelated work.
- App Store Connect: discover and prefer ASC MCP; follow the root authentication
  rules. A failed or transient API call is not a reason to ask for an Apple
  browser login. Keep signing/provisioning, upload acceptance, Apple processing,
  tester availability and review/release state as separate facts.
- Submitting to App Review: follow
  [references/app-review-followup.md](references/app-review-followup.md) for the
  monitor, rejection handling and resubmission.
