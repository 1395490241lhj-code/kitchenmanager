# Kitchen Manager — Current Project Status

## Last verified

- Date: 2026-08-16
- Commit: `21500bc` (`fix(ios): make imported recipe save flow verifiable`) — stable P3 delivery checkpoint
- Branch: `main`
- Repository state at verification: `HEAD` and `origin/main` had `0 0` divergence; tracked files were clean. The existing untracked `.agents/` workspace remains outside the tracked project state.
- Verification scope: P3 delivery closeout; production release posture and hosted verification gaps remain unchanged.

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
