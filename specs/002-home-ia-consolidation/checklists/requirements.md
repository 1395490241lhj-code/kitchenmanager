# Specification Quality Checklist: Home IA Consolidation

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-10 · **Reconciled**: 2026-09-11
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details beyond owner-approved contract facts (identifiers and existing API names are quoted because they are test-enforced contracts, as in 001)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders (the audit tables carry code evidence by design of the brief)
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain — GD-1…GD-5 govern, and the 2026-09-10 answers are recorded with superseded items marked in place
- [x] Requirements are testable and unambiguous (FR-001…FR-022)
- [x] Success criteria are measurable (SC-001…SC-012)
- [x] Success criteria are technology-agnostic where possible (SC-011 names a repo check by necessity)
- [x] All acceptance scenarios are defined (User Stories 1–6)
- [x] Edge cases are identified
- [x] Scope is clearly bounded — capability re-homing, Home reduction, canonical routing, Special Plan today and the `TodayPlanDetailView` retirement are all inside this feature; Out of Scope lists what is not
- [x] Dependencies and assumptions identified — the only sequencing dependency is FR-022, the Home IA Decision that must be recorded before Slices B, D and E

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak beyond contract facts

## Notes

**Governing decisions, session 2026-09-11.** Five owner decisions govern this specification and win
wherever the earlier session disagrees:

- **GD-1** — weekly-menu materialization shipped on `main` = `a7b7d8f` (D-041). `加入用餐计划`
  writes canonical `KitchenStore.plans`, `weeklyPlan` is a resumable draft plus its recovery
  receipt, `WeeklyMenuPlannerView` exposes `onMaterialized`, and `WeeklyMaterializationSummary`
  carries `startDate` / `endDate`. Planner can host the generator truthfully today.
- **GD-2** — `TodayPlanDetailView` retirement belongs to this feature.
- **GD-3** — the delivered feature has exactly one Home planning-management destination,
  `用餐计划` → Planner.
- **GD-4** — the Decision number is assigned at write time.
- **GD-5** — the approved Home IA is unchanged: Today Context → one Primary Task → `更多推荐` →
  `用餐计划` → `需要处理`, with Special Plan today inserted between dinner `eatOut` and the
  ordinary plan, and a factual non-interactive suppressed-plan line.

**`TodayPlanDetailView` classification.** Classification **B**: retired inside this feature, in
Slice E, after Slices A, C, B and D establish parity and remove the routes. It is not a deferred
gap and it is not verdict C. Every capability it held has a named owner in §2 of the spec — three
re-homed to Planner, two removed by explicit owner decision — and each deleted symbol carries a
zero-reference proof (FR-017).

**Decision number.** D-042 is recorded and accepted. Assignment was made after reading the
canonical record; D-041 belongs to 003. The research draft is historical and remains unnumbered.

**Clarification history.** The 2026-09-10 session is retained in `## Clarifications` for
provenance. Its nine answers are shown as recorded, and the two things the 2026-09-11 session
changed are marked **SUPERSEDED** in place: the Decision number quoted that day inside OD-1, and
the weekly-generator truthfulness answer that GD-1 resolved. Everything else stays active and
carries into FR-001…FR-015 — OD-1's substance (Planner is the single canonical saved-meal
planning surface), OD-2 through OD-6, the quick-complete semantics and placement, and Special
Plan precedence.

**Constitution III (anti-drift).** D-031 decisions 3–4 are superseded and decision 5 is narrowed by
the Decision required in FR-022, recorded in canonical memory before Slices B, D and E implement.
D-031's wording ban is respected: Home uses the plan's own title and `聚餐`, never `特殊计划`,
`AI 聚餐`, `AI 菜单` or `新建特殊计划`. D-040's delete + Undo remains the only ordinary-meal
delete contract, and D-038's AI treatment is unchanged.
