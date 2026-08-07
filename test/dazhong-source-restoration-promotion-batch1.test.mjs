import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { buildDefaultRuntimePacks } from '../scripts/recipe-runtime-quality.mjs';
import { normalizeIngredientAmount } from '../src/ingredients.js';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-quantity-review.v1.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const removed = readJson('data/recipe-curation-removed.json');
const needing = readJson('data/recipes-needing-completion.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');

const EXPECTED_IDS = ['dz1979-p143', 'dz1979-p180', 'dz1979-p195', 'dz1979-p200', 'dz1979-p204'];
const itemsById = new Map(dryRun.items.map((item) => [item.productionId, item]));

test('overlay contains exactly the five promoted recipes matching the dry-run', () => {
  const overlayIds = overlay.newRecipes
    .filter((recipe) => recipe.id.startsWith('dz1979-'))
    .map((recipe) => recipe.id)
    .sort();
  assert.deepEqual(overlayIds, EXPECTED_IDS.slice().sort());
  assert.equal(overlay.newRecipes.length, 63);
  assert.equal(Object.keys(overlay.newRecipeIngredients).length, 63);
  for (const id of EXPECTED_IDS) {
    const expected = itemsById.get(id).proposedOverlayRecipe;
    const actual = overlay.newRecipes.find((recipe) => recipe.id === id);
    assert.deepEqual(actual, expected, id);
    assert.deepEqual(
      overlay.newRecipeIngredients[id],
      itemsById.get(id).proposedOverlayIngredients[id],
      `${id} ingredients`,
    );
  }
  assert.equal(Object.keys(overlay.recipeIngredientOverrides || {}).length, 9);
  assert.ok(Object.values(overlay.recipeIngredientOverrides || {}).every((v) => v === 'replace'));
});

test('curated contains exactly the five promoted recipes with full content', () => {
  assert.equal(curated.recipes.length, 131);
  assert.equal(curated.recipes.filter((recipe) => recipe.id.startsWith('dz1979-')).length, 5);
  for (const id of EXPECTED_IDS) {
    const recipe = curated.recipes.find((entry) => entry.id === id);
    assert.deepEqual(recipe, itemsById.get(id).proposedCuratedRecipe, id);
    assert.deepEqual(
      curated.recipe_ingredients[id],
      itemsById.get(id).proposedCuratedIngredients[id],
      `${id} curated ingredients`,
    );
  }
});

test('full library, removed, and needing reports carry no batch entries', () => {
  assert.equal(full.recipes.some((recipe) => EXPECTED_IDS.includes(recipe.id)), false);
  assert.equal(removed.removed.some((entry) => EXPECTED_IDS.includes(entry.id)), false);
  assert.equal(needing.items.some((entry) => EXPECTED_IDS.includes(entry.id)), false);
  assert.equal(removed.removed.length, 204);
  assert.equal(needing.items.length, 13);
  assert.equal(full.recipes.length, 264);
});

test('promotion ledger records the batch with full provenance', () => {
  assert.equal(ledger.applicationReady, false);
  assert.equal(ledger.partialPromotion, true);
  assert.equal(ledger.batches.length, 1);
  const batch = ledger.batches[0];
  assert.equal(batch.batchId, 'dz1979-production-b01');
  assert.equal(batch.status, 'promoted');
  assert.equal(batch.baselineCommit, '7ad674d548f2d4749e183383a668f63461150842');
  assert.equal(batch.quantityReviewArtifact.includes('quantity-review'), true);
  assert.equal(batch.entries.length, 5);
  const entryIds = batch.entries.map((entry) => entry.entryId).sort();
  assert.deepEqual(entryIds, EXPECTED_IDS.slice().sort());
  for (const entry of batch.entries) {
    assert.equal(entry.productionId, entry.entryId);
    assert.equal(entry.sourceQuality, 'ready-for-later-promotion-review', entry.entryId);
    assert.equal(entry.originalClassification, 'book-only', entry.entryId);
    assert.equal(entry.promotedFromDryRun, true, entry.entryId);
    assert.ok(entry.provenanceRecord, entry.entryId);
    assert.deepEqual(entry.productionTargets, [
      'recipe-completion-overlay.json',
      'sichuan-recipes.curated.json',
    ], entry.entryId);
  }
});

