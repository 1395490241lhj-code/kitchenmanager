# Feature Specification: PR2 Prepared Portion Grouping

**Created:** 2026-10-28

**Status:** Proposed — owner design approval required; implementation is not authorized

**Surface:** Native iOS only

**Baseline:** merged PR1 `cdcae1424fafba7ffbe82ccdb6c339a6d695f599`

**Implementation design and acceptance:** [plan.md](plan.md)

## Intent and authority

Record one prepared source, such as 800g of prepared chicken, as four linked
200g physical portions. Keep its origin visible when portions are later separated
into groups. A source here is a local Prepared fact, not a raw Inventory record.

Preserve D-012 (shared container; business values separate from SwiftData
records), D-015 (Prepared/Inventory separation), D-016 (local persistence and
backup; no sync), and D-017 (UUID consumption, last portion deletes the row,
one decrement implementation, no undo). PR1 persistence-before-success and
unreadable-data guards remain mandatory.

The owner's 2026-10-28 instruction authorizes this design despite earlier notes
deferring PR2. Auth and Render investigation are closed for this task. Admin
deletion intentionally remains unavailable; JWKS recovery is owner-supplied
context, not a new infrastructure verification claim.

## User scenarios and testing

### 1. Record one measured source (P1)

Enter a name, total mass and physical portion count in the existing Prepared
add flow. Preview exact allocation before saving. For 800.0g and four portions,
show one linked source containing `200g × 4`, with 800g remaining. Reopen the app
and obtain the same source, group UUID and quantities.

Saving without mass retains the current count-only workflow. Neither workflow
adds an Inventory item or deducts chicken from Inventory.

### 2. Separate portions without losing their origin (P1)

From the four-portion group, split out one whole portion. The existing group
keeps its UUID and three portions; a new group has its own UUID and one portion.
Both retain the same source and 200g per portion. No preparation, storage,
expiry or quantity transition is implied by this separation.

PR3 can subsequently own changing one group's state/storage. PR2 does not add
`thawing`, a transition workflow, thaw dates or cook yield.

### 3. Use or remove a group (P1)

`使用 1 份` targets the visible group's UUID through the existing store entry
point. Its count decreases by exactly one, removing that row when exhausted;
siblings survive. Removing the last active group leaves no empty source record.
Row deletion removes only that group. A whole-source delete shortcut and legacy
conversion are deferred; neither is needed to create and use a newly measured
source. Existing unmeasured rows remain usable without conversion.

Success feedback and dismissal happen only after persistence succeeds. Failure
keeps the prior published/durable state, retains the draft and offers retry.
There is no consumption/deletion undo.

### Edge cases

- Different sources may share a name; names never establish linkage.
- A smaller physical package still counts as one portion. Rounded allocation
  is shown exactly; it never becomes a fractional `portionsRemaining` value.
- PR2 does **not** offer eating half a package or consuming an arbitrary number
  of grams. Such input is rejected rather than rounded/clamped into a whole
  consumption. Arbitrary partial use needs a separate owner-approved follow-up.
- Old count-only data has unknown mass. Do not infer mass from its name,
  Inventory, past servings or an assumed package size.
- Stale edits/splits cannot overwrite a consumption or another split.
- Unreadable grouping data is not an empty kitchen or a count-only fallback.

## Requirements

### Functional requirements

- **FR-01 — Identity:** A source has an immutable UUID; each active homogeneous
  group has a distinct UUID. Physical portions within one group are
  interchangeable and have no individual UUID in PR2. Existing Prepared UUIDs
  remain the consumption identities.
- **FR-02 — Quantity:** New measured sources have positive mass and 1–50 physical
  portions. Proposed precision is 0.1g, with grams as the only input unit. Reject
  excess precision, invalid numbers and allocations below 0.1g per portion.
  Display the exact allocated amounts before confirmation.
- **FR-03 — Conservation:** Creation allocates all recorded mass. Splitting
  preserves total remaining mass/count. Consumption subtracts exactly the
  targeted group's per-portion mass and one count. Deletion removes its current
  allocation; it is not recorded as eating. Remaining mass/count cannot exceed
  the immutable recorded source totals. No consumed/discarded history is invented.
