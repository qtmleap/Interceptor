# 1.1.0 beta: publication and runtime evidence

The user authorized this existing repository/import/editor/synthetic-JavaScript foundation as a separate TestFlight 1.1.0 beta on 2026-10-17. Earlier references to the queued 1.0.1 (34) describe the original implementation snapshot. The stable 1.0.1 UI release and the 1.1.0 preview have separate build identities; never attach a 1.1.0 build to the App Store 1.0.1 version. Live capture processing, consent v1 and privacy statements about webhook delivery are unchanged.

The full next-major roadmap still requires HTTP lifecycle hooks, per-revision data/endpoint grants, revocation, PacketTunnel worker, encrypted outbox and delivery. Those are not implemented by this foundation and must not be represented as complete. The explicit TestFlight authorization supersedes the earlier no-distribution status. Merge and upload gates remain required, and no App Store 1.1.0 production submission is authorized by this beta release.

## Runtime acceptance

QuickJS 2026-06-04 is pinned to the official source archive and exact vendored bytes, including the recorded audited native-work limits patch. scripts/verify-quickjs-vendor.py checks bytes and the explicit core-only compile list. Runtime unit tests cover evaluation, denial of host capabilities, output schema, quotas, cancellation and recovery. The 8 MiB setting limits the VM allocator, not process RSS. 50 ms is a cooperative evaluation/validation budget, not a hard wall-time or process-isolation guarantee; runtime destruction is not forcibly interruptible, so total reclamation latency must also be measured. Mac measurements cannot establish the minimum-iOS-device gate.

## Apple publication gate

Before submitting a build that exposes downloaded third-party scripts, review the actual implementation against Apple's current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 2.5.2 and 4.7 and prepare concrete review notes, source visibility/editing, script index and data/API disclosures. The older roadmap's VPN-origin data and webhook design also requires resolving 5.4; consent alone is not proof of acceptance. No Apple clarification has been sent and no approval for this foundation has been obtained.

A future review submission must describe the actual execution surface and data flow. This development branch does not use hidden remote activation or a privacy statement change to claim approval.

## 2026-10-17 release checks

- Integrate the published PR23 UI head without rewriting existing commits; keep the native Close/Disagree sheet and add only the Plugins route and engine license integration.
- App and PacketTunnel Debug/Release marketing versions are 1.1.0; test bundle versions stay unchanged. CI allocates build numbers.
- Keep the Mudmouth pin at `dddd2cb92fc67e414517dd316de33f6f2c6a9f4c` in native builds and both CI workflows/release config.
- Declare the catalog fstat use with C617.1, verify the bundled upstream license, and confirm AutomationRuntime is linked only into the app and its tests.
- Keep PR23 upload ahead of PR18: do not advance develop to 1.1.0 before the separate 1.0.1 upload completes and its artifact is verified.
- Use the [1.1.0 beta review notes](../app-review/review-notes-1.1.0-beta.md). Assign the preview to a separate beta group and retain earlier builds. Processing VALID alone is not external beta approval.
- M3 iPad measurements and tests do not establish a minimum-iOS-device hard real-time guarantee. Physical UI tests use the existing Debug-only isolated store; no test-store override is added to production builds.
