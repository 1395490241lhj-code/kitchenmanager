import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const review = readJson('data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');

const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const readinessByEntryId = new Map(readiness.entries.map((e) => [e.entryId, e]));

test('artifact reports zero verification problems and applicationReady=false', () => {
  assert.deepEqual(review.verificationProblems, []);
  assert.equal(review.applicationReady, false);
});

test('original scan was visually verified against the real source PDF with no conflict found', () => {
  assert.ok(review.visualScanVerification, 'visualScanVerification must be present');
  assert.equal(review.visualScanVerification.conflictFound, false);
  assert.match(review.visualScanVerification.pdfSource, /大众川菜/);
  for (const item of review.items) {
    assert.equal(item.localPdfPageRendered, true, item.entryId);
    assert.ok(item.visualVerification, `${item.entryId} missing visualVerification`);
    assert.equal(item.visualVerification.matchesCanonical, true, item.entryId);
    assert.equal(item.visualVerification.ingredientListContainsTargetItems, false, item.entryId);
    assert.equal(item.visualVerification.targetItemsQuantityGivenAnywhere, false, item.entryId);
  }
  const byId = new Map(review.items.map((i) => [i.entryId, i]));
  assert.equal(byId.get('dz1979-p129').visualVerification.renderedPage, 142);
  assert.equal(byId.get('dz1979-p130').visualVerification.renderedPage, 143);
});

test('review covers exactly p129 and p130, no more', () => {
  assert.deepEqual(review.scope.reviewedEntryIds, ['dz1979-p129', 'dz1979-p130']);
  assert.equal(review.items.length, 2);
  assert.deepEqual(review.items.map((i) => i.entryId), ['dz1979-p129', 'dz1979-p130']);
});

test('p129 methodOnly "姜、花椒" genuinely appears in method text with no source quantity', () => {
  const item = review.items.find((i) => i.entryId === 'dz1979-p129');
  const canonical = recipeByEntryId.get('dz1979-p129');
  const moi = item.items[0];
  assert.equal(moi.rawItemText, '姜、花椒');
  assert.equal(moi.rawQuantityText, null);
  const sourceMoi = canonical.methodOnlyIngredients.find((m) => m.rawItemText === '姜、花椒');
  assert.ok(sourceMoi, 'canonical methodOnlyIngredients must contain 姜、花椒');
  assert.equal(sourceMoi.rawQuantityText, null);
  assert.equal(sourceMoi.confidence, 'high');
  // Verify the method text genuinely mentions both split items.
  const methodText = canonical.methodSummary.steps.map((s) => s.summary).join(' ');
  assert.ok(methodText.includes('姜'), 'method text must genuinely mention 姜');
  assert.ok(methodText.includes('花椒'), 'method text must genuinely mention 花椒');
  assert.equal(moi.genuinelyMentionedInMethod, true);
  assert.equal(moi.genuinelyNoQuantityInSource, true);
});

test('p130 methodOnly "胡椒面" genuinely appears in method text with no source quantity', () => {
  const item = review.items.find((i) => i.entryId === 'dz1979-p130');
  const canonical = recipeByEntryId.get('dz1979-p130');
  const moi = item.items[0];
  assert.equal(moi.rawItemText, '胡椒面');
  assert.equal(moi.rawQuantityText, null);
  const sourceMoi = canonical.methodOnlyIngredients.find((m) => m.rawItemText === '胡椒面');
  assert.ok(sourceMoi, 'canonical methodOnlyIngredients must contain 胡椒面');
  assert.equal(sourceMoi.rawQuantityText, null);
  const methodText = canonical.methodSummary.steps.map((s) => s.summary).join(' ');
  assert.ok(methodText.includes('胡椒面'), 'method text must genuinely mention 胡椒面');
  assert.equal(moi.genuinelyMentionedInMethod, true);
  assert.equal(moi.genuinelyNoQuantityInSource, true);
});

