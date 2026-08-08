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

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch3-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const restored = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const batch2DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch2-dry-run.v1.json');
const batch1DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json');
const batch4DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch4-dry-run.v1.json');
const batch5DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch5-dry-run.v1.json');
const batch6DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');
const batch7DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch7-dry-run.v1.json');

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

// Batch 3 may since have been promoted (dz1979-production-b03 in the
// ledger). This file is a regression test on the frozen dry-run artifact
// itself, so it stays promotion-aware: it reconstructs the exact
// pre-Batch-3-promotion readiness/production view the dry-run was
// generated against (treating only Batch 3's own five entries as
// not-yet-promoted / not-yet-in-production) to validate the funnel and
// hard/runtime gates were computed correctly, while separately asserting
// current production matches the frozen proposal with zero drift. The
// frozen dry-run/quantity-review artifacts and every gate rule are
// unchanged; nothing here weakens a gate.
const BATCH3_PRODUCTION_IDS = dryRun.items.map((item) => item.productionId);
const BATCH3_ENTRY_IDS = new Set(dryRun.items.map((item) => item.entryId));
const batch3Promoted = BATCH3_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
// Batch 4 may since have promoted on top of Batch 3; its entries must also
// be reset to their pre-Batch-3 (not-promoted) state when reconstructing
// the exact snapshot Batch 3's dry-run was generated against, otherwise the
// recomputed remaining/eligible pools would incorrectly exclude Batch 4's
// entries too.
const BATCH4_PRODUCTION_IDS = batch4DryRun.items.map((item) => item.productionId);
const BATCH4_ENTRY_IDS = new Set(batch4DryRun.items.map((item) => item.entryId));
const batch4Promoted = BATCH4_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
// Batch 5 may since have promoted too, adding another five beyond Batch 4;
// its entries must also be reset to their pre-Batch-3 state for the same
// reason as Batch 4's.
const BATCH5_PRODUCTION_IDS = batch5DryRun.items.map((item) => item.productionId);
const BATCH5_ENTRY_IDS = new Set(batch5DryRun.items.map((item) => item.entryId));
const batch5Promoted = BATCH5_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const BATCH6_PRODUCTION_IDS = batch6DryRun.items.map((item) => item.productionId);
const BATCH6_ENTRY_IDS = new Set(batch6DryRun.items.map((item) => item.entryId));
const batch6Promoted = BATCH6_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const BATCH7_PRODUCTION_IDS = batch7DryRun.items.map((item) => item.productionId);
const BATCH7_ENTRY_IDS = new Set(batch7DryRun.items.map((item) => item.entryId));
const batch7Promoted = BATCH7_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));
const RESET_TO_NOT_PROMOTED_ENTRY_IDS = new Set([...BATCH3_ENTRY_IDS, ...BATCH4_ENTRY_IDS, ...BATCH5_ENTRY_IDS, ...BATCH6_ENTRY_IDS, ...BATCH7_ENTRY_IDS]);
const RESET_TO_NOT_PROMOTED_PRODUCTION_IDS = new Set([...BATCH3_PRODUCTION_IDS, ...BATCH4_PRODUCTION_IDS, ...BATCH5_PRODUCTION_IDS, ...BATCH6_PRODUCTION_IDS, ...BATCH7_PRODUCTION_IDS]);

const preBatch3ReadinessById = new Map(
  readiness.entries.map((entry) => [
    entry.entryId,
    RESET_TO_NOT_PROMOTED_ENTRY_IDS.has(entry.entryId) ? { ...entry, promotionState: 'not-promoted' } : entry,
  ]),
);
const preBatch3ProductionNames = new Set(
  [...productionNames].filter((name) => (
    !dryRun.items.some((item) => item.name === name)
    && !batch4DryRun.items.some((item) => item.name === name)
    && !batch5DryRun.items.some((item) => item.name === name)
    && !batch6DryRun.items.some((item) => item.name === name)
    && !batch7DryRun.items.some((item) => item.name === name)
  )),
);

// -- Independent replica of the hard gate + Batch 2/3 runtime gate ----------
// Deliberately written from scratch against readiness/canonical data rather
// than importing the generator, so the test cannot silently pass a bug the
// generator itself introduced.

