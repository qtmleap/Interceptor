# Plugin JSON response persistence

## Authorized scope

Add file persistence to Interceptor and make the Salmon Run Plugin save fetched API response JSON. Verify actual files on M3. The user has now made real Salmon Run history available. Verify real nonempty history and details on M3; synthetic data is supplementary only. Save response JSON itself: no wrapper, generated summary or authentication data. Existing native work is isolated in this task's linked worktree; preserve the earlier one-line empty-row separator correction and unrelated checkouts.

## Approach and contract

Expose `await Interceptor.saveJSON(key, jsonText)` only inside schema-2 `response.onLeave`, alongside `fetch`. `key` is a logical UTF-8 key (1–1024 bytes, no NUL), never a filesystem path. `jsonText` is the original UTF-8 JSON response text. Validate bounded JSON and write the original bytes, preserving whitespace, ordering and Unicode. Return a settled Promise only after durable publication; reject on invalid input, missing permission, revoked authority, cancellation, quota or I/O failure. No arbitrary paths, file reads, listing or deletion are exposed to JS.

Add optional schema-2 `write.files: boolean`, default false, identically validated by Swift, C and SDK. Bind writes to the exact active package/revision, current activation generation and capture consent. Permission-bearing package bytes change, requiring the existing explicit enable confirmation. Explain local JSON saving in the existing permission confirmation's footer/row only; no new screens or controls.

Use the existing deferred response executor: the scheduling probe recognizes saveJSON without I/O; the deferred VM receives separate trusted fetch and save callbacks. Preserve existing fetch-only call sites through an optional Swift save callback/default. The save callback checks cancellation and authority, awaits/stops owned work before return, and shares the invocation's bounded CPU/wall lifecycle. Restrict direct references in SDK authoring consistently with fetch/attach/send.

## Persistence and Files

The Packet Tunnel cannot write the main app's Documents container. The authoritative store is therefore the app group's `Library/Application Support/Interceptor/PluginFiles`. Isolate namespaces by a digest of trusted source-qualified installation family, stable across revisions, with a safe manifest UUID as a display prefix. Derive each file name as SHA-256(key) plus `.json`; JS cannot select directories. Same key replaces the corresponding response atomically and identical bytes are a no-op.

Bounds: 1 MiB per JSON, 64 MiB and 2,048 JSON files per namespace, at most 64 saves and 16 MiB submitted per invocation; the aggregate retained store is limited to 256 MiB / 16 namespaces, rejecting new writes without automatic data eviction. Serialize quota checks/publication with an interprocess lock. Use no-follow directory/file operations, regular-file checks, exclusive temporary files, atomic rename and directory fsync. Bound JSON depth; reject links/special files and clean owned temporaries on failure. Use iOS protection suitable for background execution after first unlock and exclude the private store from backup.

Stage protected temporary bytes and fsync outside activation lock, then fence final publication with current activation under its existing file lock; order activation lock before storage lock. Acquire the storage lock nonblocking inside that fence. Check cancellation/consent again before publication admission. OS rename/fsync has no hard deadline; shutdown drain waits for completion. A cancellation after publication admission may leave committed bytes. Revoking/deleting a plugin stops later writes and does not delete already saved results.

When Interceptor is foreground, mirror committed JSON files into app `Documents/Plugins/<namespace>/`. Enable iOS file sharing/open-in-place so users can access them in Files > On My iPad > Interceptor > Plugins. Both source inspection and M3's current Documents listing show no existing Documents content. Export never imports edited Documents files, never follows symlinks and only writes owned namespace JSON files. Sync on launch/activation and periodically while active; stat metadata to skip unchanged files, perform I/O away from the main actor and cancel the foreground loop when inactive. No new app screen is required.

Alternatives considered: directly writing main Documents from the extension is outside its sandbox; a local HTTP storage server adds unnecessary transport/access; runtime result actions are too small for batches and lose earlier successful results when a later request fails. A bounded native save callback reuses the existing async execution model.

## Salmon Run integration

Set write.files true and update the local Plugin version to 1.1.0. Keep the fixed publication day. Fetch history using `text()`, parse and validate it, then save that original response text with a fixed history key. For each validated detail, save the original full GraphQL response text under a key derived from its result ID. Do not persist the captured BulletToken response, request headers, cookies or token. Retain existing limit, version selection, principal/ID validation and non-upload behavior. A later detail failure must not remove already committed files. Empty history still produces its actual response JSON file.

## Verification

1. Failing tests first for native permission/bridge and filesystem behavior; native Swift runtime/storage tests and actual C bridge. Cover absent/denied permission, phase/probe, UTF-8/original-byte preservation, duplicate keys, invalid/large/deep JSON, quotas, symlinks, I/O failure, generation revocation and cancellation. Ensure old fetch-only hooks still pass.
2. SDK tests cover direct saveJSON placement, schema parity, canonical build outputs and generated-JS hook saving the exact fixture response texts. `bun run build` must emit the updated script, manifest and importable package.
3. Independent actual-diff review, then immutable native build/test snapshots using existing caches. Relevant existing CI suites run on pushed source; preserve unrelated simulator/devices and cleanup only owned resources.
4. Install the development app on M3 normally, preserving catalog/capture data. Import/enable the new local package through regular UI, exercise actual Nintendo BulletToken capture, and save real HTTP-200 nonempty history plus validated details. Synthetic tests cannot substitute for this live criterion.
5. Read back private and exported M3 files; compare exact bytes/hashes with corresponding responses. Assert history count>0, matching detail IDs/principal, and multiple details when available. Verify Files visibility and protection/backup exclusion on both copies. Record source/dependency/toolchain/package hashes without exposing account data.
6. Any captures are immediately converted to lossless WebP, preserving dimensions, RGBA, ICC and Retina scale, with hashes/pixel verification. Keep only required originals and clean owned streams/windows/devices/build intermediates; preserve useful private evidence and original package backups.

## Review integration points

Native: Packages/InterceptorAutomation/Sources/{AutomationCore/Manifest.swift,AutomationCore/PluginActivationStore.swift,AutomationCore/InstallationSelection.swift,AutomationRuntime/JavaScriptFetchExecutor.swift,CQuickJS/bridge.c,CQuickJS/include/CQuickJS.h}; Interceptor/Automation/{HTTPPluginProcessor.swift,AutomationSharedConfiguration.swift}; Interceptor/{ContentView.swift,Info.plist,Views/Automation/PluginPackageApprovalView.swift,Localizable.xcstrings}.

SDK: /Users/devonly/Developer/interceptor-splatnet3-plugin/{types/interceptor.d.ts,tools/compile.mjs,tools/repository_config.py,plugins/splatnet3-salmon/plugin.json,plugins/splatnet3-salmon/hooks/api.lp1.av5ja.srv.nintendo.net/api/bullet_tokens/POST.ts,tests/test_splatnet3_hook.py,tests/test_splatnet3_quickjs.py}.

## Final implementation amendments

The implementation plan records review resolutions: staged prepare/commit, durable fsync retries, bounded aggregate store, cancellation/drain commit boundary, one-way protected Files mirror, IDs-only memory retention, and immutable SDK native runtime pin plus Rust fixture adapter. saveJSON acknowledges private persistence, not export completion. The mirror restores deleted/edited owned copies on foreground sync, never imports them, and never deletes unrelated files. Quota exhaustion rejects without evicting raw data; removing the app reclaims its store.