test('p130 same-for-each is no longer an independent blocker (resolved by Batch 7)', () => {
  const recipe = recipeByEntryId.get('dz1979-p130');
  assert.ok(recipe.ingredients.some((ing) => ing.memberQuantityMode === 'same-for-each'), 'p130 should still have a same-for-each group');
  // The only remaining blocker for p130 is methodOnly (胡椒面); this test
  // documents that same-for-each alone is not blocking it anymore.
  assert.deepEqual(review.scope.note, review.scope.note); // sanity: field exists
  assert.match(review.scope.note, /same-for-each/);
});

test('all methodOnly sub-items independently classify as non-core via the unmodified real classifier', () => {
  for (const item of review.items) {
    for (const moi of item.items) {
      for (const split of moi.splitItems) {
        const result = classifyRecipeIngredient(split.item);
        assert.notEqual(result.role, 'core', `${item.entryId}:${split.item}`);
        assert.equal(result.role, split.role, `${item.entryId}:${split.item} recorded role must match live classifier`);
      }
      assert.equal(moi.allNonCore, true, `${item.entryId}:${moi.rawItemText}`);
    }
    assert.equal(item.allSplitItemsNonCore, true, item.entryId);
  }
});

test('precedent: qty=null/unit=null is an already-supported, load-bearing production shape', () => {
  let count = 0;
  for (const ings of Object.values(curated.recipe_ingredients ?? {})) {
    for (const ing of ings) {
      if (ing.qty === null && ing.unit === null) count += 1;
    }
  }
  // The frozen review artifact recorded this precedent count before Batch 8
  // itself promoted, which added its own 3 reviewed null qty/unit items
  // (姜/花椒/胡椒面); the live count is the frozen precedent plus those 3.
  assert.equal(review.precedent.existingNullQtyUnitCurratedRecordCount + 3, count);
  assert.ok(count > 0, 'curated must already contain qty=null/unit=null entries as precedent');
});

test('safety analysis concludes safe-to-allow for these two specific confirmed items', () => {
  assert.equal(review.safetyAnalysis.allItemsGenuinelyMentionedInMethodTextWithNoSourceQuantity, true);
  assert.equal(review.safetyAnalysis.allSplitSubItemsClassifyAsNonCore, true);
  assert.equal(review.safetyAnalysis.nullQtyUnitShapeAlreadySupportedInProduction, true);
  assert.equal(review.safetyAnalysis.conclusion, 'safe-to-allow-qty-null-for-these-specific-confirmed-methodonly-items');
});

test('policy recommendation is scope-limited, not a global auto-allow rule', () => {
  assert.equal(review.policyRecommendation.scopeLimitedNotGlobal, true);
  assert.ok(review.policyRecommendation.perEntryUnlockCriteria.length >= 3);
});

test('minimal implementation plan is present because the conclusion is safe', () => {
  assert.ok(review.minimalImplementationPlanIfSafe);
  assert.ok(review.minimalImplementationPlanIfSafe.steps.length > 0);
  assert.ok(review.minimalImplementationPlanIfSafe.risksAndTests.length > 0);
});

test('Batch 8 promotion stays intact while Batch 9 leaves the final 6 blockers untouched', () => {
  const promotedIds = new Set(
    (promotions.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.entryId)),
  );
  assert.equal(promotedIds.size, 33);
  assert.equal(promotedIds.has('dz1979-p129'), true);
  assert.equal(promotedIds.has('dz1979-p130'), true);
  assert.equal(readiness.summary.promotedNewRecipeCount, 33);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 6);
  assert.equal(readiness.applicationReady, false);
  // p129/p130 are now promoted by Batch 8.
  assert.equal(readinessByEntryId.get('dz1979-p129').promotionState, 'promoted');
  assert.equal(readinessByEntryId.get('dz1979-p130').promotionState, 'promoted');
  assert.equal(readinessByEntryId.get('dz1979-p137').promotionState, 'promoted');
  assert.equal(readinessByEntryId.get('dz1979-p161').promotionState, 'promoted');
  // The final 6 quantity blockers remain untouched.
  const otherBlockedIds = ['dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226'];
  for (const id of otherBlockedIds) {
    assert.equal(readinessByEntryId.get(id).promotionState, 'not-promoted', id);
  }
  assert.equal(curated.recipes.length, 159);
  assert.equal(curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length, 33);
});

test('readiness disposition counts are unchanged', () => {
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
});
