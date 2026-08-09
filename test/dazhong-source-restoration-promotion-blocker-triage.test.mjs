import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import { classifyIngredientCompatibility } from '../scripts/dazhong-runtime-compatibility.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const triage = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-blocker-triage.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const batch6DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const readinessByEntryId = new Map(readiness.entries.map((e) => [e.entryId, e]));

const EXPECTED_IDS = [
  'dz1979-p129', 'dz1979-p130', 'dz1979-p137', 'dz1979-p144', 'dz1979-p161',
  'dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p211', 'dz1979-p222',
  'dz1979-p224', 'dz1979-p226',
];
// The triage artifact is a frozen point-in-time snapshot of the 12 that
// were remaining when it was generated. Batch 7 has since mechanically
// promoted two of them (p144/p211) via the confirmed mechanical-fix-
// candidate remediation; this file stays accurate either way by checking
// their actual current promotion state via the ledger rather than assuming
// they are still unpromoted.
const ledgerPromotedEntryIds = new Set(
  (promotions.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.entryId)),
);
const MECHANICAL_FIX_IDS = ['dz1979-p144', 'dz1979-p211'];
const mechanicalFixPromotedCount = MECHANICAL_FIX_IDS.filter((id) => ledgerPromotedEntryIds.has(id)).length;
// Batch 8 has since promoted p129/p130 via the reviewed methodOnly-null
// policy; this file stays accurate either way by checking their actual
// current promotion state via the ledger rather than assuming unpromoted.
const BATCH8_FIX_IDS = ['dz1979-p129', 'dz1979-p130'];
const batch8FixPromotedCount = BATCH8_FIX_IDS.filter((id) => ledgerPromotedEntryIds.has(id)).length;
const totalTriagePromotedCount = mechanicalFixPromotedCount + batch8FixPromotedCount;

test('artifact reports zero verification problems and applicationReady=false', () => {
  assert.deepEqual(triage.verificationProblems, []);
  assert.equal(triage.applicationReady, false);
});

test('exactly the twelve remaining candidates are covered, no duplicates, no omissions', () => {
  const ids = triage.items.map((i) => i.entryId).sort();
  assert.deepEqual(ids, EXPECTED_IDS.slice().sort());
  assert.equal(new Set(ids).size, 12);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 12 - totalTriagePromotedCount);
});

test('the remaining candidate pool independently recomputed from readiness matches exactly', () => {
  const remaining = readiness.entries.filter((e) => (
    e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
  )).map((e) => e.entryId).sort();
  const expectedRemaining = EXPECTED_IDS.filter((id) => !ledgerPromotedEntryIds.has(id)).sort();
  assert.deepEqual(remaining, expectedRemaining);
});

test('blocker union matches the frozen Batch 6 dry-run hardGateExclusions and runtimeNameGateBlocked exactly', () => {
  const frozenHardGateUnion = new Set(
    Object.values(batch6DryRun.selection.hardGateExclusions).flat(),
  );
  const frozenRuntimeBlocked = new Set(
    batch6DryRun.selection.runtimeNameGateBlocked.map((b) => b.entryId),
  );
  for (const item of triage.items) {
    const hasHardGateBlocker = item.blockers.some((b) => b !== 'runtime-unresolved-name');
    const hasRuntimeBlocker = item.blockers.includes('runtime-unresolved-name');
    assert.equal(hasHardGateBlocker, frozenHardGateUnion.has(item.entryId), `${item.entryId} hard-gate union mismatch`);
    assert.equal(hasRuntimeBlocker, frozenRuntimeBlocked.has(item.entryId), `${item.entryId} runtime-gate union mismatch`);
  }
  // Every hard-gate-excluded id and every runtime-blocked id from the
  // frozen dry-run must appear somewhere in the triage items.
  const triageIds = new Set(triage.items.map((i) => i.entryId));
  for (const id of frozenHardGateUnion) assert.ok(triageIds.has(id), `${id} missing from triage`);
  for (const id of frozenRuntimeBlocked) assert.ok(triageIds.has(id), `${id} missing from triage`);
});

