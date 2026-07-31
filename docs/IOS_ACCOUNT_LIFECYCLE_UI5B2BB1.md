# UI-5B2B-B1 — Conflict Choice Presentation Correctness

Status: implemented on `claude/ios-merge-conflict-ui5b2bb1`; changes remain
uncommitted pending review.

## Scope

This phase corrects **conflict choice presentation only**. It fixes a case
where the screen displayed a selection the user had never made, and it gives
each option plain-language copy describing what that option actually does.

Explicitly **not** in this phase:

- Re-entering, re-editing, or reversing a choice that was already made.
- A "已处理" / deferred section, or any list of resolved conflicts.
- Any change to how a choice is persisted, or to write/upload semantics.
- Any preview summary of the conflict outcomes.

Those belong to **UI-5B2B-B2**, which will handle re-editing, the deferred
section, and the preview summary.

The `previewRequiresRemoteFingerprint` cleanup (write-only dead state left in
`GuestMergeController` after UI-5B2B-A) remains a **separate maintenance
item** and is deliberately untouched here.

## The defect

The conflict screen drove its `Picker` from view-local state with a fallback:

```swift
pendingChoice[candidate.localItemId] ?? .keepRemote
```

Two consequences:

1. **Phantom default.** Before the user chose anything, 保留家庭 was rendered
   as the selected option. A user who agreed with what the screen already
   showed had no way to express that, and a user who tapped 确认 could
   reasonably believe they had chosen it.
2. **Displayed selection ≠ real choice.** The persisted
   `InventoryMergeCandidate.userChoice` was never consulted for display, so
   the visible state and the stored state were independent.

## The fix

- Selection is now `candidate.userChoice == choice` — no fallback, no
  view-local default. When nothing is chosen, nothing is shown as chosen.
- View-local state is reduced to an `inFlight: Set<UUID>` debounce that
  prevents a double tap from resolving twice. It never contributes to what is
  displayed as selected.
- The segmented `Picker` is replaced with four vertically stacked, full-row
  action buttons (≥44pt, `contentShape(Rectangle())`), each showing a title
  and a wrapping consequence sentence. Each row is one combined accessibility
  element carrying `.isButton` and, when chosen, `.isSelected` — so selection
  is conveyed to VoiceOver and is not signalled by colour alone.

## Consequence copy

`InventoryMergeConflictChoicePresentation` is a pure mapping from
(choice, isSameRemoteRecord) to (title, consequence). `isSameRemoteRecord` is
computed at the call site as `remoteItemId == localItemId` and is used for
**copy selection only** — it changes no behavior.

| Choice | Same record | Different record |
| --- | --- | --- |
| 保留本机 | Updates the same family record; the family's content is replaced | Adds this entry to the family inventory; existing records unchanged |
| 保留家庭 | Family record unchanged; this entry's differences are not uploaded this time | identical |
| 两条都保留 | Adds a separate copy without overwriting the family record | Adds it as another record; both are kept |
| 本次跳过 | Not uploaded this time; both inventories stay as they are | identical |

The copy never uses fork, hash, remote ID, mutation, or snapshot. Two
drift-guard unit tests assert the copy matches what `applyingChoice` actually
does (same-ID 保留本机 → `.update`; different-ID → `.create`; same-ID
两条都保留 → non-nil `forkedLocalItemId`).

`本次跳过` deliberately makes no promise about editing the choice later,
because that entry point does not exist until B2.

## Frozen behavior

`resolveConflict`, `applyingChoice`, `readyToUpload`, `needsDecision`,
`confirmMerge`, rollback/progress/result, the preview boundary from
UI-5B2B-A, transport/API contracts, persistence schema, feature flags, and
`GuestMergeModels.swift` are unchanged. `GuestMergeModels.swift` is
byte-identical to the base commit.

Resolving the last conflict still returns to the preview screen without
confirming — that existing behavior is asserted, not altered.

## DEBUG-only fixtures

`AccountLifecycleConflictFixture` (entirely inside `#if DEBUG`, in a file that
is itself entirely `#if DEBUG`) seeds a local `.conflict` session for six
scenarios: same-ID quantity, different-ID metadata, expiry, ambiguous,
multiple unresolved, and a 20-item long list. Each scenario has its own
household and session UUID, distinct from every pre-existing merge fixture.

Safety properties:

- **Activation** is by exact launch argument. With no conflict argument
  present, `active` is `nil` and the seed returns immediately, so ordinary
  launches and the existing merge loading/empty/counts/unauthorized/offline/
  retry-success/legacy fixtures are untouched. `mergeFixtureHouseholdID`
  consults the conflict fixture first but still resolves per launch argument;
  it never points permanently at a conflict household.
- **Idempotency, scoped per process.** `saveGuestMergeSession` upserts by
  session id, so no repeat call can create a second session or duplicate
  candidates. On top of that the seed runs at most once per app process:
  - *Within* a process it must not repeat, because SwiftUI can run a `.task`
    more than once and a second run would rewrite an already-resolved session
    back to unresolved, silently undoing a choice the test just made.
  - *Across* processes it must repeat. The simulator's store outlives the app,
    so a scenario one test case resolved would otherwise be inherited in its
    resolved state by the next launch. An earlier "skip if a session already
    exists" version had exactly this defect: two UI tests failed because they
    inherited another case's resolved session.
- **No writes beyond the local session.** Seeding is one local persistence
  write. No mutation is staged, no `SyncCoordinator` runs, no token is read,
  and no network call is made. The fixture transport returns an empty change
  set for conflict scenarios so the pre-merge read succeeds without
  regenerating the seeded plan (`preparePreview` never regenerates a
  `.conflict` session).
- **Race prevention.** The seed sets a zero-size, accessibility-only marker
  (`uitest.conflictFixtureSeeded`). UI tests wait for that marker instead of
  sleeping. It exists only in DEBUG.

Release builds contain none of this: the argument strings, fixture type,
household/session identifiers, seed helper, and marker are all compiled out,
verified by a byte-level symbol scan with positive controls.

## Validation evidence

Seventeen presentation unit tests cover the absent default, persisted-choice
mapping, display order, per-identity copy, plain language, purity, and
copy/behavior drift. The UI suite covers entry and layout, the absent phantom
default, vertical row structure, same-ID and different-ID copy, single-resolve
selection behavior, the long list, Dark Mode, and Accessibility XXXL.

Screenshots are kept outside Git under
`/Users/lianghongjing/Desktop/KitchenManager-Merge-Conflict-UI5B2BB1-Review/`.
