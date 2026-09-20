# AGENTS.md

This is the single instruction entry point for every AI coding agent working on Kitchen Manager. Route to the smallest relevant context; do not preload phase history.

## 1. Source of truth

When sources disagree, use this order:

1. Actual code, committed configuration, migrations, generated project files, and executable tests, plus fresh build/runtime evidence — the implementation source of truth. For Swift/SwiftUI/Xcode-facing work, that build/runtime evidence comes from Xcode itself; see section 4.1.
2. **Canonical Kitchen Manager project memory** (the Obsidian vault, section 2) for product state, architecture, Product/IA, UI design rules, Decisions, testing/release posture and next actions.
3. `PROJECT_STATUS.md` — a repo-side, point-in-time snapshot. Useful audit and historical context, but **not canonical current state**: its test counts and implementation status reflect the commit recorded in the document. Current test runs and repo evidence outrank it.
4. `docs/product/PRINCIPLES.md` and `docs/architecture/OVERVIEW.md` for stable product and architecture rules.
5. The directly relevant contract, runbook, decision, or validation document under `docs/`.
6. `docs/development/CODING.md`, `docs/development/TESTING.md`, and `docs/development/WORKFLOW.md`.
7. `README.md` for human onboarding.
8. `CHANGELOG.md` and historical evidence for past changes only.
9. Memorix and chat history or model memory — session handoff and scratch only.

Historical evidence proves what was checked then; it does not override current code.

Generated Spec Kit artifacts — `.specify/**` and `specs/**`, the constitution included — are bounded, feature-scoped work products. They do not enter this order at all and carry no repository-wide authority. See section 6.