test('readiness marks five promoted and keeps all pre-promotion stats', () => {
  assert.equal(readiness.summary.promotedNewRecipeCount, 5);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 34);
  assert.deepEqual(readiness.summary.promotedNewRecipeIds.sort(), EXPECTED_IDS.slice().sort());
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
  assert.deepEqual(readiness.summary.quantityReadinessCounts, {
    'exact-comparable': 36,
    mixed: 3,
    'display-only': 0,
  });
});

test('PWA runtime shows all five exactly once with methods and ingredient maps', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const mode of ['curated', 'full']) {
    const recipes = runtime.packs[mode].recipes;
    const ids = recipes.map((recipe) => recipe.id);
    assert.equal(new Set(ids).size, ids.length, `${mode} duplicate ids`);
    for (const id of EXPECTED_IDS) {
      const occurrences = ids.filter((rid) => rid === id).length;
      assert.equal(occurrences, 1, `${mode} ${id} count ${occurrences}`);
      const recipe = recipes.find((entry) => entry.id === id);
      assert.ok(recipe.method, `${mode} ${id} missing method`);
      assert.ok(recipe.tags && recipe.tags.length > 0, `${mode} ${id} missing tags`);
      const ingredients = runtime.packs[mode].recipe_ingredients[id] || [];
      assert.ok(ingredients.length >= 2, `${mode} ${id} incomplete ingredient map`);
    }
  }
});

test('no orphan ingredient maps in runtime packs', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const mode of ['curated', 'full']) {
    const recipeIds = new Set(runtime.packs[mode].recipes.map((recipe) => recipe.id));
    const mapIds = Object.keys(runtime.packs[mode].recipe_ingredients || {});
    assert.deepEqual(mapIds.filter((id) => !recipeIds.has(id)), [], `${mode} orphan ingredient maps`);
  }
});

test('quantity review artifact matches production qty/unit and normalizes cleanly', () => {
  assert.equal(quantityReview.records.length, 19);
  for (const record of quantityReview.records) {
    const production = curated.recipe_ingredients[record.productionId]
      .find((ingredient) => ingredient.item === record.item);
    assert.deepEqual(production, { item: record.item, qty: record.qty, unit: record.unit }, `${record.productionId}:${record.item}`);
    const normalized = normalizeIngredientAmount(record.qty, record.unit);
    assert.ok(Number.isFinite(Number(normalized.qty)), `${record.productionId}:${record.item}`);
    assert.ok(normalized.unit, `${record.productionId}:${record.item}`);
  }
});

test('curate is idempotent: a temp re-run reproduces current curated exactly', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b1-idem-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(new URL('../scripts/curate-recipes.js', import.meta.url).pathname, path.join(tmp, 'scripts', 'curate-recipes.js'));
    fs.copyFileSync(new URL('../data/sichuan-recipes.json', import.meta.url).pathname, path.join(tmp, 'data', 'sichuan-recipes.json'));
    fs.copyFileSync(new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname, path.join(tmp, 'data', 'recipe-completion-overlay.json'));
    const run = () => {
      execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
      return fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8');
    };
    const first = run();
    const second = run();
    assert.equal(first, second);
    assert.deepEqual(JSON.parse(first), curated);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('iOS RecipeService-compatible shapes are readable for all five', () => {
  for (const id of EXPECTED_IDS) {
    const recipe = curated.recipes.find((entry) => entry.id === id);
    assert.equal(typeof recipe.id, 'string');
    assert.equal(typeof recipe.name, 'string');
    assert.equal(typeof recipe.method, 'string');
    assert.ok(Array.isArray(recipe.tags));
    for (const ing of curated.recipe_ingredients[id]) {
      assert.equal(typeof ing.item, 'string');
      assert.ok(ing.qty === null || typeof ing.qty === 'string');
      assert.ok(ing.unit === null || typeof ing.unit === 'string');
    }
  }
});

test('applicationReady stays false across promotion surfaces', () => {
  assert.equal(ledger.applicationReady, false);
  assert.equal(readiness.applicationReady, false);
  assert.equal(dryRun.baseline.applicationReady, false);
});
