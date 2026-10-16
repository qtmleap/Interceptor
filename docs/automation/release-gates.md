# Next-major foundation: publication and runtime evidence

This branch is the repository/import/editor/synthetic-JavaScript foundation. It does not change the queued TestFlight/App Store 1.0.1 (34), live capture processing, consent v1 or privacy statements about webhook delivery.

The full next-major roadmap still requires HTTP lifecycle hooks, per-revision data/endpoint grants, revocation, PacketTunnel worker, encrypted outbox and delivery. Those are not implemented by this foundation and must not be represented as complete. The foundation is not automatically merged or distributed.

## Runtime acceptance

QuickJS 2026-06-04 is pinned to the official source archive and exact vendored bytes, including the recorded audited native-work limits patch. scripts/verify-quickjs-vendor.py checks bytes and the explicit core-only compile list. Runtime unit tests cover evaluation, denial of host capabilities, output schema, quotas, cancellation and recovery. The 8 MiB setting limits the VM allocator, not process RSS. 50 ms is a cooperative evaluation/validation budget, not a hard wall-time or process-isolation guarantee; runtime destruction is not forcibly interruptible, so total reclamation latency must also be measured. Mac measurements cannot establish the minimum-iOS-device gate.

## Apple publication gate

Before submitting a build that exposes downloaded third-party scripts, review the actual implementation against Apple's current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 2.5.2 and 4.7 and prepare concrete review notes, source visibility/editing, script index and data/API disclosures. The older roadmap's VPN-origin data and webhook design also requires resolving 5.4; consent alone is not proof of acceptance. No Apple clarification has been sent and no approval for this foundation has been obtained.

A future review submission must describe the actual execution surface and data flow. This development branch does not use hidden remote activation or a privacy statement change to claim approval.
