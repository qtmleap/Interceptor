# Interceptor development


<!-- ios-development-routine-adoption -->
## Shared development routine

Read [the repository adoption notes](docs/development/ios-development-routine.md)
for platform scope, existing CI/release gates and documentation-only verification
before applying the common defaults below. Preserve existing project-specific rules and release/signing authorization.
<!-- /ios-development-routine-adoption -->

<!-- development-orchestration -->
## Parallel development and verification across projects

- Apply these preferences across projects and execution hosts. Discover the
  target repository's commands, CI coverage, required gates, and available
  skills/tools; never assume another host's installation or access applies.
- Split useful independent work among workers, including frontend and backend
  implementation. Agree API schemas, authentication, error behavior, and shared
  file ownership first. Use separate worktrees or non-overlapping file ownership;
  coordinate contract changes and verify integration against the real backend.
- Run long tests/builds asynchronously and retain their job IDs. While they run,
  continue authorized work that does not depend on their outcome. Wait when no
  useful independent work remains; do not start unrelated work to fill time.
- Keep each verification run tied to immutable source content, including relevant
  uncommitted files, dependencies, toolchain, target, and configuration. Isolate
  its worktree/copy, writable build caches, simulator, ports, and result paths from
  ongoing development. Reviews and tests may overlap on the same snapshot.
- During iteration, prefer fast checks for changed behavior, failure reproduction,
  and checks CI cannot perform. Let CI run its required full suites; inspect the
  actual workflow before assigning a check to CI. Preserve mandatory local hooks,
  repository checks, and release gates. Add broader coverage where the change's
  risk requires it rather than running every device/OS/locale/theme combination
  after every edit.
- Avoid repeating successful equivalent checks without a concrete reason, such
  as changed inputs, failure investigation, unresolved risk, or a mandatory gate.
  Reuse evidence only when its scope and environment still match. Pending, stale,
  skipped, interrupted, and unknown results are not passes. After integration or
  fixes, revalidate affected behavior on the resulting content.
- Track job outcomes and owned resources. Inspect existing jobs after timeouts
  before retrying; clean up only resources owned by the run after workers finish
  or are confirmed stopped. Cap heavy parallel jobs to avoid resource contention.
  Keep small changes lightweight and follow the existing review policy.

## UI design, previews, and store screenshots

- For new screens or substantial flow changes, first discover and reuse the
  project's canonical spec, design system, component catalog, and screen/flow
  mocks. If a mock-first workflow or mock viewer is available (for example the
  mock-diff plugin in qtmleap/claude-plugins), read that host's actual skill and
  follow it; do not require installing it. Otherwise use an available UI
  design/prototyping capability (Product Design is one option) to explore screens,
  navigation, and error/empty/loading states. Small UI fixes need no prototype.
- When design choices are pending, show candidates through the existing viewer for
  a human decision; never fabricate an adopted selection.
- For native UI with an adopted mock, compare real simulator/device captures at
  the matching state and size against it. A web screenshot is not native
  evidence, and a quantitative score is not automatic approval.
- Every native iOS/iPadOS UI-test run captures its selected checkpoints and
  compares them with approved baselines for that same OS/device/configuration.
  Use separate 18/26 cells where both are supported; preserve other mandatory
  platform gates. Pure logic/unit and docs checks need no screenshots. Follow
  `.agents/skills/ios-development/references/testing-policy.md` where present;
  otherwise find the equivalent project workflow and report gaps. Capture-only
  is not a visual pass.
- Web mocks and previews default to Tailscale-only access. Discover the actual
  host's Tailscale IP or MagicDNS name and available port. Bind to the intended
  Tailscale interface, or use loopback behind Tailscale Serve; do not enable public
  Funnel or public hosting without explicit authorization.
- Provide the actual reachable preview URL. Verify access through the intended
  tailnet client path, including API URLs and WebSocket/HMR when applicable;
  localhost success alone does not prove remote access. Report any client-side
  reachability that could not be verified. Preserve existing services and ports.
- Distinguish mock data from real backend integration. A web prototype does not
  replace required native simulator/device UI verification.
- For App Store marketing screenshots, use the app-store-screenshots skill from
  https://github.com/ParthJadhav/app-store-screenshots. Locate and read the skill on
  the execution host; reuse an existing installation and editor project. If the
  capability is missing, report it and follow the appropriate installation flow.
- Reuse suitable captures from the verified app revision; recapture affected
  screens/device/locale/theme conditions when they change. Use the editor for
  localized copy, device frames, layout, and export; visually check exported
  images and current store requirements. Apply the Tailscale preview policy even
  when a skill's example uses localhost. Run this workflow when store assets are
  requested or needed for the authorized release, not after every code edit.

## App Store Connect tools and authentication

- Discover and prefer ASC MCP for supported App Store Connect operations before
  choosing browser automation or requesting an Apple ID browser login. Use the
  existing API-key/native fastlane route for packaging and upload where applicable;
  signing/provisioning assets and web sessions remain separate dependencies.
- Do not request browser authentication merely because a task involves Apple or
  because a request failed. Distinguish missing capability, API authentication,
  permissions, and transient errors. Request interactive login only when the
  necessary operation demonstrably requires it, explain the specific blocker,
  and continue work that is independent of that blocker.
