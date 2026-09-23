---
name: km-acceptance
description: Use for non-trivial Kitchen Manager changes needing bounded scope, evidence floors, review/escalation, stop conditions, or compact handoff—especially shared/state/async/persistence/auth/sync/contract risk.
---

# Kitchen Manager Acceptance and Convergence

For non-trivial implementation, establish a bounded acceptance contract before mutation when the answer is not already obvious from a focused bug or test.

Use `docs/development/AI_CODING_ACCEPTANCE_MATRIX.md` as the risk-routing source and `docs/development/WORKFLOW.md` for execution/retry limits. `docs/development/TESTING.md` owns concrete test selection.

## Define the contract

Keep the handoff compact:

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

Accepted product/architecture decisions are outside the implementation agent's research budget unless current evidence conflicts with them.

## Match evidence to impact

Select only matrix rows that actually apply. Validation follows behavior and shared ownership, not file count.

Pay particular attention to:
- shared helpers/components/protocols/models/contracts;
- multi-step state transitions;
- async, cancellation, retry and stale-result ownership;
- persistence, migration, destructive mutation or data-loss risk;
- auth, privacy, secrets and authorization;
- sync, hosted writes, cleanup and environment selection;
- navigation/IA ownership;
- empty/error/loading/offline/degraded states;
- visual hierarchy and accessibility contracts;
- cross-client/server wire contracts;
- regression-test validity.

A green build proves compilation, not behavior. A focused test proves only the path exercised. Historical evidence proves an older tree.

## Strengthen high-risk evidence

For high-risk behavior, do not rely only on unchanged green tests. When practical, add/strengthen a regression that proves the failure mode. Use mutation or equivalent negative proof selectively where a regression could remain green for the wrong reason, especially for async ownership, destructive persistence, security/authorization, and historically decorative assertions.

Do not mutation-test routine presentation work merely to satisfy process.

## Optional Jev routing

Use Jev only when repository rules leave routing genuinely ambiguous and an expensive branch is otherwise under consideration. Do not call it for routine/local work or when `TESTING.md`, an accepted Decision, or a hard boundary already determines the answer.

Send only a compact, non-secret task state: goal, impact surface, relevant changed paths, accepted-decision names, known risks and evidence summary. Never send source files, raw logs, credentials, tokens, personal/user data, or full vault notes to the external TypeSafe service.

Run all three snap judgments in one request:

```bash
printf '%s' '{"state":{"goal":"...","impact":["..."],"changed_paths":["..."],"accepted_decisions":["..."],"risks":["..."],"evidence":["..."]}}' \
  | node .agents/skills/km-acceptance/scripts/jev-route.mjs
```

Interpret the result as advisory routing:
- `scope_pressure=decision_conflict`: stop and return to the accepted-decision/hard-boundary process.
- `scope_pressure=needs_context`: perform one bounded investigation for the concrete missing fact, not broad archaeology.
- `reasoning_tier=direct`: keep the cheapest sufficient executor/reasoning level.
- `reasoning_tier=standard`: use ordinary project reasoning.
- `reasoning_tier=deep`: consider an expensive/deep model only if the unresolved risk still requires it.
- `review_gate=skip|focused|independent`: select no extra review, a narrow review, or an independent reviewer respectively.

Hard repository rules always override Jev. Jev never authorizes commit/push/deploy, production writes, Decision changes, migration/capability changes, lower validation, or secret/user-data disclosure.

Credential lookup is `TYPESAFE_API_KEY` first, then macOS Keychain service `typesafe-ai` for the current user. Never print, log, commit, or copy the credential into task state. If neither source is available or the service fails, continue with this Skill and repository rules. Jev unavailability must not expand scope or lower evidence requirements.

## Review and escalation

Use independent review when risk or task instructions justify a second perspective, especially around public/shared contracts, persistence/migration, auth/security, sync, concurrency/state ownership, or a critical regression whose test validity is uncertain. Do not invoke broad review for routine local work by default.

Keep implemented, verified and not verified distinct.

Stop expanding and report evidence when:
- implementation evidence conflicts with an Active Decision or `AGENTS.md` hard boundary;
- progress requires unapproved scope, environment, capability, migration, hosted write or credential changes;
- repository state materially contradicts the task's accepted current state;
- repeated attempts hit the same root cause without new evidence.

Report the concrete evidence, hypotheses eliminated, blocking unknown, affected decision/scope and smallest next investigation.

## Prefer executable enforcement

If a stable invariant can be checked reliably by a test, lint, script or gate, enforce it there rather than growing `AGENTS.md` or duplicating feature-specific prose in this skill.
