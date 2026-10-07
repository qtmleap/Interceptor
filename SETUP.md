# Interceptor TestFlight release

An iOS build is uploaded to TestFlight only after a genuine pull-request merge into `develop` or
`master` of `qtmleap/Interceptor`. There is no manual, tag, schedule, rerun, local or App Store path:
`fastlane ios beta` refuses to run anywhere except the verified CI job.

## Flow (`.github/workflows/testflight.yaml`)

1. **Verify merge** (self-hosted Linux X64, Docker, Ruby 3.4.10, no secrets, read-only `GITHUB_TOKEN`).
   Proves the push is one new, non-forced, same-repository PR merge: first parent equals the push's
   `before`; the second parent (or the squash's PR record) equals the PR head; the PR head is not the
   merge commit itself; the SHA is the live tip; and the trusted `pull_request` runs of
   `.github/workflows/ios-ci.yaml` succeeded on the PR head (`ReleasePolicy`).
   `.github/workflows/ios.yml` succeeded on the PR head (`Validate TestFlight automation`, `Build and test (Xcode 27)`).
   Only the SHA and PR number are passed on. Only `github.run_attempt == 1` may run.
2. **Deploy** (self-hosted macOS ARM64 `macos-27`, Environment `testflight`). Verifies the real Xcode
   major version, re-runs the policy, then mints two short-lived GitHub App tokens (pinned
   `actions/create-github-app-token`): `match` (contents: read) and `QuantumLeap` (contents: read).
   A token is never reused across repositories and nothing falls back to a PR or repository token.
3. `fastlane ios beta` builds from a `git archive` copy of the exact SHA under `RUNNER_TEMP`.
   The authorized checkout is never written; its HEAD and cleanliness and the live branch tip are
   re-checked immediately before upload. Build number = max(App Store Connect latest + 1, project + 1,
   31 + 1, `GITHUB_RUN_NUMBER`), set only in the copy. Signing is read-only `match`
   with target-specific manual signing. The IPA is inspected (bundle ids incl. extensions, version,
   build, team) before upload. Credentials are removed from every Xcode child; the dependency token
   exists only as a private `~/.netrc` while packages resolve.
4. Uploads for both branches are serialized (`concurrency: interceptor-testflight`, `queue: max`,
   no cancellation). A `last_shipped.json` record is uploaded as an artifact (no key, certificate or IPA).

## Environment `testflight` secrets (names only)

| Secret | Use |
| --- | --- |
| `TESTFLIGHT_ASC_KEY_ID` / `_ISSUER_ID` / `_KEY_CONTENT` | App Store Connect key (ID, issuer UUID, P-256 `.p8` PEM or its base64). Kept in memory. |
| `TESTFLIGHT_MATCH_PASSWORD` | Decrypts `qtmleap/match`. |
| `TESTFLIGHT_MATCH_APP_CLIENT_ID` / `_PRIVATE_KEY` | GitHub App that mints the tokens above. Inputs only, never env vars. |

The old organization/repository secret names are intentionally not read.

## Prerequisites that are not proven by this repository

* The GitHub App installation must include `qtmleap/match` **and** `qtmleap/QuantumLeap` (repository
  selection is a human step). Until then the second token step fails and nothing is uploaded.
* Environment `testflight` restricts deployments to `develop` and `master`.
* The `macos-27` runner has Xcode 27 (checked at run time), Ruby 3.4.10 under rbenv, and an ephemeral account.
* `qtmleap/match` holds App Store profiles for `jp.qleap.intrcptr`, `jp.qleap.intrcptr.packet-tunnel` (match never creates them).
* `.github/workflows/ios-ci.yaml`, `.github/workflows/ios.yml` must run on `pull_request` with the job names listed above.
* `Mudmouth` is checked out at the pinned revision `3c1468aaaea5140835982bc8e38c9d3bfc49d2a0`; the build copy refuses any other state.

## Local checks (Ruby only, no fastlane, Apple or network)

```sh
ruby fastlane/test/run_all.rb
bash -n scripts/ci-release.sh scripts/ci-release-cleanup.sh scripts/verify-toolchain.sh
```

Files under `fastlane/lib/*.rb` (except `release_config.rb`), `fastlane/Fastfile`, `fastlane/test/` and
`scripts/` are shared across repositories; edit `fastlane/lib/release_config.rb` for per-app constants.

QuantumLeap uses the latest stable release, 1.0.0, at immutable revision
`c346aad25a1e7d09d22bf3ea32b7c341f13512ef`. Its tree matches the old locked
1.0.0 revision; the current tag was verified against the published release.