test('every triage item has at least one blocker and a valid recommendedDisposition', () => {
  const ALLOWED = ['mechanical-fix-candidate', 'targeted-review-required', 'schema-or-policy-required', 'keep-blocked'];
  for (const item of triage.items) {
    assert.ok(item.blockers.length > 0, `${item.entryId} has no recorded blocker`);
    assert.ok(ALLOWED.includes(item.recommendedDisposition), `${item.entryId} invalid disposition ${item.recommendedDisposition}`);
  }
});

test('required fields are present on every item', () => {
  const requiredFields = [
    'entryId', 'name', 'blockers', 'sourceFacts', 'currentProductionPlan',
    'runtimeStatus', 'semanticRisk', 'minimalRemediation',
    'requiresAliasChange', 'requiresConversionChange', 'requiresSchemaChange',
    'requiresHumanSourceReview', 'recommendedDisposition',
  ];
  for (const item of triage.items) {
    for (const field of requiredFields) {
      assert.ok(Object.prototype.hasOwnProperty.call(item, field), `${item.entryId} missing ${field}`);
    }
  }
});

test('same-for-each: p144 and p211 are the only entries with same-for-each as the sole blocker, and are mechanical-fix-candidate', () => {
  const byId = new Map(triage.items.map((i) => [i.entryId, i]));
  for (const id of ['dz1979-p144', 'dz1979-p211']) {
    const item = byId.get(id);
    assert.deepEqual(item.blockers, ['same-for-each'], id);
    assert.equal(item.recommendedDisposition, 'mechanical-fix-candidate', id);
    assert.equal(item.requiresAliasChange, false, id);
    assert.equal(item.requiresSchemaChange, false, id);
    assert.equal(item.requiresHumanSourceReview, false, id);
  }
  // p130/p201/p207 also carry same-for-each but are NOT mechanical-fix-candidate
  // because they stack with another blocker.
  for (const id of ['dz1979-p130', 'dz1979-p201', 'dz1979-p207']) {
    const item = byId.get(id);
    assert.ok(item.blockers.includes('same-for-each'), id);
    assert.ok(item.blockers.length > 1, id);
    assert.notEqual(item.recommendedDisposition, 'mechanical-fix-candidate', id);
  }
});

test('same-for-each split preview is lossless: production plan qty/unit for each member matches the raw "各X" quantity exactly', () => {
  for (const id of ['dz1979-p144', 'dz1979-p211']) {
    const recipe = recipeByEntryId.get(id);
    const sameForEachIngredients = recipe.ingredients.filter((ing) => ing.memberQuantityMode === 'same-for-each');
    assert.ok(sameForEachIngredients.length > 0, id);
    const plan = readinessByEntryId.get(id).productionIngredientPlan;
    for (const ing of sameForEachIngredients) {
      for (const member of ing.members ?? []) {
        const planEntry = plan.inventoryIngredients.find((p) => p.productionItem === member.item);
        assert.ok(planEntry, `${id}:${member.item} missing from productionIngredientPlan`);
        assert.equal(planEntry.qty, String(ing.normalizedQuantity.qty), `${id}:${member.item} qty mismatch`);
        assert.equal(planEntry.inventoryComparable, true, `${id}:${member.item} should be inventoryComparable`);
      }
    }
  }
});

