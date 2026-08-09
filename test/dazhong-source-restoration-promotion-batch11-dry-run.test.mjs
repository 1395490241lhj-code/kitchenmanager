import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  addMissingRecipeIngredientsToShopping,
  analyzeRecipeInventory,
  findRecipesUsingIngredients,
  getRecipeCoreIngredients,
  scoreRecipe,
} from '../src/recommendations.js';
import { loadShoppingItems } from '../src/shopping.js';
import { assertValidRecipeQuantitySemantics } from '../scripts/recipe-quantity-semantics.mjs';
import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

const repoRoot = path.resolve(new URL('..', import.meta.url).pathname);
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const BASELINE = 'c4d2a7b74090bdbee70e1e3fa81d749e786739bd';
const ORDER = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];
const dryRunFile = 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json';
const dryRun = readJson(dryRunFile);

test('Batch11 mechanical funnel and ranking select exactly the final three', () => {
  assert.equal(dryRun.baseline.main, BASELINE);
  assert.deepEqual(dryRun.selection.funnel, {
    remainingNotPromotedCandidates: 3,
    afterHardGates: 3,
    hardGateBlocked: 0,
    blockedByRuntimeNameGate: 0,
    eligible: 3,
    selected: 3,
  });
  assert.deepEqual(dryRun.selection.rankedEntryIds, ORDER);
  assert.deepEqual(dryRun.selection.selectedEntryIds, ORDER);
  assert.deepEqual(dryRun.selection.hardGateBlockedEntryIds, []);
  assert.deepEqual(dryRun.selection.runtimeNameGateBlockedEntryIds, []);
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(dryRun.applicationReady, false);
  assert.equal(dryRun.productionWrites, false);
});

test('base ingredient proposals keep all four dual rows at 500g input', () => {
  const expected = {
    'dz1979-p222': { 菜油: '500' },
    'dz1979-p224': { 菜油: '500' },
    'dz1979-p226': { 菜油: '500', 干豆粉: '500' },
  };
  for (const item of dryRun.items) {
    const ingredients = item.proposedCuratedIngredients[item.productionId];
    assert.ok(ingredients.every((ingredient) => (
      Object.keys(ingredient).sort().join(',') === 'item,qty,unit'
    )), item.entryId);
    for (const [name, qty] of Object.entries(expected[item.entryId])) {
      assert.deepEqual(ingredients.find((ingredient) => ingredient.item === name), {
        item: name, qty, unit: 'g',
      });
    }
    assert.equal(JSON.stringify(ingredients).includes('consumed'), false);
  }
});

test('proposed sidecar has four exact unique joins and round-trips without changing base bytes', () => {
  const basePack = {
    recipes: dryRun.items.map((item) => item.proposedCuratedRecipe),
    recipe_ingredients: Object.assign({}, ...dryRun.items.map((item) => item.proposedCuratedIngredients)),
  };
  const before = JSON.stringify(basePack);
  const sidecar = JSON.parse(JSON.stringify(dryRun.proposedQuantitySemanticsSidecar));
  const result = assertValidRecipeQuantitySemantics(sidecar, basePack);
  assert.equal(result.joins.length, 4);
  assert.equal(JSON.stringify(basePack), before);
  assert.deepEqual(sidecar, dryRun.proposedQuantitySemanticsSidecar);
  assert.deepEqual(result.joins, dryRun.sidecarValidation.joins);

  const consumed = Object.fromEntries(result.joins.map(({ recipeId, item }) => {
    const entry = sidecar.recipes[recipeId].ingredients[item];
    return [`${recipeId}:${item}`, [entry.input.qty, entry.consumed.qty, entry.rawQuantityText]];
  }));
  assert.deepEqual(consumed, {
    'dz1979-p222:菜油': [500, 100, '一斤耗二两'],
    'dz1979-p226:菜油': [500, 100, '一斤耗二两'],
    'dz1979-p226:干豆粉': [500, 200, '一斤耗四两'],
    'dz1979-p224:菜油': [500, 100, '一斤耗二两'],
  });
});

function packFor(item, withSidecar) {
  return {
    recipes: [item.proposedCuratedRecipe],
    recipe_ingredients: item.proposedCuratedIngredients,
    ...(withSidecar ? { quantity_semantics: dryRun.proposedQuantitySemanticsSidecar } : {}),
  };
}

