# Scripts Directory Navigation Implementation Plan

> **For agentic workers:** Use executing-plans task by task. Codex owns native verification and integration.

**Goal:** Drill through Package and path components before opening a source file.
**Architecture:** Pure immediate-child projection of validated package paths with existing closure-based SwiftUI NavigationLinks.
**Tech Stack:** Swift6, SwiftUI, XCTest; iOS18 and26.
**Spec:** Canonical docs/mock-diff/SPEC.md at /Users/devonly/Developer/interceptor-live-scripts-20261018/Interceptor, current human Scripts-tree request.

## Task checklist
- [x] Update canonical mock components/screens first.
- [x] Write focused projection tests; confirm expected failure on native Mac.
- [x] Implement projection and directory/package navigation; update obsolete flat-list UI helpers.
- [ ] Run affected native unit/UI flows and physical M3 check; retain exact capture metadata.
- [ ] Independent actual-diff review, verified commit and PR.


## Intent and approach
The user requested drilling through a tree because many scripts share a basename such as POST.js. Replace the flat per-package file list with the existing navigation list pattern: Scripts -> installed Package -> folders -> exact file; tapping a file directly opens the read-only full-screen source reader (no intermediate metadata).

A push navigation hierarchy is the chosen implementation approach derived from the user's "潜っていける" request. Inline expanding rows keep the list crowded and full-path-only labels are the current problem. Reuse existing row styles and navigation; no new controls, permissions, disk access or execution behavior.

## Behavior
- Scripts root lists installed packages, with their existing identity and bundled icon. Selecting a package opens its source root.
- The Package detail's Scripts link opens the same source-root view directly.
- Each directory shows immediate child folders first, then immediate files, deterministically sorted by exact name. Do not flatten or collapse single-child folders.
- Folder rows use the folder symbol; file rows use the document symbol. Names are the immediate component, rather than the full path.
- Nested navigation titles show the current folder name and retain package/path context in an unobtrusive section header. System Back returns one level.
- Selecting a leaf presents the existing fullScreenCover PluginSourceReader for that unchanged full relative path, with the title as the basename. Closing returns to the same parent directory; tapping again reopens. Source bytes stay exact and read-only.
- Never derive identities from basename alone. Distinguish folder/file name collisions and duplicate basenames in separate directories and packages. Prefix checks use slash components, so api and api2 are unrelated.
- Legacy schema1 remains a script.js leaf. Empty/loading/error states remain available. Assets are not scripts.
- The tree is a pure projection of already validated sourceFileNames, never FileManager/network traversal.

## Implementation and ownership
1. Codex updates canonical mock SPEC/component and screen compositions before product code.
2. Independent LocalGPT plan review and Claude feasibility review inspect the actual repository at base7125f8f.
3. Claude implementer owns PluginScriptTree.swift, PluginScriptFilesView's section in PluginBrowserView.swift, focused projection tests, and necessary existing UI navigation helper updates. No other behavior changes or commits.
4. Codex integrates and runs native builds/app-host tests and affected navigation on iOS18.5/26.5, with exact owned simulator cleanup. Codex does physical M3 navigation and captures. Every capture is immediately exact lossless WebP, dimensions/RGBA/ICC verified; retain 16bit original only if conversion impossible.
5. A fresh independent Claude reviewer reads the actual source diff and relevant files.
6. Record Mock Diff comparison or concrete missing/incompatible baseline without changing adopted selections or resizing images.

## Verification
- Projection tests: root file, nested duplicate POST.js, api/api2 boundary, deterministic order, mixed root/directory contents, folder/file same name, exact leaf paths, legacy script.js and empty input.
- Existing multi-file viewing UI test: enter correct Package and each folder, tap leaf to open source directly; exact source matches, Done returns to the same parent directory, re-tap reopens; no Test entry.
- Native device build and M3: Scripts Package -> hooks -> host -> URL segments -> POST.js; Done returns to the parent directory; Package detail Scripts shares the same tree.
- Reuse canonical Xcode DerivedData and SourcePackages from the current run, never create a per-task build tree. The worktree's default sibling Mudmouth differs from the verified dependency: Codex must fix the build mapping through an owned wrapper/safe worktree move before building, never modify the user's Mudmouth checkout.

## Plan-review resolutions
- Root SwiftUI identity is immutable revision.id, never manifest UUID alone. Package row identifiers include revision.id; closure destinations capture that exact presentation. Existing optional author/version plus source context distinguish same-named packages; no basename-derived IDs.
- Directory/file row identity is typed kind plus full relative path; the package scope is explicit. Keep leaf accessibility format plugins.file.<manifestUUID>.<fullpath>, and separate prefixes plugins.scriptPackage.<revisionID> and plugins.scriptFolder.<manifestUUID>.<fullprefix>.
- Root loaded+noerror+noinstalled shows existing localized AUTO_BROWSER_NO_SCRIPTS. Loading/error do not show an empty message simultaneously. Empty projection is total and uses existing same key; product schema2 never has empty sourceFiles.
- No file metadata screen and no path text beyond folder navigation (the directory header already shows it); the PluginFileDetailView metadata UI is removed. Keep PluginManifestJSONView.
- Child views capture immutable presentation, consistent with current file/source metadata views. There is no refresh/delete operation inside the Scripts hierarchy. Reopening the Scripts root reads current installed packages; do not introduce a new live-rebinding system.
- UI ownership includes InterceptorUITests/AutomationUITests.swift. Update openFile and return-to-root helpers and existing multifile EN/JA flow, preserving exact source/rule checks and source viewer reopen behavior. Source constants remain generated; do not edit generated fixture declarations.
- Projection accepts already validated paths (Core rejects empty/dot/dotdot components); no second security validator. It must never trap on empty input and retains exact leaf strings. Include file/folder same-name collision and duplicate basenames as pure projection tests.

## Projection interface
Create Interceptor/Automation/PluginScriptTree.swift. Immutable PluginScriptTree.Entry has enum Kind { directory, file }, name:String, path:String, kind:Kind and kind-prefixed fullpath id. Static entries(in files:[String], at directory:[String] = []) -> [Entry] returns immediate children, folders first and lexicallysorted within eachkind. It retains original fullrelativepath at leaves and uses exact array-component prefix. No filesystem, networking or mutable state.

## Verification evidence

- Projection: 13 XCTest cases passed; unchanged by the direct-source follow-up.
- Direct source: affected EN/JA UI flow passed on disposable iPhone15 simulators, iOS18.5 and26.5. Includes exact UTF8 bytes, read-only, Done returning to parent, reopen and app relaunch.
- Signed M3 build and installation succeeded. Physical navigation on the M3 has not been independently verified.
- Independent Claude actual-source review found no remaining P1/P2.
- Mock Diff compared matching English/light iPhone15 root captures to baseline-20261023:18.5 1.3904983003287845%,26.5 1.2508943018207255%. These are intentional flat-files-to-package-row differences; no baseline adoption was changed. New folder checkpoints and the direct source viewer have captures, but no matching approved regression baseline.
- LocalGPT UI-only image review could not start because its uploader could not access the Mac screenshot path. No UI-only review is claimed.
