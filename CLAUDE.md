# CLAUDE.md

Claude Code must use `AGENTS.md` as the single repository instruction entry point.

Claude Code must also follow [`docs/AI_WORKFLOW.md`](docs/AI_WORKFLOW.md) for incremental test selection, test escalation, failure retry limits, concise test output, and new-conversation handoffs. Keep concrete commands and platform matrices in `TESTING_RULES.md`.

Before changing code:

1. Read `AGENTS.md`.
2. Read `docs/AI_WORKFLOW.md`.
3. Read `PROJECT_STATUS.md`.
4. Follow the task-specific reading route in `AGENTS.md`.
5. Inspect the affected code and tests before editing.

Do not maintain a second copy of project architecture or phase status in this file. In particular, do not assume this is only a browser PWA: the repository also contains a native SwiftUI/SwiftData client, Express auth/sync APIs, and Supabase infrastructure.

Follow `CODING_RULES.md`, select tests from `TESTING_RULES.md`, and use the final report format defined in `AGENTS.md`.

Never commit, push, deploy, apply a migration, enable a hosted feature flag, or touch real user data unless the user explicitly requests it.
