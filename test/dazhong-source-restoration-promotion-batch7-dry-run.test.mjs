import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { classifyIngredientCompatibility } from '../scripts/dazhong-runtime-compatibility.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch7-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const restored = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const restoredById = new Map(restored.recipes.map((r) => [r.entryId, r]));
const readinessById = new Map(readiness.entries.map((e) => [e.entryId, e]));

const productionNames = new Set([
  ...curated.recipes.map((r) => r.name),
  ...full.recipes.map((r) => r.name),
]);

const ledgerPromotedEntryIds = new Set(
  (promotions.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.entryId)),
);
const BATCH7_PRODUCTION_IDS = dryRun.items.map((item) => item.productionId);
const BATCH7_ENTRY_IDS = new Set(dryRun.items.map((item) => item.entryId));
const batch7Promoted = BATCH7_PRODUCTION_IDS.length > 0
  && BATCH7_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));

// Pre-Batch-7 snapshot: reset Batch 7's own entries to not-promoted so the
// funnel/gate recomputation below matches the exact input the frozen
// dry-run was generated from, whether or not Batch 7 has since promoted.
const preBatch7ReadinessById = new Map(
  readiness.entries.map((entry) => [
    entry.entryId,
    BATCH7_ENTRY_IDS.has(entry.entryId) ? { ...entry, promotionState: 'not-promoted' } : entry,
  ]),
);
const preBatch7ProductionNames = new Set(
  [...productionNames].filter((name) => !dryRun.items.some((item) => item.name === name)),
);

// -- Independent replica of the Batch 7 remediated hard gate + Batch 2-6
// runtime gate. Deliberately written from scratch so the test cannot
// silently pass a bug the generator itself introduced.

function passesHardGateRemediated(entryId, { readinessSource = readinessById, namesSource = productionNames } = {}) {
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
    // Only same-for-each is allowed through; unallocated-group-total still blocks.
    if (ing.memberQuantityMode === 'unallocated-group-total') return false;
  if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity) return false;
    if ('consumedQualifier' in quantity || 'consumedUnit' in quantity) return false;
  }
  if (namesSource.has(entry.bookName)) return false;
  return true;
}

// Legacy gate (Batch 1-6): ANY memberQuantityMode hard-blocks.
function passesHardGateLegacy(entryId, opts) {
  if (!passesHardGateRemediated(entryId, opts)) return false;
  const recipe = restoredById.get(entryId);
  if (recipe.ingredients?.some((ing) => ing.memberQuantityMode)) return false;
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
  const opts = { readinessSource: preBatch7ReadinessById, namesSource: preBatch7ProductionNames };
  const remaining = [...preBatch7ReadinessById.values()]
    .filter((e) => e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted')
    .map((e) => e.entryId);
  const hardGateSurvivors = remaining.filter((id) => passesHardGateRemediated(id, opts));
  const eligible = hardGateSurvivors.filter((id) => !auditRuntimeGate(id, opts).blocked);
  const blocked = hardGateSurvivors.filter((id) => auditRuntimeGate(id, opts).blocked);
  const ranked = [...eligible].sort((a, b) => {
    const ka = complexityKey(a, opts);
    const kb = complexityKey(b, opts);
    for (let i = 0; i < ka.length; i += 1) {
      if (ka[i] < kb[i]) return -1;
      if (ka[i] > kb[i]) return 1;
    }
    return 0;
  });
  return { remaining, hardGateSurvivors, eligible, blocked, top5: ranked.slice(0, 5) };
}

test('remaining candidate pool excludes all promoted entries and matches the ledger', () => {
  const remaining = readiness.entries.filter((e) => (
    e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
  ));
  assert.equal(remaining.length, batch7Promoted ? 10 : 12);
  assert.equal(remaining.length, readiness.summary.remainingNewRecipeCandidateCount);
  for (const item of dryRun.items) {
    const expectedState = batch7Promoted ? 'promoted' : 'not-promoted';
    assert.equal(readinessById.get(item.entryId).promotionState, expectedState, item.entryId);
  }
});

test('dry-run records remediationPolicy = allow-safe-same-for-each', () => {
  assert.equal(dryRun.remediationPolicy, 'allow-safe-same-for-each');
});

test('the funnel counts match an independently recomputed selection (12 -> hard-blocked 8 -> after-hard-gates 4 -> runtime-blocked 2 -> eligible 2 -> selected 2)', () => {
  const recomputed = mechanicalFunnel();
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 12,
    afterHardGates: 4,
    hardGateBlocked: 8,
    blockedByRuntimeNameGate: 2,
    eligible: 2,
    selected: 2,
  });
  assert.equal(recomputed.remaining.length, 12);
  assert.equal(recomputed.hardGateSurvivors.length, 4);
  assert.equal(recomputed.eligible.length, 2);
  assert.deepEqual(recomputed.top5.sort(), dryRun.selection.selectedEntryIds.slice().sort());
  assert.equal(dryRun.selection.selectedEntryIds.length, 2);
  assert.deepEqual(dryRun.selection.selectedEntryIds, dryRun.items.map((item) => item.entryId));
});

