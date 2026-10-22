# Persistent package catalog implementation plan

> **For agentic workers:** Use the existing coordinated workers with non-overlapping ownership. Native verification remains with Codex. Do not start another ChatGPT tab or copy build caches.

**Goal:** Make repository package browsing a durable local database operation.

**Architecture:** Add an app-only SwiftData projection with typed package presentation records and exact content-addressed payloads. Stage source content before the existing authoritative accept/refresh commit, and filter reads by current accepted source descriptors. Route browsing exclusively through database predicates and installation through local validated payloads.

**Tech stack:** Swift, Foundation, SwiftData, existing AutomationCore, SwiftUI/XCTest.

**Spec:** `docs/superpowers/specs/2026-10-22-package-catalog.md`.

## Global constraints

- No per-navigation or per-search network request or package JSON validation.
- Preserve trust, pins, anti-rollback state, installation CAS and execution approval.
- Source identity is canonical URL + repository UUID + payload digest; pin-only generation changes keep content usable.
- Keep exact source bytes and source-qualified UUIDs; do not reconstruct install payloads from metadata.
- Use database predicates for matching; preserve Japanese, case, width and installed projection behavior.
- One canonical reusable build output per scheme/configuration; no dated cache copies.
- Every capture becomes verified exact lossless WebP before review/publication. Keep Viewer12356 running and return URLs only.

## Review focus

- Old index-only stores cannot synthesize unknown content offline; show known data and migrate independently of navigation.
- A stale ingest or concurrent source removal must not expose data from a different accepted snapshot.
- DB failure must preserve useful prior data and never reset trust or installed revisions.
- Search must retain installed-field priority, source separation, Unicode behavior and literal wildcard characters.
- Reading an altered DB payload must never authorize installation; GET uses current trusted index validation.

## Task 1: Typed SwiftData projection

Files: new `Interceptor/Automation/PluginPackagePresentation.swift`, `PackageCatalogDatabase.swift`; new DB tests/harness.

- [x] Define typed metadata/content/rule DTOs with a single mapping from validated PluginPackage, shared by DB ingestion and installed UI.
- [x] Write persistence/offline/database-query/round-trip/source-scope/bounds tests, then a minimal interface stub. Run the native failing test against actual AutomationCore before implementing behavior.
- [x] Implement staged snapshots, index-only migration rows, content-addressed raw bytes, typed metadata/files/rules, source-filtered FetchDescriptor queries and scoped detail reads.
- [x] Use a separate package ModelContainer, explicit saves, fresh MainActor read contexts and a serialized background writer. Verify actual supported search/sort predicates natively.
- [x] Test reopen, query parity, source separation, atomic failure, exact bytes, full/partial data and staging cleanup; run native RED/GREEN evidence.

## Task 2: Source lifecycle and browsing integration

Files: `AutomationController.swift`, `AddRepositoryModel.swift`, `PluginBrowserModel.swift`, package/file/manifest browser views; related controller/model/UI tests.

- [x] Centralize add/refresh/default-source ingestion before existing accept/refresh publication; reuse exact stored/installed bytes and cap downloads at three.
- [x] Seed known metadata during projection, and own one bounded background backfill per source/digest at controller level. Never trigger it from a query or destination view.
- [x] Replace catalog/category/search operations with database queries; retain existing source-qualified and installed-priority behavior.
- [x] Render details and code/manifest viewers from typed DTOs immediately. Remove destination download/validator tasks and retry-triggered navigation downloads.
- [x] GET alone loads/revalidates local stored bytes, rechecks current record and uses the existing queue. Installed operations stay on authoritative selected revisions.
- [x] Test offline reopen/navigation/search, failure preservation, migration, no network on queries and no install/activation during ingest.

## Task 3: Independent review, native evidence and install

- [x] Save source fingerprints and actual diffs including new files; request a fresh read-only Claude review. Obtain/retain LocalGPT actual-files review when accessible; never call a pending job completed.
- [ ] Build from immutable content and the verified Mudmouth pin; reuse shared package checkouts sequentially without copying them.
- [ ] Run focused logic plus affected native UI checks, preserving environment-specific comparison evidence and reporting missing baseline coverage honestly.
- [ ] Immediately convert captures to exact lossless WebP and verify pixels/profile/dimensions; update only affected Viewer targets.
- [ ] Install the verified Debug app on M3 and read back installation evidence. No VPN changes, upload, TestFlight or release operation.
- [ ] Verify/clean up owned simulators/jobs/superseded artifacts; preserve useful source and receipts. Keep Viewer12356 running.
