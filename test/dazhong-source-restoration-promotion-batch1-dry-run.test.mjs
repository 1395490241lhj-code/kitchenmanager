import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { buildDefaultRuntimePacks } from '../scripts/recipe-runtime-quality.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const crosswalk = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json');
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

// -- Mechanical selection replica ------------------------------------------

function passesSelection(entryId) {
  const entry = readinessById.get(entryId);
  const recipe = restoredById.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
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
  if (productionNames.has(entry.bookName) && !ledgerPromotedEntryIds.has(entryId)) return false;
  return true;
}

function complexityKey(entryId) {
  const recipe = restoredById.get(entryId);
  const special = recipe.ingredients.filter((ing) => ing.memberQuantityMode).length;
  return [special, recipe.ingredients.length, recipe.methodSummary?.steps?.length ?? 0, entryId];
}

function mechanicalTopFive() {
  const eligible = readiness.entries
    .map((e) => e.entryId)
    .filter(passesSelection)
    .sort((a, b) => {
      const ka = complexityKey(a);
      const kb = complexityKey(b);
      for (let i = 0; i < ka.length; i += 1) {
        if (ka[i] < kb[i]) return -1;
        if (ka[i] > kb[i]) return 1;
      }
      return 0;
    })
    .slice(0, 5);
  return eligible;
}

// -- Temp promotion chain simulation ---------------------------------------

function makeTempRepo(withBatch) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch1-test-'));
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
  const batchIds = new Set(dryRun.items.map((item) => item.productionId));
  if (withBatch) {
    const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    // The real overlay now already contains the promoted batch; strip it so
    // the simulation reproduces the pre-promotion baseline before re-adding.
    tmpOverlay.newRecipes = (tmpOverlay.newRecipes ?? [])
      .filter((recipe) => !batchIds.has(recipe.id));
    tmpOverlay.newRecipeIngredients = Object.fromEntries(
      Object.entries(tmpOverlay.newRecipeIngredients ?? {})
        .filter(([id]) => !batchIds.has(id)),
    );
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
  }
  return tmp;
}

function runCurate(tmp) {
  execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], {
    cwd: tmp,
    stdio: 'pipe',
  });
  return {
    curated: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8')),
    removed: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8')),
    needing: JSON.parse(fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8')),
    summary: fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-summary.md'), 'utf8'),
  };
}

test('the five selected entries are exactly the mechanical top five', () => {
  const expected = mechanicalTopFive();
  assert.equal(expected.length, 5);
  assert.deepEqual(dryRun.selection.selectedEntryIds, expected);
  assert.equal(dryRun.selection.eligiblePoolCount >= 29, true);
  assert.deepEqual(
    dryRun.items.map((item) => item.productionId),
    ['dz1979-p143', 'dz1979-p204', 'dz1979-p195', 'dz1979-p200', 'dz1979-p180'],
  );
});

test('every selected item fully satisfies the promotion gate', () => {
  const ledgerMatches = new Map(
    (promotions.batches ?? []).flatMap((batch) => (
      (batch.entries ?? []).map((entry) => [
        entry.entryId,
        { productionId: entry.productionId, name: entry.name },
      ])
    )),
  );
  for (const item of dryRun.items) {
    assert.equal(passesSelection(item.entryId), true, item.entryId);
    assert.equal(item.productionId, `dz1979-p${catalogById.get(item.entryId).bookPage}`, item.entryId);
    assert.equal(item.name, catalogById.get(item.entryId).bookName, item.entryId);
    assert.deepEqual(item.tags, ['川菜', catalogById.get(item.entryId).category], item.entryId);
    const expected = ledgerMatches.get(item.entryId);
    const expectedPromoted = expected
      && expected.productionId === item.productionId
      && expected.name === item.name;
    if (productionIds.has(item.productionId) || productionNames.has(item.name)) {
      assert.equal(expectedPromoted, true, `${item.productionId}/${item.name} unexplained production collision`);
    }
  }
});