- **FR-04 — Legacy:** Unmeasured rows retain their current fields, UUIDs, counts,
  editing and consumption. They are never automatically converted. A future
  opt-in conversion would measure the current remainder rather than reconstruct
  historical mass; its UI/API is outside the recommended PR2 implementation.
- **FR-05 — Editing:** For measured groups, name, prepared date and explicit
  expiry may be corrected with a stale-snapshot check. Original source mass,
  source identity, group mass and count cannot be silently changed by the old
  editor. Quantity re-portioning, source mass correction and post-create
  state/storage changes for measured groups are deferred. Initial state/storage
  selection is retained. Existing legacy editing is unchanged.
- **FR-06 — Atomic Prepared changes:** Add, edit, split, consume and group
  delete each use one Prepared persistence replacement, with
  rollback on error and one publish after commit. Do not call add/update in a
  loop to implement one logical split.
- **FR-07 — Old data and backup:** Upgrade real pre-PR2 disk data without reset;
  read existing backups without inventing grouping. New grouping must survive
  export, validation, restore, recovery snapshots, clear and rollback. Treat
  unsupported versions/corruption explicitly; never silently drop linkage.
- **FR-08 — Presentation:** Keep the current Prepared route and Component Meal
  entry. Group related rows under their source, with current count/mass and
  individual group actions. Quick Meal and Component Meal still resolve live
  group UUIDs. Preserve Home urgency, expiry wording, Dynamic Type, native
  feedback and 44pt controls. Recommendation ranking/effort remain unchanged;
  propose refining D-019's distinct-component rule so linked groups of one
  source cannot fill two meal slots or create duplicate Quick Meal alternatives.
  Independent same-name sources retain today's distinct eligibility. This
  refinement requires owner approval, not an inferred policy change.
- **FR-09 — Scope:** No PWA/server change, sync enablement, auth/account work,
  hosted operation, production migration, Inventory linkage or deduction.

### Key entities

| Concept | Meaning | Lifetime |
| --- | --- | --- |
| Prepared source | Immutable local origin and original recorded allocation | Exists while at least one linked group remains |
| Prepared group | Existing Prepared row holding identical-size portions and common row attributes | Stable row UUID until deletion/exhaustion |
| Physical portion | One interchangeable package within a group | Counted, not a separate persisted entity |

## Success criteria

- **SC-01:** 800g → four 200g portions → linked groups of three and one → consume
  one from the single group yields 600g/three portions, with no Inventory change.
- **SC-02:** Every supported action has success, rejection, save-failure and
  restart evidence; no failure publishes success or leaves a partial split.
- **SC-03:** A genuinely old on-disk store and old backup restore with identical
  unrelated data and original Prepared UUIDs. Malformed/unsupported new data
  cannot overwrite existing data.
- **SC-04:** New backups and recovery paths round-trip linkage and quantities;
  limitations of old readers and multi-domain crash recovery are documented.
- **SC-05:** Focused acceptance in the plan is satisfied on the implementation
  tree before any implementation-complete claim. This design session runs no
  application tests and claims no runtime acceptance.

## Owner decisions before implementation

1. Approve source-linked homogeneous groups, with interchangeable portions
   rather than one record/UUID per physical package.
2. Approve grams at 0.1g precision, exact remainder allocation, whole-portion
   consumption, and the measured-group editing limits above. These are proposed
   product choices, not existing accepted Decisions.
3. Approve source-aware meal-slot exclusion and Quick Meal deduplication, while
   action provenance remains the live group UUID. This is an explicit extension
   of D-019 for linked groups, with before/after-split acceptance.
4. Approve the local additive schema/backup compatibility plan in [plan.md](plan.md),
   including the backup version boundary and unsupported downgrade behavior.

Approval of this document is design consent. Implementation needs an explicit
instruction naming the approved scope/slice; it never authorizes production
migration, hosted writes, commit, push or PR creation.