test('non-exact-quantity: p201/p203/p207 all involve the same approximate-count 花椒 and are schema-or-policy-required', () => {
  const byId = new Map(triage.items.map((i) => [i.entryId, i]));
  for (const id of ['dz1979-p201', 'dz1979-p203', 'dz1979-p207']) {
    const item = byId.get(id);
    assert.ok(item.blockers.includes('non-exact-quantity'), id);
    assert.equal(item.recommendedDisposition, 'schema-or-policy-required', id);
    assert.equal(item.requiresSchemaChange, true, id);
    const recipe = recipeByEntryId.get(id);
    const huajiao = recipe.ingredients.find((ing) => ing.rawItemText === '花椒');
    assert.ok(huajiao, `${id} missing 花椒 ingredient`);
    assert.equal(huajiao.normalizedQuantity.kind, 'approximate-count', id);
    assert.equal(huajiao.normalizedQuantity.qty, null, id);
  }
});

test('consumed-dual-quantity: p222/p224/p226 all carry a consumedQty distinct from qty and are schema-or-policy-required', () => {
  const byId = new Map(triage.items.map((i) => [i.entryId, i]));
  for (const id of ['dz1979-p222', 'dz1979-p224', 'dz1979-p226']) {
    const item = byId.get(id);
    assert.ok(item.blockers.includes('consumed-dual-quantity'), id);
    assert.equal(item.recommendedDisposition, 'schema-or-policy-required', id);
    assert.equal(item.requiresSchemaChange, true, id);
    const recipe = recipeByEntryId.get(id);
    const dualIngredients = recipe.ingredients.filter((ing) => (
      'consumedQty' in (ing.normalizedQuantity ?? {}) || 'consumedReferenceQty' in (ing.normalizedQuantity ?? {})
    ));
    assert.ok(dualIngredients.length > 0, id);
    for (const ing of dualIngredients) {
      const consumed = ing.normalizedQuantity.consumedQty ?? ing.normalizedQuantity.consumedReferenceQty;
      assert.notEqual(consumed, ing.normalizedQuantity.qty, `${id}:${ing.rawItemText} consumed should differ from input qty`);
    }
  }
});

test('methodOnly: p129/p130 core-no-quantity method-only items genuinely have no rawQuantityText in the source', () => {
  const byId = new Map(triage.items.map((i) => [i.entryId, i]));
  for (const id of ['dz1979-p129', 'dz1979-p130']) {
    const item = byId.get(id);
    assert.ok(item.blockers.includes('methodOnly'), id);
    assert.equal(item.recommendedDisposition, 'targeted-review-required', id);
    assert.equal(item.requiresHumanSourceReview, true, id);
    const recipe = recipeByEntryId.get(id);
    const coreNoQty = item.sourceFacts.methodOnlyCoreNoQuantity;
    assert.ok(coreNoQty.length > 0, id);
    for (const moi of coreNoQty) {
      const source = recipe.methodOnlyIngredients.find((m) => m.rawItemText === moi.sourceRawItemText);
      assert.ok(source, `${id}:${moi.sourceRawItemText} missing from canonical methodOnlyIngredients`);
      assert.equal(source.rawQuantityText, null, `${id}:${moi.sourceRawItemText} unexpectedly has a rawQuantityText`);
    }
  }
});

test('runtime-unresolved-name remains frozen in triage while current remediation resolves p137/p161', () => {
  const byId = new Map(triage.items.map((i) => [i.entryId, i]));
  const cases = [
    { id: 'dz1979-p137', item: '子公鸡', qty: '1', unit: '只', compatibility: 'expected-unit-confirmation' },
    { id: 'dz1979-p161', item: '鸡血', qty: '500', unit: 'g', compatibility: 'exact-compatible' },
  ];
  for (const { id, item, qty, unit, compatibility } of cases) {
    const triageItem = byId.get(id);
    assert.ok(triageItem.blockers.includes('runtime-unresolved-name'), id);
    assert.equal(triageItem.recommendedDisposition, 'targeted-review-required', id);
    assert.equal(triageItem.requiresAliasChange, true, id);
    assert.ok(triageItem.runtimeStatus.unresolvedItems.includes(item), id);
    const result = classifyIngredientCompatibility(item, qty, unit);
    assert.equal(result.role, 'core', id);
    assert.equal(result.compatibility, compatibility, id);
  }
});

