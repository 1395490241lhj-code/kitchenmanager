# Inventory Sync Physical-Device Dogfood Checklist (Phase 2B-6, executed Phase 2B-7)

> **Phase 2B-7 update**: a physical iPhone 17 Pro (iOS 27.0) became
> available and ran the automatable/business-logic portion of this
> checklist for real — see `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`
> for the full results table and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`
> for the updated conclusion (**Dogfood Go / Production No-Go**). The
> human-gesture steps below (tapping through UI, toggling Airplane Mode,
> locking the screen) still require a person with the device in hand —
> this environment has no touch/tap-injection tool for a physical device.
> Status wording to use anywhere: **"automated + hosted-dogfood physical-
> device validation passed; human-gesture UI/network-toggle steps still
> pending."**

## Preconditions

- A personal or dedicated test iPhone with development-signing capability
  (a free Apple ID + local signing is enough — no App Store distribution
  needed).
- Two real development Supabase test accounts (already exist —
  `TEST_USER_A_EMAIL`/`TEST_USER_B_EMAIL` in the gitignored
  `.env.development.local`).
- In `ios-native/Kitchen Manager/Config/Local.xcconfig` (gitignored, never
  committed), temporarily set: `INVENTORY_SYNC_ENABLED = YES`,
  `INVENTORY_MERGE_UI_ENABLED = YES`, `INVENTORY_SYNC_DOGFOOD_ENABLED = YES`,
  `INVENTORY_SYNC_DIAGNOSTICS_ENABLED = YES`. Leave `SYNC_SMOKE_ENVIRONMENT = development`.
  Do **not** enter a password into the scheme, a launch argument, or any
  tracked file — sign in by hand on the device.
- Use only isolated marker data: every inventory item created for this
  checklist must be named `__inventory_dogfood_<short-id>` (pick one
  short-id, e.g. `d3v1c3`, and reuse it for the whole run) — never real
  personal inventory.
- Build and install the Debug configuration directly from Xcode onto the
  device (Product → Run, with the device selected as destination). This is
  a development-backend, development-Supabase build throughout; the
  Render deployment behind `.development`/`.production` is the same one
  either way (see `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md` item 2),
  so there is no separate "prod" risk from running this Debug build.

## Checklist (30 steps)

1. [ ] Install the Debug build on the device.
2. [ ] Sign in with development test account A (typed by hand, not scripted).
3. [ ] Add a few `__inventory_dogfood_<id>_*` items; confirm the Guest merge prompt appears.
4. [ ] Tap "稍后处理" (skip for now).
5. [ ] Re-enter the account page; confirm the prompt is still offered (recovery after skip).
6. [ ] Complete the merge (confirm).
7. [ ] Create a new `__inventory_dogfood_<id>_created` inventory item.
8. [ ] Tap "立即同步库存"; confirm it reaches "已同步".
9. [ ] Update that item's quantity.
10. [ ] Tap manual sync again; confirm it completes.
11. [ ] Delete that item.
12. [ ] Tap manual sync again; confirm it completes.
13. [ ] Force-quit the app (swipe up / app switcher kill) immediately after step 12's sync started, before confirming completion on-screen if possible — otherwise force-quit right after.
14. [ ] Relaunch the app.
15. [ ] Confirm the session is still signed in (no forced re-login).
16. [ ] Confirm no duplicate pending mutation or duplicate remote item resulted (check the diagnostics screen's pending/conflict counts — should be 0/0 once step 12 truly completed).
17. [ ] Trigger a conflict deliberately (edit the same marker item on two accounts/devices if possible, or simulate by editing while offline then editing again after reconnecting) and confirm the conflict screen appears and never silently auto-resolves.
18. [ ] Sign out.
19. [ ] Sign back in with the same account.
20. [ ] Switch to test account B; confirm account A's items/state are never visible.
21. [ ] Toggle Wi-Fi off, then on (or switch to cellular if available).
22. [ ] While offline, edit a marker item; confirm the app doesn't crash or hang and shows a sensible offline/pending state.
23. [ ] Reconnect network, then tap manual sync; confirm it completes and picks up the offline edit.
24. [ ] Lock the device, then unlock; confirm no crash and state is intact.
25. [ ] Background the app (Home button/swipe), then foreground it again; confirm no automatic sync was triggered while backgrounded and no crash occurred.
26. [ ] Open "库存同步诊断" (diagnostics) from the account page; confirm it shows plausible counts and no raw identifiers/tokens are visible on screen.
27. [ ] From diagnostics, run the consistency check; confirm it reports clean (or, if not, record exactly what it reports — do not dismiss a real finding).
28. [ ] If a rollback path is reachable from the current state (recently completed merge session), exercise it and confirm only this session's own created records are affected.
29. [ ] Clean up: delete every `__inventory_dogfood_<id>_*` marker item locally and via manual sync so the remote household has zero residual marker rows (verify via the diagnostics pending count reaching 0, or via `scripts/cleanup-guest-merge-smoke-markers.mjs` as a backstop).
30. [ ] Set all four flags in `Local.xcconfig` back to `NO` before ending the session.

## Reporting back

Whoever runs this should record, for each of the 30 steps: pass / fail /
notes, plus device model and iOS version. Any failure should be filed as a
Blocker or High finding against
`docs/INVENTORY_SYNC_RELEASE_READINESS_PHASE2B5.md`'s triage table before
`docs/INVENTORY_SYNC_GO_NO_GO.md` can move past No-Go on this axis.