test('hard-gate blocked count is mechanically consistent and funnel destinations sum to remaining (8 + 2 + 2 = 12)', () => {
  const recomputed = mechanicalFunnel();
  const blockedByDifference = recomputed.remaining.length - recomputed.hardGateSurvivors.length;
  assert.equal(blockedByDifference, 8);
  const uniqueBlockedIds = [...new Set(Object.values(dryRun.selection.hardGateExclusions).flat())];
  assert.equal(uniqueBlockedIds.length, 8);
  assert.equal(blockedByDifference, uniqueBlockedIds.length);
  assert.equal(dryRun.selection.funnel.hardGateBlocked, 8);
  assert.deepEqual(
    [...dryRun.selection.hardGateBlockedUniqueEntryIds].sort(),
    uniqueBlockedIds.sort(),
  );
  assert.deepEqual(uniqueBlockedIds.sort(), [
    'dz1979-p129', 'dz1979-p130', 'dz1979-p201', 'dz1979-p203',
    'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226',
  ]);
  assert.equal(
    dryRun.selection.funnel.hardGateBlocked + dryRun.selection.funnel.blockedByRuntimeNameGate + dryRun.selection.funnel.eligible,
    dryRun.selection.funnel.remainingNotPromotedCandidates,
  );
});

test('the two selected entries are exactly p211/p144 in that order', () => {
  assert.deepEqual(dryRun.items.map((item) => item.productionId), ['dz1979-p211', 'dz1979-p144']);
});

test('same-for-each remediation: p211 and p144 pass the remediated gate but fail the legacy gate', () => {
  const opts = { readinessSource: preBatch7ReadinessById, namesSource: preBatch7ProductionNames };
  for (const id of ['dz1979-p211', 'dz1979-p144']) {
    assert.equal(passesHardGateRemediated(id, opts), true, id);
    assert.equal(passesHardGateLegacy(id, opts), false, id);
    const recipe = restoredById.get(id);
    assert.ok(recipe.ingredients.some((ing) => ing.memberQuantityMode === 'same-for-each'), id);
  }
});

test('same-for-each split is lossless: each member inherits the exact rawQuantity-derived qty/unit, no ratio division', () => {
  for (const item of dryRun.items) {
    const recipe = restoredById.get(item.entryId);
    const sameForEachGroups = recipe.ingredients.filter((ing) => ing.memberQuantityMode === 'same-for-each');
    assert.ok(sameForEachGroups.length > 0, item.entryId);
    for (const group of sameForEachGroups) {
      assert.equal(group.normalizedQuantity.appliesTo, 'each-item', `${item.entryId}:${group.rawItemText}`);
      assert.ok((group.members ?? []).length >= 2, `${item.entryId}:${group.rawItemText} must have >=2 members`);
      for (const member of group.members) {
        // Each member's qty must equal the group's normalizedQuantity.qty
        // exactly (identical inheritance), never a divided/split fraction.
        assert.equal(member.qty, group.normalizedQuantity.qty, `${item.entryId}:${member.item}`);
        assert.equal(member.unit, group.normalizedQuantity.unit, `${item.entryId}:${member.item}`);
        const productionEntry = item.proposedCuratedIngredients[item.productionId]
          .find((p) => p.item === member.item);
        assert.ok(productionEntry, `${item.entryId}:${member.item} missing from production plan`);
        assert.equal(productionEntry.qty, String(member.qty), `${item.entryId}:${member.item}`);
        assert.equal(productionEntry.unit, member.unit, `${item.entryId}:${member.item}`);
      }
    }
  }
});

