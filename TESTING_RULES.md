# TESTING_RULES.md

This file defines how to verify changes in Kitchen Manager.

A task is not complete just because code was edited. It should pass the appropriate automated and manual checks.

---

## 1. Main Commands

Use the commands supported by this repository:

```bash
npm install
npm start
npm test
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

Current meanings:

- `npm start` runs `node server.js`.
- `npm test` runs `node --test`.
- `npm run validate:recipe-packs` validates recipe pack samples.
- `npm run validate:recipe-pack-data` validates recipe pack data.

There is no frontend build command because the app is a no-build static ES module PWA.

---

## 2. Minimum Completion Criteria

A task can be considered complete only when:

1. The requested behavior is implemented.
2. Relevant automated tests pass or failures are clearly explained.
3. The app can still start locally when runtime behavior is affected.
4. The related user flow is manually checked when UI behavior is affected.
5. No obvious browser console errors are introduced.
6. User data safety is preserved.
7. API Keys/secrets are not exposed.
8. Relevant docs are updated when project behavior or rules change.

---

## 3. Test Selection Guide

### Docs-only change

Run:

```bash
npm test
```

If not run, explain why. No manual app test is usually required.

### Pure domain logic change

Run:

```bash
npm test
```

Also run targeted tests while developing when useful:

```bash
node --test test/<relevant-test-file>.mjs
```

### Recipe data or recipe pack change

Run:

```bash
npm test
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

### Server/API/AI change

Run:

```bash
npm test
npm start
```

Then manually test the relevant API-backed feature through the app if possible.

### Frontend JS/CSS/UI change

Run:

```bash
npm test
npm start
```

Then open:

```text
http://localhost:3000
```

Manual check on a mobile-sized viewport around 390px width.

### PWA/cache-related change

Run:

```bash
npm test
```

Then manually check:

- Initial page load.
- Hard refresh.
- `sw-reset.html` behavior if relevant.
- Whether version stamping or Service Worker cache name change is needed.

---

## 4. Manual Regression Checklist

Use the relevant sections for the changed area.

### Kitchen home / today page

Check:

- Default route redirects to `#today`, and `#today` loads the kitchen home page.
- Today plan displays correctly.
- Recommendation preview does not crash.
- Empty/demo/real-data states are understandable.
- Main quick actions are visible on mobile.

### Inventory

Check:

- Add inventory item.
- Edit quantity/status where supported.
- Out-of-stock/low-stock state still behaves.
- Expiry indicators still display.
- Refresh page and confirm data persists.
- No raw `localStorage` key drift.

### Shopping list

Check:

- Manual item add/edit/done behavior.
- Missing ingredients can be added from recipe/plan flow.
- Purchased items can be stocked in.
- Any newly added shopping item field survives refresh.
- Seasonings are not added noisily unless intended.

### Recipe library and recipe detail

Check:

- Recipe list loads.
- Recipe detail loads.
- Ingredients and seasonings are separated correctly.
- Add to today plan still works.
- Missing ingredient flow still works.

### Recipe editor / overlay

Check:

- Existing recipe can be edited.
- Custom recipe can be saved where supported.
- Reset still returns to base + completion overlay behavior.
- User edits do not overwrite base data files.
- Refresh preserves overlay changes.

### Today plan / cooking completion

Check:

- Add recipe to today plan.
- Missing core ingredients prompt works.
- Cooking completion opens the confirmation/calibration flow.
- Inventory deduction only happens after user confirmation.
- Completed items render correctly.

### Staples / pantry shelf

Check:

- Toggle stocked/low/empty behavior.
- Changes affect recommendation/shopping state if intended.
- Refresh preserves state.

### AI recipe drafting/import

Check:

- Loading state appears.
- Success response is reviewable.
- Invalid/malformed AI output does not crash the app.
- Warnings/uncertainty are visible.
- Failed API call gives a useful fallback.
- No API Key appears in logs or UI unintentionally.

### Receipt/image recognition

Check:

- Image selection works.
- Recognition result requires confirmation before inventory write.
- Failure offers a fallback path such as retry or text entry.

### Link/Xiaohongshu/media import

Check:

- Invalid link fails gracefully.
- Short/weak extraction is marked uncertain.
- No fake complete recipe is created from insufficient source data.
- Server error response is understandable.
- SSRF/rate-limit behavior is not bypassed.

### Backup and restore

Check:

- Export works.
- Backup does not include API Key.
- Import asks for confirmation.
- Import/restore does not silently destroy existing data.
- New persisted fields are included when appropriate.

### Theme and mobile UI

Check:

- Light theme.
- Dark theme.
- 390px mobile viewport.
- No horizontal overflow.
- Tap targets are usable.
- New CSS uses tokens or has dark-mode coverage.

---

## 5. CI / Deployment Expectations

The GitHub Pages workflow runs the test suite before deployment. A test failure should block deployment.

Agents should not weaken CI just to make a change pass.

Do not remove tests unless they are demonstrably obsolete and the reason is documented.

---

## 6. Version and Cache Check

When frontend files are changed, especially imported JS/CSS:

1. Check whether cache-busting query params need updating.
2. Prefer:

```bash
node scripts/stamp-version.js
```

3. If Service Worker cache needs invalidation, review `sw.v18.js` `CACHE_NAME`.
4. Mention cache/version actions in the final report.

---

## 7. Final Report Template

Use this format at the end of a task:

```text
Summary:
- ...

Changed files:
- ...

Testing:
- npm test: pass/fail/not run
- npm start: checked/not checked
- Manual checks: ...

Risks / TODOs:
- ...

Documentation updated:
- PROJECT_STATUS.md: yes/no
- CHANGELOG.md: yes/no
```

If a command fails, include the exact command and a short error summary.
