import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';
import {
  addMissingRecipeIngredientsToShopping,
  analyzeRecipeInventory,
  findRecipesUsingIngredients,
} from '../src/recommendations.js';
import { loadShoppingItems } from '../src/shopping.js';

const repoRoot = new URL('..', import.meta.url).pathname;
const readJson = (file) => JSON.parse(fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');
const review = readJson('data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const recipeById = new Map(recipes.recipes.map((recipe) => [recipe.entryId, recipe]));
const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
const BASELINE = '151de3b45d22ed328835ae2165564117fbcf8cb2';
const SELECTED = ['dz1979-p203', 'dz1979-p201', 'dz1979-p207'];
const CONSUMED = ['dz1979-p222', 'dz1979-p224', 'dz1979-p226'];

function reviewedGate(entryId, allowlist = review.reviewedNonExactNullAllowlist) {
  const recipe = recipeById.get(entryId);
  const entry = readinessById.get(entryId);
  const allowed = new Set(allowlist[entryId] ?? []);
  if (recipe.ingredients.some((ingredient) => {
    const quantity = ingredient.normalizedQuantity ?? {};
    if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity
      || 'consumedQualifier' in quantity || 'consumedUnit' in quantity) return true;
    return !['exact-mass', 'exact-count'].includes(quantity.kind)
      && !allowed.has(ingredient.rawItemText);
  })) return false;
  return entry.productionIngredientPlan.inventoryIngredients.every((ingredient) => (
    ingredient.inventoryComparable
    || (allowed.has(ingredient.productionItem)
      && ingredient.qty === null
      && ingredient.unit === null
      && classifyRecipeIngredient(ingredient.productionItem).role !== 'core')
  ));
}

test('only the exact reviewed (entryId,item) allowlist unlocks non-exact quantities', () => {
  for (const id of SELECTED) assert.equal(reviewedGate(id), true, id);
  for (const id of SELECTED) {
    assert.equal(reviewedGate(id, {}), false, id + ':empty');
    assert.equal(reviewedGate(id, { [id]: ['干辣椒'] }), false, id + ':wrong-item');
    assert.equal(reviewedGate(id, { [id]: ['*'] }), false, id + ':wildcard');
  }
  for (const id of CONSUMED) assert.equal(reviewedGate(id), false, id);
});

test('mechanical funnel and selected order are exact; consumed-dual entries remain hard-blocked', () => {
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 6,
    afterHardGates: 3,
    hardGateBlocked: 3,
    blockedByRuntimeNameGate: 0,
    eligible: 3,
    selected: 3,
  });
  assert.deepEqual(dryRun.selection.rankedEntryIds, SELECTED);
  assert.deepEqual(dryRun.selection.selectedEntryIds, SELECTED);
  assert.deepEqual(dryRun.selection.hardGateExclusions.consumedDualQuantity.sort(), [...CONSUMED].sort());
  assert.deepEqual(dryRun.selection.hardGateBlockedUniqueEntryIds, [...CONSUMED].sort());
});

test('selected proposals copy readiness quantities; only reviewed 花椒 is null/null', () => {
  for (const item of dryRun.items) {
    const plan = readinessById.get(item.entryId).productionIngredientPlan.inventoryIngredients;
    const proposal = item.proposedOverlayIngredients[item.productionId];
    assert.deepEqual(proposal, plan.map((ingredient) => ({
      item: ingredient.productionItem,
      qty: ingredient.qty,
      unit: ingredient.unit,
    })), item.entryId);
    const pepper = proposal.find((ingredient) => ingredient.item === '花椒');
    assert.deepEqual(pepper, { item: '花椒', qty: null, unit: null }, item.entryId);
    assert.equal(proposal.some((ingredient) => ingredient.item === '花椒' && ingredient.qty === '10'), false);
    assert.equal(item.coreRuntimeCompatibility.gatePassed, true, item.entryId);
    assert.equal(item.coreRuntimeCompatibility.nonCoreObservations.some((ingredient) => (
      ingredient.item === '花椒' && ingredient.role === 'seasoning'
      && ingredient.qty === null && ingredient.unit === null
    )), true, item.entryId);
  }
});

