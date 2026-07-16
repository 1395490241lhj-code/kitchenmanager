# Kitchen Manager Project Workflow

This document defines how to execute one development task safely. It is not a product roadmap, architecture reference, or phase history.

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

- requested behavior
- affected layers/files
- compatibility constraints
- data-loss, security, environment, migration, or feature-flag risk
- validation plan

Stop and make the risk explicit before editing when a task may:

- migrate or clear user data
- change backup or sync contracts
- apply a database migration
- enable a flag or hosted write
- use a physical device with real local data
- point at a shared development/production-like environment
- expose a token or secret

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

## 5. Validate incrementally

Use `TESTING_RULES.md`.

Typical order:

1. syntax/compiler check for touched files;
2. focused unit/regression test;
3. affected target/suite;
4. broader Node or iOS regression when the change has cross-cutting risk;
5. manual UI/user-flow check;
6. hosted/development smoke only when required and explicitly safe;
7. physical-device validation only when the behavior depends on real device conditions.

Always run:

```bash
git diff --check
```

For PWA browser assets, review cache stamping. For flags/config, inspect both committed defaults and local ignored overrides. For secrets, inspect the diff and generated/configured artifacts without printing secret values.

## 6. Hosted and database actions

Treat these as write actions requiring explicit scope:

- applying a migration
- changing Render/Supabase configuration
- enabling a server or iOS feature flag
- running a smoke that creates remote records
- cleaning remote markers
- deploying/pushing a branch

Before a hosted smoke:

- identify the exact environment;
- use an isolated marker and least-privilege user credentials;
- ensure no service-role key is in client/runtime paths;
- confirm the cleanup method targets only the created entities;
- record pre/post residue checks;
- restore flags to their prior safe value.

Never claim a cleanup succeeded solely from UI text; verify the authoritative store/change feed/ledger where the contract requires it.

## 7. Documentation update decision

Update only the document that owns the information:

- behavior/history changed → `CHANGELOG.md`
- current project/release posture changed → `PROJECT_STATUS.md`
- stable architecture/invariant changed → `PROJECT_GUIDE.zh.md` and, if needed, its English companion
- coding policy changed → `CODING_RULES.md`
- verification policy/command changed → `TESTING_RULES.md`
- detailed design/validation evidence → focused file under `docs/`
- onboarding changed → `README.md`

Do not append full test narratives to `PROJECT_STATUS.md` or `AI_CONTEXT.md`.

## 8. Review the final diff

Before delivery:

```bash
git status --short
git diff --stat
git diff --check
```

Also review:

- every changed file, not only `git diff --stat`;
- accidental generated files, `xcresult`, DerivedData, screenshots, logs, local config, `.env`, credentials, and tokens;
- feature flags in committed and Release configuration;
- schema/migration/backup compatibility;
- whether tests actually exercised the changed path rather than merely compiling nearby code.

## 9. Commit, push, deploy

Do not commit, push, open a PR, deploy, apply migrations, or change hosted configuration unless the user requested it.

When requested:

- stage only intended files;
- use a focused commit message;
- keep local/remote branch context explicit;
- inspect CI/checks;
- do not weaken tests or safety gates to get green status;
- report deployment/environment results separately from local tests.

## 10. Delivery format

```text
Summary:
- What changed and why.

Changed files:
- Exact paths.

Validation:
- Commands and exact results.
- Manual flows checked.
- Hosted/device checks, if any.

Data / security / environment:
- Migration, backup, flags, secrets, remote writes, cleanup.

Risks / assumptions / follow-up:
- What remains and what was intentionally not done.

Documentation updated:
- PROJECT_STATUS.md: yes/no/not applicable
- CHANGELOG.md: yes/no/not applicable
```

Never say “all tests passed” when only one subsystem ran. Never use an old validation count as a substitute for testing the current tree.
