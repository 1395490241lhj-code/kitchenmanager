# Feature Specification: PR3 Prepared Group Lifecycle

**Identifier:** `007-prepared-group-lifecycle`

**Created:** 2026-10-28

**Status:** Architecture approved by owner, with mandatory legacy/backup revisions; formal specification review-ready after independent design review, awaiting owner review. Implementation and implementation planning are not authorized.

**Surface:** Native iOS Prepared only.

**Baseline:** PR2 merged at `ef23d688c8e72107b60acff0c2e7755289994bd0`; remote main and the canonical vault anchor matched this commit during specification intake.

**Feature branch:** None created. The primary checkout remains at its older HEAD with all pre-existing changes preserved. Implementation facts below were read from an isolated, read-only archive of the baseline, not inferred from that checkout.

**Input and authority:** The preceding PR3 decision memo in this chat, followed by the owner's approval and two mandatory revisions: preserve ordinary editing for count-only records until their first explicit lifecycle action, and enforce original-JSON Backup v3 completeness with explicitly encoded lifecycle nulls. This specification supersedes the memo's proposal to protect all count-only records immediately. The approval covers architecture/specification only.

**Review:** [Independent design review and disposition](review.md). [Specification quality checklist](checklists/requirements.md).

## User Scenarios & Testing

### User Story 1 — Thaw, cook and use one selected group (Priority: P1)

A user records 800g chicken as four linked 200g portions. They separate one portion, thaw it in refrigerated storage, confirm thaw completion, mark it cooked and later use it. The other three portions remain frozen throughout.

**Why this priority:** Group independence is the purpose of PR3. Recording a later cooking state must not duplicate the food or change the original measured allocation.

**Independent test:** Follow the table below, comparing complete Prepared collections after each action and restart. Source S always retains its original snapshot of 800g/four portions while a linked group exists.

| Step | Group A: original UUID | Group B: new split UUID | Recorded remaining allocation |
| --- | --- | --- | --- |
| Record source S | 4 × 200g, prepped/frozen, lifecycle absent | Absent | 800g / 4 portions |
| Split one whole portion | 3 × 200g, otherwise unchanged | 1 × 200g, same source/state/storage/dates, lifecycle absent | 800g / 4 |
| Begin thaw on B | Unchanged | Prepped/refrigerated, thawing, recorded start | 800g / 4 |
| Confirm B thaw complete | Unchanged | Prepped/refrigerated, inactive, recorded completion | 800g / 4 |
| Mark B cooked | Unchanged | Cooked/refrigerated, same B UUID, recorded cooking time | 800g / 4 |
| Use B's last portion | Unchanged | B removed | 600g / 3 |

**Acceptance scenarios:**

1. Given same-source groups A/B, when B transitions, then A's complete business value is identical before/after, including expiry and lifecycle; only derived source summaries change when quantity changes.
2. Given an already-cooked frozen group, when it begins/completes thawing, then it remains cooked; no historical cooking date is invented.
3. Given an invalid transition, stale snapshot or save failure, when confirmation is attempted, then no success is published and no partial lifecycle/date change remains.

### User Story 2 — Keep old records usable without inventing history (Priority: P1)

A user upgrades with count-only Prepared records and previously saved PR2 measured groups. Ordinary count-only editing continues until the user explicitly chooses a PR3 lifecycle action. Measured groups remain protected from generic state/storage changes at all times.

**Why this priority:** Architecture approval expressly preserves legacy editing and requires truthful unknown history.

**Independent test:** Exercise the old-record/edit matrix in FR-03 on upgraded disk stores, imported v1/v2 data and new count-only records; repeat after a successful, failed and cancelled first lifecycle action.

**Acceptance scenarios:**

1. Given `grouping == nil` and `lifecycle == nil`, when an ordinary edit changes name, count, state, storage, prepared date or expiry, then existing editing behavior remains and lifecycle stays nil.
2. Given that same record, when its first valid explicit PR3 action saves, then metadata contains only the event just recorded and protected transitions apply thereafter.
3. Given a PR2 measured group with lifecycle nil, when an old or reconstructed editor attempts a state/storage change, then the store rejects it; nil lifecycle does not grant legacy editing privileges.
4. Given an editor opened before lifecycle opt-in, when it later submits against the opted-in row, then it cannot remove metadata or overwrite the newer lifecycle/expiry state.

### User Story 3 — Separate portions already thawing (Priority: P1)

A user has several equal portions thawing together and separates some into a new group so they can later complete thawing or cook them independently.

**Independent test:** Split a measured thawing group with more than one portion. Both results preserve the exact lifecycle value and expiry, and only the selected result changes on a later confirmation.

**Acceptance scenarios:**

1. Given a measured thawing group, when k whole portions are separated, then the remainder retains its UUID and the sibling gets one draft-owned UUID; both inherit identical thaw start, phase, completion/cooking timestamps, expiry, source and per-portion mass.
2. Splitting neither starts a new thaw event nor resets any date. Confirming the new group's thaw completion does not complete the remainder.
3. Count-only records do not gain splitting or measured mass merely by opting into lifecycle tracking; their PR2 split restriction remains.

### User Story 4 — Back up and recover every lifecycle fact (Priority: P1)

A user exports or recovers a mixture of legacy, measured, thawing and cooked records. The file explicitly distinguishes absent lifecycle metadata from an incomplete record, and older readers reject unsupported files.

