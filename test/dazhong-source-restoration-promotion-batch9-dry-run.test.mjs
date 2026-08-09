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

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json');
const batch10DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const restored = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const methodOnlyReview = readJson('data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json');
const repoRoot = path.resolve(new URL('..', import.meta.url).pathname);
const runtimeFixBaseline = '0e7e1d5de768cdd4be19f042f5d861087577f8e7';
const promotionBaseline = '532f19f37d76193e266bfd459d78a07cbeebf032';

const restoredById = new Map(restored.recipes.map((r) => [r.entryId, r]));
const readinessById = new Map(readiness.entries.map((e) => [e.entryId, e]));

const productionNames = new Set([
  ...curated.recipes.map((r) => r.name),
  ...full.recipes.map((r) => r.name),
]);

const ledgerPromotedEntryIds = new Set(
  (promotions.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.entryId)),
);
const BATCH9_PRODUCTION_IDS = dryRun.items.map((item) => item.productionId);
const BATCH9_ENTRY_IDS = new Set(dryRun.items.map((item) => item.entryId));
const BATCH10_PRODUCTION_IDS = batch10DryRun.items.map((item) => item.productionId);
const BATCH10_ENTRY_IDS = new Set(batch10DryRun.items.map((item) => item.entryId));
const batch9Promoted = BATCH9_PRODUCTION_IDS.length > 0
  && BATCH9_PRODUCTION_IDS.every((id) => ledgerPromotedEntryIds.has(id));

// Pre-Batch-9 snapshot: reset Batch 9's own entries to not-promoted so the
// funnel/gate recomputation below matches the exact input the frozen
// dry-run was generated from, whether or not Batch 9 has since promoted.
const preBatch9ReadinessById = new Map(
  readiness.entries.map((entry) => [
    entry.entryId,
    BATCH9_ENTRY_IDS.has(entry.entryId) || BATCH10_ENTRY_IDS.has(entry.entryId)
      ? { ...entry, promotionState: 'not-promoted' }
      : entry,
  ]),
);
const preBatch9ProductionNames = new Set(
  [...productionNames].filter((name) => (
    !dryRun.items.some((item) => item.name === name)
    && !batch10DryRun.items.some((item) => item.name === name)
  )),
);

const REVIEWED_ALLOWLIST = new Map([
  ['dz1979-p129', new Set(['姜', '花椒'])],
  ['dz1979-p130', new Set(['胡椒面'])],
]);

// -- Independent replica of the Batch 9 gate: inherited Batch 7 same-for-each
// remediation + frozen Batch 8 methodOnly-null allowlist. Deliberately written
// from scratch so the test cannot silently pass a bug the generator itself
// introduced.

function passesSameForEachGate(entryId, { skipMethodOnlyCheck = false, readinessSource = readinessById, namesSource = productionNames } = {}) {
  const entry = readinessSource.get(entryId);
  const recipe = restoredById.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
  if (entry.promotionState !== 'not-promoted') return false;
  if (entry.sourceQuality !== 'ready-for-later-promotion-review') return false;
  const plan = entry.productionIngredientPlan;
  if (plan.quantityReadiness !== 'exact-comparable') return false;
  if (plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) return false;
  if (!skipMethodOnlyCheck && plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) return false;
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
    if (ing.memberQuantityMode === 'unallocated-group-total') return false;
    if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity) return false;
    if ('consumedQualifier' in quantity || 'consumedUnit' in quantity) return false;
  }
  if (namesSource.has(entry.bookName)) return false;
  return true;
}

function passesMethodOnlyNullGate(entryId, allowlist = REVIEWED_ALLOWLIST, opts = {}) {
  if (!passesSameForEachGate(entryId, { ...opts, skipMethodOnlyCheck: true })) return false;
  const plan = (opts.readinessSource ?? readinessById).get(entryId).productionIngredientPlan;
  const allowedItems = allowlist.get(entryId) ?? new Set();
  for (const moi of plan.methodOnlyAnalysis) {
    if (!moi.conversionWarning) continue;
    const parts = moi.sourceRawItemText.split(/[、，,]/).map((s) => s.trim()).filter(Boolean);
    if (!parts.every((part) => allowedItems.has(part))) return false;
  }
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
  return { unresolvedCount, blocked: unresolvedCount > 0 };
}

