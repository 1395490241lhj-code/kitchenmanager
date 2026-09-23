# AI Coding Acceptance Matrix

This document is the compact risk-routing table used by `km-acceptance` under the repository-wide acceptance rules in `AGENTS.md` §5. It is a development aid, not a second source of product truth and not a replacement for `TESTING.md`.

## 1. Authority and use

- `AGENTS.md` owns repository-wide agent rules and authorization boundaries.
- `TESTING.md` §5 owns iOS test selection; platform-specific verification rules remain there.
- `WORKFLOW.md` owns task execution, retry limits and delivery flow.
- This matrix answers one question: **what evidence class is proportionate to the risk introduced by this change?**

For a non-trivial task, select only the rows that actually apply. Record them in the implementation handoff as `Impact Surface`, `Validation`, `Stop Conditions` and `Exit Criteria`. Do not mechanically satisfy every row.

Classes are routing labels, not release scores: **Release blocker** means unresolved risk prevents a ready/verified claim; **Behavior** protects observable flow semantics; **Quality** protects presentation/accessibility; **Evidence integrity** protects the trustworthiness of validation; **Agent health** protects scope and convergence.

## 2. Acceptance matrix

| Risk / trigger | Default class | Minimum acceptance evidence | Escalate when |
| --- | --- | --- | --- |
| Shared component/helper/protocol/model/contract changes | Behavior | Inspect relevant consumers; run focused tests for representative affected paths; verify no caller relies on the changed assumption | Public/shared semantics changed across modules or clients |
| State transition or multi-step workflow | Behavior | Prove start, success, failure and recovery states that are reachable; add a focused regression for the changed transition | State can be persisted, resumed, retried or entered from multiple surfaces |
| Async, cancellation, retry or stale-result ownership | Behavior | Exercise cancellation/retry and late-result behavior; prove obsolete work cannot overwrite current user state | Concurrency crosses persistence, navigation, network or tool boundaries |
| Persistence, migration, destructive mutation or data-loss risk | Release blocker | Round-trip/reload evidence plus legacy/failure safety applicable to the changed layer; preserve rollback/compatibility boundaries | Existing durable data, schema, backup or migration semantics can change |
| Auth, privacy, secret handling or authorization | Release blocker | Negative-path evidence for missing/invalid credentials and authorization; inspect storage/logging boundaries; no secret exposure | Identity derivation, RLS, Keychain/session, token scope or user-data visibility changes |
| Sync, hosted writes, remote cleanup or environment selection | Release blocker | Confirm exact environment; validate affected sync invariants; prove cleanup/flags where remote writes are authorized | Migration, RLS/RPC, shared hosted state or production-like configuration is involved |
| Navigation, IA or route ownership | Behavior | Verify entry, exit/back behavior and preserved deep links; cover affected root/stack state | A destination changes owner, tab/root placement or cross-surface contract |
| Error, empty, loading, offline or degraded state | Behavior | Verify the UI/message describes the live state truthfully and offers only valid recovery actions | Failure handling can mutate state, hide data or route to a different provider/path |
| Visual hierarchy, design tokens or shared presentation primitive | Quality | Inspect the rendered result; compare against canonical design language and affected states | Shared primitive affects multiple screens or introduces a new visual convention |
| Accessibility, Dynamic Type, touch target or Reduce Motion | Quality | Check the affected accessibility semantics and adaptive state; preserve test-enforced floors | Shared controls, core flow, destructive action or accessibility contract changes |
| Cross-client/server contract or wire format | Release blocker | Verify both producer and consumer sides plus compatibility/fallback behavior; test the exact contract edge | Versioning, backward compatibility, persisted payload or server rollout ordering matters |
| Regression-test validity / suspicious green test | Evidence integrity | Demonstrate the test fails against the defect when practical; strengthen decorative assertions | The fix changes the test expectation, mocks the behavior under test, or protects a critical invariant |
| Architecture/Decision boundary or hard-boundary pressure | Agent health | Stop expansion; identify the exact Decision/boundary and evidence of conflict | Proceeding requires superseding a Decision, migration plan, capability, flag or environment change |
| Repeated failed implementation attempt / tool loop | Agent health | Follow `WORKFLOW.md` §6 retry limits; never exceed two same-root-cause attempts without new evidence before stopping and reporting eliminated hypotheses and the blocking unknown | Further progress needs broader archaeology, new credentials, environment repair or a different architecture decision |
| Completion claim / handoff | Evidence integrity | Separate implemented, verified and not verified; cite current commands/tools/results and unrun checks | Evidence is historical, partial, fallback-only, or obtained on a different tree/environment |

## 3. Risk escalation rules

Treat the table as a floor, not a ceiling. Escalate validation when one change matches multiple rows, touches a shared owner, crosses a persistence/network boundary, or can silently lose/replace user state.

A green build proves compilation, not behavior. A green focused test proves only the path it actually exercises. A historical run proves the old tree. A manual screenshot proves only the state shown. Combine evidence classes when the risk crosses those boundaries.

## 4. Negative proof and mutation guidance

Use mutation or equivalent negative proof selectively. It is valuable when a regression could stay green for the wrong reason, especially for:

- state ownership after async work;
- cancellation / retry / stale-result suppression;
- destructive persistence or migration safety;
- security/authorization boundaries;
- historically flaky or previously decorative assertions.

Do not mutation-test routine presentation changes merely to satisfy process. The goal is to prove that the regression protects the invariant, not to maximize test count.

## 5. Visual acceptance contract

For material SwiftUI/PWA visual work, the task contract should name only the states actually affected. Typical dimensions are:

- canonical spacing/type/color/surface tokens;
- populated plus relevant empty/loading/error states;
- light/dark appearance when styling changes;
- Dynamic Type / text expansion when hierarchy or wrapping changes;
- Reduce Motion when animation changes;
- touch targets and accessibility labels/identifiers when controls change.

Source inspection is not visual evidence.

For native iOS / SwiftUI visual work, use `km-ios-validation` and the applicable iOS paths in `TESTING.md`.

For PWA visual work, use the browser/runtime validation path in `TESTING.md`.

## 6. Compact implementation handoff

Use this shape when delegating bounded implementation work:

```text
Goal:
Current State:
Accepted Decisions:
Impact Surface:
Scope / Do Not Touch:
Implementation:
Validation:
Stop Conditions:
Exit Criteria:
```

Keep accepted product/architecture decisions out of the agent's research budget. If implementation reveals evidence that materially conflicts with them, stop and return the evidence rather than silently widening the task.

## 7. Automation direction

When a rule becomes deterministic and stable, prefer moving enforcement into an executable test, lint, script or CI gate. Keep this matrix for routing and rationale; do not duplicate executable rules here.
