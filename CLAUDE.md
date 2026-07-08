# CLAUDE.md

Claude Code should use this repository's shared agent instructions.

Before making code changes, read these files in order:

1. `AGENTS.md`
2. `PROJECT_GUIDE.zh.md`
3. `PROJECT_GUIDE.md`
4. `PROJECT_WORKFLOW.md`
5. `PROJECT_STATUS.md`
6. `AI_CONTEXT.md`
7. `CODING_RULES.md`
8. `TESTING_RULES.md`
9. `CHANGELOG.md`
10. `README.md`
11. `package.json`

Important reminders:

- This is a no-framework, no-build, local-first ES module PWA with a lightweight Express server.
- Do not introduce React/Vue/Svelte/TypeScript/Tailwind/Vite unless explicitly approved.
- Do not change `localStorage` keys, hash routes, backup behavior, API Key handling, or deployment workflow without explicit approval.
- Run relevant tests from `TESTING_RULES.md` before finalizing.
- Update `PROJECT_STATUS.md` and `CHANGELOG.md` after meaningful changes.
