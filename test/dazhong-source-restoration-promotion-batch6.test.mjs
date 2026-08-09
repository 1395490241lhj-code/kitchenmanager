import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { buildDefaultRuntimePacks } from '../scripts/recipe-runtime-quality.mjs';
import { normalizeIngredientAmount } from '../src/ingredients.js';
import { classifyIngredientCompatibility } from '../scripts/dazhong-runtime-compatibility.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-quantity-review.v1.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const removed = readJson('data/recipe-curation-removed.json');
const needing = readJson('data/recipes-needing-completion.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');

const EXPECTED_IDS = ['dz1979-p159', 'dz1979-p168'];
const BATCH1_IDS = ['dz1979-p143', 'dz1979-p180', 'dz1979-p195', 'dz1979-p200', 'dz1979-p204'];
const BATCH2_IDS = ['dz1979-p187', 'dz1979-p202', 'dz1979-p205', 'dz1979-p188', 'dz1979-p196'];
const BATCH3_IDS = ['dz1979-p212', 'dz1979-p216', 'dz1979-p218', 'dz1979-p221', 'dz1979-p206'];
const BATCH4_IDS = ['dz1979-p183', 'dz1979-p198', 'dz1979-p153', 'dz1979-p209', 'dz1979-p223'];
const BATCH5_IDS = ['dz1979-p162', 'dz1979-p186', 'dz1979-p185', 'dz1979-p219', 'dz1979-p213'];
const itemsById = new Map(dryRun.items.map((item) => [item.productionId, item]));
const BATCH7_IDS = ['dz1979-p211', 'dz1979-p144'];
const BATCH8_IDS = ['dz1979-p129', 'dz1979-p130'];
const BATCH9_IDS = ['dz1979-p161', 'dz1979-p137'];
const BATCH10_IDS = ['dz1979-p203', 'dz1979-p201', 'dz1979-p207'];
const BATCH11_IDS = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];
// Batch 7 may since have been promoted on top of Batch 1-6; this file only
// regression-tests Batch 6's own promoted content, so it stays accurate
// either way by checking Batch 7's presence via the ledger.
const batch7Promoted = BATCH7_IDS.every((id) => (
  ledger.batches.some((b) => (b.entries ?? []).some((e) => e.entryId === id))
));
const batch8Promoted = BATCH8_IDS.every((id) => (
  ledger.batches.some((b) => (b.entries ?? []).some((e) => e.entryId === id))
));
const batch9Promoted = BATCH9_IDS.every((id) => (
  ledger.batches.some((b) => (b.entries ?? []).some((e) => e.entryId === id))
));
const batch10Promoted = BATCH10_IDS.every((id) => (
  ledger.batches.some((b) => (b.entries ?? []).some((e) => e.entryId === id))
));
const batch11Promoted = BATCH11_IDS.every((id) => (
  ledger.batches.some((b) => (b.entries ?? []).some((e) => e.entryId === id))
));
const laterCount = (batch7Promoted ? 2 : 0) + (batch8Promoted ? 2 : 0) + (batch9Promoted ? 2 : 0) + (batch10Promoted ? 3 : 0) + (batch11Promoted ? 3 : 0);
const laterLedgerCount = (batch7Promoted ? 1 : 0) + (batch8Promoted ? 1 : 0) + (batch9Promoted ? 1 : 0) + (batch10Promoted ? 1 : 0) + (batch11Promoted ? 1 : 0);

