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

## Screenshots and comparison on every UI-test run

Every selected native UI-test run, local or CI, captures the defined screen/flow
checkpoints and compares them with the approved regression baselines for the
same environment. Include the affected screens and relevant loading, empty,
error and navigation states. Reuse the capture from that run; no second UI run
just to collect images. Pure logic/unit and documentation-only checks need no
screenshots. A UI change still needs its affected visual checks before the PR
gate completes, locally or through actual CI coverage on matching inputs.

- Use real simulator/device captures, not web mocks or marketing compositions.
  Reuse an existing capture/comparison runner where suitable. A design-mock
  comparison is separate from comparison with an approved regression baseline.
- Keep success captures as well as failures in the test result/artifacts. With
  XCTest, attach the screenshot and set the attachment's `lifetime` to `.keepAlways`
  ([Apple attachment guidance](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues)).
  A test passing does not prove its images were retained or compared.
- Fix fixtures, account/data state, clock/timezone, locale, appearance, text size,
  orientation and animations; wait for a known ready state instead of arbitrary
  sleeps. Use sanitized fixtures and the existing private artifact access and
  retention policy. Keep personal/account images out of source and public links.
- Key references by app/checkpoint, native platform, full OS/runtime version and
  build, device profile/size/scale, locale, appearance, Dynamic Type, orientation
  and fixture identity. Pin the rendering toolchain/configuration as well.
  Compare matching cells only; never pixel-diff iOS 18 against iOS 26.
- Retain baseline, current capture and diff (an overlay when helpful), with source
  and environment metadata and the comparator/tolerance configuration. Use the
  project's explicit tolerances and narrowly justified masks; do not loosen
  them or hide changed UI to get a pass. Unexpected differences fail the visual
  gate until resolved; an image score alone is not approval.
- First or intentionally changed baselines need review of the actual images and
  a recorded human selection or the existing authorized baseline-review process.
  Update each affected OS cell explicitly, with its reason. CI must not silently
  record/overwrite references, adopted mocks or unrelated tracked captures.
- Distinguish **captured only**, **compared with design mock**, and **compared with
  matching regression baseline**. Missing capture/comparator/reference or a
  required unrun cell is **unverified**, not a pass. Missing harnesses are reported
  as integration work; this instruction-only template installs none.

## Mandatory WebP compression

Follow root `AGENTS.md`, “Screenshot compression (mandatory)”, for every capture.
Create and verify a lossless WebP immediately after capture/export, preserving
native dimensions, Retina scale and decoded pixels. Use the WebP for retained
exports, viewers and reviews. Keep an original only for a documented consumer
that requires its format; preserve required XCTest attachments and approved
baselines. Record hashes, sizes, verification and any retained originals. Include
this requirement explicitly in delegated capture tasks.

## Sharing remote screenshots

For remote screen captures, including ad-hoc UI inspection and test comparisons,
return image/viewer URLs the user can open through Tailscale. Follow the root
`AGENTS.md` tailnet-only access policy; a remote filesystem path or capture-host
localhost URL alone does not deliver the images.

- Identify the host holding the captures; it may differ from the coordinator or
  container. Discover its actual Tailscale IP, listener and available port.
  Prefer a suitable existing viewer. For direct serving, bind only to the
  discovered Tailscale IP, never a wildcard or LAN/public interface; verify the
  listener and choose another port on collision without stopping its owner.
  Return the actual IP-based URL. If using an existing loopback service behind
  Tailscale Serve, return its actual HTTPS hostname URL; do not substitute an IP
  into a hostname certificate. Discover the host's supported CLI/configuration
  before changing a route ([Serve documentation](https://tailscale.com/docs/features/tailscale-serve)).
- Export only intended images and a small index/manifest into a run-specific
  directory. Use sanitized fixtures; when suitability for sharing is unknown,
  withhold the export and report that blocker. Never serve the repository, home,
  DerivedData, credentials, raw logs or `.xcresult` bundles. Inspect the export's
  file list, including hidden files and symlinks; every served file must belong
  to that export. Simple static servers can follow links outside their root
  ([Python HTTP server guidance](https://docs.python.org/3/library/http.server.html#security-considerations)).
- Link to full-resolution captures; reuse the existing viewer or a small index
  for navigation. When comparing images, label baseline/current/diff separately
  and link every available image. State missing comparison artifacts rather than
  inventing them. Reference the run/job ID, source fingerprint, checkpoint,
  OS/runtime, device and other matching configuration/comparator metadata from
  this policy. A reachable stale image is not evidence for newer source.
- Open the viewer and each advertised image through the intended client tailnet
  path. Confirm the response is the intended decodable image, not a login/error
  page; check it against the export manifest/hash. Check index links as well.
  Host-side localhost or HTTP success alone does not verify client access. When
  no suitable client is available, report **client access not verified**, with
  the actual URL and blocker. Keep sharing/reachability status separate from
  captured-only, mock-comparison and regression-comparison status.
- Before advertising a URL, record the serving host, owned process/job or Serve
  route, export directory, responsible owner and review-window expiry time.
  Keep exported images independent of test/simulator cleanup, so normal device
  cleanup can finish while the reported review link remains usable. Register
  cleanup for expiry or an explicit stop; remove only owned viewer resources,
  routes and exports, preserving unrelated services and retained test evidence.
  Report early termination or uncertain cleanup instead of promising availability.

This template defines delivery rules; it starts no viewer and provides no live
URL or client-reachability evidence by itself.

## iOS / iPadOS 18 and 26 cells

For UI-affecting changes, run the affected visual checks on both iOS/iPadOS 18.x
and 26.x when the app supports both. Keep separate approved baseline sets for
these OS families; a pass on one cannot waive a failure on the other. Select and
pin an available compatible minor/runtime build for each family after checking
the app, extensions, dependencies and UI-test runner's effective minimum OS.

For 26-only apps, run 26.x and mark 18 **not applicable**; do not lower deployment
targets or add compatibility branches just to fill the matrix. For tvOS, macOS,
SwiftPM-only or Flutter work, apply the repository's actual platform/consumer
scope. Flutter may use its integration/screenshot flow for Dart UI and native
host evidence for iOS rendering; OS-independent widget goldens alone do not
prove the 18/26 device cells. A missing UI harness does not satisfy coverage.

Unsupported OS is **not applicable**. A supported required OS with no usable
runtime/device/toolchain, baseline or completed run is **unverified**, with the
blocker stated. Installed runtimes alone are not execution evidence. The 18/26
pair does not replace supported-minimum/current or other mandatory release gates
(e.g. a min-17 app still needs the relevant minimum-OS release evidence). Keep
local iteration focused; before PR/release close the required affected cells,
reuse matching CI evidence, and broaden device/locale/theme cells by risk rather
than rerunning the full cross product after every edit.

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
