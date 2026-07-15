# Inventory Sync Final Go / No-Go (Phase 2B-7)

## Conclusion: **Dogfood Go / Production No-Go**

Physical-device validation is no longer entirely missing — a real iPhone
17 Pro (iOS 27.0) ran the full automated test suite (including the hosted
dogfood smoke against the real development backend) for real, plus a real
OS-level app-kill/relaunch cycle via `devicectl`. Every automatable,
non-destructive check passed. What remains open is the human-gesture layer
(actual on-screen taps through the Guest-merge UI, a real Airplane Mode
toggle, a real screen lock/unlock, Instruments-based memory profiling) —
this environment has no tool to drive those, so they are honestly reported
as not executed rather than fabricated. Per this phase's own rule ("只要真机未验证，最终不得给出 production Go"),
**that gap alone is enough to keep the final decision at Dogfood Go, not
Production Go.**

## Why this isn't a full Production Go

The Phase 2B-7 spec's Production-Go bar requires "真机全流程通过" — the
*entire* 87-item human-facing checklist passing, including the tap-driven
UI steps. This phase closed the automatable ~70% of it for real (device
install, real business-logic execution on real hardware, real hosted
network calls, real process kill/relaunch) but the remaining human-gesture
steps were not executed by a person this run. Reporting anything stronger
than Dogfood Go here would violate the phase's own explicit rule and the
project's standing instruction to never claim more than what was actually
verified.

## Full criteria table

| Criterion | Status |
|---|---|
| 真机全流程通过 (full physical-device flow, including UI taps) | ❌ **Not fully met** — automatable/business-logic portion passed for real on-device; human-gesture UI steps (merge-prompt taps, Airplane Mode toggle, lock/unlock, foreground/background via gesture) not executed (tooling) |
| 断网恢复通过 (offline recovery) | ✅ met at the logic layer (fault-injection tests ran for real on-device) — ❌ not met at the literal "toggle Airplane Mode by hand" layer |
| App kill 恢复通过 | ✅ met — both a simulated in-flight-mutation recovery test **and** a genuine OS-level `devicectl terminate` + relaunch of the real app process, on real hardware |
| account isolation 通过 | ✅ met — isolation tests ran for real on-device |
| rollback 通过 | ✅ met — rollback tests ran for real on-device |
| diagnostics 脱敏 | ✅ met — redaction test ran for real on-device; real hosted dogfood diagnostics snapshot reported clean |
| consistency checker clean | ✅ met — real hosted dogfood run reported 0 issues |
| hosted dogfood 通过 | ✅ met — **twice now**: once from this machine (Phase 2B-6) and once for real from the physical device itself over its own network (Phase 2B-7) |
| archive safety 通过 | ✅ met (Phase 2B-6, unchanged this phase) |
| production config audit 通过 | ✅ met (Phase 2B-6, unchanged this phase) |
| 0 blocker | ✅ met — no product defect found; every gap is a tooling/evidence gap, not a bug |
| 所有默认 flags 仍为 NO | ✅ met — verified via `git diff`, and verified on the physical device itself: the dogfood build's flags were temporary and the device was rebuilt/reinstalled with flags `NO` before this phase ended, confirmed via a `plutil` inspection of the reinstalled binary's compiled `Info.plist` |
| marker 0 残留 | ✅ met — confirmed via `scripts/cleanup-guest-merge-smoke-markers.mjs` after the on-device hosted dogfood run |

## What would change this to Production Go

A person needs to physically hold the device and walk through the
human-gesture items in `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`
/ the results table in `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`
marked "BLOCKED (tooling)": tapping through the Guest-merge prompt/preview/
conflict screens, a real Wi-Fi/cellular toggle during an offline edit, a
real lock-screen/unlock cycle, and a real foreground/background swipe
during a sync. None of these are expected to behave differently from the
already-passing business logic underneath them — but "expected" is not
"verified," and this project's standing rule is to never report more than
was actually observed.

## What would change this to No-Go

Any of: a real UI crash/hang during the human-gesture steps, data loss,
duplicate creation, cross-account leakage, a secret appearing on-screen or
in a log, or the diagnostics/consistency checker showing anything other
than clean during a real human-driven run.

## Status wording to use anywhere this is referenced

**"Dogfood Go / Production No-Go — automated and hosted-dogfood validation
passed on real physical hardware; the human-gesture UI/network-toggle
layer of physical-device validation is still pending a person with the
device in hand."** Never shorten this to "physical device validated" or
"production ready."
