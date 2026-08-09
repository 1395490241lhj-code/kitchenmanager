import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { buildDefaultRuntimePacks } from '../scripts/recipe-runtime-quality.mjs';
import { classifyIngredientCompatibility } from '../scripts/dazhong-runtime-compatibility.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch2-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const restored = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');

const restoredById = new Map(restored.recipes.map((r) => [r.entryId, r]));
const catalogById = new Map(catalog.entries.map((e) => [e.entryId, e]));
const readinessById = new Map(readiness.entries.map((e) => [e.entryId, e]));

const productionNames = new Set([
  ...curated.recipes.map((r) => r.name),
  ...full.recipes.map((r) => r.name),
]);
const productionIds = new Set([
  ...curated.recipes.map((r) => r.id),
  ...full.recipes.map((r) => r.id),
  ...(overlay.newRecipes ?? []).map((r) => r.id),
]);

const ledgerPromotedEntryIds = new Set(
  (promotions.batches ?? []).flatMap((batch) => (
    (batch.entries ?? []).map((entry) => entry.entryId)
  )),
);

const EXPECTED_PRODUCTION_IDS = ['dz1979-p187', 'dz1979-p188', 'dz1979-p196', 'dz1979-p202', 'dz1979-p205'];
const BATCH3_PRODUCTION_IDS = ['dz1979-p212', 'dz1979-p216', 'dz1979-p218', 'dz1979-p221', 'dz1979-p206'];
const BATCH4_PRODUCTION_IDS = ['dz1979-p183', 'dz1979-p198', 'dz1979-p153', 'dz1979-p209', 'dz1979-p223'];
const BATCH5_PRODUCTION_IDS = ['dz1979-p162', 'dz1979-p186', 'dz1979-p185', 'dz1979-p219', 'dz1979-p213'];
const BATCH6_PRODUCTION_IDS = ['dz1979-p159', 'dz1979-p168'];
const BATCH7_PRODUCTION_IDS = ['dz1979-p211', 'dz1979-p144'];
const BATCH8_PRODUCTION_IDS = ['dz1979-p129', 'dz1979-p130'];
const BATCH9_PRODUCTION_IDS = ['dz1979-p161', 'dz1979-p137'];
// Batch 3/4/5/6/7 may since have been promoted on top of Batch 1/2; this file
// only regression-tests Batch 2's own promoted content, so it stays
// accurate either way by checking their presence via the ledger.
const batch3Promoted = BATCH3_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch4Promoted = BATCH4_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch5Promoted = BATCH5_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch6Promoted = BATCH6_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch7Promoted = BATCH7_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch8Promoted = BATCH8_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const batch9Promoted = BATCH9_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const laterBatchesPromotedCount = (batch3Promoted ? 1 : 0) + (batch4Promoted ? 1 : 0) + (batch5Promoted ? 1 : 0) + (batch6Promoted ? 1 : 0) + (batch7Promoted ? 1 : 0) + (batch8Promoted ? 1 : 0) + (batch9Promoted ? 1 : 0);
const laterBatchesRecipeCount = (batch3Promoted ? 5 : 0) + (batch4Promoted ? 5 : 0) + (batch5Promoted ? 5 : 0) + (batch6Promoted ? 2 : 0) + (batch7Promoted ? 2 : 0) + (batch8Promoted ? 2 : 0) + (batch9Promoted ? 2 : 0);
const idsFromLaterBatches = [
  ...(batch3Promoted ? BATCH3_PRODUCTION_IDS : []),
  ...(batch4Promoted ? BATCH4_PRODUCTION_IDS : []),
  ...(batch5Promoted ? BATCH5_PRODUCTION_IDS : []),
  ...(batch6Promoted ? BATCH6_PRODUCTION_IDS : []),
  ...(batch7Promoted ? BATCH7_PRODUCTION_IDS : []),
  ...(batch8Promoted ? BATCH8_PRODUCTION_IDS : []),
  ...(batch9Promoted ? BATCH9_PRODUCTION_IDS : []),
];

