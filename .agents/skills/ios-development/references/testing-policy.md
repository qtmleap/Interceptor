# iOS testing policy

Applies to native iOS/iPadOS apps and their associated macOS targets. Discover
actual schemes, test plans and destinations first (`xcodebuild -list`,
`-showdestinations`); the names below are categories, not commands.

## Choosing scope

| Moment | Run | Do not |
| --- | --- | --- |
| Local edit | Smallest regression covering the change (a test class/method or one test plan), plus mandatory hooks | Routine full suite/device matrix without a change-specific or mandatory reason |
| Reproducing a failure | The failing test on the failing destination | Widen before it is understood |
| Before a PR | Checks selected by changed behavior: touched modules, affected UI flows, layouts or locales the change reaches | Re-run unaffected, already-green equivalents |
| PR / CI | Full required CI on the exact source being merged | Replace it with a local run, or bypass it with local caches |
| Release | Risk matrix below, on the release candidate source | Claim readiness from PR gate status |

A check CI cannot perform (simulator UI, device behavior, accessibility) is a
valid local or pre-PR check. A check CI already performs on the same source is
not repeated without a reason: changed inputs, failure investigation, unresolved
risk or a mandatory gate.

## PR gate vs release readiness

- **PR gate status**: required checks, hooks and reviews for merging.
- **Release readiness**: the PR gate plus the release matrix and any real-device
  or live-service checks the release touches.

A green gate alone does not establish release readiness. State both separately.

## Release risk matrix

Cover each dimension the release can affect; choose representative cells, not
the full cross product.

- OS: supported minimum and current.
- Devices: relevant iPhone and iPad sizes; layout, orientation and window sizing
  (iPad multitasking, Stage Manager, macOS window resize) where supported.
- Locales: ja/en, or the app's actual locales, including long-text and
  right-to-left layouts if supported.
- Appearance: light and dark.
- Accessibility when affected: Dynamic Type, VoiceOver, reduce motion, contrast.
- Upgrade path from the previous release when data or migrations changed.

## Needs actual devices or services

For affected behavior or mandatory release checks, validate hardware sensors,
camera, USB/accessories, device lifecycle/network behavior and performance/energy
on suitable actual devices. Use local StoreKit and simulator notification fixtures
for focused regression checks, then appropriate Apple sandbox/TestFlight or APNs
evidence for service integration. Local fixtures alone do not establish actual
delivery or store integration. Use authorized test accounts and environments.
Record required missing device/service evidence as "not verified"; do not claim
those checks or release readiness passed while that evidence is missing.

Apple's [sandbox overview](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox)
distinguishes StoreKit Testing in Xcode from sandbox integration.

## Evidence and freshness

Each run records: job ID, source fingerprint (commit plus dirty/untracked
content), host, toolchain/SDK, destinations, tests selected, result artifacts,
and observed state. Pending, stale (inputs changed), expired, skipped,
interrupted and unknown are not passes. Evidence is
reusable only when source, dependencies, toolchain, SDK, destination and
configuration still match.

## Parallelism

- Use separate DerivedData, result bundle and simulator per concurrent run.
- Build-for-testing products may feed test-without-building only for the same
  snapshot, SDK and configuration, via the project's existing runner.
- Cap concurrent heavy jobs; builds and simulators contend for CPU, memory and
  disk.
- Follow SKILL.md section 4 for simulator ownership and cleanup.