**Independent test:** Execute the version/shape and rollback contracts in FR-09–FR-11, including original-byte validation, actual preview confirmation re-encoding and restart. No path may reduce a tracked record to an untracked record accidentally.

### User Story 5 — Offer food appropriate for an immediate meal (Priority: P2)

Quick Meal and Component Meal exclude frozen and actively thawing Prepared groups from immediate suggestions. Users still see those records in Prepared and the existing board for future use.

**Independent test:** Mix frozen, thawing and refrigerated siblings of one source. Filter availability per group, retain source-based slot exclusion, and prove a stale meal action cannot consume a now-ineligible group.

### Edge Cases

- Same-name independent sources, multiple same-source groups and rounded 33.4g/33.3g allocations retain distinct UUID action targets.
- An overdue finish-by date is not silently moved forward by thawing, completion or cooking.
- A recorded cooked date can precede thaw start for food cooked before freezing; valid history is not forced into thaw-before-cook order.
- Metadata absence, explicit null, malformed metadata, unknown metadata version and unknown raw state/storage values have different handling.
- Missing/depleted records, duplicate split UUIDs, stale editors/writers and repeated confirmation cannot recreate food or restart a clock.
- Cancellation, save failure and retry of the first legacy action never opt the record in prematurely.
- An interrupted restore can leave mixed domains and an outstanding recovery copy. This remains distinct from a single Prepared transaction's old/new boundary.

## Requirements

### Functional Requirements

#### FR-01 — Scope and existing authority

Preserve D-012 (business values separate from persistence records/shared container), D-015 (Prepared separate from Inventory), D-016 (local persistence and backup, no sync), D-017 (one UUID-based decrement, last portion removes row, no new undo), D-019 with its accepted PR2 source-selection refinement, D-020 (existing Component Meal entry) and D-022 (Home urgency and advisory expiry wording).

The owner-approved PR3 change adds per-group lifecycle facts, guarded transitions and immediate-meal availability. It does not add Inventory linkage/deduction, yield measurement, reservations, Planner features, PWA/server behavior, auth, sync, hosted operations, flags or release work. No implementation plan, development slices, task list, source/schema/test changes or application test runs are deliverables of this specification phase.

#### FR-02 — Exact lifecycle value and validity

Keep `PreparedComponentState = prepped | cooked` and `PreparedStorage = refrigerated | frozen`. Add optional group-owned `lifecycle`, separate from `grouping` and its immutable shared `source`. New creations start with lifecycle nil; initial state/storage selection remains available.

| Lifecycle field | Exact value / meaning |
| --- | --- |
| `version` | Integer `1`; independent of root backup v3 and grouping metadata v1 |
| `thawPhase` | String `inactive` or `thawing` |
| `thawStartedAt` | Nullable recorded event timestamp |
| `thawCompletedAt` | Nullable recorded event timestamp |
| `cookedAt` | Nullable recorded event timestamp |

Nil lifecycle means **no PR3 lifecycle metadata recorded**. `inactive` means no active recorded thaw; neither value proves that food has thawed, is ready or is safe. Metadata is a bounded record of these explicit events, not an event ledger or a timer.

For a non-null value, exactly these five keys are permitted and required in its encoded object; nullable timestamps are explicitly null when unknown. Dates use the existing Foundation Codable date representation (finite seconds since 2001-01-01T00:00:00Z); no unrelated date-format change is introduced. Reject wrong types, unknown keys/phase/version and missing required metadata fields rather than defaulting them into validity or silently dropping fields. Future lifecycle semantics require an explicit metadata-version change.

Validity rules:

- `thawing` requires refrigerated storage, non-null start and null completion. Preparation state can be prepped or cooked.
- A non-null completion requires a non-null start, inactive phase and completion at or after start. A recorded start with inactive phase requires its recorded completion.
- A non-null `cookedAt` requires cooked state. Cooked state does not require a cooking timestamp: it can predate PR3 tracking.
- PR3-recorded thaw history requires refrigerated storage. A future refreezing cycle is not represented here.
- A lifecycle with inactive phase and all three timestamps null is invalid: no explicit PR3 action creates an empty opt-in marker.
- No inferred chronology is imposed between pre-existing cooking and later thawing. The mark-cooked action after a recorded thaw requires its event time at or after that thaw's completion.
- Group identity, collection/allocation validity and lifecycle validity are checked together on load and before persistence. Present invalid metadata is never treated as absent.

Every transition captures its event timestamp once for the confirmed intent and preserves it across an unchanged save retry. Opening a sheet, an ordinary edit, reload, split, consumption or export creates no lifecycle event. Clock/time inconsistencies reject the proposed event with the draft retained; they are not repaired by inventing dates.

#### FR-03 — Legacy and protected-edit matrix

Define a protected record as **measured grouping present OR lifecycle present**. The two conditions are independent.

| Existing record | Ordinary editing | PR3 action and subsequent behavior |
| --- | --- | --- |
| Count-only, lifecycle nil | Preserve current name/count/state/storage/prepared-date/expiry editing. Editing never infers lifecycle. | A first successful valid action creates metadata; cancellation/failure/rejection leaves nil. |
| Count-only, lifecycle present | Name, count, prepared-date and explicit expiry corrections remain available with stale checks; no fabricated mass/source or new quantity conversion. | State/storage/lifecycle are protected and change only through valid explicit transitions. Metadata cannot be cleared to regain old editing. |
| Measured PR2/new group, lifecycle nil | Existing name/prepared-date/expiry corrections only; preserve protected count/mass/source/state/storage. | Valid PR3 action creates metadata; generic edits never become an alternative transition path. |
| Measured group, lifecycle present | Same measured correction limits; preserve lifecycle when correcting other fields. | State/storage/lifecycle use guarded transitions. |