test('remaining candidate pool excludes all promoted entries and matches the ledger', () => {
  const remaining = readiness.entries.filter((e) => (
    e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
  ));
  assert.equal(batch9Promoted, true);
  assert.equal(remaining.length, 3);
  assert.equal(remaining.length, readiness.summary.remainingNewRecipeCandidateCount);
  for (const item of dryRun.items) {
    const expectedState = batch9Promoted ? 'promoted' : 'not-promoted';
    assert.equal(readinessById.get(item.entryId).promotionState, expectedState, item.entryId);
  }
});

test('dry-run inherits the frozen policies without expansion', () => {
  assert.equal(dryRun.remediationPolicy, 'allow-safe-same-for-each+allow-reviewed-methodonly-null');
  assert.deepEqual(dryRun.reviewedMethodOnlyNullAllowlist, {
    'dz1979-p129': ['姜', '花椒'],
    'dz1979-p130': ['胡椒面'],
  });
  assert.deepEqual(dryRun.remediationPolicies, {
    inheritedFromBatch7: 'allow-safe-same-for-each',
    inheritedFromBatch8: 'allow-reviewed-methodonly-null',
    newThisRound: 'none',
  });
  assert.equal(dryRun.methodOnlyReviewArtifact, 'data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json');
});

test('the frozen methodOnly review artifact still confirms safe-to-allow with zero problems', () => {
  assert.equal(methodOnlyReview.safetyAnalysis.conclusion, 'safe-to-allow-qty-null-for-these-specific-confirmed-methodonly-items');
  assert.deepEqual(methodOnlyReview.verificationProblems, []);
});

test('the funnel matches an independent mechanical recomputation (8 -> 6 -> 2 -> 0 -> 2)', () => {
  const opts = { readinessSource: preBatch9ReadinessById, namesSource: preBatch9ProductionNames };
  const remaining = [...preBatch9ReadinessById.values()]
    .filter((e) => e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted')
    .map((e) => e.entryId);
  const hardGateSurvivors = remaining.filter((id) => passesMethodOnlyNullGate(id, REVIEWED_ALLOWLIST, opts));
  const eligible = hardGateSurvivors.filter((id) => !auditRuntimeGate(id, opts).blocked);
  const blocked = hardGateSurvivors.filter((id) => auditRuntimeGate(id, opts).blocked);
  assert.equal(remaining.length, 8);
  assert.equal(hardGateSurvivors.length, 2);
  assert.equal(eligible.length, 2);
  assert.equal(blocked.length, 0);
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 8,
    afterHardGates: 2,
    hardGateBlocked: 6,
    blockedByRuntimeNameGate: 0,
    eligible: 2,
    selected: 2,
  });
  assert.deepEqual(eligible.sort(), dryRun.selection.selectedEntryIds.slice().sort());
});

test('hard-gate blocked count is mechanically consistent and funnel destinations sum to remaining (6 + 0 + 2 = 8)', () => {
  const uniqueBlockedIds = [...new Set(Object.values(dryRun.selection.hardGateExclusions).flat())];
  assert.equal(uniqueBlockedIds.length, 6);
  assert.deepEqual(uniqueBlockedIds.sort(), [
    'dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226',
  ]);
  assert.equal(
    dryRun.selection.funnel.hardGateBlocked + dryRun.selection.funnel.blockedByRuntimeNameGate + dryRun.selection.funnel.eligible,
    dryRun.selection.funnel.remainingNotPromotedCandidates,
  );
});