function passesHardGates(entryId, { readinessSource = readinessById, namesSource = productionNames } = {}) {
  const entry = readinessSource.get(entryId);
  const recipe = restoredById.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
  if (entry.promotionState !== 'not-promoted') return false;
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
  if (namesSource.has(entry.bookName)) return false;
  return true;
}

function auditRuntimeGate(entryId, { readinessSource = readinessById } = {}) {
  const entry = readinessSource.get(entryId);
  const coreResults = [];
  for (const ing of entry.productionIngredientPlan.inventoryIngredients) {
    const result = classifyIngredientCompatibility(ing.productionItem, ing.qty, ing.unit);
    if (result.role === 'core') coreResults.push(result);
  }
  const unresolvedCount = coreResults.filter((r) => r.compatibility === 'unresolved-name-match').length;
  const unitConfirmationCount = coreResults.filter((r) => r.compatibility === 'expected-unit-confirmation').length;
  return { unresolvedCount, unitConfirmationCount, blocked: unresolvedCount > 0 };
}

function complexityKey(entryId, opts) {
  const recipe = restoredById.get(entryId);
  const audit = auditRuntimeGate(entryId, opts);
  const special = recipe.ingredients.filter((ing) => ing.memberQuantityMode).length;
  return [audit.unitConfirmationCount, special, recipe.ingredients.length, recipe.methodSummary?.steps?.length ?? 0, entryId];
}

function mechanicalFunnel() {
  // Recomputed against the pre-Batch-3-promotion snapshot, matching the
  // exact input the frozen dry-run was generated from.
  const opts = { readinessSource: preBatch3ReadinessById, namesSource: preBatch3ProductionNames };
  const remaining = [...preBatch3ReadinessById.values()]
    .filter((e) => e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted')
    .map((e) => e.entryId);
  const hardGateSurvivors = remaining.filter((id) => passesHardGates(id, opts));
  const eligible = hardGateSurvivors.filter((id) => !auditRuntimeGate(id, opts).blocked);
  const blocked = hardGateSurvivors.filter((id) => auditRuntimeGate(id, opts).blocked);
  const top5 = [...eligible].sort((a, b) => {
    const ka = complexityKey(a, opts);
    const kb = complexityKey(b, opts);
    for (let i = 0; i < ka.length; i += 1) {
      if (ka[i] < kb[i]) return -1;
      if (ka[i] > kb[i]) return 1;
    }
    return 0;
  }).slice(0, 5);
  return { remaining, hardGateSurvivors, eligible, blocked, top5 };
}

test('remaining candidate pool excludes all promoted entries and matches the ledger', () => {
  const remaining = readiness.entries.filter((e) => (
    e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
  ));
  // Each of Batch 3, 4, and 5 (if promoted) removes five more from the
  // original 29-candidate pool this dry-run was generated against.
  const expectedRemaining = 29 - (batch3Promoted ? 5 : 0) - (batch4Promoted ? 5 : 0) - (batch5Promoted ? 5 : 0) - (batch6Promoted ? 2 : 0) - (batch7Promoted ? 2 : 0);
  assert.equal(remaining.length, expectedRemaining);
  assert.equal(remaining.length, readiness.summary.remainingNewRecipeCandidateCount);
  for (const entry of remaining) {
    assert.equal(ledgerPromotedEntryIds.has(entry.entryId), false, `${entry.entryId} should not be in the remaining pool`);
  }
  const expectedLedgerSize = 10 + (batch3Promoted ? 5 : 0) + (batch4Promoted ? 5 : 0) + (batch5Promoted ? 5 : 0) + (batch6Promoted ? 2 : 0) + (batch7Promoted ? 2 : 0);
  assert.equal(ledgerPromotedEntryIds.size, expectedLedgerSize);
  // Batch 3's five entries must have a promotionState consistent with the
  // ledger: promoted if and only if the ledger records them as promoted.
  for (const item of dryRun.items) {
    const expectedState = batch3Promoted ? 'promoted' : 'not-promoted';
    assert.equal(readinessById.get(item.entryId).promotionState, expectedState, item.entryId);
    assert.equal(ledgerPromotedEntryIds.has(item.entryId), batch3Promoted, item.entryId);
  }
});

test('the funnel counts match an independently recomputed selection (29 -> 19 -> 17 -> 5)', () => {
  const recomputed = mechanicalFunnel();
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 29,
    afterHardGates: 19,
    blockedByRuntimeNameGate: 2,
    eligible: 17,
    selected: 5,
  });
  assert.equal(recomputed.remaining.length, 29);
  assert.equal(recomputed.hardGateSurvivors.length, 19);
  assert.equal(recomputed.eligible.length, 17);
  assert.deepEqual(recomputed.top5.sort(), dryRun.selection.selectedEntryIds.slice().sort());
  assert.equal(dryRun.selection.selectedEntryIds.length, 5);
  assert.deepEqual(dryRun.selection.selectedEntryIds, dryRun.items.map((item) => item.entryId));
});

