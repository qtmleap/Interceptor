# Shared iOS development routine in Interceptor

Adopted from [qtmleap/devcontainers](https://github.com/qtmleap/devcontainers/tree/0ffa75dec05570817c499452ac6faf1c3413006c)
at `0ffa75dec05570817c499452ac6faf1c3413006c`. The four files under `.agents/skills/ios-development/` are copied
without modification. Future refreshes compare that directory and merge the
marked `development-orchestration` block in root `AGENTS.md`, preserving local
rules. Adoption does not install tools or grant additional release authority.

## Repository scope

Native iOS app in `Interceptor.xcodeproj`, with pure-Swift automation under `Packages/InterceptorAutomation`. Use the existing design/automation entry points.

`ios.yml` contains automation-package tests and native simulator checks; `ios-ci.yaml` covers release policy. Inspect their actual results and selected destinations before reusing evidence.

Uploads use `.github/workflows/testflight.yaml` after a verified merge. Existing release and signing gates remain authoritative.

## Applying the routine

- Root `AGENTS.md` holds the common parallel-work, review/session, Tailscale,
  UI and ASC policy. `CLAUDE.md` imports it for Claude Code.
- Use [the native skill](../../.agents/skills/ios-development/SKILL.md) for its
  applicable native app scope; read its testing and release references when
  relevant. The repository scope above takes precedence over generic app
  examples. Apply checks to supported targets rather than inventing platforms.
- Keep the repository's existing mandatory gates and release route. The common
  internal-feature/external-RC timing defaults apply only where no stricter
  project policy exists.
- For documentation-only PRs, verify content, links, copied-file hashes and
  mandatory Git hooks. Native app binaries and simulator state are unchanged;
  this is no claim of native test success or release readiness. Let required CI
  run on the PR source rather than duplicating its unchanged full suites locally.
- Check release workflow triggers before merging: existing merge automation may
  distribute a build even for a documentation PR. This rollout opens a PR;
  merge timing remains with the repository's release process.
- An App Review monitor is established by a future authorized submission flow
  according to the copied follow-up reference. No monitor is installed merely
  by adopting these instructions.

## UI screenshots and OS coverage

Apply the [visual testing policy](../../.agents/skills/ios-development/references/testing-policy.md)
for retained captures, matching references and baseline review on every selected
UI-test run.

The project contains 17.0 and 18.5 target settings. Resolve the effective app and UI-runner floor, pin a compatible 18.x minor (18.5 where required), and pair it with 26.x; do not assume every 18.x runtime is compatible.

## Remote screenshot sharing

When UI screenshots are captured remotely, follow the
[sharing workflow](../../.agents/skills/ios-development/references/testing-policy.md#sharing-remote-screenshots).
Return actual tailnet image/viewer links, including baseline/current/diff when
comparing, and report client reachability and viewer expiry separately from
visual-test outcomes. Existing platform, release and access-control rules remain
in force. This adoption starts no viewer and claims no live URL.
