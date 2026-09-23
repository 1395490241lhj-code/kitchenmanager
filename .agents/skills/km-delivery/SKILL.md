---
name: km-delivery
description: Use to close Kitchen Manager work: final diff, truthful validation report, documentation ownership, authorized commit/push/PR, remote verification, and vault reconciliation.
---

# Kitchen Manager Delivery

Close only the work actually completed and verified. Do not turn delivery into an opportunity for unrelated cleanup.

## Review the final tree

Before delivery, inspect:
- `git status --short`;
- `git diff --stat`;
- `git diff --check`;
- every changed file;
- accidental generated files, xcresult/DerivedData/screenshots/logs/local config/secrets;
- affected feature flags and compatibility boundaries;
- whether tests exercised the changed behavior rather than merely compiling nearby code.

Follow `docs/development/WORKFLOW.md` §§8–10 for documentation ownership, final-diff review and write-action rules.

## Respect authorization

Do not commit, push, open a PR, deploy, apply migrations, change hosted configuration, enable flags or touch real user data unless the user explicitly requested that action.

When commit/push is requested:
- stage only intended files;
- use a focused commit message;
- keep local/remote branch state explicit;
- do not weaken tests or safety gates to obtain green status;
- verify the resulting local/remote truth rather than assuming a successful-looking command was enough.

## Reconcile canonical memory

After meaningful verified work, invoke `km-project-memory` and reconcile only the notes warranted by the change. Advance the vault `head_commit` only after the relevant work is committed and the vault is reconciled through that exact commit.

If the vault is unavailable, include the exact `VAULT UPDATE` instructions required by `km-project-memory` instead of inventing an in-repo substitute.

## Final report

Use this compact shape:

```text
Summary:
- ...

Changed files:
- ...

Validation:
- Command/tool: ...
  Result: ...
- Manual/render checks: ...
- Not run: ...

Data / security / environment:
- ...

Risks / assumptions / follow-up:
- ...

Documentation updated:
- ...
```

For iOS work, follow `km-ios-validation` reporting requirements and identify whether evidence came from Xcode MCP or xcodebuild fallback.

Never say “all tests passed” unless all relevant named suites actually ran. Never substitute an old run for current-tree evidence.