test('no mechanical-fix-candidate carries requiresAliasChange, requiresSchemaChange, or requiresHumanSourceReview', () => {
  for (const item of triage.items) {
    if (item.recommendedDisposition === 'mechanical-fix-candidate') {
      assert.equal(item.requiresAliasChange, false, item.entryId);
      assert.equal(item.requiresSchemaChange, false, item.entryId);
      assert.equal(item.requiresHumanSourceReview, false, item.entryId);
    }
  }
});

test('prioritization groups partition the twelve items with no overlap and match recommendedDisposition', () => {
  const groups = {
    'mechanical-fix-candidate': triage.prioritization.mechanicalFixCandidates.map((i) => i.entryId),
    'targeted-review-required': triage.prioritization.targetedReviewRequired.map((i) => i.entryId),
    'schema-or-policy-required': triage.prioritization.schemaOrPolicyRequired.map((i) => i.entryId),
    'keep-blocked': triage.prioritization.keepBlocked.map((i) => i.entryId),
  };
  const allGroupedIds = Object.values(groups).flat();
  assert.equal(new Set(allGroupedIds).size, allGroupedIds.length, 'duplicate ids across priority groups');
  assert.deepEqual(allGroupedIds.sort(), EXPECTED_IDS.slice().sort());
  for (const [disposition, ids] of Object.entries(groups)) {
    for (const id of ids) {
      const item = triage.items.find((i) => i.entryId === id);
      assert.equal(item.recommendedDisposition, disposition, id);
    }
  }
  assert.deepEqual(triage.prioritization.nextMechanicalBatchCandidates.sort(), groups['mechanical-fix-candidate'].sort());
});

test('production and ledger reflect the triage snapshot plus any subsequent mechanical-fix-candidate promotions only', () => {
  assert.equal(ledgerPromotedEntryIds.size, 27 + totalTriagePromotedCount);
  for (const item of triage.items) {
    const expectedPromoted = [...MECHANICAL_FIX_IDS, ...BATCH8_FIX_IDS].includes(item.entryId) && ledgerPromotedEntryIds.has(item.entryId);
    assert.equal(ledgerPromotedEntryIds.has(item.entryId), expectedPromoted, `${item.entryId} promotion state must match ledger`);
  }
  assert.equal(curated.recipes.length, 153 + totalTriagePromotedCount);
  assert.equal(curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length, 27 + totalTriagePromotedCount);
  const curatedIds = new Set(curated.recipes.map((r) => r.id));
  for (const item of triage.items) {
    // Each blocked entry's would-be production id (dz1979-pNNN) must not
    // exist in full (Batch 7's mechanical fix only ever targets curated,
    // never Full); items not covered by the mechanical-fix remediation must
    // also still be absent from curated.
    const productionId = `dz1979-p${item.bookPage}`;
    if (![...MECHANICAL_FIX_IDS, ...BATCH8_FIX_IDS].includes(item.entryId)) {
      assert.equal(curatedIds.has(productionId), false, `${productionId} must not be promoted`);
    }
    assert.equal(full.recipes.some((r) => r.id === productionId), false, `${productionId} must not be in full`);
  }
});

test('readiness disposition/quantity-readiness stats are unchanged and applicationReady stays false', () => {
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
  assert.equal(readiness.summary.promotedNewRecipeCount, 27 + totalTriagePromotedCount);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 12 - totalTriagePromotedCount);
  assert.equal(readiness.applicationReady, false);
});

test('baseline block records the correct commit and current production counts', () => {
  assert.equal(triage.baseline.main, '5b737cf8bc418a8e8c8cd1b057783a1500302b56');
  assert.equal(triage.baseline.promotedBatches, 6);
  assert.equal(triage.baseline.promotedCount, 27);
  assert.equal(triage.baseline.remainingCount, 12);
  assert.equal(triage.baseline.curatedCount, 153);
});
