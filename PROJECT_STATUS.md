# Kitchen Manager — Current Project Status

> [!note] Point-in-time snapshot — not canonical current state
> This document is a **point-in-time project status snapshot**. Its test counts and
> implementation status reflect the commit and date recorded in "Last verified" below,
> not necessarily the current repository state.
>
> **Canonical current project state lives in the Obsidian project memory referenced by
> [`AGENTS.md`](AGENTS.md) section 2 ("Project memory").** Current test runs and repo
> evidence outrank this snapshot; see `AGENTS.md` section 1 for the full source-of-truth
> order.
>
> The body below is preserved as the audit record it was written to be.

## Last verified

- Date: 2026-08-21
- Commit: `b6a669e` (`chore(agents): normalize project skill installs and track skills lock`) — release-readiness audit baseline
- Branch: `main`
- Repository state at verification: tracked files were clean before this batch's release-readiness edits. The existing untracked `.agents/` workspace remains outside the tracked project state.
- Verification scope: release-readiness audit plus the deterministic fixes it identified (sync 429 mapping, export-compliance key, blocking archive-guard CI step, stale release docs). Production release posture and hosted verification gaps remain unchanged.

## Release-readiness audit (2026-08-21)

Validated at `b6a669e`: `npm test` 1781/1781 pass; iOS Release build
succeeds; `npm run ios:release:check` and `npm run ios:archive:guard`
(all 9 checks) pass.

Resolved since the original `0b162ba` blocker audit:

- APP-ICON-001 — real 1024×1024 AppIcon asset exists; `appIconPresence` PASS.
- CI-ARCHIVE-GATE-001 — `continue-on-error` removed; the archive guard now gates CI.
- Sync `429` responses now map to `SyncError.rateLimited` with `retryAfter` preserved (previously collapsed to `.transport`, making the rate-limit backoff path unreachable).
- `ITSAppUsesNonExemptEncryption = false` declared, so uploads no longer stall on Missing Compliance.

Known open items are unchanged below; additionally
`ReceiptCompactListUITests/testReceiptList_twentyItems_isCompactAndScrollable`
is flaky under a full-suite run (passes in isolation) and is not yet addressed.

> [!warning] Correction (2026-08-27) — the "passes in isolation" half is no longer true
> The audit sentence above is preserved as written on 2026-08-21. Its characterization
> has since been disproved. On Xcode 27.0 / iOS 27 simulator the test fails in a full
> suite run **and** when run on its own, and the same failure reproduces at the same
> file, line and assertion (`ReceiptCompactListUITests.swift:127`) on an unmodified
> `4838e8f` baseline worktree build. The sibling test in that file passes on both builds.
>
> Correct classification: **pre-existing baseline-reproduced Receipt UI failure**. It is
> not a Home V2 regression and not a passes-in-isolation flake. Receipt code is unchanged.

## P3 delivery checkpoint

P3-A, P3-B and P3-C are sealed at `21500bc`:

- P3-A: shared `EditableRecipeDraft` save eligibility, deterministic Recipe/Cooking fixtures, GuestMerge persistence isolation and restored `npm test` baseline.
- P3-B: parallel Groq/Gemini text providers; `/api/ai-chat` text and vision use the unified OpenAI SDK transport; vision remains Groq-only. `maxRetries: 0`, 45-second timeout, request-id propagation and safe error contract are preserved.
- P3-C: deterministic post-extraction Import seed, real “保存到菜谱库” flow verification, Normal and Accessibility XXXL hit-target verification, and zero-network/zero-paid-AI UI coverage.

Deferred backlog:

- `Recipe.samples` onboarding/product decision.
- Media OCR frame direct Axios POST.
- Dead `RecipeImportOptionsView` cleanup.
- Repo-wide accessibility-identifier cleanup.
- Hosted Groq/Gemini verification.

## Current release posture

- Kitchen Manager is a **Production Go Candidate with conditions**, not Production Enabled.
- Every actual release stage remains **No-Go** until its operational prerequisites are closed; see [`docs/archive/release/V1_RELEASE_BLOCKERS.md`](docs/archive/release/V1_RELEASE_BLOCKERS.md).
- PWA and iOS core local features remain usable in Guest mode.
- Inventory sync and Guest merge are implemented and substantially validated, but all committed sync, merge, smoke, dogfood and diagnostics flags remain `NO`.
- There is no production cohort, production Supabase project, live crash/alert provider or App Store/TestFlight distribution path.

## Active workstreams

- Production-enablement preparation: environment isolation, distribution signing/App Store Connect, monitoring and a shared rate-limit store.
- Hosted Groq/Gemini verification remains deferred; the deployed environment and live receipt-image path require external confirmation outside this checkout.
- Recipe/source data quality: current 《大众川菜》 source-restoration scope is closed, while its accepted source limitations and App-readiness work remain separate follow-ups.

## Current blockers / operational gaps

- A separate production Supabase project has not been provisioned; the existing project is the development environment.
- Distribution-class signing, an App Store Connect app record and uploaded TestFlight build do not exist.
- Crash reporting ships only a no-op provider; no SDK/DSN sends events. Backend metrics/logging exist, but no alert provider or dashboard is connected.
- `/api/sync/*` rate limiting uses an in-memory store suitable only for the current single-instance Stage 1 boundary.
- Account deletion is implemented and locally validated against disposable Supabase, but hosted-development and production completion remain unverified.
- Public recipe-import diagnostics still need the documented privacy-hardening pass before production exposure.
- Hosted Groq/Gemini configuration and live image verification remain outside this checkout.

## Next milestones

1. Provision and validate the separate production Supabase project without enabling client sync flags.
2. Complete Apple Developer/App Store Connect prerequisites and produce a distribution-class signed archive before Internal TestFlight.
3. Integrate production monitoring choices: crash provider/consent, alert routing and shared sync rate-limit storage.
4. Validate hosted account deletion and the deployed receipt-image AI path with isolated test data.
5. Complete diagnostics privacy hardening before broader production rollout.

## Completed capability summary

- Web/PWA: native HTML/CSS/JavaScript application with `localStorage`, Service Worker, inventory, planning, recipes, shopping, recommendations, AI-assisted imports and backup/restore.
- Native iOS: SwiftUI/SwiftData client for the core kitchen flows, Keychain-backed account sessions, accessible native Home/Inventory/Recipe/Shopping/Settings experiences, Cooking Mode and URL Share Extension import.
- Auth/sync: Guest-first email/password auth, `/api/me`, household/user scope separation, authenticated inventory bootstrap/pull/mutations, idempotency, version conflicts, tombstones and change feed.
- Guest merge: remote read-only preview, explicit conflict choices, stable keep-both identity, manual sync, bounded/coalesced mutations, diagnostics and scoped rollback.
- Safety/operations: minimum-app-version gate, sync rate limiting, structured backend logging/request IDs/health checks, no-op crash-reporting abstraction, local migration replay/pgTAP and release/archive guards.
- Account lifecycle: account deletion, ownership handling, anonymization, real email/password reauthentication and fail-closed Admin-capability checks are implemented; hosted validation remains open.
- Recipe quality: recommendation matching/session behavior, import grounding, evidence preservation and deterministic runtime checks are present in current main.
- 《大众川菜》当前来源范围已收尾：147 条均有归属，39/39 source-ready new-recipe-candidates were promoted，58 remain explicitly blocked，`applicationReady=false`；详细证据见 [`data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md`](data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md)。
