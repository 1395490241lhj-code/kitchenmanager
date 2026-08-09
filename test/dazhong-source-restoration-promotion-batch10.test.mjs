import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const repoRoot = path.resolve(new URL('..', import.meta.url).pathname);
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const BASELINE = '204646b66a0fe0ed804cac4611a30845e655e837';
const SELECTED = ['dz1979-p203', 'dz1979-p201', 'dz1979-p207'];
const BLOCKED = ['dz1979-p222', 'dz1979-p224', 'dz1979-p226'];
const BATCH11 = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-quantity-review.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const runtimeBaseline = readJson('data/recipe-runtime-baseline.json');
const baselineJson = (file) => JSON.parse(execFileSync(
  'git',
  ['show', BASELINE + ':' + file],
  { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 },
));

test('production is exactly frozen Batch10 +3 recipes/+3 maps with zero existing drift', () => {
  const before = baselineJson('data/sichuan-recipes.curated.json');
  const beforeOverlay = baselineJson('data/recipe-completion-overlay.json');
  assert.equal(before.recipes.length, 159);
  assert.equal(curated.recipes.length, 165);
  assert.equal(Object.keys(curated.recipe_ingredients).length, Object.keys(before.recipe_ingredients).length + 6);
  assert.deepEqual(
    curated.recipes
      .filter((recipe) => !before.recipes.some((old) => old.id === recipe.id))
      .map((recipe) => recipe.id)
      .sort(),
    [...SELECTED, ...BATCH11].sort(),
  );
  for (const recipe of before.recipes) {
    assert.deepEqual(curated.recipes.find((entry) => entry.id === recipe.id), recipe, recipe.id);
    assert.deepEqual(curated.recipe_ingredients[recipe.id], before.recipe_ingredients[recipe.id], recipe.id + ':map');
  }
  assert.deepEqual(overlay.newRecipes.slice(0, beforeOverlay.newRecipes.length), beforeOverlay.newRecipes);
  for (const item of dryRun.items) assert.deepEqual(overlay.newRecipes.find((recipe) => recipe.id === item.productionId), item.proposedOverlayRecipe);
  for (const [id, ingredients] of Object.entries(beforeOverlay.newRecipeIngredients)) {
    assert.deepEqual(overlay.newRecipeIngredients[id], ingredients, id + ':existing-overlay-map');
  }
  for (const item of dryRun.items) {
    assert.deepEqual(curated.recipes.find((recipe) => recipe.id === item.productionId), item.proposedCuratedRecipe, item.entryId);
    assert.deepEqual(curated.recipe_ingredients[item.productionId], item.proposedCuratedIngredients[item.productionId], item.entryId + ':map');
    assert.deepEqual(overlay.newRecipeIngredients[item.productionId], item.proposedOverlayIngredients[item.productionId], item.entryId + ':overlay-map');
  }
});

test('the only Batch10 null ingredients are the three reviewed 花椒 pairs', () => {
  const nulls = SELECTED.flatMap((id) => (
    curated.recipe_ingredients[id]
      .filter((ingredient) => ingredient.qty === null || ingredient.unit === null)
      .map((ingredient) => [id, ingredient])
  ));
  assert.deepEqual(nulls, SELECTED.map((id) => [id, { item: '花椒', qty: null, unit: null }]));
  assert.equal(quantityReview.records.some((record) => record.item === '花椒'), false);
  assert.equal(quantityReview.records.length, 22);
  assert.deepEqual(quantityReview.summary.unitCounts, { g: 19, '根': 3 });
});

test('ledger records dz1979-production-b10 with the requested baseline and frozen artifacts', () => {
  assert.equal(ledger.batches.length, 11);
  const batch = ledger.batches.find((entry) => entry.batchId === 'dz1979-production-b10');
  assert.equal(batch.batchId, 'dz1979-production-b10');
  assert.equal(batch.status, 'promoted');
  assert.equal(batch.baselineCommit, BASELINE);
  assert.equal(batch.dryRunArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');
  assert.equal(batch.quantityReviewArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch10-quantity-review.v1.json');
  assert.deepEqual(batch.entries.map((entry) => entry.entryId), SELECTED);
  assert.ok(batch.entries.every((entry) => entry.promotedFromDryRun === true));
  assert.equal(ledger.applicationReady, false);
  assert.equal(ledger.partialPromotion, true);
});

test('readiness keeps Batch10 and marks the consumed-dual entries promoted by Batch11', () => {
  assert.equal(readiness.summary.promotedNewRecipeCount, 39);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 0);
  assert.equal(readiness.applicationReady, false);
  assert.deepEqual(
    readiness.entries
      .filter((entry) => entry.promotionDisposition === 'new-recipe-candidate' && entry.promotionState === 'not-promoted')
      .map((entry) => entry.entryId)
      .sort(),
    [],
  );
  for (const id of BLOCKED) {
    const entry = readiness.entries.find((candidate) => candidate.entryId === id);
    assert.equal(entry.promotionState, 'promoted', id);
    const canonical = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json')
      .recipes.find((recipe) => recipe.entryId === id);
    assert.ok(canonical.ingredients.some((ingredient) => 'consumedQty' in (ingredient.normalizedQuantity ?? {})), id);
    assert.equal(curated.recipes.some((recipe) => recipe.id === id), true, id);
  }
});

test('structured reviewed registry reaches 305 with Batch10 quantities intact', () => {
  const sourceRecords = ledger.batches.flatMap((batch) => readJson(batch.quantityReviewArtifact).records ?? []);
  const keys = new Set(sourceRecords.map((record) => record.productionId + ':' + record.item));
  assert.equal(sourceRecords.length, 294);
  assert.equal(keys.size, 294);
  assert.equal(sourceRecords.length + 11, 305);
  for (const id of SELECTED) {
    for (const ingredient of curated.recipe_ingredients[id]) {
      if (ingredient.qty === null && ingredient.unit === null) continue;
      assert.ok(keys.has(id + ':' + ingredient.item), id + ':' + ingredient.item);
    }
  }
});

test('Full/removed/needing/canonical/crosswalk/name-matches and frozen reviews/artifacts are byte-identical', () => {
  const sourceDir = path.join(repoRoot, 'data/source-restoration');
  const protectedPaths = fs.readdirSync(sourceDir)
    .filter((name) => /^dazhong-chuancai-1979-promotion-batch(?:[1-9]|10)-(?:dry-run|quantity-review)\.v1\.(?:json|md)$/.test(name))
    .map((name) => 'data/source-restoration/' + name);
  protectedPaths.push(
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
  );
  for (const file of protectedPaths) {
    const expected = execFileSync('git', ['show', BASELINE + ':' + file], {
      cwd: repoRoot,
      maxBuffer: 32 * 1024 * 1024,
    });
    assert.deepEqual(fs.readFileSync(path.join(repoRoot, file)), expected, file);
  }
});

test('runtime baseline and curation summary reflect exactly 165 curated recipes', () => {
  assert.equal(runtimeBaseline.sources.curated.count, 165);
  assert.equal(runtimeBaseline.sources.full.count, 264);
  const summary = fs.readFileSync(path.join(repoRoot, 'data/recipe-curation-summary.md'), 'utf8');
  assert.match(summary, /原始菜谱（base \+ overlay 合并后的有效集） \| 361/);
  assert.match(summary, /\*\*curated 保留\*\* \| \*\*165\*\*/);
});