test('all dry-run item fields are present with production-only schema shapes', () => {
  const required = [
    'entryId',
    'productionId',
    'name',
    'tags',
    'proposedOverlayRecipe',
    'proposedOverlayIngredients',
    'proposedCuratedRecipe',
    'proposedCuratedIngredients',
    'provenanceRecord',
    'sourceToProductionTransformNotes',
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

test('temp promotion from dry-run proposals reproduces current curated exactly', () => {
  const tmp = makeTempRepo(true);
  try {
    const out = runCurate(tmp);
    // Stripped to the pre-promotion baseline and re-added from the dry-run,
    // the simulated output must equal the actual promoted curated file.
    assert.deepEqual(out.curated.recipes, curated.recipes);
    assert.deepEqual(out.curated.recipe_ingredients, curated.recipe_ingredients);
    for (const id of dryRun.items.map((i) => i.productionId)) {
      const recipe = out.curated.recipes.find((r) => r.id === id);
      assert.ok(recipe.method, `${id} missing method`);
      assert.ok(recipe.tags, `${id} missing tags`);
      assert.ok(out.curated.recipe_ingredients[id].length >= 2, `${id} incomplete map`);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('pre-promotion baseline is exactly the current curated minus the five batch recipes', () => {
  const tmp = makeTempRepo(false);
  try {
    const overlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
    const tmpOverlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    const batchIds = new Set(dryRun.items.map((item) => item.productionId));
    tmpOverlay.newRecipes = (tmpOverlay.newRecipes ?? [])
      .filter((recipe) => !batchIds.has(recipe.id));
    tmpOverlay.newRecipeIngredients = Object.fromEntries(
      Object.entries(tmpOverlay.newRecipeIngredients ?? {})
        .filter(([id]) => !batchIds.has(id)),
    );
    fs.writeFileSync(overlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);
    const out = runCurate(tmp);
    assert.equal(out.curated.recipes.length, curated.recipes.length - 5);
    assert.equal(out.curated.recipes.some((r) => batchIds.has(r.id)), false);
    const expectedIds = new Set(
      curated.recipes.map((r) => r.id).filter((id) => !batchIds.has(id)),
    );
    assert.deepEqual(new Set(out.curated.recipes.map((r) => r.id)), expectedIds);
    const currentById = new Map(curated.recipes.map((r) => [r.id, r]));
    const baselineById = new Map(out.curated.recipes.map((r) => [r.id, r]));
    for (const id of expectedIds) {
      assert.deepEqual(baselineById.get(id), currentById.get(id), `${id} drifted`);
      assert.deepEqual(out.curated.recipe_ingredients[id], curated.recipe_ingredients[id], `${id} ingredients drifted`);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('temp curate keeps removed and needing reports semantically unchanged', () => {
  const tmp = makeTempRepo(true);
  try {
    const out = runCurate(tmp);
    const realRemoved = readJson('data/recipe-curation-removed.json');
    const realNeeding = readJson('data/recipes-needing-completion.json');
    assert.equal(out.removed.removed.length, realRemoved.removed.length);
    assert.deepEqual(out.removed.removed.map((r) => r.id), realRemoved.removed.map((r) => r.id));
    assert.equal(out.needing.items.length, realNeeding.items.length);
    assert.deepEqual(out.needing.items.map((r) => r.id), realNeeding.items.map((r) => r.id));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('PWA runtime packs contain all five batch recipes exactly once', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const mergedIds = new Set(runtime.packs.full.recipes.map((r) => r.id));
  for (const item of dryRun.items) {
    assert.ok(mergedIds.has(item.productionId), `${item.productionId} missing in full runtime`);
    assert.ok(runtime.packs.curated.recipes.some((r) => r.id === item.productionId), `${item.productionId} missing in curated runtime`);
    const occurrences = runtime.packs.full.recipes.filter((r) => r.id === item.productionId).length;
    assert.equal(occurrences, 1, `${item.productionId} duplicated in full runtime`);
  }
});

test('batch additions are unique and remain visible in production after later batches promote', () => {
  const ids = dryRun.items.map((item) => item.productionId);
  assert.equal(new Set(ids).size, 5);
  const names = dryRun.items.map((item) => item.name);
  assert.equal(new Set(names).size, 5);
  for (const id of ids) {
    assert.ok(overlay.newRecipes.some((r) => r.id === id), `${id} missing in overlay newRecipes`);
    assert.ok(overlay.newRecipeIngredients[id], `${id} missing overlay ingredients`);
    assert.ok(curated.recipe_ingredients[id], `${id} missing curated ingredients`);
  }
  const overlayNewIds = overlay.newRecipes.map((r) => r.id).filter((id) => id.startsWith('dz1979-'));
  // Later batches (e.g. Batch 2) may add more dz1979- ids; Batch 1's five
  // must remain a subset, never removed or altered.
  for (const id of ids) {
    assert.ok(overlayNewIds.includes(id), `${id} missing from overlay dz1979- ids`);
  }
  assert.equal(full.recipes.some((r) => ids.includes(r.id)), false);
});

test('iOS RecipeService-compatible field shapes decode from temp curated output', () => {
  const tmp = makeTempRepo(true);
  try {
    const out = runCurate(tmp);
    for (const id of dryRun.items.map((i) => i.productionId)) {
      const recipe = out.curated.recipes.find((r) => r.id === id);
      assert.equal(typeof recipe.id, 'string');
      assert.equal(typeof recipe.name, 'string');
      assert.equal(typeof recipe.method, 'string');
      assert.ok(Array.isArray(recipe.tags));
      for (const ing of out.curated.recipe_ingredients[id]) {
        assert.equal(typeof ing.item, 'string');
        assert.ok(ing.qty === undefined || ing.qty === null || typeof ing.qty === 'string');
        assert.ok(ing.unit === undefined || ing.unit === null || typeof ing.unit === 'string');
      }
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('canonical, crosswalk, and readiness are unchanged', () => {
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
});

test('dry-run reports no verification problems and no production writes', () => {
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(dryRun.simulation.tempCurateResult.strictCurrentPlusFive, true);
  assert.equal(dryRun.pwaVisibilityAudit.serviceWorker.cacheBumpRequired, false);
  assert.equal(dryRun.iosDecodeAudit.batch1Compatible, true);
});