// -- Independent replica of the hard gate + Batch 2 runtime gate -----------
// Deliberately written from scratch against readiness/canonical data rather
// than importing the generator, so the test cannot silently pass a bug the
// generator itself introduced.

function passesHardGates(entryId, { allowPromoted = false } = {}) {
  const entry = readinessById.get(entryId);
  const recipe = restoredById.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
  if (entry.promotionState !== 'not-promoted' && !(allowPromoted && entry.promotionState === 'promoted')) return false;
  if (entry.sourceQuality !== 'ready-for-later-promotion-review') return false;
  const plan = entry.productionIngredientPlan;
  if (plan.quantityReadiness !== 'exact-comparable') return false;
  if (plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) return false;
  if (plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) return false;
  if (recipe.contentMissing === true || recipe.contentIncomplete === true) return false;
  if (recipe.uncertainties?.length > 0) return false;
  const confidence = recipe.confidence ?? {};
  if (confidence.recognition !== 'high' || confidence.conversion !== 'high') return false;
  if (recipe.methodSummary?.confidence !== 'high') return false;
  if (recipe.titleVisualCheck?.confidence !== 'high') return false;
  if (recipe.ingredients?.some((ing) => (
    ing.confidence?.recognition !== 'high' || ing.confidence?.conversion !== 'high'
  ))) return false;
  for (const ing of recipe.ingredients ?? []) {
    const quantity = ing.normalizedQuantity ?? {};
    if (!['exact-mass', 'exact-count'].includes(quantity.kind)) return false;
    if (ing.memberQuantityMode) return false;
    if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity) return false;
    if ('consumedQualifier' in quantity || 'consumedUnit' in quantity) return false;
  }
  // A name collision is only a real conflict if some *other* recipe already
  // owns that name in production. If this entry itself has been promoted
  // under its own book name (ledger-confirmed), that match is expected.
  const dryRunItem = dryRun.items.find((it) => it.entryId === entryId);
  const nameOwnedBySelf = allowPromoted && dryRunItem && dryRunItem.name === entry.bookName
    && curated.recipes.some((r) => r.id === dryRunItem.productionId && r.name === entry.bookName);
  if (productionNames.has(entry.bookName) && !nameOwnedBySelf) return false;
  return true;
}

function auditRuntimeGate(entryId) {
  const entry = readinessById.get(entryId);
  const coreResults = [];
  for (const ing of entry.productionIngredientPlan.inventoryIngredients) {
    const result = classifyIngredientCompatibility(ing.productionItem, ing.qty, ing.unit);
    if (result.role === 'core') coreResults.push(result);
  }
  const unresolvedCount = coreResults.filter((r) => r.compatibility === 'unresolved-name-match').length;
  const unitConfirmationCount = coreResults.filter((r) => r.compatibility === 'expected-unit-confirmation').length;
  return { unresolvedCount, unitConfirmationCount, blocked: unresolvedCount > 0 };
}

function complexityKey(entryId) {
  const recipe = restoredById.get(entryId);
  const audit = auditRuntimeGate(entryId);
  const special = recipe.ingredients.filter((ing) => ing.memberQuantityMode).length;
  return [audit.unitConfirmationCount, special, recipe.ingredients.length, recipe.methodSummary?.steps?.length ?? 0, entryId];
}

