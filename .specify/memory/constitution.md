# Kitchen Manager Spec Kit Constitution

This constitution governs work performed through Spec Kit bounded-change workflows in the
Kitchen Manager repository. It is not the repository's source of truth. `AGENTS.md` is the
single repository instruction entry point and outranks this document; see Governance.

## Core Principles

### I. Evidence Before Assumption

Meaningful work MUST begin from current evidence appropriate to the task. Agents MUST inspect
the relevant code, configuration and tests, and MUST satisfy the project-memory and staleness
gates defined in `AGENTS.md`, before asserting system behavior or changing it. Historical
reports, prior chat context, previously generated Spec Kit artifacts and model memory MUST NOT
override fresher executable or canonical evidence; where they disagree, the fresher evidence
wins and the stale claim MUST be corrected rather than carried forward.

**Rationale**: Spec-driven work is only useful when the spec is grounded in the system that
actually exists.

### II. Bounded Change and Scope Discipline

Every Spec Kit workflow MUST define a bounded intended change and state it explicitly. Agents
MUST NOT retroactively specify or redesign the existing application unless that inventory is
itself the explicitly requested change. Plans and implementation MUST preserve unrelated
behavior and MUST NOT bundle opportunistic refactors, dependency changes, formatting sweeps or
cleanup outside the bounded change; such items are recorded as follow-ups instead.

**Rationale**: Narrow scopes make AI-generated work reviewable and reduce unintended
regressions.

### III. Canonical Authority and Decision Integrity

Spec Kit artifacts MUST respect the authority hierarchy defined in `AGENTS.md`. An existing
Decision or a test-enforced contract MUST NOT be silently overturned by a spec, plan or task.
When a requested change conflicts with one, the conflict MUST be identified explicitly — naming
the specific Decision or test — and resolved through the project's existing decision and change
process, never absorbed into a new artifact as though it were settled. Volatile product facts
and detailed canonical contracts MUST NOT be duplicated into this constitution.

**Rationale**: The constitution governs how Spec Kit works; it does not become a second
product-memory system.

### IV. Trust Before Automation and Data Safety

Changes touching AI output, imported data, persistence, synchronization, user data or
destructive actions MUST preserve the trust-before-automation and data-safety posture defined by
canonical project rules. Spec Kit planning MUST surface meaningful data-loss, privacy, migration
and rollback risks before implementation begins. No generated artifact may weaken a confirmation
step, local-first behavior, a safety default or an existing data protection; proposing such a
change requires stating it plainly as its own decision for explicit approval.

**Rationale**: Automation must not gain authority merely because a generated plan recommends it.

### V. Validation Proportional to Risk

Every implemented change MUST have fresh validation appropriate to its actual risk and affected
surface. Prefer the smallest focused tests that prove the changed contract, then expand
validation when shared behavior, persistence, migrations, security, cross-surface behavior or
release risk warrants it. Success MUST NOT be claimed from older test results. Unrun tests,
skipped validation and unresolved risks MUST be stated explicitly rather than omitted.

**Rationale**: Validation should be strong enough to establish correctness without adding ritual
for low-risk changes.

### VI. Authorization Is Never Implied

A specification, implementation plan, task list, `/speckit-implement` result or
`/speckit-converge` result is never authorization for an otherwise restricted action. The
repository mutation boundaries and user-authorization rules in `AGENTS.md` remain in force
throughout the entire Spec Kit lifecycle. In particular, commit, push, PR creation, deployment,
migrations, hosted-configuration changes, production writes, flag enablement and real-user-data
operations MUST have the same explicit authorization inside Spec Kit that they require outside
it. A generated task that describes such an action is a proposal, not permission.

**Rationale**: Planning what may eventually be required is different from permission to execute
it.

### VII. Convergence Includes Reconciliation

A Spec Kit change is not complete merely because code was generated or tests passed. Before
declaring completion, an agent MUST:

- reconcile the implementation against the feature spec, plan and tasks;
- resolve remaining divergence, or record it explicitly as a known gap;
- run the repository's required validation;
- produce the final report required by `AGENTS.md`;
- reconcile canonical project memory when the verified work warrants it, under the project's own
  write-back rules.

`/speckit-converge` supports this process; it does not replace repository-specific completion
gates.

**Rationale**: Completion means the intended change, the implementation evidence and the project
record agree.

## Additional Constraints

- Spec Kit applies to medium and large bounded changes, and to similarly high-risk work, as
  routed by `AGENTS.md`. Small or local work MAY skip it entirely.
- Feature specs describe WHAT and WHY. They MUST NOT prescribe implementation.
- Plans describe HOW, against the architecture that exists today.
- Every task MUST trace materially back to a requirement or acceptance criterion. Tasks without
  such a trace MUST be removed or justified.
- Clarification MUST resolve material ambiguity before implementation begins. Ambiguity that
  would change the shape of the work is not deferred into implementation.
- Analysis and convergence findings MUST be handled according to severity. CRITICAL findings —
  including constitution violations — MUST be resolved before implementation proceeds or
  convergence is declared. Non-critical findings MAY be fixed, explicitly accepted with
  rationale, or recorded as a follow-up where `AGENTS.md` permits it. Findings MUST NOT be
  silently ignored.
- This document MUST NOT store volatile facts: branch names, commit SHAs, test counts, UI
  layouts, active feature status, provider names, deployment state or similar. Their canonical
  owners are defined by `AGENTS.md`.

## Development Workflow

For work routed through Spec Kit:

`specify → clarify when materially needed → plan → tasks → analyze for significant or high-risk
work → implement → validate → converge → repository final report and reconciliation`

This sequence is not ceremonial:

- Optional stages MAY be skipped when their value is genuinely absent and `AGENTS.md` permits it.
- Stages MUST NOT be skipped merely to save time when ambiguity or risk makes them useful.
- The repository's existing gates remain authoritative regardless of which stages ran.

## Governance

1. `AGENTS.md` outranks this constitution for repository-wide source of truth, task routing and
   authorization. This constitution is authoritative only inside Spec Kit bounded-change
   workflows, and only within the authority `AGENTS.md` delegates to it.
2. Within that delegated scope, Spec Kit specs, plans and tasks MUST comply with this
   constitution.
3. This constitution MUST NOT override the source-of-truth order in `AGENTS.md` §1, canonical
   project memory, Decisions, the design language, architecture and contract documents,
   executable tests, implementation evidence, the hard boundaries in `AGENTS.md`, or its
   authorization rules. When a Spec Kit artifact conflicts with any of those authorities, the
   Spec Kit artifact is what gets corrected.
4. No generated spec, plan, task or workflow result grants authorization to commit, push, deploy,
   apply migrations, modify hosted configuration, enable production behavior or touch real user
   data. Such authorization comes only from the user, under `AGENTS.md`.
5. Product facts and product or architecture decisions belong to their canonical owners, not to
   this document.
6. Constitution changes MUST be explicit, independently reviewable and versioned in their own
   change. An amendment MUST explain why the durable process rule itself changed; the
   constitution MUST NOT be amended merely to make a conflicting feature plan pass.
7. Amendments use semantic versioning: MAJOR for backward-incompatible governance or principle
   removals and redefinitions, MINOR for a new or materially expanded principle or section, PATCH
   for clarifications and non-semantic refinements.

**Version**: 1.0.0 | **Ratified**: 2026-09-10 | **Last Amended**: 2026-09-10