The grandfathered count-only/no-metadata picker changes are ordinary record corrections, not recorded PR3 cooking/thawing/refreezing events. Retaining them is the owner's explicit compatibility exception; it does not add a PR3 direct-from-frozen cooking or reverse-transition action. Their first explicit PR3 action still obeys FR-04.

An existing editor must preserve metadata it did not edit. For protected rows, a missing expected row, stripped metadata, changed grouping or attempts to alter protected state/storage fail before writing. A stale editor must explicitly reload/recheck; it cannot silently adopt a new lifecycle while reapplying an obsolete expiry date. Ordinary count-only editing does not automatically opt into lifecycle protection.

#### FR-04 — Allowed and invalid transition matrix

`I` means lifecycle absent or valid inactive metadata. `T` means valid thawing metadata. All permitted actions require the selected live group UUID, exact expected full row, an explicit expiry review and a writable valid Prepared collection. They operate on the entire selected group's portions.

| Current storage / phase / state | Begin thaw | Confirm thaw complete | Mark cooked |
| --- | --- | --- | --- |
| Frozen / I / prepped | Allow → refrigerated/T/prepped; start = event time | Reject: not actively thawing | Reject: direct from frozen |
| Frozen / I / cooked | Allow → refrigerated/T/cooked; retain any known cookedAt | Reject: not actively thawing | Reject: already cooked and frozen |
| Refrigerated / T / prepped | Reject: already thawing | Allow → refrigerated/I/prepped; completion = event time | Reject: thaw not confirmed complete |
| Refrigerated / T / cooked | Reject: already thawing | Allow → refrigerated/I/cooked; retain cookedAt | Reject: already cooked / active thaw |
| Refrigerated / I / prepped | Reject: not frozen | Reject: no active thaw | Allow → refrigerated/I/cooked; cookedAt = event time |
| Refrigerated / I / cooked | Reject: not frozen | Reject: no active thaw | Reject: already cooked |
| Invalid lifecycle/state/storage, unavailable collection, missing/stale row | Reject, zero writes | Reject, zero writes | Reject, zero writes |

Each allowed action preserves all previous valid recorded timestamps except the specific new timestamp it adds. Begin thaw sets completion null; it cannot erase an earlier thaw cycle because recorded thaw history cannot coexist with frozen storage in this version. A nil lifecycle on first mark-cooked becomes inactive with cookedAt only; its thaw timestamps remain null. Confirm-thaw on nil metadata is invalid and does not create metadata.

There is no automatic completion by elapsed time, expiry, app restart or recommendation. There is no PR3 refreeze, cooked→prepped, completed→thawing, lifecycle deletion, direct-from-frozen cooking or persisted consumed state. Initial frozen creation and FR-03's grandfathered editing remain distinct from these actions.

#### FR-05 — Identity, recorded quantity, splitting and consumption

Transitions preserve group UUID, source UUID/snapshot, original source name/mass/count, per-portion decigrams and live count. Preserve original `preparedAt`; recorded cooking time is separate. Cooking changes the same row and never adds a cooked sibling or assumes weight loss. Source summaries describe remaining **original recorded allocation**, not measured cooked yield, nutrition or consumed-versus-discarded history.

Retain PR2 checked Int64 decigram arithmetic, whole physical portions and original q/q+1 allocation-bucket limits. No fractional consumption, re-portioning, new yield, arbitrary gram deduction, merging or automatic coalescing is added.

**Splitting actively thawing measured groups is allowed.** For `1 <= k < n`, retain the remainder UUID, allocate one stable draft-owned sibling UUID and copy the complete lifecycle value unchanged to both. Also copy state/storage/preparedAt/expiry/grouping. The timestamps describe the existing shared physical history up to separation; a split is not a new thaw event. Each group then records future completion/cooking independently. Split is one collection replacement, conserves count/mass and creates no expiry review/reset because it changes none of those facts. Duplicate IDs, stale snapshots and invalid k fail before writing. Count-only splitting remains unsupported even after lifecycle opt-in.

Use the sole existing UUID decrement for every consumption surface. Partial consumption changes count only and preserves the remaining row's lifecycle exactly; the final portion removes the group and its metadata. Siblings survive. The final linked group leaves no empty persisted source parent. Manual Prepared consumption/deletion retains existing bookkeeping behavior in any valid state; it is not a food-safety assertion and creates no implicit cooking event. Meal-surface eligibility adds a precondition to this same decrement, not a second decrement implementation. No new undo or Inventory consumption receipt is introduced.

#### FR-06 — Expiry review without silent extension

Every explicit PR3 lifecycle action presents the selected group's existing editable finish-by date and requires confirmation of a reviewed target date bound to the expected row and action. Use the existing advisory wording `建议…吃完`; never describe an automatic date or eligibility as a food-safety guarantee.