test('overlay contains exactly the twenty-seven Batch1+2+3+4+5+6 promoted recipes, all matching their dry-runs', () => {
  const overlayIds = overlay.newRecipes
    .filter((recipe) => recipe.id.startsWith('dz1979-'))
    .map((recipe) => recipe.id)
    .sort();
  assert.deepEqual(overlayIds, [...BATCH1_IDS, ...BATCH2_IDS, ...BATCH3_IDS, ...BATCH4_IDS, ...BATCH5_IDS, ...EXPECTED_IDS, ...(batch7Promoted ? BATCH7_IDS : []), ...(batch8Promoted ? BATCH8_IDS : []), ...(batch9Promoted ? BATCH9_IDS : []), ...(batch10Promoted ? BATCH10_IDS : []), ...(batch11Promoted ? BATCH11_IDS : [])].sort());
  assert.equal(overlay.newRecipes.length, 85 + laterCount);
  assert.equal(Object.keys(overlay.newRecipeIngredients).length, 85 + laterCount);
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
  // Existing Batch 1-5 overrides/patches are untouched.
  assert.equal(Object.keys(overlay.recipeIngredientOverrides || {}).length, 9);
  assert.ok(Object.values(overlay.recipeIngredientOverrides || {}).every((v) => v === 'replace'));
});

test('curated contains exactly the twenty-seven Batch1+2+3+4+5+6 promoted recipes with full content (151 -> 153)', () => {
  assert.equal(curated.recipes.length, 153 + laterCount);
  assert.equal(curated.recipes.filter((recipe) => recipe.id.startsWith('dz1979-')).length, 27 + laterCount);
  for (const id of EXPECTED_IDS) {
    const recipe = curated.recipes.find((entry) => entry.id === id);
    assert.deepEqual(recipe, itemsById.get(id).proposedCuratedRecipe, id);
    assert.deepEqual(
      curated.recipe_ingredients[id],
      itemsById.get(id).proposedCuratedIngredients[id],
      `${id} curated ingredients`,
    );
  }
  // Batch 1/2/3/4/5's twenty-five remain, unmodified.
  for (const id of [...BATCH1_IDS, ...BATCH2_IDS, ...BATCH3_IDS, ...BATCH4_IDS, ...BATCH5_IDS]) {
    assert.ok(curated.recipes.some((r) => r.id === id), `${id} must remain in curated`);
  }
});

test('Full library, removed, and needing reports carry no Batch 6 entries and stay at their frozen sizes', () => {
  assert.equal(full.recipes.some((recipe) => EXPECTED_IDS.includes(recipe.id)), false);
  assert.equal(removed.removed.some((entry) => EXPECTED_IDS.includes(entry.id)), false);
  assert.equal(needing.items.some((entry) => EXPECTED_IDS.includes(entry.id)), false);
  assert.equal(removed.removed.length, 204);
  assert.equal(needing.items.length, 13);
  assert.equal(full.recipes.length, 264);
});

test('recipe-curation-summary.md reflects exactly the dry-run-predicted mechanical count changes', () => {
  const summary = fs.readFileSync(
    new URL('../data/recipe-curation-summary.md', import.meta.url),
    'utf8',
  );
  const n = laterCount;
  assert.match(summary, new RegExp(`原始菜谱（base \\+ overlay 合并后的有效集）\\s*\\|\\s*${349 + n}`));
  assert.match(summary, new RegExp(`overlay 新增/补全后净增\\s*\\|\\s*${85 + n}`));
  assert.match(summary, new RegExp(`curated 保留\\*\\*\\s*\\|\\s*\\*\\*${153 + n}`));
  assert.match(summary, new RegExp(`从有效集保留（有做法直接保留）\\s*\\|\\s*${132 + n}`));
  assert.match(summary, new RegExp(`从 overlay 补全 method 的菜\\s*\\|\\s*${132 + n}`));
  assert.match(summary, new RegExp(`从 overlay 补全 ingredients 的菜\\s*\\|\\s*${95 + n}`));
});