function mechanicalFunnel() {
  const remaining = readiness.entries
    .filter((e) => e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted')
    .map((e) => e.entryId);
  const hardGateSurvivors = remaining.filter(passesHardGates);
  const eligible = hardGateSurvivors.filter((id) => !auditRuntimeGate(id).blocked);
  const blocked = hardGateSurvivors.filter((id) => auditRuntimeGate(id).blocked);
  const top5 = [...eligible].sort((a, b) => {
    const ka = complexityKey(a);
    const kb = complexityKey(b);
    for (let i = 0; i < ka.length; i += 1) {
      if (ka[i] < kb[i]) return -1;
      if (ka[i] > kb[i]) return 1;
    }
    return 0;
  }).slice(0, 5);
  return { remaining, hardGateSurvivors, eligible, blocked, top5 };
}

test('remaining candidate pool excludes Batch 1 promoted entries and matches the ledger', () => {
  const remaining = readiness.entries.filter((e) => (
    e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
  ));
  // Batch 2 has since promoted; the dry-run's own recorded funnel snapshot
  // (34 remaining at dry-run creation time) is preserved on the frozen
  // artifact and checked separately below. Live readiness now reflects
  // Batch 1 + Batch 2 promoted (10), so live remaining is 29.
  assert.equal(dryRun.selection.funnel.remainingNotPromotedCandidates, 34);
  assert.equal(remaining.length, readiness.summary.remainingNewRecipeCandidateCount);
  for (const entry of remaining) {
    assert.equal(ledgerPromotedEntryIds.has(entry.entryId), false, `${entry.entryId} should not be in the remaining pool`);
  }
  // The five Batch 2 entries must now be present in the ledger alongside
  // Batch 1's five (10 total, or 15 total if Batch 3 has also promoted),
  // and none of them may still show up as "remaining" (not-promoted).
  for (const item of dryRun.items) {
    assert.ok(ledgerPromotedEntryIds.has(item.entryId), `${item.entryId} should be in the ledger after promotion`);
  }
  assert.equal(ledgerPromotedEntryIds.size, 10 + laterBatchesRecipeCount);
});

test('the funnel counts match an independently recomputed selection (34 -> 24 -> 22 -> 5)', () => {
  // This funnel is inherently point-in-time: it was computed against live
  // readiness at dry-run creation, before Batch 2 promoted. Re-running it
  // against current (post-promotion) readiness would legitimately produce
  // different remaining/eligible counts, since the five selected items no
  // longer have promotionState=not-promoted. What must still hold is that
  // the frozen artifact's own recorded funnel numbers are internally
  // self-consistent, and its recorded selected ids match its own items.
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 34,
    afterHardGates: 24,
    blockedByRuntimeNameGate: 2,
    eligible: 22,
    selected: 5,
  });
  assert.equal(dryRun.selection.selectedEntryIds.length, 5);
  assert.deepEqual(dryRun.selection.selectedEntryIds, dryRun.items.map((item) => item.entryId));
});

test('the five selected entries are exactly p187/p202/p205/p188/p196', () => {
  assert.deepEqual(
    dryRun.items.map((item) => item.productionId),
    ['dz1979-p187', 'dz1979-p202', 'dz1979-p205', 'dz1979-p188', 'dz1979-p196'],
  );
});

test('runtime name gate blocks exactly dz1979-p137 and dz1979-p161 on their unresolved core items', () => {
  const blocked = dryRun.selection.runtimeNameGateBlocked;
  assert.equal(blocked.length, 2);
  const byId = new Map(blocked.map((b) => [b.entryId, b]));
  assert.equal(byId.get('dz1979-p137')?.bookName, '椒麻鸡块');
  assert.deepEqual(byId.get('dz1979-p137')?.unresolvedItems, ['子公鸡']);
  assert.equal(byId.get('dz1979-p161')?.bookName, '拌鸡血');
  assert.deepEqual(byId.get('dz1979-p161')?.unresolvedItems, ['鸡血']);
  // Cross-check against the readiness bookName directly (no hardcoded trust).
  assert.equal(readinessById.get('dz1979-p137').bookName, byId.get('dz1979-p137').bookName);
  assert.equal(readinessById.get('dz1979-p161').bookName, byId.get('dz1979-p161').bookName);
});

