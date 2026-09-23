---
name: km-project-memory
description: Use when Kitchen Manager work needs current canonical Obsidian state/decisions, vault identity or staleness checks, degraded mode, or post-work reconciliation.
---

# Kitchen Manager Project Memory

Treat the repository as implementation truth and the external Obsidian folder as canonical project memory. Do not replace either with chat history, Memorix, `PROJECT_STATUS.md`, or Spec Kit artifacts.

## Resolve and verify the vault

Resolve:

```text
${KITCHENMANAGER_VAULT:-$HOME/Documents/Obsidian Vault/10 Projects/Kitchen Manager}
```

Treat the vault as available only when all are true:
1. the directory exists;
2. `Project.md` exists;
3. `Current Status.md` exists;
4. `Project.md` identifies Kitchen Manager and remote `1395490241lhj-code/kitchenmanager`;
5. `Current Status.md` frontmatter contains `head_commit:`.

If any check fails, use Degraded mode below. Never invent another path or create a substitute vault.

## Read before meaningful work

Read only:
1. `Project.md`;
2. `Current Status.md`;
3. `Next Actions.md`;
4. the task-relevant canonical note selected by `km-task-routing`.

`Current Status.md` is the only vault-wide reconciliation anchor. Other notes may carry dates and per-fact evidence, but they do not replace its `head_commit`.

Then check both committed and uncommitted freshness:

```bash
git merge-base --is-ancestor <head_commit> HEAD
git log --oneline <head_commit>..HEAD
git status --short
```

Interpretation:
- commits after `head_commit` mean memory is stale for those commits; disclose that staleness in the first work update and inspect those commits before trusting affected status claims;
- a failed ancestor check is a hard stop: report that the anchor is absent/diverged rather than guessing;
- a dirty tree means memory can be stale for relevant uncommitted work even when `head_commit == HEAD`.

## Classify dirty state

Product-relevant dirty state includes `src/**`, `app.js`, `server.js`, `styles.css`, `ios-native/**`, `data/**`, `supabase/**`, `test/**`, `docs/**`, `PROJECT_STATUS.md`, `package.json`, `*.xcconfig`, `project.pbxproj`, and `*.entitlements`. Disclose and inspect it before relying on canonical status.

Governance/tooling state includes `AGENTS.md`, committed `.agents/skills/km-*`, `skills-lock.json`, generated third-party `.agents/**`, `.specify/**`, `.claude/skills/speckit-*`, and `.claude/settings.local.json`. Disclose relevant changes, but do not treat them as product-state drift by themselves.

Inspect anything else before classifying it. Never describe a dirty tree as clean.

## Read canonical notes selectively

- UI / Home / product: `Product & IA.md`, `UI Design System.md`, and only relevant entries from `Decisions.md`.
- Architecture / persistence / auth / backend / sync: `Architecture.md`, relevant Decisions, and `Testing & Release.md` only when environment/release posture matters.
- Testing / release / security: `Testing & Release.md`, plus the relevant Architecture or Decision entry.
- Historical investigation: `Timeline.md` and `Sources.md` only as needed.
- Documentation-only: the always-three plus the note that owns the fact being documented.

Do not read all canonical notes by default. Read individual Decision entries rather than the whole file. Use `Sources.md` as an evidence index, not mandatory reading.

## Preserve accepted decisions

Do not silently overturn an Active Decision or test-enforced product contract. If current implementation evidence conflicts with one, stop scope expansion and report:
1. concrete evidence;
2. the affected Decision or contract;
3. the minimum affected scope;
4. the smallest proposed resolution.

A Decision is superseded by a new explicit Decision, never by quietly ignoring the old one.

Do not copy volatile feature-state lists into `AGENTS.md` or this skill. Read current stable/open product state from the canonical notes and tests.

## Reconcile after meaningful verified work

Update only what the work warrants, in this order:
1. `Current Status.md`;
2. `Next Actions.md`;
3. at most one task-specific canonical note: `Product & IA.md`, `UI Design System.md`, `Architecture.md`, or `Testing & Release.md`;
4. `Decisions.md` only when an actual decision was made;
5. `Timeline.md` only for a material milestone;
6. `Sources.md` only for a durable new evidence entry.

Never update every note just because a session occurred.

Advance `Current Status.md` `head_commit:` only to an existing committed revision and only after memory has been reconciled through that revision. Never advance it for uncommitted work.

## Degraded mode

If vault identity/availability fails:
- state `Project memory unavailable at <path> — running in degraded mode.` in the first work update;
- fall back to `AGENTS.md` → current git history → `docs/product/PRINCIPLES.md` → `docs/architecture/OVERVIEW.md` → the focused task contract → optional session handoff/memory;
- continue normal builds/tests/development, but do not write project memory; optional session/memory systems being unavailable does not block work;
- after meaningful verified work, include a `VAULT UPDATE` section describing exact per-file changes a vault-side session should apply and whether `head_commit` may advance.