test('promotion ledger records Batch 6 with full provenance while keeping Batch 1/2/3/4/5 intact', () => {
  assert.equal(ledger.applicationReady, false);
  assert.equal(ledger.partialPromotion, true);
  assert.equal(ledger.batches.length, 6 + laterLedgerCount);
  const batch1 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b01');
  const batch2 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b02');
  const batch3 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b03');
  const batch4 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b04');
  const batch5 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b05');
  const batch6 = ledger.batches.find((b) => b.batchId === 'dz1979-production-b06');
  assert.ok(batch1, 'Batch 1 entry must still exist');
  assert.ok(batch2, 'Batch 2 entry must still exist');
  assert.ok(batch3, 'Batch 3 entry must still exist');
  assert.ok(batch4, 'Batch 4 entry must still exist');
  assert.ok(batch5, 'Batch 5 entry must still exist');
  assert.ok(batch6, 'Batch 6 entry must exist');
  assert.equal(batch1.entries.length, 5);
  assert.equal(batch2.entries.length, 5);
  assert.equal(batch3.entries.length, 5);
  assert.equal(batch4.entries.length, 5);
  assert.equal(batch5.entries.length, 5);
  assert.equal(batch6.status, 'promoted');
  assert.equal(batch6.baselineCommit, 'da6f8bc5a079f086a5545a6368c678a92d174250');
  assert.equal(batch6.dryRunArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');
  assert.equal(batch6.quantityReviewArtifact, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch6-quantity-review.v1.json');
  assert.equal(batch6.entries.length, 2);
  const entryIds = batch6.entries.map((entry) => entry.entryId).sort();
  assert.deepEqual(entryIds, EXPECTED_IDS.slice().sort());
  for (const entry of batch6.entries) {
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

test('readiness marks twenty-seven promoted (5+5+5+5+5+2), remaining drops to 12, and preserves classification stats', () => {
  assert.equal(readiness.summary.promotedNewRecipeCount, 27 + laterCount);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 12 - laterCount);
  assert.deepEqual(
    readiness.summary.promotedNewRecipeIds.sort(),
    [...BATCH1_IDS, ...BATCH2_IDS, ...BATCH3_IDS, ...BATCH4_IDS, ...BATCH5_IDS, ...EXPECTED_IDS, ...(batch7Promoted ? BATCH7_IDS : []), ...(batch8Promoted ? BATCH8_IDS : []), ...(batch9Promoted ? BATCH9_IDS : []), ...(batch10Promoted ? BATCH10_IDS : []), ...(batch11Promoted ? BATCH11_IDS : [])].sort(),
  );
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
  for (const id of EXPECTED_IDS) {
    const entry = readiness.entries.find((e) => e.entryId === id);
    assert.equal(entry.promotionState, 'promoted', id);
  }
  // p137/p161 remain not-promoted; not addressed this round.
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    const entry = readiness.entries.find((e) => e.entryId === id);
    assert.equal(entry.promotionState, batch9Promoted ? 'promoted' : 'not-promoted', id);
  }
});

test('PWA runtime shows both Batch 6 recipes exactly once, alongside Batch 1/2/3/4/5, with methods and ingredient maps', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const mode of ['curated', 'full']) {
    const recipes = runtime.packs[mode].recipes;
    const ids = recipes.map((recipe) => recipe.id);
    assert.equal(new Set(ids).size, ids.length, `${mode} duplicate ids`);
    for (const id of [...BATCH1_IDS, ...BATCH2_IDS, ...BATCH3_IDS, ...BATCH4_IDS, ...BATCH5_IDS, ...EXPECTED_IDS]) {
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

test('no orphan ingredient maps in runtime packs after Batch 6', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const mode of ['curated', 'full']) {
    const recipeIds = new Set(runtime.packs[mode].recipes.map((recipe) => recipe.id));
    const mapIds = Object.keys(runtime.packs[mode].recipe_ingredients || {});
    assert.deepEqual(mapIds.filter((id) => !recipeIds.has(id)), [], `${mode} orphan ingredient maps`);
  }
});

test('Batch 6 core runtime compatibility: 0 unresolved-name-match, 2 expected-unit-confirmation', () => {
  let coreCount = 0;
  let exactCount = 0;
  let unitConfirmationCount = 0;
  for (const id of EXPECTED_IDS) {
    const ingredients = curated.recipe_ingredients[id];
    for (const ingredient of ingredients) {
      const result = classifyIngredientCompatibility(ingredient.item, ingredient.qty, ingredient.unit);
      if (result.role !== 'core') continue;
      coreCount += 1;
      assert.notEqual(result.compatibility, 'unresolved-name-match', `${id}:${ingredient.item}`);
      if (result.compatibility === 'exact-compatible') exactCount += 1;
      if (result.compatibility === 'expected-unit-confirmation') unitConfirmationCount += 1;
    }
  }
  assert.equal(unitConfirmationCount, 2);
  assert.equal(coreCount, exactCount + unitConfirmationCount);
  assert.ok(coreCount > 0);
});

test('p137, p161 (runtime-name-gate blocked) remain unpromoted this round', () => {
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    assert.equal(curated.recipes.some((r) => r.id === id), batch9Promoted, `${id} must not be promoted`);
    assert.equal(overlay.newRecipes.some((r) => r.id === id), batch9Promoted, `${id} must not be in overlay`);
  }
});

test('Batch 6 quantity review artifact matches production qty/unit and normalizes cleanly', () => {
  assert.equal(quantityReview.records.length, 24);
  for (const record of quantityReview.records) {
    const production = curated.recipe_ingredients[record.productionId]
      .find((ingredient) => ingredient.item === record.item);
    assert.deepEqual(production, { item: record.item, qty: record.qty, unit: record.unit }, `${record.productionId}:${record.item}`);
    const normalized = normalizeIngredientAmount(record.qty, record.unit);
    assert.ok(Number.isFinite(Number(normalized.qty)), `${record.productionId}:${record.item}`);
    assert.ok(normalized.unit, `${record.productionId}:${record.item}`);
    assert.equal(record.evidenceType, 'source-restoration', `${record.productionId}:${record.item}`);
    assert.equal(record.reviewStatus, 'approved', `${record.productionId}:${record.item}`);
  }
});

test('curate is idempotent: a temp re-run reproduces current curated exactly', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-b6-idem-'));
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

test('iOS RecipeService-compatible shapes are readable for both Batch 6 recipes', () => {
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

test('iOS RecipeService-compatible shapes decode across the full 153-recipe curated pack', () => {
  for (const recipe of curated.recipes) {
    assert.equal(typeof recipe.id, 'string', recipe.id);
    assert.equal(typeof recipe.name, 'string', recipe.id);
    if (recipe.method !== undefined) assert.equal(typeof recipe.method, 'string', recipe.id);
    if (recipe.tags !== undefined) assert.ok(Array.isArray(recipe.tags), recipe.id);
    const ingredients = curated.recipe_ingredients[recipe.id] || [];
    for (const ing of ingredients) {
      assert.equal(typeof ing.item, 'string', recipe.id);
      assert.ok(ing.qty === null || ing.qty === undefined || typeof ing.qty === 'string', recipe.id);
      assert.ok(ing.unit === null || ing.unit === undefined || typeof ing.unit === 'string', recipe.id);
    }
  }
  assert.equal(curated.recipes.length, 153 + laterCount);
});

test('applicationReady stays false across every Batch 6 promotion surface', () => {
  assert.equal(ledger.applicationReady, false);
  assert.equal(readiness.applicationReady, false);
  assert.equal(dryRun.baseline.applicationReady, false);
  assert.equal(quantityReview.applicationReady, false);
});

test('this promotion strictly used the frozen dry-run fields, no reselection or recomputation', () => {
  assert.deepEqual(dryRun.items.map((item) => item.productionId), EXPECTED_IDS);
  assert.deepEqual(dryRun.verificationProblems, []);
  for (const item of dryRun.items) {
    assert.deepEqual(item.proposedOverlayRecipe, item.proposedCuratedRecipe, item.entryId);
    assert.deepEqual(
      item.proposedOverlayIngredients[item.productionId],
      item.proposedCuratedIngredients[item.productionId],
      item.entryId,
    );
  }
});
