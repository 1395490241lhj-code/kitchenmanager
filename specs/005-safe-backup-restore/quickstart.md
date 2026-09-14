# Quickstart: Safe backup restore

**Feature**: 005 | **Branch**: `codex/005-safe-backup-restore` | **Base**: `dbb7bce`

## What this feature is

Backup import currently goes from "member taps a file" straight to "seven data domains replaced",
with no validation of whether the file is even a Kitchen Manager backup. This feature puts a
validation gate and an explicit decision in front of that, keeps a durable copy of the pre-import
data, and replaces the single success/error string with five distinguishable outcomes.

## What it is not

It does not make restore atomic. Seven independent persistence commits remain seven independent
commits. The product promise is a successful restore **or** a truthful recovery result -- never a
claim of atomicity. It also does not touch clear-local-data, sync, the backup payload's contents,
or the Settings information architecture.

## Orientation

Read in this order:

1. `spec.md` -- Problem, then User Story 1 (the catastrophic path) and its acceptance scenarios.
2. `research.md` R1 (why validation is separate from decoding) and R3 (the recovery decision and
   the alternatives that lost).
3. `research.md` R5 -- the four persistences whose failed saves poison the compensating write.
   This is why Phase 3 comes before Phase 4.
4. `plan.md` Phases, then `tasks.md`.

## The one invariant to hold in mind

Nothing persistent may change until all six of these have happened, in order: file read, decode,
validation, preview shown, member confirmation, recovery copy created. Every task in Phase 2
through Phase 6 either establishes that boundary or proves it. If a change makes that boundary
harder to observe in a test, it is the wrong change.

## Key evidence for anyone verifying the premise

- `format` and `version` exist on `KitchenBackupPayload` and have no readers anywhere in the repo.
- `decodeIfPresent ?? []` on every field means `{}` is a structurally valid backup today.
- `restoreBackupData`'s compensation uses `try?` throughout, so rollback failure is silent.
- Shopping, consumption, prepared components and special plans hold long-lived `ModelContext`s and
  do not clean up after a failed save; today plan, weekly plan and user recipes do.
- `reconcileInventoryFromPersistence()` is the existing pattern for re-establishing in-memory
  state from disk, and it covers inventory only.

## Running the focused validation

Unit and failure-injection coverage:

```bash
xcodebuild test -project 'ios-native/Kitchen Manager/Kitchen Manager.xcodeproj' \
  -scheme KitchenManager -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:KitchenManagerTests/BackupRestoreSafetyTests
```

The existing Settings suite must keep passing unchanged:

```bash
xcodebuild test -project 'ios-native/Kitchen Manager/Kitchen Manager.xcodeproj' \
  -scheme KitchenManager -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:KitchenManagerUITests/SettingsExperienceUITests
```

Test target names are the expected ones; the acceptance criterion is coverage, not a filename.
