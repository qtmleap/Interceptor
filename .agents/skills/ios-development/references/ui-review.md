# UI comprehension review with LocalGPT

Use for a review of whether people can understand a screen or flow. This is a UI-only exception to the repository's LocalMCP actual-file review route. Code correctness and security reviews keep their existing separate evidence requirements.

## Inputs and independence

- Start a fresh topic-specific LocalGPT UI-review session that has not received implementation context. Continue that session for revised images of the same UI.
- Supply only current screenshots, interaction recordings or a visible UI, plus a brief user goal when needed. Label mock versus native evidence accurately. Use neutral image names.
- Do not supply source code, repository/file references, diffs, design specifications, implementation explanations, intended answers, developer justifications or code-review conclusions. Do not explain an unclear control on the reviewer's behalf.
- Explicitly prohibit LocalMCP and other file/code access. For screenshot reviews, prohibit all tools and ask for judgment solely from the attached images. Never use a previous code-review conversation for this role.
- Discover LocalGPT status, capabilities and available models through its MCP as usual, using the existing shared tab. Image upload transport by Codex does not grant the reviewer filesystem access. If image input fails, report it; do not replace the review with code, copied file contents or a falsely labelled native capture.

## What the review must test

Ask the reviewer to explain, before proposing fixes, what a first-time user would understand from each screen: its purpose, the available action, the expected result and any information-sharing or permission consequences. A gap the reviewer can fill only by guessing is a finding, not evidence that the interface works.

Check whether labels, headings, explanations and controls work together. Look for repeated wording, unexplained terms, an isolated warning without a clear affected action, confusing navigation, and missing information needed to decide. For sensitive options, identify who receives access, what data may leave and what the user should consider before enabling it. Defaults and confirmation mechanics can be useful, but do not replace an explanation of the consequence.

Require each finding to cite an image/screen and visible wording, the likely misunderstanding, severity and a concrete UI revision. Do not require source-file references from this reviewer. Ask it to state what the supplied UI cannot establish and whether it used any other sources/tools. A visually plausible mock or a passing screenshot test does not prove user comprehension.

Preserve the user's chosen layout rules, including supplementary prose in Section footers. Codex evaluates findings; a reviewer suggestion to put explanations inside list items does not override that requirement. UI review never establishes hidden behavior, code correctness, security or human design adoption.

## Reusable request

> Review only the supplied UI as a first-time user. Use no tools, including LocalMCP, file access, search or code inspection. No implementation context is supplied. Explain what each screen and action communicates, then identify unclear purpose, terminology, outcomes, scope, information sharing, warnings, repetition and navigation. Do not infer invisible behavior. For each issue cite the image and visible wording, likely user misunderstanding, severity and a concrete revision. State what cannot be established from the UI and whether you used any other source or tool.

## Evidence and follow-up

Retain the exact request, supplied image hashes/version, session/job and completed report privately. Record the returned tool configuration/available trace when exposed; do not claim technical tool disabling merely from a prompt or self-report. A running receipt is not a completed review.

Codex checks the findings and revises the appropriate mock/native UI through the existing design workflow, then sends only revised UI evidence back to this reviewer. Keep engineering validation in a separate reviewer/session. Missing UI images or an unavailable reviewer leaves UI comprehension unreviewed; an implementation review cannot substitute for it.
