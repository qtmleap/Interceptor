# LocalGPT UI reviews

Use LocalGPT to review whether users can understand the interface from what is
visible. This review is separate from implementation and security reviews.

## Review inputs

- Start a fresh UI-review session with no previous code or implementation context.
  Reuse that session for revised UI captures of the same flow.
- Provide only current screenshots, interaction recordings or the visible UI,
  plus a brief user goal when needed. Distinguish mock and native captures.
- Do not provide code, diffs, repository/file references, design specifications,
  implementation explanations, intended answers or code-review conclusions.
- Explicitly prohibit LocalMCP and file/code access. For attached screenshot
  reviews, prohibit all tools and require judgment from the images alone.
- Do not explain unclear controls for the reviewer or let it infer hidden behavior.
  If it cannot understand something from the UI, that is a finding.

## Review questions

Ask what each screen and action communicates before requesting improvements:

- Can the user identify the purpose, available action and expected result?
- Are terminology, headings, labels and explanations clear and nonredundant?
- Do warnings identify the affected action and its consequence?
- For permissions or data sharing, can the user understand who receives access,
  what information may leave, and what to consider before enabling it?
- Is navigation understandable, including confirmation, cancellation and recovery?

Defaults and confirmation mechanics do not replace explaining the consequence
of an option. Supplementary explanations belong in Section footers, not list
items. Preserve this requirement when evaluating reviewer suggestions.

## Reusable review request

> Review only the supplied UI as a first-time user. Use no tools, including
> LocalMCP, file access, search or code inspection. Explain what each screen and
> action communicates, then identify unclear purpose, terminology, outcomes,
> scope, data sharing, warnings, repetition and navigation. Do not infer invisible
> behavior. For each issue cite the image and visible wording, likely user
> misunderstanding, severity and a concrete revision. State what cannot be
> established from the UI and whether you used any other source or tool.

## Evidence and follow-up

Retain the exact request, image versions/hashes, session/job and completed report.
Check returned tool configuration or traces when available; a prompt or self-report
alone does not prove tools were technically disabled. A running job is not a review.

Codex evaluates findings against user requirements, revises the UI through the
existing design workflow, and sends only revised UI evidence for follow-up.
Use separate reviewers/sessions for code correctness and security; a UI-only
review cannot establish either, and code review cannot substitute for this review.

<!-- screenshot-webp -->
## Screenshot compression (mandatory)

- Apply this rule to every project and execution host, including native,
  simulator/device, browser and mock captures, exports, and delegated work.
- Immediately after each capture/export, convert its transient original to a
  lossless WebP as the next processing step, before publishing or handing it to
  a reviewer. Preserve native pixel dimensions, alpha (including RGB under fully
  transparent pixels; enable the encoder's exact mode) and the color profile.
  Record Retina scale in the manifest; do not resize or use lossy compression
  for comparison evidence.
- Verify the WebP decodes at the original dimensions with identical RGBA pixels
  using the same recorded color profile/space for both decodes. Record the tool,
  source/output hashes, dimensions, scale, byte sizes and verification result.
  If an input cannot be represented losslessly, retain it and report the blocker;
  do not silently reduce bit depth, gamut, dimensions or frames.
- Treat PNG/JPEG/TIFF originals as temporary. After verifying the WebP and updating
  its consumers, remove only this run's redundant originals. If a tool requires
  the original format (for example XCTest result bundles, an approved baseline,
  or store submission), still create the WebP and retain only the required
  original for that named consumer, recording its purpose and retention. Create
  the WebP derivative before uploading the required original. Do not rewrite approved
  baselines or test bundles merely to change their image format.
- Use the real .webp extension and image/webp media type; update viewer links,
  manifests and hashes without breaking existing consumers. Missing encoders,
  failed conversions or failed pixel checks are unfinished work; report them
  instead of silently keeping only an uncompressed screenshot or deleting it.
- Include this requirement explicitly in every delegated task that may capture
  screenshots, even if the worker cannot read these instructions. Workers must
  pass it to their own delegates. Require WebP paths, verification and any retained
  originals; the coordinator independently verifies this evidence before claiming
  completion.
<!-- /screenshot-webp -->