| Action | Proposed date and default |
| --- | --- |
| Begin thaw | Show a refrigerated planning seed anchored to this action's event time: existing two-day prepped / three-day cooked suggestion. Initially select the earlier of existing expiry and that seed. |
| Confirm thaw complete | Keep the existing expiry exactly; review it without restarting or extending the clock. |
| Mark cooked | Show the existing three-day cooked/refrigerated seed anchored to cooking time; initially select the earlier of existing expiry and that seed. |

The seed uses the current suggestion helper's calendar-day semantics, not an elapsed-hours or safety promise. The event time, calendar used for the draft and chosen date remain stable during an unchanged retry. An explicit user date edit may choose a later date, but a later value must be represented as a deliberate reviewed edit in the submitted intent; it cannot arise from automatic recomputation, stale draft adoption or a default. No unreviewed lifecycle mutation API bypass is allowed.

An overdue date remains overdue by default; it does not prevent recording an actual supported event and is never silently made current. Thaw completion does not grant a fresh two-/three-day allowance. Stored expiry remains mandatory. Generic legacy editing continues its existing expiry behavior under FR-03. Home urgency continues using the stored expiry and D-022's existing today/tomorrow/past threshold, independently of immediate-meal eligibility.

#### FR-07 — Persistence, publication, stale edits and retry

Keep one proposed complete Prepared collection, validate it, durably save once, then publish once. There is no optimistic state/expiry update, didSet second write or source-wide transition loop. The transition, its timestamps and reviewed expiry are one atomic Prepared replacement. Beginning thaw after an explicit PR2 split is a separate action; a failed transition leaves a valid separated frozen group.

Exact expected-row comparison includes lifecycle, dates, count and grouping. Persistence retains its current full-snapshot stale-writer check, new context per operation, explicit save and context rollback. Even an unrelated sibling mutation by another writer can require reload; do not claim row-level merge. Invalid transition and same-store stale rejection perform zero persistence writes. A stale durable writer must not commit or publish its proposal.

Failures preserve the prior committed/published collection and draft. Retry against the same expected row reuses event time, split UUID where applicable and reviewed date. A stale result requires explicit current-row recheck, valid action re-selection if needed and renewed expiry review; it must never replay an old action against a different row/state. Missing/exhausted records are not recreated. Success feedback/dismissal occurs only after persistence confirms success.

After process death before save, restart must read the complete old collection. After save but before publication, restart must read the complete new collection. Neither restart path automatically reissues the action or consume request. This is not durable exactly-once user intent across a later, separately confirmed manual action, arbitrary power-loss/fsync proof or a global transaction across backup domains.

#### FR-08 — SwiftData compatibility and unreadable data

The approved local representation adds a nullable versioned lifecycle payload to the existing Prepared record (`lifecycleData: Data? = nil`), keeping `portionGroupingData` and its version unchanged. Retain existing columns/types, IDs, ordering, shared 18-model factory, store location and business/record separation. No new parent relationship/table, mass backfill, lifecycle backfill, store recreation or substitute migration is authorized by this specification.

Missing/null lifecycle storage maps to nil. A non-null payload decodes strictly under FR-02. Lifecycle-bearing rows require known raw preparation/storage values **before** the existing `.cooked`/`.refrigerated` fallbacks can erase invalidity. Preserve lifecycle-absent legacy fallback behavior; do not bundle broad corruption-policy changes. Collection validation still rejects incompatible sibling source snapshots and invalid allocations. Lifecycle differences between siblings are valid because lifecycle is not part of the source snapshot.

Any unreadable lifecycle or invalid combination must retain underlying data and expose the existing unavailable/reload route. It cannot load as an empty available collection, export the empty placeholder, or overwrite the original on failure. Existing clear/restore compensation must retain full lifecycle equality.

An optional column is an inferred-migration candidate, not proof. Acceptance requires two independently attributable old-layout origins:

1. The preserved genuine pre-PR2 18-model fixture, produced with the old field layout lacking grouping/lifecycle columns, opened by the eventual PR3 production factory on a disposable copy.
2. A genuine PR2-layout store produced by the actual baseline binary/frozen owning schema and factory, containing count-only plus measured/rounded groups, lacking the lifecycle column, closed in its producing process, then opened by PR3 on a copy.

Retain producer commit/module/schema provenance, hashes, raw layout proof and expected values for all 18 record types. A PR3-compiled class with nil fields is not old-layout evidence. Verify first upgrade, unchanged old values/order/UUIDs, all unrelated domains, new lifecycle writes, fresh-process reopen and repeated open; retain original fixtures unchanged. Fresh empty/in-memory parity does not substitute. Failure or unprovable old-layout fidelity stops implementation for a separately approved migration design; never reset, reseed, move the store or silently introduce VersionedSchema changes.

#### FR-09 — Exact Backup v1/v2/v3 contract

Keep format `kitchen-manager-native-backup`. New exports and newly created recovery copies use root version **3**, even when every lifecycle is null or Prepared is empty. Read versions 1, 2 and 3 explicitly; reject unknown/missing/invalid root versions before destructive work. Retain the four existing mandatory array domains and all unrelated optional-domain semantics.

