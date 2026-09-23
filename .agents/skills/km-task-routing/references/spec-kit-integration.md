# Spec Kit integration recovery

Read this only when a Kitchen Manager task requires Spec Kit and the generated Codex integration is missing or unhealthy.

## Authority boundary

Spec Kit artifacts remain bounded feature work products. They do not override `AGENTS.md`, implementation evidence, canonical project memory, accepted Decisions, design language, architecture/contracts, testing ownership, or hard boundaries.

The shared committed layer is `.specify/scripts/`, `.specify/templates/`, `.specify/memory/`, `.specify/integrations/` and `.specify/workflows/`. Machine-local Spec Kit state remains ignored.

Claude Code `speckit-*` skills under `.claude/skills/` are committed. Codex `speckit-*` skills under `.agents/skills/` are generated and ignored.

## Restore Codex integration

From the repository root:

```bash
specify integration upgrade codex
specify integration status
```

Expect the status to report the Claude and Codex integrations installed and zero missing managed files.

Spec Kit is pinned for this project at v1.0.6. If the machine-level CLI itself is absent, install the pinned version:

```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v1.0.6
```

Bug and assessment extensions are deliberately not installed. Do not add one unless a task actually requires it.