test('real inventory, recommendation, and shopping behavior is identical with or without sidecar', () => {
  installLocalStorageStub();
  const context = { plan: [], recipeActivity: {}, favoriteIds: [], today: '2026-08-09' };
  for (const item of dryRun.items) {
    const plain = packFor(item, false);
    const withSidecar = packFor(item, true);
    const inventory = [];
    assert.deepEqual(
      analyzeRecipeInventory(item.proposedCuratedRecipe, withSidecar, inventory),
      analyzeRecipeInventory(item.proposedCuratedRecipe, plain, inventory),
      item.entryId,
    );
    assert.deepEqual(
      scoreRecipe(item.proposedCuratedRecipe, withSidecar, inventory, context),
      scoreRecipe(item.proposedCuratedRecipe, plain, inventory, context),
      item.entryId,
    );
    assert.deepEqual(
      findRecipesUsingIngredients(withSidecar, inventory, ['花生米', '鸡蛋']),
      findRecipesUsingIngredients(plain, inventory, ['花生米', '鸡蛋']),
      item.entryId,
    );

    resetLocalStorage();
    addMissingRecipeIngredientsToShopping(item.proposedCuratedRecipe, plain, inventory);
    const plainShopping = loadShoppingItems();
    resetLocalStorage();
    addMissingRecipeIngredientsToShopping(item.proposedCuratedRecipe, withSidecar, inventory);
    const stableShoppingFields = (rows) => rows.map(({ id: _id, ...row }) => row);
    assert.deepEqual(stableShoppingFields(loadShoppingItems()), stableShoppingFields(plainShopping), item.entryId);
  }
});

test('complete p226 path canonicalizes dry flour out of core without hiding real peanut and egg core rows', () => {
  installLocalStorageStub();
  resetLocalStorage();
  const item = dryRun.items.find((candidate) => candidate.entryId === 'dz1979-p226');
  const pack = packFor(item, true);
  const core = getRecipeCoreIngredients(item.proposedCuratedRecipe, pack);
  assert.equal(core.some((ingredient) => ['干豆粉', '豆粉'].includes(ingredient.item)), false);
  assert.deepEqual(core.map((ingredient) => ingredient.item).sort(), ['花生', '鸡蛋'].sort());
  const analysis = analyzeRecipeInventory(item.proposedCuratedRecipe, pack, []);
  assert.equal(analysis.totalCore, 2);
  assert.deepEqual(analysis.missing.map((ingredient) => ingredient.item).sort(), ['花生', '鸡蛋'].sort());
});

test('temp curate is exactly 162 to 165 and auxiliary files do not drift', () => {
  assert.deepEqual(dryRun.simulation.tempCurateResult, {
    headCuratedCount: 162,
    simulatedCuratedCount: 165,
    newRecipeIds: ['dz1979-p222', 'dz1979-p224', 'dz1979-p226'],
    newRecipeCount: 3,
    existingDeleted: 0,
    existingRecipeObjectModified: 0,
    existingIngredientMapModified: 0,
    strictCurrentPlusN: true,
  });
  assert.deepEqual(dryRun.simulation.auxiliaryGeneratedFiles, {
    recipeCurationRemoved: 'unchanged',
    recipesNeedingCompletion: 'unchanged',
    overlayUpdatedAtPreserved: true,
  });
});

test('Batch11 generators are deterministic and never modify the real sidecar', () => {
  const artifactPaths = [
    dryRunFile,
    'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json',
  ];
  const sidecarPath = path.join(repoRoot, 'data/recipe-quantity-semantics.json');
  const sidecarBefore = fs.existsSync(sidecarPath) ? fs.readFileSync(sidecarPath) : null;
  const before = artifactPaths.map((file) => fs.readFileSync(path.join(repoRoot, file)));
  execFileSync('node', ['scripts/build-dazhong-chuancai-promotion-batch11-dry-run.mjs'], { cwd: repoRoot });
  execFileSync('node', ['scripts/build-dazhong-chuancai-batch11-quantity-review.mjs'], { cwd: repoRoot });
  const after = artifactPaths.map((file) => fs.readFileSync(path.join(repoRoot, file)));
  assert.deepEqual(after, before);
  const sidecarAfter = fs.existsSync(sidecarPath) ? fs.readFileSync(sidecarPath) : null;
  assert.deepEqual(sidecarAfter, sidecarBefore);
});

test('frozen source-restoration evidence is byte-identical to baseline after promotion', () => {
  const sourceDir = path.join(repoRoot, 'data/source-restoration');
  const protectedPaths = fs.readdirSync(sourceDir)
    .filter((name) => /^dazhong-chuancai-1979-promotion-batch(?:[1-9]|10)-/.test(name))
    .map((name) => `data/source-restoration/${name}`);
  protectedPaths.push(
    'data/sichuan-recipes.json',
    'data/recipe-curation-removed.json',
    'data/recipes-needing-completion.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
  );
  for (const file of protectedPaths) {
    const baseline = execFileSync('git', ['show', `${BASELINE}:${file}`], {
      cwd: repoRoot, maxBuffer: 32 * 1024 * 1024,
    });
    assert.deepEqual(fs.readFileSync(path.join(repoRoot, file)), baseline, file);
  }
});
