# Implementation plan

1. Verify baseline, canonical anchor, pinned SDK and frozen file receipts. Create separate managed worktree, copy only 26 inherited PR1 files, record paths.
2. Add real-SDK service-boundary regressions before implementation; keep original red source/evidence frozen.
3. Implement private provider-owned FIFO, monitored existing storage, synchronous SDK event inbox and independent acknowledged consumer. Route bootstrap/restore/auth/refresh/logout/error removal through it. Preserve production storage configuration and logout scope.
4. Connect AuthStore reduction and opaque context ownership; invalidate stale deletion authorization across fresh contexts and awaited cleanup. Present unavailable authority with existing sign-in recovery.
5. Exercise reserved-simulator tests under whole-command lease with offline transport and uniquely scoped Keychain service; controlled continuations/clock and UIKit lifecycle notifications. Attempt one snapshot control only with new diagnostic evidence.
6. Focused then full required unit tests, Release simulator build, negative controls, source hashes, independent focused review, diff/report. No commit or integration into frozen PR1.

Compatibility: no Keychain migration/format change, no fresh SDK/dependency tree, no credentials or real kitchens. Refresh timer remains enabled through coordinator with 30-second ticks, three-tick threshold, immediate foreground eligibility and background suspension.
