# UI-5B2B-B2A — Preview Summaries & Resolved Visibility

Status: implemented on `claude/ios-merge-summary-ui5b2bb2a`; changes remain
uncommitted pending review.

## Scope

Read-only work on the merge **preview**. It corrects what the summary counts,
makes already-decided conflicts visible, and makes the confirmation copy match
what a confirm would actually upload.

Explicitly **not** in this phase:

- Re-editing, reversing, or re-entering a recorded choice.
- Any call to `resolveConflict`.
- Any change to `InventoryMergeConflictChoice`, `applyingChoice`,
  `readyToUpload`, `confirmMerge`'s writes, session-status transitions, or
  `forkedLocalItemId`.
- Persistence schema/migrations, `SyncCoordinator`, transport, API, feature
  flags, progress/result, rollback.

Re-editing is **UI-5B2B-B2B**, which will also carry the two safety changes the
B2 audit identified (fork-id preservation across a keepBoth round trip, and a
status guard on `resolveConflict`). The `previewRequiresRemoteFingerprint`
cleanup remains a separate maintenance item.

`GuestMergeModels.swift` and `GuestMergeController.swift` are byte-identical to
the base commit.

## Bugs this phase fixes

Both were shipping before this change, independent of B2:

1. **Conflict-reason counts included resolved items.** `quantityConflicts`,
   `expiryConflicts`, `metadataConflicts`, and `ambiguousConflicts` match on
   `conflictReason` alone. The section was gated on `!plan.conflicts.isEmpty`,
   so a plan with 3 quantity conflicts and 2 already decided displayed
   "需要处理的冲突 · 数量不同 3 条" while only 1 remained.
2. **保留家庭 and 本次跳过 were invisible.** `keepRemote` produces
   `action == .keepRemote` and a user-chosen skip produces `action == .skip`
   *with* a non-nil `conflictReason`. Neither appears in `creates`, `updates`,
   `conflicts`, or `exactMatches`, so both vanished from the preview entirely.
   (Neither was ever miscounted as 无需处理 — that requires
   `conflictReason == nil` — they simply had no row at all.)

A third, related problem is addressed by the copy: with every conflict
kept-remote or skipped, `readyToUpload` is empty, yet the button still read
"确认合并库存". Confirming there uploads nothing while implying the whole local
inventory is about to be sent.

## Pure presentation mapping

`InventoryMergeSummaryPresentation.swift` is SwiftUI-free and holds four value
types plus the shared predicates. It reads a plan and returns values; it never
mutates a plan, candidate, or session, and never touches a controller,
persistence, the auth state, the network, or a mutation path. The model's own
computed properties are left exactly as they were, so `readyToUpload` and
`confirmMerge` keep their prior meaning — the corrected counts are derived
alongside them, not by redefining them.

| Number | Predicate |
| --- | --- |
| 计划新增 | `action == .create && !needsDecision` |
| 计划更新 | `action == .update && !needsDecision` |
| 保留家庭 | `conflictReason != nil && userChoice == .keepRemote` |
| 本次跳过 | `conflictReason != nil && userChoice == .skip` |
| 仍待处理 | `needsDecision` |
| 无需处理 | `action == .skip && conflictReason == nil` |
| 可上传数量 | `(action == .create \|\| action == .update) && !needsDecision` |

Conflict-reason rows now require `conflictReason == reason && needsDecision`, and
empty rows are dropped.

same-ID `keepBoth` continues to count under 计划新增: `confirmMerge` stages a
create under `forkedLocalItemId`, so that is what it is.

## Post-partial-confirm accuracy

The production flow allows a session to confirm **twice**. A first confirm
uploads `readyToUpload`; if unresolved conflicts remain, `confirmMerge` parks the
session in `.conflict`; resolving the last one returns it to `.previewReady`.
The plan then mixes candidates this session **already uploaded** with ones only
just decided — and `InventoryMergeCandidate` records no per-item upload state.

`GuestMergeTests.testPartialConfirmThenResolvingTheLastConflictReturnsToPreviewReadyWithMixedPlan`
reproduces exactly that against the real `confirmMerge`/`resolveConflict`, and
proves `uploadedItemCount > 0`, `confirmedAt != nil`, and that the uploaded
candidate is still in the plan afterwards.

Consequences for the copy, all handled in the pure mapping:

- The review footer must not say choices are un-uploaded (false after a partial
  confirm) *or* uploaded (false before the first one). It says neither:
  「这里汇总本次会话中已经选择的处理方式，不代表各条目的当前上传状态。」 —
  identical in every state, so the sentence cannot change meaning underneath the
  user.
- Row labels are 计划新增/计划更新 rather than 将新增/将更新: the counts include
  candidates already uploaded by an earlier confirm, and no per-item state exists
  to separate them. No fabricated "remaining" figure is shown.
