# Release policy

Instruction-only common defaults for FUTURE releases. This template starts no
live job, upload or install, and adoption grants no new Apple write,
notification or release authority. Existing human or standing grants are reused
without fresh permission inside their scope; stricter project gates are kept.
Test scope and the release matrix: [testing-policy.md](testing-policy.md).
App Review follow-up and stop states: [app-review-followup.md](app-review-followup.md).

## 1. Scope record

Keep these in existing private project notes or the task record; no mandatory
new config file: version, build, source and artifact/export identity, repo,
backend, config, evidence, audience and groups, notifications, release mode,
window and timezone.

## 2. Timing defaults

| Step | Default timing |
| --- | --- |
| Local edit / PR | No routine upload. |
| Internal TestFlight | A completed, integrated, meaningful feature, with required CI, review and a native smoke check. |
| External TestFlight | A planned release candidate, for the intended beta scope, after relevant release-risk evidence and test feedback. |
| App Store submission | After candidate testing and the risk gates in the testing policy, plus metadata, backend and review readiness. |
| Public release | Separate from approval; follows the chosen existing release plan. |

- A project may not need an external beta, and an urgent limited hotfix may narrow
  optional soak or breadth by risk. Mandatory gates are never skipped.
- No universal fixed 24h soak and no full cross-product matrix. Reuse exactly
  matching evidence and reviews across stages.

## 3. Artifacts

- Promote the same eligible tested artifact when promotable. Changed source,
  dependencies, SDK, export, signing, config or backend contract may need
  affected revalidation. A new binary is not tested merely because the source
  SHA matches.
- A build uploaded for TestFlight Internal Only cannot go to external testers or
  customers ([Apple](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)).
  Choose the correct eligible export/build and revalidate; do not pretend a flag
  can be flipped. Avoid a rebuild when an eligible build already exists.

## 4. TestFlight

- Before upload, preflight the exact team, app, platform, version, build and
  distribution scope, plus existing automatic group assignment and notify
  settings.
- Keep these facts distinct: upload accepted; processing/compliance ready;
  intended existing group association, beta review, notifications and
  distribution availability; actual tester-client visibility/install. Discover
  the real ASC state schemas; invent no universal constants.
- Report each verified fact and each unverified client path honestly. Keep async
  IDs and the source mapping. After a timeout, inspect state; do not duplicate
  the upload or mint a new build blindly.
- Groups unspecified: discover the existing authorized scope from the repo, task
  and ASC; ask only for a missing material audience choice.
- Upload authority does not imply groups, invites, public links, Beta App Review,
  notifications or public release. Honor an explicit existing broader standing
  grant; send no notices without one.
- External Beta App Review is separate from App Store Review
  ([Apple](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)).
  Source backends must be compatible and the environment proper. A tailnet-only
  mock is no evidence that public users can reach production. An intentionally
  private/tailnet app scope is allowed; legitimate private backends are not banned.

## 5. Submission and launch

- Before App Store submission, reread the effective release mode (manual, auto,
  or date/phased) and compare it with the authorized launch plan
  ([Apple](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)).
  Auto may publish on approval. On conflict, stop the dependent submit and
  resolve it; do not silently change settings, and do not ask repeatedly when
  the grant is clear.
- With no release policy, recommend manual release during a staffed
  support/monitoring window, or an explicitly authorized earliest date and
  timezone. This is advice, not a live ASC mutation. A date is the earliest
  time, not guaranteed instant publication; set no arbitrary clock default.
- Phased rollout only if eligible and already chosen or authorized; never enable
  it silently.
- Recheck the final candidate, backend and gates before an authorized release.
- Store binary rollback is not easy; do not claim it. Record a practical
  forward-fix, compatible-backend or feature-flag plan and availability
  observations.
- An actual App Store submission follows app-review-followup.md. This file adds
  no monitoring rules and no schedules.