- Keep upload acceptance, Apple processing completion, tester availability, and
  App Review/release state distinct. Inspect operation status after an uncertain
  upload or write instead of blindly resending it.
- When an App Review submission is confirmed (or an authorized submitted app is
  read back), create or update one monitor for that exact app/platform in the
  app's existing chat: hourly by default (configurable), quiet when unchanged.
  Read current rejection messages, fix within scope, verify, and resubmit when
  the state requires it; human scope and stricter gates still apply. Classify
  the issue before writes; never auto-resubmit withdrawn submissions or replay
  uncertain writes. Sending reviewer replies needs explicit human authority.
  Follow
  `.agents/skills/ios-development/references/app-review-followup.md` if present;
  else find an equivalent release workflow. Report missing monitoring/tool
  capabilities explicitly; never claim an unscheduled monitor is active.

## Review routing and named reviewers

Applies only when the named tools are available; otherwise report the missing
preferred capability and use an authorized alternative. Required repo gates and
existing review policy always still apply.

- **LocalGPT**: planning, design, independent review. **Claude Code (MCP)**:
  primarily independent review of implemented code and its actual diff; also
  repo inspection, implementation and feasibility checks when assigned.
  **LocalMCP**: only the LocalGPT worker's verified host I/O; never a reviewer.
  **Codex**: coordination, integration, visual and actual evidence.
- Before substantive implementation, get an independent LocalGPT plan review and
  a Claude repo-feasibility review before sharing conclusions.
- After substantive implementation, use a fresh, separate, read-only Claude
  reviewer, not the implementer's self-review. Complex or high-impact changes
  also get a LocalGPT actual-files review, only if its worker access is verified.
- Small low-impact changes: one adequate route, proportional. Do not repeat
  reviews per upload or stage unless source, contract or risk changed.
- Tie each review to target SHA/content, the actual diff or relevant files, and
  the gates. Findings carry severity and file references; Codex verifies
  material resolutions. A running receipt is not a completed review.
- Discover LocalGPT status, then capabilities, then models, sequentially; discover
  Claude models/source/execution_context. Choose observed IDs proportionally
  (Instant/Haiku light, Thinking/Sonnet routine, GPT 6 Pro/Opus difficult or
  high-impact when available); no fixed IDs.
- Verify host/workspace before file tasks. LocalGPT's own LocalMCP must prove
  access, and jobs must use that same selected connection. Do not paste files or
  large diffs as a fallback. Codex and Claude use native tools in their accessible
  workspaces. Use topic-specific LocalGPT sessions through its MCP on the existing
  shared tab; do not bypass failures through browser automation. A missing
  actual-file review cannot be claimed.

## Session reuse and token efficiency

- Continue the same topic and worker role in its existing LocalGPT session.
  Keep independent reviewers separate from implementers. Resume a reviewer's own
  follow-up only if the tool supports it; do not invent Claude resume support.
  Job IDs and MCP transport sessions are not model conversation memory.
- When the discovered Claude MCP schema supports it, start an independent
  code-review chain with `review:true`, `resumable:true` and an explicit suitable
  model. Retain the returned job/session identifiers. For that reviewer's
  follow-up, use `resume_job_id` from its current successful head and send only
  changed paths, the delta, the new source fingerprint and unresolved findings.
  Build the manifest with native tools; include relevant uncommitted and new
  files. Give a read-only reviewer a manifest it can read without shell access.
  Re-read affected source and verify integration; start a fresh chain after a
  blocked/failed turn or when topic, role or pinned model must change.
- Use bounded job listings and requested findings. Inspect `result.usage` (or
  failure accounting when available): invocation token/cache counts differ from
  cumulative conversation model usage and cost. Compare only matching scopes;
  absent accounting or a reset makes cost deltas unknown. CLI estimates do not
  prove billing savings. Never sum cumulative costs as separate invocation costs.
- Reuse model/capability and host-access discoveries while valid; refresh after
  relevant host, authentication, tool or task requirements change, or failure.
- Send concise paths, revisions, line ranges, acceptance criteria and deltas.
  Request bounded findings or changed conclusions, not repeated full reports.
  Keep useful source-bound summaries privately; read current affected files
  when inputs change. A cached review cannot approve unseen changes.
- Use native tools for deterministic checks and batch independent reads. Avoid
  model calls for acknowledgements, formatting or already-known status.
- Preserve stable reusable instructions where the actual API supports caching.
  Session reuse does not guarantee a cache hit or lower total usage. Inspect
  input/output and cache-read/write usage when exposed; otherwise report savings
  as unverified. Do not pad prompts or retain irrelevant history for a cache hit.
- This template adds no cache or session engine. If the current Claude MCP has
  no resume interface, use concise self-contained requests and retained job
  results; do not claim that it resumes a previous conversation.

## Native iOS / iPadOS work

- For native iOS/iPadOS (or associated macOS target) features, debugging,
  review, testing, or release, read `.agents/skills/ios-development/SKILL.md`
  if present in the project; otherwise continue with the rules above. Skip it
  for web-only work and generic documentation.
- For packaging, TestFlight, App Store submission or launch, also read
  `.agents/skills/ios-development/references/release-policy.md` if present.
<!-- /development-orchestration -->