- The confirmation checks `hasUploadedAlready` (`confirmedAt != nil ||
  uploadedItemCount > 0`) **before every other branch**, so a partly-uploaded
  session can never reach the definite first-pass copy — including the all-skip
  「本次不会上传任何库存」, which would be false there. It shows
  「确认当前处理计划」 with 「当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。」 — one sentence, identical whether or not
  conflicts remain, because the source provides no reliable basis for a per-item
  "remaining" claim and the copy must not imply this page can tell them apart.

## Resolved groups

Four groups — 已选择保留本机 / 已选择保留家庭 / 已选择两条都保留 / 本次跳过 —
each defined by `conflictReason != nil && userChoice == <case>`. Because
`userChoice` is a single optional, the partition cannot overlap; grouping by
`action` would, since `.create` covers keepBoth forks, different-ID keepLocal,
and plain non-conflict creates alike.

Unresolved candidates and non-conflict candidates never appear. Order within a
group is `plan.candidates` order (`filter` preserves it — nothing is sorted).
No persisted enum, no schema change, no migration.

已处理 totals **include** 本次跳过, and the entry text says so
("已处理 4 条，其中 1 条本次跳过") rather than leaving the number to be read as
"will upload".

## Read-only resolved review

`InventoryMergeResolvedReviewView` takes an immutable `InventoryMergePlan`, not
the controller — so it structurally cannot call `resolveConflict`, stage
anything, or change a choice. Collapsed `DisclosureGroup`s per group; each row
shows the ingredient, the recorded choice, the consequence copy (reused verbatim
from B1, so the two screens can never describe an outcome differently), and the
local/family values that differed.

No copy on this screen or its accessibility labels asserts a per-item upload
state — see *Post-partial-confirm accuracy* for why neither direction would be
true in every state. Reachable after a restart for any non-terminal session. A
`.completed` session is terminal and is therefore never resumed — reviewing a
finished merge is out of scope.

## Confirmation copy

Button title and supporting copy only. The action behind the button, the
`.disabled` condition, and everything `confirmMerge` writes are untouched —
including keeping confirm enabled while conflicts remain, which is the existing
partial-merge path.

| Case | Button |
| --- | --- |
| session already confirmed once | 确认当前处理计划 (checked first) |
| no conflicts | 确认合并库存 · "计划新增 N 条、计划更新 M 条。" |
| unresolved > 0, uploadable > 0 | 先合并其余 N 条 |
| unresolved > 0, uploadable == 0 | 确认当前处理结果 |
| unresolved == 0, uploadable == 0 | 完成，不上传任何条目 |

Only non-zero parts appear in the copy, and the zero-uploadable branch is
evaluated before the partial-merge branch so "先合并其余 0 条" is unreachable.

## DEBUG-only fixtures

`AccountLifecycleSummaryFixture` adds ten `.previewReady` scenarios: mixed,
resolved-only, all-skip, keepRemote-only, keepRemote+skip, unresolved with
uploadable, unresolved with zero uploadable, long resolved list, no-conflict, and
post-partial-confirm-resumed (the only one carrying `confirmedAt` and
`uploadedItemCount > 0`).
Each has its own household (…0051+) and session (…0061+) UUID, disjoint from the
B1 conflict fixtures and the legacy merge fixtures. Dark Mode and XXXL reuse the
mixed scenario with the existing appearance/content-size launch arguments.

Recorded choices are produced by the model's own `applyingChoice` on the fixture
value — never by calling `resolveConflict`.

One detail worth recording: unlike the B1 `.conflict` fixtures, a
`.previewReady` plan **is** subject to `preparePreview`'s regeneration check, so
a placeholder `planHash` would have caused the seeded plan to be regenerated and
the recorded choices discarded. The fixture therefore computes a real
`InventoryMergePlanner.planHash` from the live local inventory at seed time plus
the empty remote snapshot the fixture transport returns, and a unit test asserts
`isPlanStillValid` holds for every scenario.

Seeding reuses the single existing injection point in `ContentView` and the same
per-process scoping as B1: never repeated within a process (so a re-run `.task`
cannot clobber state a test changed), always re-seeded in a new process (so
nothing leaks between UI test cases). One local persistence write; no mutation,
no coordinator, no token, no network. A DEBUG-only marker
(`uitest.summaryFixtureSeeded`) lets UI tests wait rather than sleep.

Release builds contain none of it, verified by a byte-level symbol scan with
positive controls.

## Validation evidence

Presentation unit tests cover all six predicates, the reason-count fix, the
keepRemote/skip-vs-无需处理 distinction, keepBoth counting as an addition, the
group partition and ordering, purity, and all six confirmation cases. Fixture
tests cover activation, isolation, plan validity, per-process idempotency, and
zero mutations/cursors/inventory writes. The UI suite covers the counts, the
reason breakdown, the review entry and screen, group/candidate ordering, all
confirmation cases, restart, Dark Mode, XXXL, and the hidden tab bar.

Screenshots are kept outside Git under
`/Users/lianghongjing/Desktop/KitchenManager-Merge-Summary-UI5B2BB2A-Review/`.