| Original file declaration | Prepared-array rule | Original row `lifecycle` rule | Grouping rule |
| --- | --- | --- | --- |
| v1 | Existing missing/null → empty compatibility remains; supplied rows must decode validly | Key must be absent, including on count-only rows; present null also rejects | Existing legacy-only rule: no non-null grouping |
| v2 | Must be explicitly array-valued; missing/null/non-array rejects; `[]` valid | Key must be absent; present null also rejects | Existing optional per-row grouping v1 and complete collection validation |
| v3 | Must be explicitly array-valued; missing/null/non-array rejects; `[]` valid | Every row must contain the key; explicit null or a valid FR-02 object only | Same optional per-row grouping v1 and collection validation |

Inspect these presence rules in the **original JSON before tolerant payload/row decoding or preview re-encoding**. Apply them equally to imports, preview candidates and outstanding recovery copies. For v3, an omitted key is corruption/incompleteness, not legacy. Distinguish absent from explicit null; a non-object row or malformed object fails validation. Reject lifecycle keys in declared v1/v2 even when null. No save, recovery-copy preparation, domain writer or successful preview follows rejection.

The v3 Prepared row encoder must explicitly encode `lifecycle: null` when nil (`encodeNil` or an equivalent explicit encoding contract). Synthesized optional encoding / `encodeIfPresent` is insufficient. Non-null lifecycle encodes all five FR-02 keys, including null timestamps. Grouping remains independently optional as in PR2.

Illustrative row fragments, using the existing numeric date representation:

```json
{"lifecycle": null}
```

```json
{"lifecycle":{"version":1,"thawPhase":"thawing","thawStartedAt":815000000,"thawCompletedAt":null,"cookedAt":null}}
```

These fragments omit unchanged required row fields for readability and are not complete importable backups. No v1/v2 compatibility export stripping lifecycle or source linkage is offered.

#### FR-10 — Preview, old readers and lossless recovery

The current preview validates a candidate and then re-encodes its decoded payload for restore. Therefore validation and new v3 encoding must be coordinated explicitly:

- First validate original v1/v2 bytes using FR-09. Only after success may the validated candidate be normalized to a v3 payload for preview confirmation/re-encoding, with lifecycle null for genuinely untracked imported rows. This changes representation, not the user's facts.
- Preserve the original file's declared version and genuinely present export-date information as preview provenance. Do not invent an old export date, rewrite the input file, or re-encode v3 fields under an old root declaration.
- Validate v3 completeness before any normalization. A missing lifecycle key cannot be repaired by re-encoding null. Confirmed preview and direct restore must have equivalent field-complete effects.
- New pre-restore recovery copies always describe the **current** complete kitchen in v3, regardless of the incoming file's version. They preserve current lifecycle data even when the user intentionally restores an older backup without history.
- Existing outstanding v1/v2 recovery copies stay readable and remain byte-identical until resolved. Never overwrite or silently upgrade an unresolved copy. Explicit restoration of an older copy may intentionally restore its lack of lifecycle history under the existing whole-scope confirmation contract; never merge current metadata into old rows or pretend the old file contained it.
- Exporting an outstanding recovery copy is also a new export: validate its original bytes first, then generate a lossless v3 document with explicit lifecycle nulls where the old file had no history. Preserve the on-device unresolved original bytes unchanged. Identify the export as recovery-snapshot contents; any newly generated export time is not presented as the old snapshot's original creation time. Raw copy preservation and v3 document generation are distinct operations.
- Full lifecycle values participate in preview representation, export, readback, equality, backup-scope comparison, compensation, clear rollback and explicit recovery. Old v1/v2 absence alone maps to nil, not fabricated history.
- A frozen actual PR2 v2 validator/reader must reject a new v3 file at the root version gate before row decoding or writes. A reader fixture that imports evolving current payload types alone proves only the root gate, not historical row-decoding fidelity. Preserve/freeze the relevant PR2 owning code for any stronger claim.

#### FR-11 — Rollback and recovery boundaries

Single Prepared save failure must roll back lifecycle/expiry/quantity together. Field-complete reread determines truth; optimistic memory is not proof. On restore, keep the established seven-domain order: inventory, shopping, plans, consumption, weekly plan, Prepared, special plans.

| Boundary | Required accepted behavior | Explicit limit |
| --- | --- | --- |
| Invalid file / missing lifecycle key / unsupported version | Reject before recovery-copy preparation or any domain writer; existing data/copy unchanged | A tolerant successful decode is not validation |
| Restore preparation/recovery-copy failure | No domain writes; preserve outstanding copy and current state | No new bypass of copy protection |
| Exception after Prepared commit, before special plans | Compensate under existing contract; claim recovered only after all compensations succeed and full reread equals the pre-restore scope, including lifecycle | A failed restore is never reported as success |
| Compensation or reread failure | Preserve recovery copy and existing unsafe/unavailable behavior; no false recovered result or writable empty Prepared placeholder | No stronger global write fence is introduced |
| Process kill after Prepared restore commit | Mixed domains may remain; original recovery bytes survive; normal new import refuses; explicit recovery remains available | Not whole-kitchen crash atomicity |
| Successful explicit recovery | Restore all seven original domains, verify full values/lifecycle and two later fresh-process probes; resolve copy only under existing successful/proven-recovery contract | Do not overwrite an unresolved copy with the mixed state |
| Old application on upgraded live store | Unsupported/unverified downgrade; retain compatible pre-upgrade recovery material and use a compatible reader | Backup v3 rejection does not block an older binary opening the live store |

`lastRestoreOutcome` remains process-local; after restart it is not a persisted unsafe marker. An outstanding copy blocks a new import, not every ordinary mutation. No global restore transaction/fence, production rollback operation, filesystem power-loss guarantee or live-store downgrade guard is part of PR3.