**This project-level order overrides the generic user-level Memorix rules** in `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Those rules are generic; for Kitchen Manager, Memorix stays subordinate to repo evidence and canonical project memory. A Memorix brief does **not** substitute for reading the vault, and the "brief is the default retrieval boundary" rule does not apply to the canonical notes in section 2.

## 2. Project memory

Canonical project memory is an Obsidian folder **outside this repository**. Resolve it as:

    "${KITCHENMANAGER_VAULT:-$HOME/Documents/Obsidian Vault/10 Projects/Kitchen Manager}"

**It counts as available only if all of these hold.** A directory that merely exists is not enough, and a wrong-project folder is worse than none:

1. the directory exists;
2. `Project.md` exists;
3. `Current Status.md` exists;
4. the identity matches Kitchen Manager — `Project.md` names the project and the remote `1395490241lhj-code/kitchenmanager`;
5. `Current Status.md` frontmatter contains `head_commit:`.

If any check fails you are in **Degraded mode** (section 2.6). Do not improvise a substitute.

### 2.1 Kitchen Manager is not iOS-only

The product spans four surfaces:

- **Web/PWA** — native HTML/CSS/JS, Service Worker, `localStorage`;
- **Native iOS** — SwiftUI, SwiftData, Keychain, `supabase-swift`;
- **Express server** — static hosting, AI/scraping/media, auth and sync APIs;
- **Supabase** — Auth, Postgres, RLS, controlled sync RPC (development environment only).

**Identify the target client before applying any product or UI conclusion.** Do not transfer client-specific wording or behavior from one client to another. Canonical example — recommendation-browser regeneration remains `AI 换几道` on iOS; Home-level `AI 换几道` is retired. The PWA recommendation refresh action is `换一批 ›`. They are different clients, not two names for one control.

### 2.2 Always read, before meaningful work

1. `Project.md`
2. `Current Status.md`
3. `Next Actions.md`

`Current Status.md` is the **only** vault-wide reconciliation anchor. Its `head_commit:` means: the committed repo state through which canonical project memory has been reconciled. The other notes carry `updated:` dates and their own inline evidence paths and per-fact commit references; they do not carry a vault-wide anchor.

Then run the staleness check — **both halves are required**:

    git merge-base --is-ancestor <head_commit> HEAD && git log --oneline <head_commit>..HEAD
    git status --short

- Commits listed → project memory is stale for those commits. Read them before trusting any status claim, and say so in your first message.
- `--is-ancestor` fails → the vault names a commit absent from this clone, or history moved. Stop and ask; do not guess.
- Working tree dirty → apply the relevance rules in section 2.3. **Never report the working tree as clean when it is not**, and never conclude "fully current" from `head_commit == HEAD` alone.

### 2.3 Dirty working tree — classify by relevance

Not every dirty file invalidates canonical product state.

**Product-relevant** — `src/**`, `app.js`, `server.js`, `styles.css`, `ios-native/**`, `data/**`, `supabase/**`, `test/**`, `docs/**`, `PROJECT_STATUS.md`, `package.json`, `*.xcconfig`, `project.pbxproj`, `*.entitlements`. Disclose these, inspect them, and treat canonical project memory as possibly stale for that uncommitted work **even when `head_commit == HEAD`**.

**Known tooling state** — `skills-lock.json`, `.agents/**`, `.specify/**`, `.claude/skills/speckit-*`, `.claude/settings.local.json`. `.agents/` is gitignored and remains fully regenerable, but it now has **two** generators rather than one: its non-Spec-Kit skills come from `skills-lock.json` via `npx skills`, and its `speckit-*` skills are produced by the Spec Kit CLI (section 6.1). Changes here are expected rather than drift. **Disclose them, but do not treat them as invalidating canonical product state.**

**Anything else** — inspect its diff before classifying it. Never classify a file you have not looked at.

`head_commit` is never advanced for uncommitted work (see section 2.5).

### 2.4 Task-aware reading

Do **not** read all ten canonical notes by default. After the always-three above, add only what the task needs:

| Task | Also read |
| --- | --- |
| UI / Home / product | `Product & IA.md`, `UI Design System.md`, and only the relevant Decisions |
| Architecture / persistence / auth / backend / sync | `Architecture.md`, relevant Decisions, and `Testing & Release.md` only when the task is environment- or release-related |
| Testing / release / security | `Testing & Release.md`, plus the relevant `Architecture.md` or Decisions |
| Historical investigation | `Timeline.md`, `Sources.md` |
| Documentation-only | the always-three, plus whichever canonical note owns the fact being documented |

Read individual entries from `Decisions.md`, not the whole file. `Sources.md` is a lookup index for tracing a claim to its code evidence — not mandatory front-to-back reading.

### 2.5 After meaningful verified work — write back

In this order, and only as far as the work actually warrants:

1. `Current Status.md`;
2. `Next Actions.md`;
3. at most one task-specific canonical note — `Product & IA.md`, `UI Design System.md`, `Architecture.md` or `Testing & Release.md`;
4. `Decisions.md` — only when an actual decision was made;
5. `Timeline.md` — only for a material milestone, not per session;
6. `Sources.md` — only when a durable new evidence entry is useful.

Never update every note merely because a session occurred.

Advance `Current Status.md` `head_commit:` **only** to a commit that exists, **only** after the verified work is committed, and **only** once the vault has been reconciled through that commit. If work is still uncommitted, leave `head_commit` unchanged and describe the relevant dirty state separately in `Current Status.md`.

### 2.6 Degraded mode — vault unavailable or identity unverified

The vault is Mac-local. It is not in Git and is not synced.

- **Say so in your first message**: `Project memory unavailable at <path> — running in degraded mode.` Never work silently without it.
- Fall back, in order: this file → `git log` → `docs/product/PRINCIPLES.md` → `docs/architecture/OVERVIEW.md` → the focused contract for the task → Memorix handoff **if available**. Memorix being unreachable is not an error and does not block work; note it once and continue.
- **Never** create the vault, guess another path, or write project memory into the repo as a substitute.
- **Never** treat `PROJECT_STATUS.md` or `docs/IOS_HOME_DASHBOARD.md` as canonical current state — both carry superseded claims and are banner-marked.
- Builds, tests and normal development run fine without the vault. Only *memory writes* are blocked.
- If meaningful verified work occurred, end with a **VAULT UPDATE** block in your final message: the exact per-file edits a vault-side session should apply, including whether `head_commit` may advance and to which commit. A human carries it across; nothing automated does.

### 2.7 Anti-drift — stable contracts and open areas

**Do not silently overturn an Active Decision or a test-enforced product contract.** If a requested change conflicts with one: identify the specific Decision or test, explain the conflict, and require an explicit new product or technical reason before proceeding. If the old decision is intentionally superseded, record a new Decision. A Decision changes by a new Decision — never by a change that quietly ignores it.

These are stable, not immutable forever. Currently stable:

- **iOS Home is a stateful Today surface** — `Today Context → one Primary Task → Needs Attention`,
  with a fixed `今天` navigation title and the page's state carried by the primary task's own
  heading. Decision Mode when no Today Plan exists; Execution Mode once one does, where
  recommendation is demoted to the secondary `更多推荐` rather than removed. Regeneration
  remains inside the recommendation browser; Home-level `AI 换几道` is retired. Primary-task
  precedence: mealPrep → dinner eatOut → Special Plan today → ordinary meal plan → quick →
  recommendation. Do not infer a meal slot from Special Plan `scheduledAt`.
  See the Home V2 IA entry and D-042 in `Decisions.md`;
- recommendation-first Home IA, **as narrowed by the Home V2 IA Decision** — it continues to
  protect the empty-plan state (Home must actively help decide, never just report an empty plan)
  and no longer requires recommendation to hold equal weight once a plan exists;
- Today Plan card renders only when a plan exists;
- an empty plan shows no empty Today Plan card ahead of the recommendation;
- iOS Home section ordering is test-enforced (`KitchenManagerUITests/HomeDashboardUITests.swift`)
  — the enforced order is now Today Context → Primary Task → Needs Attention, anchored on leaf
  accessibility identifiers (a SwiftUI accessibility modifier on a container overrides its
  descendants', so section-level ids silently erase the ids of the controls inside them);
- Home attention is one named list — `需要处理` rows name the food; the count chips are gone,
  and `HomeDashboardSummary.attentionItems` is the only Home attention presentation path;
- Quiet Kitchen R3.1 supersedes the former cooking-green / management-blue visual separation: shared product accent for cooking and management, existing subordinate AI role; preserve behavioral roles. See `docs/design/KITCHEN_DESIGN_LANGUAGE.md` and canonical Decision D-037;
- AI stays visually subordinate to cooking where the current design implements the 0.30 vs 0.45 distinction;
- a >=4.5:1 contrast floor, test-enforced (`KitchenManagerTests/UIFeedbackTests.swift`);
- >=44pt / 44px touch targets;
- Guest-first / local-first behavior;
- no silent upload, clear or merge of local kitchen data;
- trust-before-automation — AI output is draft; receipts, imports and cooking deductions require confirmation;
- a single SwiftData container with business-model / Record separation;
- sync, merge, smoke, dogfood and diagnostics flags default `NO` in every committed configuration;
- the Home semantic-surface hierarchy is **scoped to Home** — it is *not* a repo-wide no-shadow / no-border prohibition, and secondary screens and sheets legitimately retain low-opacity strokes and restrained shadows.

**Open areas — work on these normally; canonical memory must not freeze open design space:**

- Web/PWA Home IA beyond the settled accessibility contracts;
- Demo Kitchen onboarding;
- secondary-sheet and secondary-screen styling;
- `Recipe.samples` onboarding;
- the Shopping inline-title outlier;
- production Supabase topology implementation;
- crash provider, alert routing and rate-limit store choices;
- iOS deployment target 26.0 — a current SDK constraint, not permanent product law.

## 3. Minimum reading

For an ordinary task, read only:

- `AGENTS.md`;
- canonical project memory: `Project.md`, `Current Status.md` (with the staleness check in section 2.2), `Next Actions.md`, plus only the task-relevant notes listed in section 2.4;
- `PROJECT_STATUS.md`, as a point-in-time snapshot rather than current state;
- `package.json`;
- directly affected code;
- directly affected tests;
- at most one or two relevant topic documents below.

Inspect the current branch, worktree, call chain, feature flags, environment and data-loss risk before editing. Preserve unrelated work.

## 4. Task routing

### PWA / browser / localStorage

Choose the relevant sections of:

- `docs/architecture/OVERVIEW.md`;
- `docs/development/CODING.md` or `docs/development/TESTING.md`.

When persistence changes, inspect `src/storage.js`, `src/migrations.js`, `src/backup.js`, affected views/components and focused tests.

### Native iOS / SwiftUI / SwiftData

Choose the relevant sections of:

- `docs/architecture/OVERVIEW.md`;
- `docs/development/CODING.md` or `docs/development/TESTING.md`.

Inspect the affected View, business model, persistence protocol/record, store/controller and XCTest/XCUITest files.

Validate the result through Xcode — see section 4.1.

### Server / AI / media / extraction

Read `server.js`, affected `src/server/**` modules and tests, plus at most one of:

- `docs/development/CODING.md`;
- the focused service contract/design document.

Preserve SSRF protection, limits, timeouts, redaction and safe errors.

### Auth / Supabase / sync

Read the affected code/tests and select only the relevant long-term contract, normally one of:

- `docs/architecture/AUTH_SYNC_ARCHITECTURE.md`;
- `docs/contracts/SYNC_API_CONTRACT.md`;
- `docs/contracts/INVENTORY_MERGE_CONTRACT.md`;
- `docs/contracts/INVENTORY_MUTATION_COALESCING.md`;
- `docs/contracts/MINIMUM_APP_VERSION_ENFORCEMENT.md`;
- `docs/contracts/SYNC_API_RATE_LIMITING.md`.

Use a latest validation document only when the task depends on its exact evidence. Do not read every Phase file.

### Documentation-only

Read the code/config/history that the document claims to describe. Verify links and ownership using `docs/README.md`; do not synchronize stale claims across multiple files.

### 4.1 iOS validation — Xcode MCP

Apple's `xcrun mcpbridge` exposes Xcode's own build, test, diagnostic and preview tools to an
external agent. **When that bridge is available, Xcode is the authoritative build and runtime
validation environment for Swift/SwiftUI/Xcode-facing changes.** Source inspection is never
evidence that an iOS change works.

Validation is proportional to the affected surface. Do not run every available tool on every task:

| Affected surface | Minimum validation |
| --- | --- |
| Swift implementation | Build the `KitchenManager` scheme through Xcode MCP; inspect Xcode diagnostics before claiming completion; run the relevant automated tests where such tests exist |
| Tests | Execute the relevant XCTest/XCUITest scope through Xcode when practical. Compiling is not passing |
| SwiftUI / visual UI | Build and test as above, plus Xcode Preview/render tools when the affected surface has a usable preview. Inspect the rendered result rather than treating source as visual proof. Cover the appearance states the change actually affects — light/dark, Dynamic Type, device size or orientation — not arbitrary permutations |
| Xcode project / capability / entitlement | Validate through Xcode, inspecting diagnostics and build behavior. The section 5 boundary on signing, accounts, provisioning, entitlements and capabilities applies in full |
| Documentation-only / non-iOS | Not required, unless the change can affect the built application |

Which tests the project requires is still governed by `docs/development/TESTING.md` section 5. Xcode
MCP changes how a run is driven, not what has to be run.

**Context safety.** The canonical project is `ios-native/Kitchen Manager/Kitchen Manager.xcodeproj`
and the canonical shared scheme is `KitchenManager`. Confirm that the active Xcode context is this
project before using project-scoped tools; whichever Xcode window happens to be open may belong to
another repository. Discover session-specific values each session and never hard-code them — MCP
workspace identifiers, simulator UUIDs and DerivedData paths are all ephemeral.

**When the bridge is unavailable.** Report that explicitly, fall back to the supported `xcodebuild`
workflow in `docs/development/TESTING.md` section 4, and label the result as fallback validation
rather than MCP-backed validation. Never fabricate Xcode MCP output. When Xcode does report a
failure, separate failures introduced by the current change from pre-existing or environment-related
ones, and do not repair unrelated project or environment problems that the task does not cover.

**This section supplements the existing gates and replaces none of them.** Scope gates, working-tree
cleanliness and known-dirty-file handling (section 2.3), the anti-drift contracts (section 2.7), the
hard boundaries (section 5), the existing suites and design-language requirements, and the rule
against committing or pushing unless explicitly requested all continue to apply unchanged. Where an
existing project rule demands stronger verification than this section, follow the stronger rule.

### 4.2 AI coding acceptance and convergence

For meaningful implementation work, establish a bounded acceptance contract before mutation when the
answer is not already obvious from a focused bug or test: observable completion, impact surface,
validation surface, scope / do-not-touch boundaries, stop conditions and exit criteria. Use
`docs/development/AI_CODING_ACCEPTANCE_MATRIX.md` to route risk to proportionate evidence; it does not
replace `docs/development/TESTING.md` test ownership.

- Keep **implemented**, **verified** and **not verified** distinct. Completion claims require current,
  reproducible evidence; an older green run is historical evidence only.
- Validation follows impact, not file count. A change to a shared component, helper, protocol, model or
  contract requires inspecting its relevant consumers and validating representative affected paths.
- High-risk behavior — state transitions, async/cancellation/retry, persistence or data loss, auth/security,
  migrations and sync — must not rely only on unchanged green tests. When practical, add or strengthen a
  regression that proves the failure mode; for especially critical logic, use mutation/negative proof or an
  equivalent check showing the test would fail if the defect returned. Test ownership remains with
  `docs/development/TESTING.md` section 5.
- Stop expanding the task when new evidence conflicts with an Active Decision or hard boundary, requires
  unapproved scope/environment changes, materially contradicts the stated repository state, or two
  consecutive attempts attack the same root cause without new evidence. Report: evidence, hypotheses
  eliminated, blocking unknown, affected decision/scope and the smallest next investigation.
- Prefer executable enforcement over prose. If an invariant can be checked reliably by a test, lint, script
  or gate, put enforcement there; keep docs/prompts for rationale and routing. Do not grow `AGENTS.md` with
  feature-specific acceptance checklists.
- Delegated implementation handoffs should stay compact and include Goal, Current State, Accepted Decisions,
  Impact Surface, Scope / Do Not Touch, Validation, Stop Conditions and Exit Criteria. Broad repository
  archaeology is opt-in investigation work, not a default implementation step.

## 5. Hard boundaries

Do not change these without explicit approval and a compatibility/migration plan where applicable:

- PWA hash routes, bottom navigation, `S.keys`, schema, migrations or backup contract;
- user-recipe Overlay precedence or base-recipe immutability;
- iOS business-model/SwiftData migration compatibility;
- Keychain/session/secret-storage assumptions;
- signing identities, Apple accounts, provisioning profiles, entitlements or capabilities — and never change any of these merely to make a build, test or validation pass;
- household/user scope, RLS, cursor/version/idempotency/tombstone contracts;
- default-off sync, merge, smoke, dogfood, diagnostics or production-safety flags;
- startup, login, timer, background or Realtime sync behavior;
- verified-JWT identity derivation;
- GitHub Pages, Service Worker, package manager, lockfile, major folders or framework architecture.

Never silently enable production writes, target an unapproved environment, use service-role credentials in clients, expose secrets, or describe development evidence as production rollout approval.

Do not commit, push, open a PR, deploy, apply migrations, change hosted configuration, enable flags or touch real user data unless explicitly requested.

## 6. Spec Kit

Spec Kit (GitHub `spec-kit`, pinned at v1.0.6) is a **feature-level workflow layer for bounded
changes**. It is not a source of repository-wide truth, and it does not replace anything in
section 1 or section 2.

- `AGENTS.md` remains the single repository instruction entry point. It outranks every generated
  Spec Kit artifact — including `.specify/memory/constitution.md` — whenever the two appear to
  disagree about repository-wide source-of-truth, routing or authorization rules.
- Implementation evidence, the canonical vault (section 2), `Decisions`, the design language,
  `docs/architecture/**` and `docs/contracts/**` keep exactly the authority section 1 gives them.
  A Spec Kit artifact never supersedes them, and section 2.7 anti-drift still applies inside a
  Spec Kit workflow.
- Spec Kit owns bounded-change artifacts only: feature specification, clarification,
  implementation plan, task breakdown, consistency analysis, implementation workflow and
  convergence.
- Do **not** retroactively specify the existing application with Spec Kit.
- Do **not** copy volatile project status or canonical product facts into the constitution merely
  to fill template slots. The constitution carries durable process principles; product state and
  product decisions stay in the vault.

When it applies:

- **Skip Spec Kit** for small or local changes — a focused bug fix, a copy change, a contained
  refactor, documentation.
- **Use the appropriate Spec Kit workflow** for medium or large bounded features, migrations,
  data-model changes, sync/auth/provider-routing changes, architecture work, and similarly
  high-risk changes.

Bug and assessment extensions are deliberately not installed. Do not install one unless a task
actually requires it.

Spec Kit changes nothing about authorization. After `/speckit-implement` or `/speckit-converge`,
the ordinary rules still apply in full: real validation, the section 5 hard boundaries, the
prohibition on commit/push/PR/deploy/migrations/hosted configuration without explicit request,
the section 7 final report, and vault reconciliation under section 2.5. A generated task list is
not approval to cross any of those.

### 6.1 Integration files

| Agent | Spec Kit skills | Committed |
| --- | --- | --- |
| Claude Code | `.claude/skills/speckit-*` | yes |
| Codex CLI | `.agents/skills/speckit-*` | no — `.agents/` is gitignored |

The shared layer — `.specify/scripts/`, `.specify/templates/`, `.specify/memory/`,
`.specify/integrations/` and `.specify/workflows/` — is committed. `.specify/.gitignore` keeps
machine-local state (`feature.json`, extension config overrides) out of Git.

Because `.agents/` stays gitignored, a fresh clone or a new worktree has the Claude skills but
**not** the Codex ones. Restore them with:

    specify integration upgrade codex

Then confirm with `specify integration status` — expect `Integration status: OK`,
`Installed integrations: claude, codex` and `Missing managed files: 0`. Spec Kit itself is
installed per machine rather than per clone:

    uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v1.0.6

## 7. Required final report

```text
Summary:
- ...

Changed files:
- ...

Validation:
- Command: ...
  Result: ...
- Manual checks: ...

Data / security / environment:
- ...

Risks / assumptions / follow-up:
- ...

Documentation updated:
- PROJECT_STATUS.md: yes/no/not applicable
- CHANGELOG.md: yes/no/not applicable
```

List unrun tests and the exact next command. Never infer a pass from an older report.

For an iOS implementation task, `Validation:` must name the evidence actually obtained — the Xcode build result, the diagnostics inspected, the tests executed and their outcome, and the Preview/render inspection for visual work — and must say whether that evidence came from Xcode MCP or from the `xcodebuild` fallback. Never report an iOS change as verified or working on the strength of completed source edits alone.