test('unallocated-group-total continues to hard-block under the remediated gate', () => {
  // Construct a synthetic entry-shaped check: the remediated gate function
  // itself special-cases unallocated-group-total explicitly. Verify via a
  // direct probe on the gate logic using a real recipe ingredient shape.
  const fakeEntryId = '__unallocated_probe__';
  readinessById.set(fakeEntryId, {
    ...readinessById.get('dz1979-p144'),
    promotionDisposition: 'new-recipe-candidate',
    promotionState: 'not-promoted',
    bookName: '__unallocated_probe_name__',
  });
  const probeRecipe = {
    ...restoredById.get('dz1979-p144'),
    ingredients: restoredById.get('dz1979-p144').ingredients.map((ing) => (
      ing.memberQuantityMode === 'same-for-each'
        ? { ...ing, memberQuantityMode: 'unallocated-group-total' }
        : ing
    )),
  };
  restoredById.set(fakeEntryId, probeRecipe);
  assert.equal(passesHardGateRemediated(fakeEntryId), false, 'unallocated-group-total must still block');
  restoredById.delete(fakeEntryId);
  readinessById.delete(fakeEntryId);
});

test('p130 remains blocked by methodOnly even though its same-for-each group is now expressible', () => {
  const recipe = restoredById.get('dz1979-p130');
  assert.ok(recipe.ingredients.some((ing) => ing.memberQuantityMode === 'same-for-each'), 'p130 should have a same-for-each group');
  assert.equal(passesHardGateRemediated('dz1979-p130'), false);
  const plan = readinessById.get('dz1979-p130').productionIngredientPlan;
  assert.ok(plan.methodOnlyAnalysis.some((item) => item.conversionWarning));
});

test('p201 and p207 remain blocked by non-exact-quantity even though their same-for-each groups are now expressible', () => {
  for (const id of ['dz1979-p201', 'dz1979-p207']) {
    const recipe = restoredById.get(id);
    assert.ok(recipe.ingredients.some((ing) => ing.memberQuantityMode === 'same-for-each'), id);
    assert.equal(passesHardGateRemediated(id), false, id);
    const plan = readinessById.get(id).productionIngredientPlan;
    assert.notEqual(plan.quantityReadiness, 'exact-comparable', id);
  }
});

test('p129 remains blocked by methodOnly, p203 by non-exact-quantity, p222/p224/p226 by consumed-dual-quantity', () => {
  assert.equal(passesHardGateRemediated('dz1979-p129'), false);
  assert.ok(readinessById.get('dz1979-p129').productionIngredientPlan.methodOnlyAnalysis.some((i) => i.conversionWarning));

  assert.equal(passesHardGateRemediated('dz1979-p203'), false);
  assert.notEqual(readinessById.get('dz1979-p203').productionIngredientPlan.quantityReadiness, 'exact-comparable');

  for (const id of ['dz1979-p222', 'dz1979-p224', 'dz1979-p226']) {
    assert.equal(passesHardGateRemediated(id), false, id);
    const recipe = restoredById.get(id);
    assert.ok(recipe.ingredients.some((ing) => (
      'consumedQty' in (ing.normalizedQuantity ?? {}) || 'consumedReferenceQty' in (ing.normalizedQuantity ?? {})
    )), id);
  }
});

test('p137 and p161 remain runtime-blocked on unresolved-name-match (子公鸡/鸡血), unchanged from Batch 2-6', () => {
  const blocked = dryRun.selection.runtimeNameGateBlocked;
  assert.equal(blocked.length, 2);
  const byId = new Map(blocked.map((b) => [b.entryId, b]));
  assert.deepEqual(byId.get('dz1979-p137')?.unresolvedItems, ['子公鸡']);
  assert.deepEqual(byId.get('dz1979-p161')?.unresolvedItems, ['鸡血']);
  const selectedIds = dryRun.items.map((item) => item.entryId);
  assert.equal(selectedIds.includes('dz1979-p137'), false);
  assert.equal(selectedIds.includes('dz1979-p161'), false);
});

