# UI-5B2B-A — Explicit Preview Boundary & Persisted-Plan Safety

Status: implemented on `claude/ios-merge-preview-ui5b2ba`; changes remain
uncommitted pending validation.

## Boundary

Account rendering and the inline Guest merge prompt perform local eligibility
detection only. The credential provider, sync transport, and `GET
/api/sync/changes` are created only after the user opens the merge sheet. The
sheet owns loading, fetch failure, retry, and empty/preview presentation. A
sheet dismissal cancels its view task and does not schedule a hidden retry.

## Persisted-plan safety

When a production remote transport is present, a legacy active plan without a
`remoteSnapshotHash` is never presented as a trusted preview. A fresh remote
read regenerates the plan before confirmation. The controller also fails
closed before staging mutations if a production preview lacks that
fingerprint. Existing hashed plans keep the current drift check and valid
restart recovery. Offline/no-transport test and smoke callers retain their
local-only semantics.

## Frozen behavior

Conflict choices, confirmation semantics, progress/result/rollback, sync
transport/API contracts, persistence schema, feature flags, authentication,
account deletion, and Guest behavior are unchanged. Preview reads are GET-only;
they do not advance the persisted sync cursor or stage mutations.

## Validation evidence

Focused controller and UI tests cover the explicit read boundary, failed-read
handling, local-data preservation, and legacy-plan regeneration. Screenshots
belong outside Git under
`/Users/lianghongjing/Desktop/KitchenManager-Merge-Preview-UI5B2BA-Review/`.
The DEBUG-only fixture now covers loading, empty remote, counts/conflicts,
unauthorized, offline, retry-success, legacy regeneration, dark mode, and
XXXL presentation. All eleven required images were regenerated from the final
successful UI-test result bundle and opened for review. The preview and
conflict views add only a presentation safe-area inset so the last content
remains above the floating tab bar at XXXL; no merge mutation is performed by
the fixture.
