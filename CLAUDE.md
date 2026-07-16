# CLAUDE.md

Claude Code must use `AGENTS.md` as the single repository instruction entry point.

Before changing code:

1. Read `AGENTS.md`.
2. Read `PROJECT_STATUS.md`.
3. Follow the task-specific reading route in `AGENTS.md`.
4. Inspect the affected code and tests before editing.

Do not maintain a second copy of project architecture or phase status in this file. In particular, do not assume this is only a browser PWA: the repository also contains a native SwiftUI/SwiftData client, Express auth/sync APIs, and Supabase infrastructure.

Follow `CODING_RULES.md`, select tests from `TESTING_RULES.md`, and use the final report format defined in `AGENTS.md`.

Never commit, push, deploy, apply a migration, enable a hosted feature flag, or touch real user data unless the user explicitly requests it.