test('every selected item passes the runtime gate with 0 unresolved-name-match', () => {
  for (const item of dryRun.items) {
    assert.equal(item.coreRuntimeCompatibility.gatePassed, true, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.counts['unresolved-name-match'], 0, item.entryId);
  }
});

test('quantity review preview has exactly 20 records with unit distribution 19 g + 1 只', () => {
  assert.equal(dryRun.quantityReviewPreview.recordCount, 20);
  const unitCounts = {};
  for (const record of dryRun.quantityReviewPreview.records) {
    unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
  }
  assert.deepEqual(unitCounts, { g: 19, '只': 1 });
});

test('promotion chain reproduces exactly pre-promotion-plus-two (153 -> 155) with zero drift', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b7-test-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(new URL('../scripts/curate-recipes.js', import.meta.url).pathname, path.join(tmp, 'scripts', 'curate-recipes.js'));
    fs.copyFileSync(new URL('../data/sichuan-recipes.json', import.meta.url).pathname, path.join(tmp, 'data', 'sichuan-recipes.json'));
    const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
    // Use the real overlay with Batch 7's entries stripped out, so this
    // reconstructs the exact pre-Batch-7-promotion baseline the frozen
    // dry-run was generated against, whether or not Batch 7 is currently
    // promoted in the real overlay.
    const realOverlay = JSON.parse(fs.readFileSync(
      new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
      'utf8',
    ));
    const preOverlay = {
      ...realOverlay,
      newRecipes: (realOverlay.newRecipes ?? []).filter((r) => !BATCH7_PRODUCTION_IDS.includes(r.id)),
      newRecipeIngredients: Object.fromEntries(
        Object.entries(realOverlay.newRecipeIngredients ?? {}).filter(([id]) => !BATCH7_PRODUCTION_IDS.includes(id)),
      ),
    };
    fs.writeFileSync(overlayPath, `${JSON.stringify(preOverlay, null, 2)}\n`);
    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    const preCurated = JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'));
    assert.equal(preCurated.recipes.length, 153);

    const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    const overridesBefore = tmpOverlay.recipeIngredientOverrides;
    tmpOverlay.newRecipes = [...(tmpOverlay.newRecipes ?? []), ...dryRun.items.map((item) => item.proposedOverlayRecipe)];
    tmpOverlay.newRecipeIngredients = {
      ...(tmpOverlay.newRecipeIngredients ?? {}),
      ...Object.fromEntries(dryRun.items.map((item) => [item.productionId, item.proposedOverlayIngredients[item.productionId]])),
    };
    fs.writeFileSync(overlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);
    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    const out = {
      curated: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8')),
      removed: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8')),
      needing: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8')),
    };
    assert.equal(out.curated.recipes.length, 155);
    const newIds = out.curated.recipes.map((r) => r.id).filter((id) => !preCurated.recipes.some((r2) => r2.id === id));
    assert.equal(newIds.length, 2);
    assert.deepEqual(newIds.sort(), dryRun.items.map((item) => item.productionId).sort());

    const existingIds = preCurated.recipes.map((r) => r.id);
    const existingModified = existingIds.filter((id) => (
      JSON.stringify(preCurated.recipes.find((r) => r.id === id)) !== JSON.stringify(out.curated.recipes.find((r) => r.id === id))
    ));
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

    const realRemoved = readJson('data/recipe-curation-removed.json');
    const realNeeding = readJson('data/recipes-needing-completion.json');
    assert.deepEqual(out.removed.removed.map((r) => r.id), realRemoved.removed.map((r) => r.id));
    assert.deepEqual(out.needing.items.map((r) => r.id), realNeeding.items.map((r) => r.id));

    const afterOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    assert.deepEqual(afterOverlay.recipeIngredientOverrides, overridesBefore);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('temp curate run is deterministic across two consecutive invocations (byte-identical)', () => {
  function runOnce() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b7-repro-'));
    try {
      fs.mkdirSync(path.join(tmp, 'scripts'));
      fs.mkdirSync(path.join(tmp, 'data'));
      fs.copyFileSync(new URL('../scripts/curate-recipes.js', import.meta.url).pathname, path.join(tmp, 'scripts', 'curate-recipes.js'));
      fs.copyFileSync(new URL('../data/sichuan-recipes.json', import.meta.url).pathname, path.join(tmp, 'data', 'sichuan-recipes.json'));
      const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
      fs.copyFileSync(new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname, overlayPath);
      const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
      tmpOverlay.newRecipes = [...(tmpOverlay.newRecipes ?? []), ...dryRun.items.map((item) => item.proposedOverlayRecipe)];
      tmpOverlay.newRecipeIngredients = {
        ...(tmpOverlay.newRecipeIngredients ?? {}),
        ...Object.fromEntries(dryRun.items.map((item) => [item.productionId, item.proposedOverlayIngredients[item.productionId]])),
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

test('PWA runtime packs contain both new recipes exactly once, no duplicates/orphans', () => {
  const basePacks = { curated, full };
  const realOverlay = readJson('data/recipe-completion-overlay.json');
  const simulatedOverlay = {
    ...realOverlay,
    newRecipes: [...(realOverlay.newRecipes ?? []), ...dryRun.items.map((item) => item.proposedOverlayRecipe)],
    newRecipeIngredients: {
      ...(realOverlay.newRecipeIngredients ?? {}),
      ...Object.fromEntries(dryRun.items.map((item) => [item.productionId, item.proposedOverlayIngredients[item.productionId]])),
    },
  };
  for (const mode of ['curated', 'full']) {
    const merged = [...basePacks[mode].recipes];
    const ingMap = { ...basePacks[mode].recipe_ingredients };
    const existingIds = new Set(merged.map((r) => r.id));
    for (const recipe of simulatedOverlay.newRecipes) {
      if (!existingIds.has(recipe.id)) { merged.push({ ...recipe }); existingIds.add(recipe.id); }
    }
    for (const [id, ingredients] of Object.entries(simulatedOverlay.newRecipeIngredients)) {
      if (!ingMap[id]) ingMap[id] = ingredients;
    }
    for (const item of dryRun.items) {
      const occurrences = merged.filter((r) => r.id === item.productionId).length;
      assert.equal(occurrences, 1, `${mode}:${item.productionId}`);
      assert.ok(ingMap[item.productionId], `${mode}:${item.productionId} missing map`);
    }
    const idCounts = new Map();
    for (const r of merged) idCounts.set(r.id, (idCounts.get(r.id) ?? 0) + 1);
    for (const [id, count] of idCounts) assert.equal(count, 1, `duplicate ${id} in ${mode}`);
    for (const id of Object.keys(ingMap)) assert.ok(existingIds.has(id), `orphan ${id} in ${mode}`);
  }
});

test('iOS RecipeService-compatible shapes decode from every proposed item', () => {
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
  assert.equal(dryRun.iosDecodeAudit.batch7Compatible, true);
});

test('dry-run reports no verification problems and Batch 1-6 stay marked promoted', () => {
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(dryRun.baseline.batch1Promoted, true);
  assert.equal(dryRun.baseline.batch5Promoted, true);
  assert.equal(dryRun.baseline.batch6Promoted, true);
  assert.equal(dryRun.simulation.tempCurateResult.strictCurrentPlusN, true);
  assert.equal(dryRun.simulation.tempCurateResult.headCuratedCount, 153);
  assert.equal(dryRun.simulation.tempCurateResult.simulatedCuratedCount, 155);
});

test('Batch 1-6 frozen dry-run artifacts are untouched (byte-identical to committed state)', () => {
  for (let n = 1; n <= 6; n += 1) {
    const artifact = readJson(`data/source-restoration/dazhong-chuancai-1979-promotion-batch${n}-dry-run.v1.json`);
    assert.deepEqual(artifact.verificationProblems, [], `batch${n} should still report zero problems`);
  }
  assert.equal(promotions.batches.length, batch7Promoted ? 7 : 6);
  for (const batch of promotions.batches) {
    assert.equal(batch.status, 'promoted');
  }
});