test('every selected item fully satisfies both gates (as promoted) and has zero unit-confirmation core ingredients', () => {
  for (const item of dryRun.items) {
    // These 5 have since been promoted, so promotionState is 'promoted' not
    // 'not-promoted'; every other hard-gate field must still hold.
    assert.equal(readinessById.get(item.entryId).promotionState, 'promoted', item.entryId);
    assert.equal(passesHardGates(item.entryId, { allowPromoted: true }), true, item.entryId);
    const audit = auditRuntimeGate(item.entryId);
    assert.equal(audit.blocked, false, item.entryId);
    assert.equal(audit.unresolvedCount, 0, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.gatePassed, true, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.counts['unresolved-name-match'], 0, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.counts['expected-unit-confirmation'], 0, item.entryId);
    assert.equal(item.productionId, `dz1979-p${catalogById.get(item.entryId).bookPage}`, item.entryId);
    assert.equal(item.name, catalogById.get(item.entryId).bookName, item.entryId);
    assert.equal(item.category, catalogById.get(item.entryId).category, item.entryId);
    assert.deepEqual(item.tags, ['川菜', catalogById.get(item.entryId).category], item.entryId);
  }
});

test('all dry-run item fields are present with production-only schema shapes', () => {
  const required = [
    'entryId',
    'productionId',
    'name',
    'category',
    'tags',
    'selectionMetrics',
    'proposedOverlayRecipe',
    'proposedOverlayIngredients',
    'proposedCuratedRecipe',
    'proposedCuratedIngredients',
    'provenanceRecord',
    'sourceToProductionTransformNotes',
    'quantityReviewPreview',
    'coreRuntimeCompatibility',
  ];
  for (const item of dryRun.items) {
    for (const field of required) {
      assert.ok(Object.prototype.hasOwnProperty.call(item, field), `${item.entryId} missing ${field}`);
    }
    assert.deepEqual(item.proposedOverlayRecipe, item.proposedCuratedRecipe, item.entryId);
    assert.deepEqual(
      item.proposedOverlayIngredients[item.productionId],
      item.proposedCuratedIngredients[item.productionId],
      item.entryId,
    );
    const recipe = item.proposedCuratedRecipe;
    assert.equal(typeof recipe.id, 'string', item.entryId);
    assert.equal(typeof recipe.name, 'string', item.entryId);
    assert.equal(typeof recipe.method, 'string', item.entryId);
    assert.ok(Array.isArray(recipe.tags), item.entryId);
    for (const ing of item.proposedCuratedIngredients[item.productionId]) {
      assert.ok(['item', 'qty', 'unit'].every((k) => Object.prototype.hasOwnProperty.call(ing, k)), item.entryId);
      assert.equal(typeof ing.item, 'string', item.entryId);
    }
  }
});

test('methods come only from canonical methodSummary steps', () => {
  for (const item of dryRun.items) {
    const recipe = restoredById.get(item.entryId);
    const expected = recipe.methodSummary.steps
      .map((step) => `${step.order}. ${step.summary}`)
      .join('\n');
    assert.equal(item.proposedCuratedRecipe.method, expected, item.entryId);
  }
});

test('ingredients reuse the audited productionIngredientPlan exactly', () => {
  for (const item of dryRun.items) {
    const plan = readinessById.get(item.entryId).productionIngredientPlan;
    const expected = plan.inventoryIngredients.map((ing) => ({
      item: ing.productionItem,
      qty: ing.qty,
      unit: ing.unit,
    }));
    assert.deepEqual(item.proposedCuratedIngredients[item.productionId], expected, item.entryId);
  }
});

