# Shared iOS development routine in Interceptor

Adopted from [qtmleap/devcontainers](https://github.com/qtmleap/devcontainers/tree/e481a99ab47994d6bdb7514adba12798699d4795)
at `e481a99ab47994d6bdb7514adba12798699d4795`. The four files under `.agents/skills/ios-development/` are copied
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