test('the two mechanically selected entries are exactly p137/p161', () => {
  assert.deepEqual(dryRun.items.map((item) => item.productionId).sort(), ['dz1979-p137', 'dz1979-p161']);
});

test('quantity review preview contains only real non-null qty/unit records', () => {
  const preview = dryRun.quantityReviewPreview.records;
  assert.equal(dryRun.quantityReviewPreview.recordCount, 18);
  assert.equal(preview.length, 18);
  for (const record of preview) {
    assert.ok(record.qty !== null && record.unit !== null, `${record.entryId}:${record.item} should be a real structured record`);
  }
});

test('p137/p161 pass the runtime gate while preserving source ingredient names', () => {
  const opts = { readinessSource: preBatch9ReadinessById };
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    const audit = auditRuntimeGate(id, opts);
    assert.equal(audit.blocked, false, id);
    assert.equal(audit.unresolvedCount, 0, id);
  }
  const byId = new Map(dryRun.items.map((item) => [item.entryId, item]));
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    const item = byId.get(id);
    assert.equal(item.coreRuntimeCompatibility.gatePassed, true, id);
    assert.equal(item.coreRuntimeCompatibility.counts['unresolved-name-match'], 0, id);
  }
  assert.deepEqual(dryRun.selection.runtimeNameGateBlocked, []);
  const p137Ingredients = byId.get('dz1979-p137').proposedCuratedIngredients['dz1979-p137'];
  const p161Ingredients = byId.get('dz1979-p161').proposedCuratedIngredients['dz1979-p161'];
  assert.deepEqual(p137Ingredients.find((ing) => ing.item === '子公鸡'), { item: '子公鸡', qty: '1', unit: '只' });
  assert.deepEqual(p161Ingredients.find((ing) => ing.item === '鸡血'), { item: '鸡血', qty: '500', unit: 'g' });
});

test('p201/p203/p207 (non-exact) and p222/p224/p226 (consumed-dual) remain hard-blocked', () => {
  const opts = { readinessSource: preBatch9ReadinessById, namesSource: preBatch9ProductionNames };
  for (const id of ['dz1979-p201', 'dz1979-p203', 'dz1979-p207']) {
    assert.equal(passesMethodOnlyNullGate(id, REVIEWED_ALLOWLIST, opts), false, id);
    assert.notEqual(readinessById.get(id).productionIngredientPlan.quantityReadiness, 'exact-comparable', id);
  }
  for (const id of ['dz1979-p222', 'dz1979-p224', 'dz1979-p226']) {
    assert.equal(passesMethodOnlyNullGate(id, REVIEWED_ALLOWLIST, opts), false, id);
    const recipe = restoredById.get(id);
    assert.ok(recipe.ingredients.some((ing) => (
      'consumedQty' in (ing.normalizedQuantity ?? {}) || 'consumedReferenceQty' in (ing.normalizedQuantity ?? {})
    )), id);
  }
});

