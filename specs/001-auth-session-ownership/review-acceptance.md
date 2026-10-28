# Prepared PR1 and auth ownership: local review candidate

Recorded 2026-10-27. The cumulative independent review returned **CONDITIONAL
PASS**: no source-proven blocking defect was found, but integration and release
acceptance remain open. This bounded feature record does not advance canonical
project state or supersede an accepted product Decision.

## Scope and authorization

- Base: `207ca095311175b3ab5d09af037347c27f0ee94f`.
- Local review branch: `codex/km-pr1-auth-ownership-review`.
- One atomic candidate contains the inherited 26-file Prepared PR1 baseline and
  the validated auth-ownership integration. The 15-path cumulative integration
  overlaps three inherited paths, giving 38 reviewed paths, plus this record.
- Prepared mutations persist before publishing success; unreadable-load guards,
  UUID consumption, successful final-portion deletion and the existing no-undo
  contract remain. Recipe and sync contracts are preserved.
- Auth operations use a private provider owner spanning SDK effects, complete
  stored-session verification and acknowledged state reduction. Destructive
  cleanup is scoped to its original stores and auth context. Initiator
  cancellation does not release an admitted sign-out before settlement.
- The owner separately authorized local branch creation, staging and a reviewable
  commit after the implementation plan's earlier no-Git-write boundary. This
  authorizes no push, PR, merge, deployment, PR2 work, production mutation or
  accepted canonical-anchor advance. The earlier spec/plan/task files are
  preserved as reviewed planning artifacts; their unchecked tasks are not test
  results.

## Reused validation and source binding

All 424 native files match each of the four existing green manifests:
`corrective-gate-green-sources.json`, `corrective-focused-sources.json`,
`corrective-full-unit-sources.json` and `corrective-release-sources.json`.
Each manifest file has SHA-256:

```text
304cce4fc4ba5c87e88b7a5606c7a05edb5de4575ff78ae9328d95349395ca11
```

The retained evidence root is
`auth-ownership-integration-20261027/corrective-pass-1/`, outside Git. Its
`RESULT.md`, `validation-final.json`, `combined-integration-hashes.json`, command
records, logs, xcresults and preservation receipts own the detailed evidence.
The original phase-labelled Keychain probe, RED results and real-SDK negative
control are retained. The negative control passes by detecting actual unfenced
replacement-session erasure; it does not accept that unsafe design.

| Existing validation | Result |
| --- | --- |
| Corrective RED | 7 executed: 2 passed, 5 failed, 0 skipped; 12 failure records |
| Green gate | 8 passed, 0 failed, 0 skipped |
| Focused auth/Keychain/deletion | 85 passed, 0 failed, 0 skipped |
| Complete native unit suite | 2,687 executed: 2,682 passed, 0 failed, 5 skipped |
| Release simulator build | Succeeded; fixture/hooks absent and eight enablement flags `NO` |
| Static source/contract guards | 138 passed; not runtime acceptance |

These are source-bound existing results, not newly executed tests. The five
unit skips are credential-gated hosted-smoke tests. Validation used the documented
xcodebuild fallback with Xcode 27.2 (27B5019j), iOS 27.2 and reserved Codex
simulator `18FAEFC5-3087-48A4-8131-5B97F48D62C6`. Simulator runs used whole-command
leases and disabled parallel testing. The documentation-only local commit
preparation does not justify another full-suite run.

## Outstanding acceptance checklist

- [ ] Actual iOS cold launch and process relaunch with empty, valid and expired
  isolated sessions; actual OS background/foreground transitions, refresh
  eligibility, background suspension and foreground resumption through the
  production coordinator path. Posted notifications and adapter recreation are
  narrower evidence.
- [ ] Account deletion navigation back/reentry, caller cancellation and retry:
  retain ownership until SDK/event/ack settlement, confirm remotely once, avoid
  reclearing new local records and preserve replacement-account data. Include
  reentry around matching guest settlement. Ownership refresh currently does
  not allow the expected guest state; the review found no sustained production
  interleaving proving a blocker, so this remains an acceptance edge.
- [ ] Same-user recovery form completion/dismissal. Identical user/email recovery
  can leave the form open because dismissal observes status equality rather
  than the successful submission result. Session restoration is a separate
  outcome from form dismissal.
- [ ] Independent `kAXErrorAPIDisabled` UI testing blocker: retain separately from
  auth correctness. Attempt the isolated snapshot control only with new
  diagnostic evidence; run affected UI coverage only after the control succeeds.
  No simulator reset, security-setting change or repeated blocked-suite run.
- [ ] Physical-device Keychain/network/lock/background/relaunch behavior and
  hosted-provider behavior require separately scoped acceptance. Do not infer
  them from simulator or offline transport tests.
- [ ] Remote global-logout settlement and effects on later same-user server
  sessions remain unverified. Default global logout scope is unchanged.

## Documented follow-ups and retained boundaries

- Two warnings at the lifecycle notification closures in
  `ProviderSessionCoordinator.swift` (reviewed lines 69 and 72) are new relative
  to frozen PR1 but unchanged by the corrective pass. Current targets use Swift
  5 language mode; resolve these diagnostics before adopting Swift 6.
- Supabase Swift remains 2.51.0 at
  `27f31bfb7be836a33c89f6636ef69a2cfff9a3fd`. Its internal Keychain error lacks a
  public machine-readable status. The narrow dynamic-type/domain/exact-text
  classifier must be revalidated after relevant SDK or toolchain changes.
  SDK-facing calls preserve the original thrown error; other representations
  fail closed.
- Recovery remains process-lifetime only. Revoked-context cleanup intentionally
  stays blocked to protect newer sessions/data; no persistent recovery marker
  or authority resurrection is included.
- No SDK pin, Keychain service/key/format, signing, schema, backup, production
  environment or enablement flag is changed by commit preparation. All original
  checkouts, dirty work, protected caches and evidence must remain preserved.
- Merge and deployment need their own explicit authorization and applicable
  acceptance. This local review candidate establishes neither.
