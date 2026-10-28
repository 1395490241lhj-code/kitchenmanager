# Bounded iOS auth-session ownership

Approved direction: 2026-10-27 approach 2 and pinned Supabase 2.51.0 feasibility; not production acceptance.

A private provider client is the sole session writer. Admission spans SDK effects and acknowledged state reduction. New authentication contexts invalidate old destructive authority; ordinary refresh retains context. Unknown origin/storage failure blocks credentials/destructive authority without erasing data and permits later fresh authentication. Preserve Keychain service/key/encoding, global logout scope, refresh capabilities and local-only recovery.

No backend/SDK/schema/backup/storage-format/sync flag change, PR2, durable recovery, staging/commit/push or hosted data. Original PR1 and dirty checkout stay frozen.

Acceptance: real-SDK writer ordering and negative control; full session storage equality; cancellation/failures/unknown-origin; same-user fresh context vs refresh; isolated simulator Keychain; iOS lifecycle/restore/refresh; deletion one-confirmation/retry/context isolation; Prepared/restore/recipe regressions; full unit suite and Release build. UI affected suite remains blocked until a single isolated snapshot control succeeds with new evidence.

Stop on uncontrolled iOS SDK writer, refresh regression, no settlement boundary, storage/publication divergence, unapproved scope or retry limit.
