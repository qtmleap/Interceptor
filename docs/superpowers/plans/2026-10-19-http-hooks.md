# Four HTTP lifecycle hooks implementation plan

> **For agentic workers:** Use the approved delegation/native execution policy
> and execute the assigned task with tests before code; coordinate shared files.

**Goal:** Implement the four callbacks consistently in live native forwarding,
the Rust emulator and author documentation.

**Architecture:** A shared bounded C phase runner exposes Interceptor.attach;
Mudmouth owns an async transport seam. A separate per-revision activation file
lets PacketTunnel execute only explicitly approved packages.

**Tech Stack:** Swift6, QuickJS2026-06-04, C11, SwiftNIO, Rust1.74+, Python3,
Bun1.3.6 and VitePress1.6.4.

**Spec:** ../specs/2026-10-19-http-hooks.md

## Global constraints

- Four dotted phase names; leave follows successful local forwarding.
- Shared C implementation and existing quotas; bounded queues and storage.
- New/edited packages inactive; v1 remains dry-run compatible.
- JS examples use const; no let. No external webhook delivery in this change.
- Preserve signing, repository trust, release gates and unrelated worktrees.

## Review focus

- Matching or grants cannot widen through source registration or prototype tricks.
- Leave never fires on failed writes and cannot modify already forwarded bytes.
- Overflow, compression, 1xx, HEAD and upgrades preserve framing and FIFO.
- Revocation between admission and write prevents forwarding a plugin result.
- Signed v1 packages and corrupt stores retain their previous safety behavior.

## Tasks

1. **Core/runtime (Claude worker):** Add failing Swift/C behavioral tests; observe
   failure; implement v2 manifest/phase/result and host registration; run package
   tests. Own AutomationCore Manifest, new runtime files, bridge/header and tests.
2. **Transport (Claude worker):** Add failing embedded-channel tests; observe
   failure; implement the Mudmouth async seam/lifecycle buffering and successful
   write tracking; run isolated transport tests. Own Mudmouth only.
3. **Activation/native UI (Codex plus Claude):** Add store/revocation tests before
   changes; integrate separate shared activation and app approval/PacketTunnel
   adapter; update test fixture/phase picker/result preview; native build/tests.
   Own native app/PacketTunnel and new activation files, not core worker files.
4. **Simulator/author docs (Codex plus Claude):** Update manifest validation,
   types, samples, fixtures and Rust CLI against the new shared C entry. Restore
   the code-native diagram and four separate hook sections. Verify equivalent
   conformance vectors and Linux standalone runs; review/render Japanese.
5. **Integration/review:** Freeze source manifests including dirty/new files;
   request fresh independent Claude review plus available LocalGPT actual-files
   review; resolve findings; run affected checks on resulting content. Commit
   through the identity guard, create linked dependency PRs, inspect CI, and
   integrate only in the authorized order with exact source pins.

Record commands, failures, outcomes, source fingerprints and owned resources in
build/http-hooks/. A running job is never counted as a completed review/test.
