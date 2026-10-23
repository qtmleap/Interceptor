# Plugin file destinations implementation plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development. The user authorized execution; do not ask for another plan approval.

**Goal:** Plugin-controlled generic file paths with Storage Enum and verified M3 iCloud Drive/Salmon Run delivery.

**Architecture:** QuickJS passes a validated destination and raw bytes to an activation-fenced private record store. The main app exports payloads using a persistent user-selected root and coordinated File Provider writes.

**Tech Stack:** Swift 6, QuickJS C, TypeScript/Bun, Rust simulator, native iOS document picker.

**Spec:** ../specs/2026-10-24-plugin-file-destinations-design.md

## Global constraints

- Approved API and Enum, raw payloads, no manifest destination duplication or unnecessary screens.
- Preserve current fetch/lifecycle/grant/quotas and unrelated working trees.
- Native base d81deb2; SDK base 1471892; existing source-bound passing baseline evidence retained.
- Workers edit only assigned paths, no commits, screenshots or shared builds; Codex verifies on this Mac and M3.

## Review focus

- Binary zero bytes and Uint8Array subviews must survive without truncation.
- Canonical path aliases and cross-family external collisions must not overwrite another file.
- Route/payload must be one atomic record across crash or cancellation.
- Stale bookmark, cancellation and offline provider preserve private data and avoid prompt loops.
- M3 root selection/relaunch must produce the exact requested visible path and original response bytes.

### Task 1: Durable generic file records

Files: new AutomationCore/PluginFileDestination.swift, PluginFileStore.swift and focused AutomationCoreTests/PluginFileStoreTests.swift. Reuse descriptor/protection primitives without changing the legacy JSON spool.

Interfaces: produces Core types and methods specified above, consumed by Tasks 2/3.

- [ ] Add failing text/binary/empty/path/atomicity/alias/ownership/quota tests; Codex runs native swift test to observe RED before implementation.
- [ ] Implement bounded destination validation and single-record private publication; add header-only enumeration/read methods.
- [ ] Run focused Core tests and existing legacy JSON store tests; expected PASS.

### Task 2: QuickJS, Swift runtime, SDK and Salmon Plugin

Files: CQuickJS/bridge.c and include/CQuickJS.h; AutomationRuntime/JavaScriptFetchExecutor.swift and RuntimeTests/JavaScriptSaveJSONTests.swift; SDK types/interceptor.d.ts, tools/compile.mjs, tools/simulator/src/main.rs, affected tests/docs and Salmon hook.

Interfaces: consumes Core destination, produces createFile callback and immutable Storage Enum. Header callback signatures match the spec. Codex owns HTTPPluginProcessor integration.

- [ ] Add failing runtime tests for createFile, Enum, non-JSON/binary/empty, offsets, arguments/grants and cancellation; observe RED with Codex's native tools.
- [ ] Replace unpublished JSON API with generic createFile across native runtime and simulator. Validate before callback; retain strict object/property checks and execution budgets.
- [ ] Update TS authoring/compiler/generated sample behavior and hook paths: Salmon Run/history.json and Salmon Run/details/<safe deterministic result ID>.json; original response text unchanged.
- [ ] Run native Runtime/fetch tests and focused SDK tests, observing PASS. Pin SDK to resulting native revision before final runtime build/check.

### Task 3: Native coordinated export and necessary folder authorization

Files: new Interceptor/Automation/PluginFilePublisher.swift and PluginFileDestinationController.swift (or focused equivalent); AutomationSharedConfiguration, HTTPPluginProcessor, PluginFilesExporter, ContentView, existing approval/localization and app tests.

Interfaces: consumes record enumeration and callback. Publishes raw bytes, manages bookmark per trusted family and export ownership state. No arbitrary paths from JS or bookmark access in tunnel.

- [ ] Add meaningful failing publisher tests for raw delivery, owned replacement, unknown-file conflict, links and temporary failure/retry.
- [ ] Integrate generic record store under existing activation fence and add foreground coordinated publisher/metadata cache.
- [ ] Present only native folder picker for pending cloud family without valid root; persist bookmark, handle cancellation/stale access, and update existing permission footer. Reuse canonical mock conventions for any custom visible change; no new custom screen.
- [ ] Run affected native tests and signed app build; expected PASS. Review final diff via fresh independent Claude; complex final file/security behavior also LocalGPT actual-files review with verified access.

### Task 4: Build artifacts and M3 acceptance

- [ ] Run bun run check, rebuild actual native C simulator on the final pinned revision, run affected actual-C tests, and bun run build. Confirm script, manifest and importable package hashes.
- [ ] Install signed app on physical M3 preserving catalog/history; import new Plugin through normal UI.
- [ ] Select/create the top-level iCloud Drive/Salmon Run folder using system picker; capture actual result history/detail, return to Interceptor for publishing.
- [ ] Relaunch app, re-resolve bookmark and verify matching file count/IDs and hashes in iCloud Drive/Salmon Run; verify synced Mac readback when available. Record actual server-sync limits separately.
- [ ] Verify all owned device/stream/temp resources cleaned, source identity checked, PRs updated and CI status honestly reported.