#### FR-12 — Immediate-meal eligibility and future availability

For Prepared records only, immediate-meal eligibility requires **refrigerated storage and no active thaw**, plus existing candidate classification rules. Apply this per live group before source selection/exclusion/deduplication. A lifecycle-nil refrigerated record retains today's ordinary eligibility without inventing a thaw-completed event. Invalid/unreadable records cannot produce meal actions.

| Prepared condition | Quick Meal | Component Meal | Prepared/board/future use |
| --- | --- | --- | --- |
| Frozen, prepped or cooked | Excluded | Excluded | Retained and visible |
| Refrigerated, actively thawing, prepped or cooked | Excluded | Excluded | Retained and visible with status |
| Refrigerated, inactive/nil, prepped | Existing prepped templates/effort rules; cooking still required | Existing independent prepped selection rules | Retained |
| Refrigerated, inactive/nil, cooked | Existing cooked templates/effort rules | Existing independent cooked selection rules | Retained |

This is an **immediate-meal** availability rule, not a global delete/filter on stored Prepared data and not a food-safety or time-to-ready guarantee. Frozen/thawing groups remain in source totals, Prepared management, the existing meal-prep board, expiry attention where applicable, backups and information available for future planning. Do not add a new Planner integration/reservation model or remove food from future consideration.

Keep Quick Meal and Component Meal ranking/effort/structure independent under D-019. Keep PR2 source-based selection identity and group-UUID action provenance; one source cannot fill two slots or generate duplicate equivalents. Filter unavailable siblings before choosing an eligible sibling; do not discard the whole source because one group is frozen. Inventory availability, including existing frozen convenience-food behavior, is unchanged.

Stale meal cards/sheets must recheck the live expected row and eligibility inside the same serialized mutation boundary as the sole decrement, without a suspension between check and proposal. A changed/ineligible/missing row rejects without decrement. Manual Prepared usage follows FR-05's existing bookkeeping contract.

#### FR-13 — Native UI and accessibility

Retain existing Prepared navigation/source sections, split entry and Component Meal entry. Add only the valid contextual actions `开始解冻`, `解冻完成`, `标为做熟` to the selected group, using a native confirmation/form that identifies name, group context, count and recorded mass where known, shows before/after state/storage and includes the required expiry review. An action affects all portions in that group; separate whole portions first for different treatment. Do not add a combined split-and-thaw workflow in this scope.

Show `解冻中` while active. Inactive/nil never displays a fabricated `已解冻` or a countdown. Recorded completion/cooking dates can be shown as actual recorded events; unknown dates stay unknown. Continue distinguishing original recorded source mass from remaining allocation; do not relabel it measured cooked weight.

Untracked legacy ordinary editors retain their state/storage controls. After successful opt-in, and for all measured groups, state/storage become read-only in generic correction editors and explicit transition actions own changes. Count-only correction capabilities otherwise follow FR-03. A legacy first-action sheet explains that subsequent state/storage changes use the protected actions. Cancellation writes nothing.

On failure retain draft/action/date, show a native error and offer retry/reload. On stale result show current facts and require explicit recheck/expiry review; do not quietly overwrite a newer date or timestamp. Distinguish unreadable from empty. Never offer a success toast/dismissal before persistence success or an undo that this architecture does not support.

Reuse existing tokens/native components; 44pt controls, wrapping/stacking at Accessibility sizes and group-specific spoken labels identify the correct food without reading raw UUIDs. Validate Light/Dark, normal/Accessibility XXXL, small-phone Light, long/same-name groups, cancelled action, save failure/retry and stale recheck. Obtain actual VoiceOver listening/focus evidence for the changed controls, including failure alert, retry and focus return; screenshots/labels/query success alone are not a spoken/focus pass. If unavailable, retain an explicit HOLD. Preserve the known PR2 editor-frame warning as an unresolved baseline limitation; investigate only a demonstrated PR3 regression within approved scope.

#### FR-14 — Focused acceptance contract (requirements, not results)

All rows below are **required future evidence, not executed or passed by this design session**. Preserve original PR2 fixtures, worktrees, reports, screenshots, xcresults and producer provenance.