test('approximate seasoning null does not affect coverage, recommendation target matching, or shopping shortfall', () => {
  const memory = new Map();
  globalThis.localStorage = {
    getItem: (key) => memory.get(key) ?? null,
    setItem: (key, value) => memory.set(key, String(value)),
    removeItem: (key) => memory.delete(key),
  };
  for (const item of dryRun.items) {
    memory.clear();
    const pack = {
      recipes: [item.proposedCuratedRecipe],
      recipe_ingredients: item.proposedCuratedIngredients,
    };
    const core = item.proposedCuratedIngredients[item.productionId]
      .find((ingredient) => classifyRecipeIngredient(ingredient.item).role === 'core');
    const inventory = [{ name: core.item, qty: Number(core.qty), unit: core.unit, stockStatus: 'ok' }];
    const analysis = analyzeRecipeInventory(item.proposedCuratedRecipe, pack, inventory);
    assert.equal(analysis.totalCore, 1, item.entryId);
    assert.equal(analysis.status, 'ok', item.entryId);
    assert.deepEqual(analysis.missing, [], item.entryId);
    assert.deepEqual(findRecipesUsingIngredients(pack, inventory, ['花椒']), [], item.entryId);

    addMissingRecipeIngredientsToShopping(item.proposedCuratedRecipe, pack, []);
    const shopping = loadShoppingItems();
    assert.equal(shopping.some((entry) => entry.name === '花椒'), false, item.entryId);
    assert.equal(shopping.length, 1, item.entryId);
    assert.notEqual(shopping[0].name, '花椒', item.entryId);
  }
});

function curateWithProposal() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b10-test-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(path.join(repoRoot, 'scripts/curate-recipes.js'), path.join(tmp, 'scripts/curate-recipes.js'));
    fs.copyFileSync(path.join(repoRoot, 'data/sichuan-recipes.json'), path.join(tmp, 'data/sichuan-recipes.json'));
    const overlay = readJson('data/recipe-completion-overlay.json');
    overlay.newRecipes.push(...dryRun.items.map((item) => item.proposedOverlayRecipe));
    Object.assign(overlay.newRecipeIngredients, Object.fromEntries(
      dryRun.items.map((item) => [item.productionId, item.proposedOverlayIngredients[item.productionId]]),
    ));
    fs.writeFileSync(path.join(tmp, 'data/recipe-completion-overlay.json'), JSON.stringify(overlay, null, 2) + '\n');
    execFileSync('node', [path.join(tmp, 'scripts/curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    return {
      curated: fs.readFileSync(path.join(tmp, 'data/sichuan-recipes.curated.json')),
      removed: fs.readFileSync(path.join(tmp, 'data/recipe-curation-removed.json')),
      needing: fs.readFileSync(path.join(tmp, 'data/recipes-needing-completion.json')),
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

test('two real temp curate runs are byte-identical and produce exactly current +3 with zero existing drift', () => {
  const first = curateWithProposal();
  const second = curateWithProposal();
  assert.deepEqual(first, second);
  const simulated = JSON.parse(first.curated);
  assert.equal(curated.recipes.length, 159);
  assert.equal(simulated.recipes.length, 162);
  assert.equal(Object.keys(simulated.recipe_ingredients).length, Object.keys(curated.recipe_ingredients).length + 3);
  for (const recipe of curated.recipes) {
    assert.deepEqual(simulated.recipes.find((entry) => entry.id === recipe.id), recipe, recipe.id);
    assert.deepEqual(simulated.recipe_ingredients[recipe.id], curated.recipe_ingredients[recipe.id], recipe.id + ':map');
  }
  assert.deepEqual(JSON.parse(first.removed), readJson('data/recipe-curation-removed.json'));
  assert.deepEqual(JSON.parse(first.needing), readJson('data/recipes-needing-completion.json'));
});

test('PWA/iOS proposal shapes pass and dry-run reports no problems', () => {
  assert.equal(dryRun.iosDecodeAudit.batch10Compatible, true);
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.deepEqual(dryRun.simulation.tempCurateResult, {
    headCuratedCount: 159,
    simulatedCuratedCount: 162,
    newRecipeIds: ['dz1979-p201', 'dz1979-p203', 'dz1979-p207'],
    newRecipeCount: 3,
    existingDeleted: 0,
    existingRecipeObjectModified: 0,
    existingIngredientMapModified: 0,
    newRecipesHaveMethod: true,
    newRecipesHaveTags: true,
    newIngredientMapsComplete: true,
    strictCurrentPlusN: true,
  });
});

test('Batch 1-9, final review, runtime review, and all production/readiness inputs are byte-identical to review commit', () => {
  const sourceDir = path.join(repoRoot, 'data/source-restoration');
  const protectedPaths = fs.readdirSync(sourceDir)
    .filter((name) => /^dazhong-chuancai-1979-promotion-batch[1-9]-/.test(name))
    .map((name) => 'data/source-restoration/' + name);
  protectedPaths.push(
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
    'data/sichuan-recipes.curated.json',
    'data/sichuan-recipes.json',
    'data/recipe-completion-overlay.json',
    'data/recipe-curation-removed.json',
    'data/recipes-needing-completion.json',
  );
  for (const file of protectedPaths) {
    const baseline = execFileSync('git', ['show', BASELINE + ':' + file], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 });
    assert.deepEqual(fs.readFileSync(path.join(repoRoot, file)), baseline, file);
  }
  assert.equal(readiness.summary.promotedNewRecipeCount, 33);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 6);
  assert.equal(readiness.applicationReady, false);
});