test('the five selected entries are exactly p212/p216/p218/p221/p206', () => {
  assert.deepEqual(
    dryRun.items.map((item) => item.productionId),
    ['dz1979-p212', 'dz1979-p216', 'dz1979-p218', 'dz1979-p221', 'dz1979-p206'],
  );
});

test('runtime name gate blocks exactly dz1979-p137 and dz1979-p161 on their unresolved core items (unchanged from Batch 2)', () => {
  const blocked = dryRun.selection.runtimeNameGateBlocked;
  assert.equal(blocked.length, 2);
  const byId = new Map(blocked.map((b) => [b.entryId, b]));
  assert.equal(byId.get('dz1979-p137')?.bookName, '椒麻鸡块');
  assert.deepEqual(byId.get('dz1979-p137')?.unresolvedItems, ['子公鸡']);
  assert.equal(byId.get('dz1979-p161')?.bookName, '拌鸡血');
  assert.deepEqual(byId.get('dz1979-p161')?.unresolvedItems, ['鸡血']);
  assert.equal(readinessById.get('dz1979-p137').bookName, byId.get('dz1979-p137').bookName);
  assert.equal(readinessById.get('dz1979-p161').bookName, byId.get('dz1979-p161').bookName);
  // These two must not be selected in Batch 3, consistent with the
  // "do not fix in this round" instruction.
  const selectedIds = dryRun.items.map((item) => item.entryId);
  assert.equal(selectedIds.includes('dz1979-p137'), false);
  assert.equal(selectedIds.includes('dz1979-p161'), false);
});