| Gate | Required evidence / rejection boundary |
| --- | --- |
| A01 State model | Every FR-02 combination and FR-04 matrix cell; nil→first-action behavior; cooked-before-thaw chronology; invalid timestamps/version/raw strings reject without normalizing to cooked/refrigerated. |
| A02 Legacy editing | All four FR-03 rows, including ordinary count-only state/storage edits with nil preserved, failed/cancelled opt-in, post-opt-in protection and old editor unable to strip metadata. |
| A03 Group independence / mass | Full chicken lifecycle; rounded allocation; all transition siblings byte-equivalent as business values; same UUID on cooking; unchanged source snapshot and no yield; no unrelated domain mutation. |
| A04 Thawing split | k/n boundaries, duplicate/stable retry UUIDs, exact metadata/expiry inheritance, conservation and independent later completions/cooking/consumption; legacy split still rejected. |
| A05 Save/stale failures | Before-save failure rolls back all fields; save-before-single-publication; same-store stale and second durable writer rejection; unchanged draft/event time on retry; no write on invalid transition. |
| A06 Genuine disk upgrades | Both actual pre-PR2 and actual PR2 old-layout origins in FR-08, all 18 record types, ordering/UUIDs, initial/repeated open and new write/restart; production/in-memory factory parity separately. |
| A07 Backup version/shape | Original bytes: v1 absent/null Prepared accepted, v1 grouped rejected; v2/v3 absent/null/non-array Prepared rejected and [] accepted; v1/v2 lifecycle key absent accepted and present-null/object rejected; every v3 row explicit null/object accepted and missing/wrong/malformed/future metadata rejected before preview/copy/writers; unknown root versions rejected. |
| A08 Explicit encoding / preview | Inspect actual v3 export/recovery JSON for every row's lifecycle key, including nil; mixed legacy/measured/active/completed/cooked field-complete round trip. Original v1/v2 validate before canonical v3 preview re-encoding; invalid v3 cannot normalize into validity; old PR2 reader rejects v3; exporting old recovery contents generates v3 without changing the retained original; no misleading original export provenance. |
| A09 Restore / clear rollback | Populate all seven domains; fail after Prepared and compare every lifecycle/group field after compensation/reread; compensation/reconciliation failures retain copy and truthful unsafe state; clear compensation preserves lifecycle under existing clear limits. |
| A10 Process boundaries | Controlled process cuts before save and after durable save/before publication for begin-thaw, complete-thaw, mark-cooked, active-thaw split and consume; two distinct new-process probes per cut compare complete old/new collections and siblings, with no automatic replay. Reuse qualified PR2 mechanisms; DEBUG-only probes excluded from Release. |
| A11 Interrupted restore / old copies | A v3 import and explicit v3 recovery cut after Prepared/before special plans, plus retained v1 and v2 outstanding-copy cases. Verify mixed-state limits, byte-identical copies, new-import refusal, explicit recovery of all seven domains and two fresh-process probes. Never claim global fence or power-loss proof. |
| A12 Recommendations / use | All FR-12 rows in both independent policies; one ready sibling beside frozen/thawing siblings; same-source slot/dedup protection; state/storage changes under a stale meal action reject; no Inventory behavior change; excluded groups remain available for future use. |
| A13 Native / accessibility | FR-13 actual rendered states, untracked versus protected editors, group action/expiry review, 44pt/AXXXL/Light/Dark, error/stale/draft behavior and genuine spoken VoiceOver/focus or explicit HOLD; preserve baseline warning status. |
| A14 Shared regression / evidence | Focused lifecycle/grouping/persistence/backup/restore/meal tests, then full native unit gate because shared Codable/store/backup behavior changes; source-bound results and relevant existing semantic guards. Xcode is authoritative; no unrun suite or reused PR2 receipt is reported as fresh PR3 acceptance. |

For later authorized simulator testing, use the sole reserved Codex device and whole-command `dev-sim-slot run codex --` lease, explicit assigned UDID and serial flags. Reuse the project cache, preserve evidence and report slot status. No test execution, device operation, new fixture production or cache creation is authorized now. Failure of an old-layout, restore or compatibility gate stops release/acceptance and returns the concrete missing evidence; it does not authorize a repair outside scope.

### Key Entities

| Entity | Ownership and lifetime |
| --- | --- |
| Prepared source snapshot | Existing immutable shared origin/allocation; never owns lifecycle; survives through remaining embedded groups |
| Prepared group | Existing row/action UUID, physical portion count, preparation/storage/dates and optional lifecycle; removed on final use/delete |
| Prepared lifecycle v1 | Group-specific explicit thaw/cooking facts; no independent UUID, timer, ledger or source-wide propagation |
| Transition intent | Selected UUID, expected complete row, action, fixed event time and explicit reviewed expiry/edit intent; ephemeral, never a replay queue |
| Native backup v3 | Existing whole-kitchen format with explicit lifecycle completeness; separate version from grouping/lifecycle payloads |
| Recovery copy | Existing durable pre-restore whole-scope asset; new copies v3; old unresolved v1/v2 copies preserved until resolved |

## Success Criteria

### Measurable Outcomes

- **SC-01:** The complete four-portion chicken example changes only the selected group, retains 800g of original recorded allocation through cooking and leaves exactly 600g/three frozen portions after B's final use, without any Inventory deduction.
- **SC-02:** Every permitted action has success, invalid/stale rejection, save-failure/retry and restart evidence. Rejection publishes no success; process cuts reveal only complete old/new Prepared states and never auto-repeat consumption.
- **SC-03:** All formerly ordinary count-only edits remain available until explicit successful opt-in; no old row acquires invented historical events. Every measured group remains protected regardless of metadata absence.
- **SC-04:** Both genuine old disk origins preserve all existing Prepared facts and unrelated data through upgrade and repeat reopen. Unsupported/corrupt metadata is visible and cannot silently clear the kitchen.
- **SC-05:** Every new backup/recovery row explicitly represents lifecycle presence or null, every declared old file containing a lifecycle key is rejected, and preview/restore/recovery round trips lose no recorded fact. Old readers reject new exports.
- **SC-06:** Both immediate-meal policies exclude frozen/thawing Prepared groups while retaining eligible siblings and all records for future use. Every displayed action addresses the correct live group.
- **SC-07:** All material independent design findings are resolved or explicitly owner-held before this specification is called review-ready. Runtime acceptance, implementation planning and implementation remain separate future authorizations.

## Assumptions and Bounded Design Choices

