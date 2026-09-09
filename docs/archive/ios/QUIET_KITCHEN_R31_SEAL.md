# Quiet Kitchen R3.1 production migration seal

Disposition: **PASS WITH DOCUMENTED BASELINE REDS**, explicitly accepted by the project owner on 2026-09-09. This is not an all-green test result.

## Integrated scope

Normal fast-forward push to main: `7fc84e2` → `7a69893` → `aa42abf` → `45b5022`.
`7a69893` is the separately validated Swift concurrency fix. The two R3.1 commits change only `AppTheme.swift`, `KitchenTheme.swift`, `HomeView.swift`, and `InventoryControlStrip.swift` under `ios-native/Kitchen Manager/KitchenManager/`.
The migration is presentation-only. Models, persistence, sync, providers, AI pipelines, routes and tests are unchanged. Planner inherits the shared tokens without a page-specific change. The research app is not shipped.

## Evidence and owner disposition

Recovered `/private/tmp/r31-final-gate.xcresult`: 1804 passed / 6 failed / 6 skipped. Recovered `/private/tmp/r31-retry.xcresult`: 3 passed / 3 failed. These local bundles are not committed and are not permanent portable evidence.

| Failure | Accepted disposition |
|---|---|
| `PlannerRegressionUITests.testLightAccessibilityMatrix` | Event-synthesis timeout; focused retry passed; infrastructure flake. |
| `PlannerUITests.testEditAndDeleteFlow` | Focused retry passed; infrastructure flake. |
| `ProductionDesignLanguageUITests.testDarkAccessibilityXXXL` | Screenshot timeout; focused retry passed; infrastructure flake. |
| `SettingsExperienceUITests.testCoreSettingsEntriesRemainReachable` | Reproduced on clean `7a69893`; Settings unchanged; pre-existing baseline failure, out of scope. |
| `ShoppingRegressionUITests` accessibility matrices | Shopping source unchanged; Dark reproduced on clean baseline; Light accepted by owner as baseline-flaky around scroll-reveal / scrollbar detection; out of scope. |

Additional evidence explicitly reaffirmed by the owner: Release simulator `BUILD SUCCEEDED`; focused Home / Inventory suites passed; canonical Home → Planner route verified. These are accepted prior-run evidence, not newly executed checks during sealing.

Fresh recovery checks: migration worktree clean; intended four-file migration scope; `git diff --check` passed; fetched origin/main was exactly `7fc84e2`; expected three-commit range matched. Normal push verified remote main at `45b5022155a4e3fce1263139aae43bea9c9cb48c`, local/remote ahead-behind 0/0. A subsequent documentation-only reconciliation commit does not alter this tested source tree.

## Follow-up boundary

Settings reachability and Shopping accessibility matrices require independent follow-up work. Acceptance does not authorize fixing, suppressing, deleting or weakening tests in this migration. No fresh full-suite or Release rerun was performed for documentation reconciliation. No flags, hosted configuration, migrations or user data were changed; this seal is not App Store or production environment enablement.
