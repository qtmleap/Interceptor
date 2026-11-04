## Manifest browser proposals — 2026-10-20

These are proposals, with no adoption implied. Reuse the native grouped-list design, typography and colors above. A human chooses the new catalog and screens in Mock Diff Viewer before native implementation.

Hierarchy: Repositories → Repository → Manifests → Manifest (enabled/disabled) → Scripts → full-screen Script. A repository contains purpose-specific Manifest bundles; the user imports only the ones they want. Registration and metadata refresh never import or enable a Manifest. The local virtual repository preserves file imports in the same hierarchy, without a publisher or update checks.

Normal Manifest use requires no code: show purpose, published/imported/active versions and the state-dependent Import, Import Update, Enable or Disable action. Scripts, Manifest JSON and Test are explicit navigation destinations; show neither code nor sample JSON in the normal Manifest detail. Scripts have no individual enable controls. Source and JSON are read-only; source opens full screen on both phone and tablet, with Done.

Check states distinguish not checked, checking, metadata update, up to date and failed. Never call persisted data latest without a successful check. Repository sequence is an update number, while a Manifest has a SemVer version. Published 2.0.0 with imported/active 1.0.0 offers Import Update. Imported 2.0.0 with active 1.0.0 offers Enable 2.0.0; import leaves 1.0.0 active, while explicit enable and OK atomically replace it. No separate Approve action.

The dedicated Test screen has prepared read-only sample JSON, a prominent Run Test button outside list rows, and a short footer explaining that it does not change live traffic or send data externally. Supplemental explanations belong in footers. Empty/error screens offer recovery. Fixtures use example.com and synthetic packages only.

Components live in `src/manifest-components.ts`, importing shared primitives from `src/components.ts`. Screens declare and resolve their required parts through `requireParts`; missing parts fail generation. The catalog shows status, versions, primary-button disabled/loading states, navigation, confirmation and read-only content. Screens do not restate component markup.

Build: `bun docs/mock-diff/src/manifest-screens.ts`. Generated HTML is self-contained, with Japanese/English, light/dark, iPhone 402×874 and landscape iPad 1180×820 variants. Browser mocks are design evidence; native captures and regression comparisons remain separate requirements.

The import, active and update mocks are successive states of one synthetic example, not simultaneous inventory. Local example is a separate file-imported bundle, shown disabled with an Enable action. Catalog updates use an explicit catalog label; activation status names the version it describes. The first-import and Manifest JSON mocks show 1.0.0, followed by the separate 2.0.0 update states.