- The owner's current approval supersedes earlier proposal-only PR3 deferrals solely for formalizing this architecture. It does not reopen closed auth/Render/release investigation or authorize implementation.
- Refrigerator thawing is the supported recorded process. No additional thaw method, automatic duration or food-safety rule is inferred.
- Allowing measured active-thaw splits with identical metadata is the bounded design choice: it reuses whole-portion separation, records no new event and permits later independent actions. Restricting these splits would remove an existing operation without a demonstrated invariant need.
- Post-opt-in count-only quantity corrections remain ordinary corrections because lifecycle protection concerns state/storage/events; no measured allocation is invented. Their state/storage protections persist.
- Timestamp field names, strict null encoding and the raw-byte version matrix are the formal architecture contract. Coding/API decomposition, migrations beyond the additive candidate, test implementation and development slices belong to a separately authorized plan.
- Canonical status remains anchored to merged PR2; an uncommitted specification does not advance its head_commit or claim PR3 implementation. This bounded specification records the current owner approval; no new vault Decision number or unrelated status rewrite is fabricated.
- No material owner choice is intentionally deferred into implementation. Any later proposal to change an approved transition, legacy editing, expiry default, backup boundary, yield or downgrade posture must return to the owner explicitly.

## Baseline Evidence and Design Provenance

All implementation references below mean the exact merged baseline above. The unchanged historical PR2 spec/plan contain proposal-era status; their acceptance/closeout and the owner's current instruction establish what was delivered/authorized.

- `ios-native/Kitchen Manager/KitchenManager/PreparedComponent.swift`: current two enums, Codable fields and 2/3/30-day advisory suggestion table.
- `PreparedPortionGroupingMetadata.swift`, `PreparedPortionGrouping.swift`: source/group allocation and collection invariants.
- `KitchenStore.swift` Prepared section: expected-row split, generic grouped-edit protections, sole UUID decrement, validate→persist→publish; backup/restore section: seven-domain order and compensation.
- `Persistence/PreparedComponentRecord.swift`, `PreparedComponentPersistence.swift`, `KitchenPersistenceFactory.swift`: optional grouping blob, existing enum fallbacks, fresh contexts/stale snapshot/save/rollback and shared 18-model factory.
- `KitchenBackup.swift`, `KitchenRecoverySnapshot.swift`, `KitchenRestoreOutcome.swift`, `MainFeatureViews.swift` restore preview: original-JSON version/Prepared-array gates, recovery lifecycle and candidate re-encoding.
- `QuickMealCandidate.swift`, `QuickMealAssembly.swift`, `ComponentMeal.swift`, `PreparedPortionUsage.swift`: current storage-insensitive pool, independent policies, source selection and group action identities.
- `PreparedComponentViews.swift`, `PreparedPortionGroupingViews.swift`, `PreparedPortionGroupingPresentation.swift`: current legacy/protected editors, draft/recheck semantics, rows and whole-portion split.
- [PR2 specification](https://github.com/1395490241lhj-code/kitchenmanager/blob/ef23d688c8e72107b60acff0c2e7755289994bd0/specs/006-prepared-portion-grouping/spec.md), [PR2 plan §§2–5](https://github.com/1395490241lhj-code/kitchenmanager/blob/ef23d688c8e72107b60acff0c2e7755289994bd0/specs/006-prepared-portion-grouping/plan.md), [PR2 acceptance A1–A16](https://github.com/1395490241lhj-code/kitchenmanager/blob/ef23d688c8e72107b60acff0c2e7755289994bd0/specs/006-prepared-portion-grouping/acceptance.md), [PR2 closeout](https://github.com/1395490241lhj-code/kitchenmanager/blob/ef23d688c8e72107b60acff0c2e7755289994bd0/specs/006-prepared-portion-grouping/closeout.md). Primary-checkout copies can be older or absent; these pinned merged Git objects own this baseline.
- `KitchenManagerTests/PreparedPortionGroupingSchemaUpgradeTests.swift`, `PreparedPortionGroupingBackupTests.swift`, `PreparedPortionGroupingStoreTests.swift`, `PreparedPortionGroupingRecommendationTests.swift`, `Fixtures/PreparedPrePR2/{README.md,provenance.json}` and restore/recovery tests: existing assertions/fixture provenance inspected, not rerun here.
- Repository AGENTS.md, Spec Kit constitution, `docs/development/{TESTING,WORKFLOW,AI_CODING_ACCEPTANCE_MATRIX}.md`, `docs/design/KITCHEN_DESIGN_LANGUAGE.md` and canonical Project/Current Status/Next Actions/Architecture/relevant D-015–D-022 entries: governing boundaries, validation ownership and preserved limitations.
- Previous PR3 decision memo in this conversation: recommended separate thaw lifecycle, recorded mass/no yield, immediate-meal availability, reviewed expiry, v3 and unsupported downgrade. Owner's subsequent mandatory revisions are incorporated in FR-03 and FR-09/FR-10; their exact wording takes precedence over the earlier memo.

## Authorization and Exit Boundary

Deliver this specification, its quality checklist and independent review/dispositions only. Do not create an implementation plan/tasks/development slices, change Swift/schema/tests/backup implementation, run native suites, produce old-layout fixtures now, commit/push/PR/merge/deploy, touch production data or begin PR4. The next step requires owner review of this formal specification and separate authorization of the implementation plan.