test('every selected item satisfied both gates pre-promotion and has zero unit-confirmation core ingredients', () => {
  const opts = { readinessSource: preBatch3ReadinessById, namesSource: preBatch3ProductionNames };
  for (const item of dryRun.items) {
    // Pre-promotion, every selected item must have been not-promoted and
    // pass both gates against the exact snapshot the dry-run used.
    assert.equal(preBatch3ReadinessById.get(item.entryId).promotionState, 'not-promoted', item.entryId);
    assert.equal(passesHardGates(item.entryId, opts), true, item.entryId);
    const audit = auditRuntimeGate(item.entryId, opts);
    assert.equal(audit.blocked, false, item.entryId);
    assert.equal(audit.unresolvedCount, 0, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.gatePassed, true, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.counts['unresolved-name-match'], 0, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.counts['expected-unit-confirmation'], 0, item.entryId);
    assert.equal(item.productionId, `dz1979-p${catalogById.get(item.entryId).bookPage}`, item.entryId);
    assert.equal(item.name, catalogById.get(item.entryId).bookName, item.entryId);
    assert.equal(item.category, catalogById.get(item.entryId).category, item.entryId);
    assert.deepEqual(item.tags, ['川菜', catalogById.get(item.entryId).category], item.entryId);
    // Post-promotion, current readiness state must match the ledger.
    const expectedState = batch3Promoted ? 'promoted' : 'not-promoted';
    assert.equal(readinessById.get(item.entryId).promotionState, expectedState, item.entryId);
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
      assert.equal(record.qty, String(canonicalIngredient.normalizedQuantity.qty), `${item.entryId}:${record.item}`);
    }
  }
  assert.equal(totalRecords, 35);
  assert.equal(dryRun.quantityReviewPreview.recordCount, 35);
  assert.equal(dryRun.quantityReviewPreview.records.length, 35);
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

test('promotion chain reproduces exactly pre-promotion-plus-five (136 -> 141) with zero drift', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch3-test-'));
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
    // Use the real overlay with Batch 3's (and any later Batch 4's) entries
    // stripped out, so this reconstructs the exact pre-Batch-3-promotion
    // baseline the frozen dry-run was generated against, whether or not
    // Batch 3/4 are currently promoted in the real overlay.
    const realOverlay = JSON.parse(fs.readFileSync(
      new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
      'utf8',
    ));
    const preOverlay = {
      ...realOverlay,
      newRecipes: (realOverlay.newRecipes ?? []).filter((r) => !RESET_TO_NOT_PROMOTED_PRODUCTION_IDS.has(r.id)),
      newRecipeIngredients: Object.fromEntries(
        Object.entries(realOverlay.newRecipeIngredients ?? {}).filter(([id]) => !RESET_TO_NOT_PROMOTED_PRODUCTION_IDS.has(id)),
      ),
    };
    fs.writeFileSync(overlayPath, `${JSON.stringify(preOverlay, null, 2)}\n`);
    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    const preCurated = JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'));
    assert.equal(preCurated.recipes.length, 136);

    const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    const overridesBefore = tmpOverlay.recipeIngredientOverrides;
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
    const out = {
      curated: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8')),
      removed: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8')),
      needing: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8')),
    };

    assert.equal(out.curated.recipes.length, 141);

    const newIds = out.curated.recipes.map((r) => r.id).filter((id) => !preCurated.recipes.some((r2) => r2.id === id));
    assert.equal(newIds.length, 5);
    assert.deepEqual(newIds.sort(), dryRun.items.map((item) => item.productionId).sort());

    const existingIds = preCurated.recipes.map((r) => r.id);
    const existingModified = existingIds.filter((id) => {
      const before = preCurated.recipes.find((r) => r.id === id);
      const after = out.curated.recipes.find((r) => r.id === id);
      return JSON.stringify(before) !== JSON.stringify(after);
    });
    const existingIngredientModified = existingIds.filter((id) => (
      JSON.stringify(preCurated.recipe_ingredients[id]) !== JSON.stringify(out.curated.recipe_ingredients[id])
    ));
    const existingDeleted = existingIds.filter((id) => !out.curated.recipes.some((r) => r.id === id));
    assert.equal(existingModified.length, 0);
    assert.equal(existingIngredientModified.length, 0);
    assert.equal(existingDeleted.length, 0);

    for (const id of newIds) {
      const recipe = out.curated.recipes.find((r) => r.id === id);
      assert.ok(recipe.method, `${id} missing method`);
      assert.ok(recipe.tags, `${id} missing tags`);
      assert.ok(out.curated.recipe_ingredients[id].length >= 2, `${id} incomplete map`);
      assert.equal(out.curated.recipes.filter((r) => r.id === id).length, 1, `${id} duplicated`);
    }

    // The real, current (post-promotion) curated file must match this
    // simulation exactly, proving zero drift from the frozen proposal.
    // (Only valid when Batch 4 has not also promoted, since real curated
    // would then also include Batch 4's five beyond this simulation's 141.)
    if (batch3Promoted && !batch4Promoted) {
      assert.deepEqual(
        [...out.curated.recipes].sort((a, b) => a.id.localeCompare(b.id)),
        [...curated.recipes].sort((a, b) => a.id.localeCompare(b.id)),
      );
    }

    const realRemoved = readJson('data/recipe-curation-removed.json');
    const realNeeding = readJson('data/recipes-needing-completion.json');
    if (batch3Promoted && !batch4Promoted) {
      assert.deepEqual(out.removed.removed.map((r) => r.id), realRemoved.removed.map((r) => r.id));
      assert.deepEqual(out.needing.items.map((r) => r.id), realNeeding.items.map((r) => r.id));
    }

    // recipeIngredientOverrides untouched.
    const afterOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    assert.deepEqual(afterOverlay.recipeIngredientOverrides, overridesBefore);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('temp curate run is deterministic across two consecutive invocations (byte-identical)', () => {
  function runOnce() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch3-repro-'));
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

test('PWA runtime packs built from the temp-simulated overlay contain all five batch recipes exactly once, no duplicates/orphans', () => {
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
    const idCounts = new Map();
    for (const r of merged) idCounts.set(r.id, (idCounts.get(r.id) ?? 0) + 1);
    for (const [id, count] of idCounts) assert.equal(count, 1, `duplicate id ${id} in simulated ${mode} runtime`);
    // No orphan ingredient maps referencing missing recipes.
    for (const id of Object.keys(ingMap)) {
      assert.ok(existingIds.has(id), `orphan ingredient map for missing recipe ${id} in simulated ${mode} runtime`);
    }
  }
});

test('production reflects the frozen proposal exactly: Batch 3 ids/names present iff promoted, matching the ledger', () => {
  for (const item of dryRun.items) {
    assert.equal(productionIds.has(item.productionId), batch3Promoted, `${item.productionId} presence must match ledger state`);
    assert.equal(productionNames.has(item.name), batch3Promoted, `${item.name} presence must match ledger state`);
  }
  // Batch 4/5/6 may have promoted on top of Batch 3, each adding more
  // recipes beyond Batch 3's own contribution.
  const expectedBase = batch3Promoted ? 141 : 136;
  const laterRecipeCount = (batch4Promoted ? 5 : 0) + (batch5Promoted ? 5 : 0) + (batch6Promoted ? 2 : 0) + (batch7Promoted ? 2 : 0);
  assert.equal(curated.recipes.length, expectedBase + laterRecipeCount);
  // Batch 4/5/6 may have promoted on top of Batch 3, adding more dz1979-
  // recipes; this only asserts Batch 3's own contribution is present.
  const dz1979Count = curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length;
  assert.equal(dz1979Count >= (batch3Promoted ? 15 : 10), true);
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
  assert.equal(dryRun.iosDecodeAudit.batch3Compatible, true);
});

test('dry-run reports no verification problems and no production writes', () => {
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(dryRun.baseline.batch1Promoted, true);
  assert.equal(dryRun.baseline.batch2Promoted, true);
  assert.equal(dryRun.simulation.tempCurateResult.strictCurrentPlusFive, true);
  assert.equal(dryRun.simulation.tempCurateResult.headCuratedCount, 136);
  assert.equal(dryRun.simulation.tempCurateResult.simulatedCuratedCount, 141);
  assert.equal(dryRun.pwaVisibilityAudit.serviceWorker.cacheBumpRequired, false);
});

test('canonical, crosswalk, and Batch 1/2 frozen artifacts remain unchanged; ledger records the expected number of promoted batches', () => {
  const crosswalk = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json');
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
  assert.deepEqual(batch2DryRun.selection.selectedEntryIds, ['dz1979-p187', 'dz1979-p202', 'dz1979-p205', 'dz1979-p188', 'dz1979-p196']);
  assert.deepEqual(batch1DryRun.verificationProblems, []);
  assert.deepEqual(batch2DryRun.verificationProblems, []);
  const expectedBatchCount = (batch3Promoted ? 3 : 2) + (batch4Promoted ? 1 : 0) + (batch5Promoted ? 1 : 0) + (batch6Promoted ? 1 : 0) + (batch7Promoted ? 1 : 0);
  assert.equal(promotions.batches.length, expectedBatchCount);
  assert.equal(promotions.batches[0].status, 'promoted');
  assert.equal(promotions.batches[1].status, 'promoted');
  // Batch 3's ledger presence must match its actual promotion state.
  assert.equal(promotions.batches.some((b) => b.batchId === 'dz1979-production-b03'), batch3Promoted);
  if (batch3Promoted) {
    const batch3 = promotions.batches.find((b) => b.batchId === 'dz1979-production-b03');
    assert.equal(batch3.status, 'promoted');
  }
});