test('promotion chain reproduces exactly current-plus-two (157 -> 159) with zero drift', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b9-test-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(new URL('../scripts/curate-recipes.js', import.meta.url).pathname, path.join(tmp, 'scripts', 'curate-recipes.js'));
    fs.copyFileSync(new URL('../data/sichuan-recipes.json', import.meta.url).pathname, path.join(tmp, 'data', 'sichuan-recipes.json'));
    const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
    // Use the real overlay with Batch 9's entries stripped out, so this
    // reconstructs the exact pre-Batch-9-promotion baseline the frozen
    // dry-run was generated against, whether or not Batch 9 is currently
    // promoted in the real overlay.
    const realOverlay = JSON.parse(fs.readFileSync(
      new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
      'utf8',
    ));
    const preOverlay = {
      ...realOverlay,
      newRecipes: (realOverlay.newRecipes ?? []).filter((r) => (
        !BATCH9_PRODUCTION_IDS.includes(r.id) && !BATCH10_PRODUCTION_IDS.includes(r.id)
      )),
      newRecipeIngredients: Object.fromEntries(
        Object.entries(realOverlay.newRecipeIngredients ?? {}).filter(([id]) => (
          !BATCH9_PRODUCTION_IDS.includes(id) && !BATCH10_PRODUCTION_IDS.includes(id)
        )),
      ),
    };
    fs.writeFileSync(overlayPath, `${JSON.stringify(preOverlay, null, 2)}\n`);
    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    const preCurated = JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'));
    assert.equal(preCurated.recipes.length, 157);

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
    assert.equal(out.curated.recipes.length, 159);
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
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b9-repro-'));
    try {
      fs.mkdirSync(path.join(tmp, 'scripts'));
      fs.mkdirSync(path.join(tmp, 'data'));
      fs.copyFileSync(new URL('../scripts/curate-recipes.js', import.meta.url).pathname, path.join(tmp, 'scripts', 'curate-recipes.js'));
      fs.copyFileSync(new URL('../data/sichuan-recipes.json', import.meta.url).pathname, path.join(tmp, 'data', 'sichuan-recipes.json'));
      const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
      fs.copyFileSync(new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname, overlayPath);
      const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
      tmpOverlay.newRecipes = [
        ...(tmpOverlay.newRecipes ?? []).filter((recipe) => !BATCH9_PRODUCTION_IDS.includes(recipe.id)),
        ...dryRun.items.map((item) => item.proposedOverlayRecipe),
      ];
      tmpOverlay.newRecipeIngredients = {
        ...Object.fromEntries(Object.entries(tmpOverlay.newRecipeIngredients ?? {})
          .filter(([id]) => !BATCH9_PRODUCTION_IDS.includes(id))),
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

test('iOS RecipeService-compatible shapes decode from every proposed item, including null qty/unit', () => {
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
});

test('dry-run reports no verification problems and Batch 1-8 stay marked promoted', () => {
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.baseline.main, runtimeFixBaseline);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(dryRun.baseline.batch1Promoted, true);
  assert.equal(dryRun.baseline.batch6Promoted, true);
  assert.equal(dryRun.baseline.batch7Promoted, true);
  assert.equal(dryRun.baseline.batch8Promoted, true);
  assert.equal(dryRun.simulation.tempCurateResult.strictCurrentPlusN, true);
  assert.equal(dryRun.simulation.tempCurateResult.headCuratedCount, 157);
  assert.equal(dryRun.simulation.tempCurateResult.simulatedCuratedCount, 159);
});

test('Batch 1-9 frozen dry-run artifacts remain valid after the ledger reaches ten promoted batches', () => {
  for (let n = 1; n <= 9; n += 1) {
    const artifact = readJson(`data/source-restoration/dazhong-chuancai-1979-promotion-batch${n}-dry-run.v1.json`);
    assert.deepEqual(artifact.verificationProblems, [], `batch${n} should still report zero problems`);
  }
  assert.equal(promotions.batches.length, 10);
  assert.equal(promotions.batches.some((batch) => batch.batchId === 'dz1979-production-b09'), true);
  for (const batch of promotions.batches) {
    assert.equal(batch.status, 'promoted');
  }
});

test('frozen artifacts, review evidence, runtime fix, and non-target production files are unchanged', () => {
  const sourceRestorationDir = path.join(repoRoot, 'data/source-restoration');
  const frozenBatchArtifacts = fs.readdirSync(sourceRestorationDir)
    .filter((name) => /^dazhong-chuancai-1979-promotion-batch[1-9]-/.test(name))
    .map((name) => `data/source-restoration/${name}`);
  const protectedPaths = [
    ...frozenBatchArtifacts,
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
    'data/sichuan-recipes.json',
    'data/recipe-curation-removed.json',
    'data/recipes-needing-completion.json',
    'src/ingredients.js',
    'scripts/dazhong-runtime-compatibility.mjs',
  ];
  for (const relativePath of protectedPaths) {
    const baseline = execFileSync('git', ['show', `${promotionBaseline}:${relativePath}`], {
      cwd: repoRoot,
      maxBuffer: 16 * 1024 * 1024,
    });
    assert.deepEqual(fs.readFileSync(path.join(repoRoot, relativePath)), baseline, relativePath);
  }
  const canonicalPath = 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json';
  const canonicalBaseline = JSON.parse(execFileSync(
    'git',
    ['show', `${promotionBaseline}:${canonicalPath}`],
    { cwd: repoRoot, maxBuffer: 16 * 1024 * 1024 },
  ));
  const canonicalCurrent = JSON.parse(fs.readFileSync(path.join(repoRoot, canonicalPath), 'utf8'));
  delete canonicalBaseline.updatedAt;
  delete canonicalCurrent.updatedAt;
  assert.deepEqual(canonicalCurrent, canonicalBaseline, `${canonicalPath} semantic drift`);
});

test('production still contains the two frozen Batch 9 proposals unchanged after Batch 10', () => {
  const baselineCurated = JSON.parse(execFileSync(
    'git', ['show', `${promotionBaseline}:data/sichuan-recipes.curated.json`],
    { cwd: repoRoot, maxBuffer: 16 * 1024 * 1024 },
  ));
  const baselineOverlay = JSON.parse(execFileSync(
    'git', ['show', `${promotionBaseline}:data/recipe-completion-overlay.json`],
    { cwd: repoRoot, maxBuffer: 16 * 1024 * 1024 },
  ));
  assert.equal(curated.recipes.length, 162);
  assert.equal(curated.recipes.length, baselineCurated.recipes.length + 5);
  for (const recipe of baselineCurated.recipes) {
    assert.deepEqual(curated.recipes.find((entry) => entry.id === recipe.id), recipe, recipe.id);
    assert.deepEqual(curated.recipe_ingredients[recipe.id], baselineCurated.recipe_ingredients[recipe.id], `${recipe.id}:map`);
  }
  for (const item of dryRun.items) {
    assert.deepEqual(curated.recipes.find((entry) => entry.id === item.productionId), item.proposedCuratedRecipe, item.productionId);
    assert.deepEqual(curated.recipe_ingredients[item.productionId], item.proposedCuratedIngredients[item.productionId], `${item.productionId}:map`);
  }
  assert.deepEqual(overlay.newRecipes.slice(0, baselineOverlay.newRecipes.length), baselineOverlay.newRecipes);
  for (const [id, ingredients] of Object.entries(baselineOverlay.newRecipeIngredients)) {
    assert.deepEqual(overlay.newRecipeIngredients[id], ingredients, `${id}:overlay-map`);
  }
  for (const item of dryRun.items) {
    assert.deepEqual(
      overlay.newRecipes.find((recipe) => recipe.id === item.productionId),
      item.proposedOverlayRecipe,
      item.productionId + ':overlay-recipe',
    );
  }
});

test('Batch 9 ledger remains exact and only three consumed-dual blockers remain', () => {
  const batch = promotions.batches.find((entry) => entry.batchId === 'dz1979-production-b09');
  assert.equal(batch.batchId, 'dz1979-production-b09');
  assert.equal(batch.baselineCommit, promotionBaseline);
  assert.equal(batch.dryRunArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json');
  assert.equal(batch.quantityReviewArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-quantity-review.v1.json');
  assert.deepEqual(batch.entries.map((entry) => entry.entryId), ['dz1979-p161', 'dz1979-p137']);
  assert.equal(readiness.summary.promotedNewRecipeCount, 36);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 3);
  assert.equal(readiness.applicationReady, false);
  const remaining = readiness.entries
    .filter((entry) => entry.promotionDisposition === 'new-recipe-candidate' && entry.promotionState === 'not-promoted')
    .map((entry) => entry.entryId)
    .sort();
  assert.deepEqual(remaining, ['dz1979-p222', 'dz1979-p224', 'dz1979-p226']);
});