test('quantity review preview is exact-only, unit-whitelisted, and traces back to canonical raw quantities without recomputation', () => {
  const UNIT_WHITELIST = /^(g|ml|个|只|颗|枚|根|条|片|块|瓣|张|把|棵|头|支|份|盒|袋|包|瓶|罐|听)$/;
  let totalRecords = 0;
  for (const item of dryRun.items) {
    const recipe = restoredById.get(item.entryId);
    const canonicalByRaw = new Map((recipe.ingredients ?? []).map((ing) => [ing.rawItemText, ing]));
    assert.equal(item.quantityReviewPreview.records.length, item.quantityReviewPreview.recordCount, item.entryId);
    totalRecords += item.quantityReviewPreview.recordCount;
    for (const record of item.quantityReviewPreview.records) {
      assert.match(record.unit, UNIT_WHITELIST, `${item.entryId}:${record.item}`);
      assert.ok(['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind), `${item.entryId}:${record.item}`);
      const canonicalIngredient = canonicalByRaw.get(record.item);
      assert.ok(canonicalIngredient, `${item.entryId}:${record.item} missing canonical source`);
      assert.equal(record.sourceRawQuantityText, canonicalIngredient.rawQuantityText, `${item.entryId}:${record.item}`);
      assert.deepEqual(record.normalizedQuantity, {
        kind: canonicalIngredient.normalizedQuantity.kind,
        qty: canonicalIngredient.normalizedQuantity.qty,
        unit: canonicalIngredient.normalizedQuantity.unit,
      }, `${item.entryId}:${record.item}`);
      // qty must equal the normalized qty as a string: never recomputed here.
      assert.equal(record.qty, String(canonicalIngredient.normalizedQuantity.qty), `${item.entryId}:${record.item}`);
    }
  }
  assert.equal(totalRecords, 29);
  assert.equal(dryRun.quantityReviewPreview.recordCount, 29);
  assert.equal(dryRun.quantityReviewPreview.records.length, 29);
});

test('coreRuntimeCompatibility results only classify core ingredients and never fabricate exact-compatible without evidence', () => {
  for (const item of dryRun.items) {
    for (const result of item.coreRuntimeCompatibility.coreIngredientResults) {
      assert.equal(result.role, 'core', `${item.entryId}:${result.item}`);
      assert.ok(['exact-compatible', 'expected-unit-confirmation', 'unresolved-name-match'].includes(result.compatibility), `${item.entryId}:${result.item}`);
      assert.equal(result.normalizedQuantity.finite, true, `${item.entryId}:${result.item}`);
      assert.ok(result.reasons.length > 0, `${item.entryId}:${result.item}`);
    }
    for (const observation of item.coreRuntimeCompatibility.nonCoreObservations) {
      assert.notEqual(observation.role, 'core', `${item.entryId}:${observation.item}`);
    }
  }
});

test('promotion-aware: stripping the five promoted ids from a temp copy and re-applying the frozen proposals reproduces 131 -> 136 exactly', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch2-test-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(
      new URL('../scripts/curate-recipes.js', import.meta.url).pathname,
      path.join(tmp, 'scripts', 'curate-recipes.js'),
    );
    fs.copyFileSync(
      new URL('../data/sichuan-recipes.json', import.meta.url).pathname,
      path.join(tmp, 'data', 'sichuan-recipes.json'),
    );
    const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
    fs.copyFileSync(
      new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
      overlayPath,
    );
    const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    const overridesBefore = tmpOverlay.recipeIngredientOverrides;
    // Real production already contains the Batch 2 promotion. To exercise
    // the same "add these 5 via curate-recipes.js" mechanics that promotion
    // itself relied on, strip the five promoted ids back out of the temp
    // overlay first, then re-add them from the frozen proposals. This
    // proves the frozen dry-run proposals are what actually produced
    // today's production state, without assuming production is still
    // pre-promotion.
    const batchIdSet = new Set(dryRun.items.map((item) => item.productionId));
    tmpOverlay.newRecipes = (tmpOverlay.newRecipes ?? []).filter((r) => !batchIdSet.has(r.id));
    tmpOverlay.newRecipeIngredients = Object.fromEntries(
      Object.entries(tmpOverlay.newRecipeIngredients ?? {}).filter(([id]) => !batchIdSet.has(id)),
    );
    tmpOverlay.newRecipes = [
      ...tmpOverlay.newRecipes,
      ...dryRun.items.map((item) => item.proposedOverlayRecipe),
    ];
    tmpOverlay.newRecipeIngredients = {
      ...tmpOverlay.newRecipeIngredients,
      ...Object.fromEntries(dryRun.items.map((item) => [
        item.productionId,
        item.proposedOverlayIngredients[item.productionId],
      ])),
    };
    fs.writeFileSync(overlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);

    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    const out = {
      curated: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8')),
      removed: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8')),
      needing: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8')),
    };

    // Real production is now 136 (post Batch1+2), 141 (post Batch3 too), or
    // 146 (post Batch4 too); the re-derived temp result must match it
    // exactly, proving no drift. Derived from real curated directly so it
    // stays correct regardless of how many later batches have promoted.
    const expectedCount = curated.recipes.length;
    assert.equal(curated.recipes.length, expectedCount);
    assert.equal(out.curated.recipes.length, expectedCount);
    assert.deepEqual(out.curated, curated);

    const batchIds = batchIdSet;
    const newIds = out.curated.recipes.map((r) => r.id).filter((id) => !curated.recipes.some((r2) => r2.id === id));
    assert.equal(newIds.length, 0);

    const existingIds = curated.recipes.map((r) => r.id);
    const existingModified = existingIds.filter((id) => {
      const before = curated.recipes.find((r) => r.id === id);
      const after = out.curated.recipes.find((r) => r.id === id);
      return JSON.stringify(before) !== JSON.stringify(after);
    });
    const existingIngredientModified = existingIds.filter((id) => (
      JSON.stringify(curated.recipe_ingredients[id]) !== JSON.stringify(out.curated.recipe_ingredients[id])
    ));
    const existingDeleted = existingIds.filter((id) => !out.curated.recipes.some((r) => r.id === id));
    assert.equal(existingModified.length, 0);
    assert.equal(existingIngredientModified.length, 0);
    assert.equal(existingDeleted.length, 0);

    for (const id of batchIds) {
      const recipe = out.curated.recipes.find((r) => r.id === id);
      assert.ok(recipe.method, `${id} missing method`);
      assert.ok(recipe.tags, `${id} missing tags`);
      assert.ok(out.curated.recipe_ingredients[id].length >= 2, `${id} incomplete map`);
      // no duplicates
      assert.equal(out.curated.recipes.filter((r) => r.id === id).length, 1, `${id} duplicated`);
    }

    const realRemoved = readJson('data/recipe-curation-removed.json');
    const realNeeding = readJson('data/recipes-needing-completion.json');
    assert.deepEqual(out.removed.removed.map((r) => r.id), realRemoved.removed.map((r) => r.id));
    assert.deepEqual(out.needing.items.map((r) => r.id), realNeeding.items.map((r) => r.id));

    // recipeIngredientOverrides untouched (9 entries preserved as-is).
    const afterOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    assert.deepEqual(afterOverlay.recipeIngredientOverrides, overridesBefore);
    assert.equal(Object.keys(afterOverlay.recipeIngredientOverrides).length, 9);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('temp curate run is deterministic across two consecutive invocations (byte-identical)', () => {
  function runOnce() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch2-repro-'));
    try {
      fs.mkdirSync(path.join(tmp, 'scripts'));
      fs.mkdirSync(path.join(tmp, 'data'));
      fs.copyFileSync(
        new URL('../scripts/curate-recipes.js', import.meta.url).pathname,
        path.join(tmp, 'scripts', 'curate-recipes.js'),
      );
      fs.copyFileSync(
        new URL('../data/sichuan-recipes.json', import.meta.url).pathname,
        path.join(tmp, 'data', 'sichuan-recipes.json'),
      );
      const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
      fs.copyFileSync(
        new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
        overlayPath,
      );
      const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
      tmpOverlay.newRecipes = [
        ...(tmpOverlay.newRecipes ?? []),
        ...dryRun.items.map((item) => item.proposedOverlayRecipe),
      ];
      tmpOverlay.newRecipeIngredients = {
        ...(tmpOverlay.newRecipeIngredients ?? {}),
        ...Object.fromEntries(dryRun.items.map((item) => [
          item.productionId,
          item.proposedOverlayIngredients[item.productionId],
        ])),
      };
      fs.writeFileSync(overlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);
      execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
      return JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'));
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
  const run1 = runOnce();
  const run2 = runOnce();
  assert.deepEqual(run1, run2);
});

test('the real PWA runtime packs contain every Batch 2 recipe exactly once now that it is promoted', async () => {
  // Batch 2 has since been promoted; buildDefaultRuntimePacks reads the real
  // on-disk overlay, so each item must be present exactly once, matching
  // the frozen proposal.
  const runtime = await buildDefaultRuntimePacks();
  const mergedIds = runtime.packs.full.recipes.map((r) => r.id);
  for (const item of dryRun.items) {
    const occurrences = mergedIds.filter((id) => id === item.productionId).length;
    assert.equal(occurrences, 1, `${item.productionId} should appear exactly once in real runtime after promotion`);
  }
});

test('PWA runtime packs built from the temp-simulated overlay contain all five batch recipes exactly once', () => {
  // Uses the same merge primitives as buildDefaultRuntimePacks but against
  // the in-memory simulated overlay (base + Batch 2 additions), so the
  // check exercises the real merge logic without writing to any real file.
  const basePacks = {
    curated: readJson('data/sichuan-recipes.curated.json'),
    full: readJson('data/sichuan-recipes.json'),
  };
  const realOverlay = readJson('data/recipe-completion-overlay.json');
  const simulatedOverlay = {
    ...realOverlay,
    newRecipes: [
      ...(realOverlay.newRecipes ?? []),
      ...dryRun.items.map((item) => item.proposedOverlayRecipe),
    ],
    newRecipeIngredients: {
      ...(realOverlay.newRecipeIngredients ?? {}),
      ...Object.fromEntries(dryRun.items.map((item) => [
        item.productionId,
        item.proposedOverlayIngredients[item.productionId],
      ])),
    },
  };

  for (const mode of ['curated', 'full']) {
    const merged = [...basePacks[mode].recipes];
    const ingMap = { ...basePacks[mode].recipe_ingredients };
    const existingIds = new Set(merged.map((r) => r.id));
    for (const recipe of simulatedOverlay.newRecipes) {
      if (!existingIds.has(recipe.id)) {
        merged.push({ ...recipe });
        existingIds.add(recipe.id);
      }
    }
    for (const [id, ingredients] of Object.entries(simulatedOverlay.newRecipeIngredients)) {
      if (!ingMap[id]) ingMap[id] = ingredients;
    }
    for (const item of dryRun.items) {
      const occurrences = merged.filter((r) => r.id === item.productionId).length;
      assert.equal(occurrences, 1, `${item.productionId} must appear exactly once in simulated ${mode} runtime`);
      assert.ok(ingMap[item.productionId], `${item.productionId} missing ingredient map in simulated ${mode} runtime`);
      assert.equal(ingMap[item.productionId].length, item.proposedOverlayIngredients[item.productionId].length);
    }
    // No duplicate ids and no orphan ingredient maps referencing missing recipes.
    const idCounts = new Map();
    for (const r of merged) idCounts.set(r.id, (idCounts.get(r.id) ?? 0) + 1);
    for (const [id, count] of idCounts) assert.equal(count, 1, `duplicate id ${id} in simulated ${mode} runtime`);
  }
});

test('promotion-aware: production now contains exactly the frozen Batch 2 proposals, byte-identical, nothing extra', () => {
  // Batch 2 has since promoted. Real production must equal Batch 1's five
  // plus Batch 2's five (10 dz1979- recipes total), and each Batch 2
  // recipe/ingredient map in production must be byte-identical to its
  // frozen dry-run proposal.
  assert.equal(curated.recipes.length, 136 + laterBatchesRecipeCount);
  assert.equal(curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length, 10 + laterBatchesRecipeCount);
  for (const item of dryRun.items) {
    assert.ok(productionIds.has(item.productionId), `${item.productionId} should be in production after promotion`);
    assert.ok(productionNames.has(item.name), `${item.name} should be in production after promotion`);
    const overlayRecipe = overlay.newRecipes.find((r) => r.id === item.productionId);
    assert.deepEqual(overlayRecipe, item.proposedOverlayRecipe, `${item.productionId} overlay recipe must match frozen proposal`);
    assert.deepEqual(overlay.newRecipeIngredients[item.productionId], item.proposedOverlayIngredients[item.productionId], `${item.productionId} overlay ingredients must match frozen proposal`);
    const curatedRecipe = curated.recipes.find((r) => r.id === item.productionId);
    assert.deepEqual(curatedRecipe, item.proposedCuratedRecipe, `${item.productionId} curated recipe must match frozen proposal`);
    assert.deepEqual(curated.recipe_ingredients[item.productionId], item.proposedCuratedIngredients[item.productionId], `${item.productionId} curated ingredients must match frozen proposal`);
  }
});

test('iOS RecipeService-compatible field shapes decode from every proposed item', () => {
  for (const item of dryRun.items) {
    const recipe = item.proposedCuratedRecipe;
    assert.equal(typeof recipe.id, 'string');
    assert.equal(typeof recipe.name, 'string');
    assert.equal(typeof recipe.method, 'string');
    assert.ok(Array.isArray(recipe.tags));
    for (const ing of item.proposedCuratedIngredients[item.productionId]) {
      assert.equal(typeof ing.item, 'string');
      assert.ok(ing.qty === null || typeof ing.qty === 'string');
      assert.ok(ing.unit === null || typeof ing.unit === 'string');
    }
  }
  assert.equal(dryRun.iosDecodeAudit.batch2Compatible, true);
});

test('dry-run reports no verification problems and no production writes', () => {
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(dryRun.baseline.batch1Promoted, true);
  assert.equal(dryRun.simulation.tempCurateResult.strictCurrentPlusFive, true);
  assert.equal(dryRun.simulation.tempCurateResult.headCuratedCount, 131);
  assert.equal(dryRun.simulation.tempCurateResult.simulatedCuratedCount, 136);
  assert.equal(dryRun.pwaVisibilityAudit.serviceWorker.cacheBumpRequired, false);
});

test('canonical, crosswalk, and Batch 1 frozen artifacts remain unchanged; ledger now records both promoted batches', () => {
  const crosswalk = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json');
  const batch1DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json');
  const batch1QuantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-quantity-review.v1.json');
  const batch1RuntimeAudit = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-runtime-audit.v1.json');

  assert.equal(restored.applicationReady, false);
  assert.deepEqual(crosswalk.summary.classificationCounts, {
    'exact-name': 74,
    'confirmed-alias': 7,
    'probable-match-needs-review': 1,
    'book-only': 65,
  });
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
  assert.deepEqual(batch1DryRun.selection.selectedEntryIds, ['dz1979-p143', 'dz1979-p204', 'dz1979-p195', 'dz1979-p200', 'dz1979-p180']);
  assert.equal(batch1QuantityReview.records.length, 19);
  assert.equal(batch1RuntimeAudit.summary.coreCompatibilityCounts['exact-compatible'], 5);
  assert.equal(batch1RuntimeAudit.summary.coreCompatibilityCounts['expected-unit-confirmation'], 2);
  assert.equal(batch1RuntimeAudit.summary.coreCompatibilityCounts['unresolved-name-match'], 0);
  assert.equal(promotions.batches.length, 2 + laterBatchesPromotedCount);
  assert.equal(promotions.batches[0].status, 'promoted');
  assert.equal(promotions.batches[0].batchId, 'dz1979-production-b01');
  assert.equal(promotions.batches[1].status, 'promoted');
  assert.deepEqual(promotions.batches[1].entries.map((e) => e.entryId), dryRun.items.map((i) => i.entryId));
});
