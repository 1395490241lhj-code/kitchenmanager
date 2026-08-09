# Kitchen Manager Development Workflow

This document defines how to execute one development task safely, including incremental test selection, failure handling and conversation handoff. It is not a roadmap, architecture reference or phase history. Concrete platform commands live only in [`TESTING.md`](TESTING.md).

## 1. Start with repository reality

Before editing:

```bash
git status --short
git branch --show-current
git log -1 --oneline
```

- Do not discard, reset, checkout over, or reformat unrelated existing work.
- Identify whether uncommitted changes belong to the current task.
- Resolve the exact target surface: PWA, iOS, server, Supabase, sync, shared contract, tests, or docs.
- Read `AGENTS.md`, `PROJECT_STATUS.md`, the affected code, and the affected tests.
- Follow the scoped reading route in `AGENTS.md`; do not preload every historical phase report.

## 2. Define scope and risks

Write a short implementation plan for non-trivial work that states:

- requested behavior;
- affected layers/files;
- compatibility constraints;
- data-loss, security, environment, migration, or feature-flag risk;
- validation plan.

Stop and make the risk explicit before editing when a task may:

- migrate or clear user data;
- change backup or sync contracts;
- apply a database migration;
- enable a flag or hosted write;
- use a physical device with real local data;
- point at a shared development/production-like environment;
- expose a token or secret.

## 3. Inspect the full call chain

Examples:

- PWA persistence: View → domain helper → `S`/migration/backup
- iOS persistence: View → Store/Controller → business model → persistence protocol/record/migration
- Auth: View → AuthStore/service → Keychain/session → API client
- Sync: View/controller → credential provider → coordinator → adapter/persistence → transport → Express → RPC/RLS
- AI import: UI → validation/client → Express service → upstream model → sanitizer → review/save

Do not patch only the visible symptom when the invariant lives in another layer.

## 4. Make the smallest coherent change

During implementation:

- keep unrelated refactors out of scope;
- preserve public behavior unless the request changes it;
- reuse existing helpers, protocols, tokens, error types, and test fixtures;
- keep UI, domain, persistence, transport, and database responsibilities separated;
- add regression tests near the invariant that failed;
- retain safe defaults and explicit user confirmation;
- never use documentation changes to hide an unresolved implementation gap.

For a discovered unrelated bug, document it separately unless it blocks the requested task or creates immediate data/security risk.

## 5. Select validation incrementally

Start with the smallest evidence that can prove the changed behavior. Escalate only when the change has a real broader effect.

### 5.1 Documentation, copy and presentation-only changes

- Documentation-only work checks claims, paths, links and diff consistency.
- Pure UI/copy/layout work builds the affected target and checks the necessary Preview, simulator or visual state.
- If navigation, shared state, persistence or networking also changes, use the corresponding behavior scope below.

### 5.2 A single View, ViewModel, Service or isolated module

- Run the directly related test file, class or method.
- Add the necessary syntax, compile or local runtime check.
- Do not run unrelated modules by default.

### 5.3 SwiftData, migration, auth, sync, network or cross-module contracts

- Run focused tests for the affected module and invariant.
- Add the required migration, RLS, integration, security or manual-flow evidence from `TESTING.md`.
- Escalate to a broader suite only for shared infrastructure, core data models, public routes/protocols or multi-client contracts.

### 5.4 Full-suite thresholds

Run the full unit suite only when a complete feature phase ends, a commit/merge is being prepared, shared infrastructure or a core model changes, or the user requests it. Run the full UI suite only for release gates, major completed user flows or an explicit request.

When these thresholds are not met, the final report must name the skipped suites and why they are unrelated to the current impact.

## 6. Test output, failure and retry limits

- On success, keep only the command, scope, result and necessary environment details.
- On failure, read only the failing test and nearby error context.
- For the same failing test, class, target or root cause, make at most one automatic code fix and rerun. If it still fails, stop changing code and report the failure, attempted fix, likely cause and remaining risk.
- Environment/tool failures such as simulator destination, temporary cache, package resolution, command arguments or working directory may receive at most two limited retries without business-code changes.
- A different error inside the same failing scope does not create an unlimited new retry budget.
- Never weaken assertions, disable safety checks, skip failures or run unrelated tests to manufacture green output.

## 7. Hosted and database actions

Treat these as write actions requiring explicit scope:

- applying a migration;
- changing Render/Supabase configuration;
- enabling a server or iOS feature flag;
- running a smoke that creates remote records;
- cleaning remote markers;
- deploying or pushing a branch.

Before a hosted smoke:

- identify the exact environment;
- use an isolated marker and least-privilege user credentials;
- ensure no service-role key is in client/runtime paths;
- confirm the cleanup method targets only the created entities;
- record pre/post residue checks;
- restore flags to their prior safe value.

Never claim a cleanup succeeded solely from UI text; verify the authoritative store/change feed/ledger where the contract requires it.

## 8. Documentation ownership

Update only the document that owns the information:

- current project/release posture → `PROJECT_STATUS.md`;
- notable change already in main → `CHANGELOG.md`;
- stable product principle → `docs/product/PRINCIPLES.md`;
- stable architecture/invariant → `docs/architecture/OVERVIEW.md`;
- coding policy → `docs/development/CODING.md`;
- verification policy/command → `docs/development/TESTING.md`;
- detailed design, contract, runbook, decision or historical evidence → its focused file under `docs/`;
- onboarding → `README.md`.

Do not append test narratives to current-state or product-principle documents. Full ownership rules are in [`docs/README.md`](../README.md).

## 9. Review the final diff

Before delivery:

```bash
git status --short
git diff --stat
git diff --check
```

Also review:

- every changed file, not only `git diff --stat`;
- accidental generated files, xcresult, DerivedData, screenshots, logs, local config, `.env`, credentials, and tokens;
- feature flags in committed and Release configuration;
- schema/migration/backup compatibility;
- whether tests actually exercised the changed path rather than merely compiling nearby code.

## 10. Commit, push and deploy

Do not commit, push, open a PR, deploy, apply migrations or change hosted configuration unless the user requested it.

When requested:

- stage only intended files;
- use a focused commit message;
- keep local/remote branch context explicit;
- inspect CI/checks;
- do not weaken tests or safety gates to get green status;
- report deployment/environment results separately from local tests.

## 11. Delivery format

Use the report format in `AGENTS.md`. Never say “all tests passed” when only one subsystem ran, and never use an old validation count as a substitute for testing the current tree.

## 12. Conversation handoff

Suggest a new conversation when a complete feature is finished, work is switching to a clearly different module, logs/screenshots have accumulated heavily, background files are being reread repeatedly, or a PR/phase has ended. Do not interrupt small follow-up adjustments within the same feature.

A handoff should include:

- current branch and worktree state;
- completed work;
- focused validation actually run;
- full unit/UI suites not run and why;
- recommended next task;
- minimum documents for the next conversation.

## 13. Documentation-only verification

Ordinary Markdown, Agent instruction and development-document changes do not run full Node or iOS suites by default. Check current facts, relative links, cross-references and `git diff --check`. Run a focused test only when a test, script, build step or semantic guard actually parses the changed document, or when the user explicitly requests it.
