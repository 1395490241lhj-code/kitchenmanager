import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  addMissingRecipeIngredientsToShopping,
  analyzeRecipeInventory,
  getRecipeCoreIngredients,
  scoreRecipe,
} from '../src/recommendations.js';
import { loadShoppingItems } from '../src/shopping.js';
import { assertValidRecipeQuantitySemantics } from '../scripts/recipe-quantity-semantics.mjs';
import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

const repoRoot = path.resolve(new URL('..', import.meta.url).pathname);
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const baseline = '09e8bd44c421b87f435e373f6dad9726acfe3c53';
const selected = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const sidecar = readJson('data/recipe-quantity-semantics.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const baselineJson = (file) => JSON.parse(execFileSync('git', ['show', `${baseline}:${file}`], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 }));

test('production is exactly frozen Batch11 +3 recipes/+3 maps with zero existing drift', () => {
  const before = baselineJson('data/sichuan-recipes.curated.json');
  const beforeOverlay = baselineJson('data/recipe-completion-overlay.json');
  assert.equal(before.recipes.length, 162);
  assert.equal(curated.recipes.length, 165);
  assert.equal(Object.keys(curated.recipe_ingredients).length, Object.keys(before.recipe_ingredients).length + 3);
  assert.deepEqual(curated.recipes.filter((recipe) => !before.recipes.some((old) => old.id === recipe.id)).map((recipe) => recipe.id).sort(), [...selected].sort());
  for (const recipe of before.recipes) {
    assert.deepEqual(curated.recipes.find((entry) => entry.id === recipe.id), recipe, recipe.id);
    assert.deepEqual(curated.recipe_ingredients[recipe.id], before.recipe_ingredients[recipe.id], `${recipe.id}:map`);
  }
  assert.deepEqual(overlay.newRecipes.slice(0, beforeOverlay.newRecipes.length), beforeOverlay.newRecipes);
  assert.deepEqual(overlay.newRecipes.slice(-3).map((recipe) => recipe.id), selected);
  assert.equal(overlay.updatedAt, beforeOverlay.updatedAt);
  for (const [id, ingredients] of Object.entries(beforeOverlay.newRecipeIngredients)) assert.deepEqual(overlay.newRecipeIngredients[id], ingredients, id);
  for (const item of dryRun.items) {
    assert.deepEqual(curated.recipes.find((recipe) => recipe.id === item.productionId), item.proposedCuratedRecipe);
    assert.deepEqual(curated.recipe_ingredients[item.productionId], item.proposedCuratedIngredients[item.productionId]);
    assert.deepEqual(overlay.newRecipeIngredients[item.productionId], item.proposedOverlayIngredients[item.productionId]);
  }
});

test('actual sidecar exactly equals the frozen proposal and validates four exact item joins', () => {
  assert.deepEqual(sidecar, dryRun.proposedQuantitySemanticsSidecar);
  const before = fs.readFileSync(path.join(repoRoot, 'data/sichuan-recipes.curated.json'));
  const result = assertValidRecipeQuantitySemantics(sidecar, curated);
  assert.deepEqual(result.joins, dryRun.sidecarValidation.joins);
  assert.equal(result.joins.length, 4);
  assert.deepEqual(fs.readFileSync(path.join(repoRoot, 'data/sichuan-recipes.curated.json')), before);
  assert.deepEqual(result.joins.map(({ recipeId, item }) => [recipeId, item, sidecar.recipes[recipeId].ingredients[item].input.qty, sidecar.recipes[recipeId].ingredients[item].consumed.qty]), [
    ['dz1979-p222', '菜油', 500, 100],
    ['dz1979-p226', '菜油', 500, 100],
    ['dz1979-p226', '干豆粉', 500, 200],
    ['dz1979-p224', '菜油', 500, 100],
  ]);
});

test('actual production consumers behave identically with or without sidecar', () => {
  installLocalStorageStub();
  const context = { plan: [], recipeActivity: {}, favoriteIds: [], today: '2026-08-09' };
  const withSidecar = { ...curated, quantity_semantics: sidecar };
  for (const id of selected) {
    const recipe = curated.recipes.find((entry) => entry.id === id);
    assert.deepEqual(analyzeRecipeInventory(recipe, withSidecar, []), analyzeRecipeInventory(recipe, curated, []), id);
    assert.deepEqual(scoreRecipe(recipe, withSidecar, [], context), scoreRecipe(recipe, curated, [], context), id);
    resetLocalStorage();
    addMissingRecipeIngredientsToShopping(recipe, curated, []);
    const plain = loadShoppingItems().map(({ id: _id, ...row }) => row);
    resetLocalStorage();
    addMissingRecipeIngredientsToShopping(recipe, withSidecar, []);
    assert.deepEqual(loadShoppingItems().map(({ id: _id, ...row }) => row), plain, id);
  }
  const p226 = curated.recipes.find((recipe) => recipe.id === 'dz1979-p226');
  assert.deepEqual(getRecipeCoreIngredients(p226, withSidecar).map((row) => row.item).sort(), ['花生', '鸡蛋'].sort());
  assert.equal(analyzeRecipeInventory(p226, withSidecar, []).totalCore, 2);
});

test('ledger, readiness, and reviewed quantity totals reflect the formal promotion', () => {
  assert.equal(ledger.batches.length, 11);
  const batch = ledger.batches.at(-1);
  assert.equal(batch.batchId, 'dz1979-production-b11');
  assert.equal(batch.baselineCommit, baseline);
  assert.deepEqual(batch.entries.map((entry) => entry.entryId), selected);
  assert.equal(quantityReview.records.length, 21);
  assert.deepEqual(quantityReview.summary.unitCounts, { g: 20, '个': 1 });
  const sourceRecords = ledger.batches.flatMap((entry) => readJson(entry.quantityReviewArtifact).records ?? []);
  assert.equal(sourceRecords.length, 294);
  assert.equal(new Set(sourceRecords.map((record) => `${record.productionId}:${record.item}`)).size, 294);
  assert.equal(sourceRecords.length + 11, 305);
  assert.equal(readiness.summary.promotedNewRecipeCount, 39);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 0);
  assert.equal(readiness.applicationReady, false);
  assert.equal(readiness.productionPromotion, false);
});

test('frozen Batch1-11 artifacts and non-target source evidence are byte-identical', () => {
  const sourceDir = path.join(repoRoot, 'data/source-restoration');
  const files = fs.readdirSync(sourceDir)
    .filter((name) => /^dazhong-chuancai-1979-promotion-batch(?:[1-9]|10|11)-(?:dry-run|quantity-review)\.v1\.(?:json|md)$/.test(name))
    .map((name) => `data/source-restoration/${name}`);
  files.push(
    'data/sichuan-recipes.json',
    'data/recipe-curation-removed.json',
    'data/recipes-needing-completion.json',
    'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.md',
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.md',
  );
  for (const file of files) {
    const expected = execFileSync('git', ['show', `${baseline}:${file}`], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 });
    assert.deepEqual(fs.readFileSync(path.join(repoRoot, file)), expected, file);
  }
});
