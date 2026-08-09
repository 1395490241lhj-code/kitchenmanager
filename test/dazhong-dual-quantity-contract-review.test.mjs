import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { analyzeRecipeInventory } from '../src/recommendations.js';
import { getCanonicalName } from '../src/ingredients.js';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';
import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

const readJson = (file) => JSON.parse(fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
const review = readJson('data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.json');
const canonical = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const recipeById = new Map(canonical.recipes.map((recipe) => [recipe.entryId, recipe]));

function resolveSidecar(base, sidecar, recipeId, item) {
  const matches = (base[recipeId] || []).filter((ingredient) => ingredient.item === item);
  assert.equal(matches.length, 1, `${recipeId}:${item} must identify exactly one base ingredient`);
  const semantics = sidecar.recipes?.[recipeId]?.ingredients?.[item];
  assert.ok(semantics, `${recipeId}:${item} sidecar entry missing`);
  assert.deepEqual(
    { qty: Number(matches[0].qty), unit: matches[0].unit },
    semantics.input,
    `${recipeId}:${item} sidecar input must equal the base ingredient`,
  );
  return semantics;
}

test('review is baseline-pinned, design-only, and keeps the application blocked', () => {
  assert.deepEqual(review.baseline, {
    commit: '6f6b94ba9efa5b02bb90f3eef5fec22ff9d3a48b',
    curated: 162,
    full: 264,
    promoted: 36,
    remaining: 3,
    remainingEntryIds: ['dz1979-p222', 'dz1979-p224', 'dz1979-p226'],
    applicationReady: false,
  });
  assert.equal(review.applicationReady, false);
  assert.equal(review.recommendedDesign, 'B');
  assert.deepEqual(review.writeTargets, [
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.md',
    'test/dazhong-dual-quantity-contract-review.test.mjs',
  ]);
});

test('main-agent scan semantics match canonical and p226 dry flour is seasoning after runtime canonicalization', () => {
  for (const sourceRecipe of review.sourceSemantics) {
    const recipe = recipeById.get(sourceRecipe.entryId);
    assert.ok(recipe, sourceRecipe.entryId);
    assert.equal(sourceRecipe.source.visuallyConfirmedByMainAgent, true);
    for (const pair of sourceRecipe.dualQuantityIngredients) {
      const ingredient = recipe.ingredients.find((entry) => entry.rawItemText === pair.item);
      assert.ok(ingredient, `${sourceRecipe.entryId}:${pair.item}`);
      assert.equal(ingredient.rawQuantityText, pair.rawQuantityText);
      assert.deepEqual(
        { qty: ingredient.normalizedQuantity.qty, unit: ingredient.normalizedQuantity.unit },
        pair.input,
      );
      assert.deepEqual(
        {
          qty: ingredient.normalizedQuantity.consumedQty,
          unit: ingredient.normalizedQuantity.consumedUnit,
          referenceQty: ingredient.normalizedQuantity.consumedReferenceQty ?? null,
          qualifier: ingredient.normalizedQuantity.consumedQualifier ?? null,
        },
        pair.consumed,
      );
    }
  }
  assert.equal(classifyRecipeIngredient('菜油').role, 'seasoning');
  assert.equal(classifyRecipeIngredient('干豆粉').role, 'core');
  assert.equal(getCanonicalName('干豆粉'), '豆粉');
  assert.deepEqual(classifyRecipeIngredient(getCanonicalName('干豆粉')), {
    name: '豆粉', role: 'seasoning', reason: 'starch',
  });
  assert.equal(review.mainAgentIndependentConclusion.p226HasCoreDualQuantityIngredient, false);
  assert.equal(review.mainAgentIndependentConclusion.p226HasSourceSignificantCoatingIngredient, true);
});

test('sidecar round-trip is lossless, base ingredients are byte-stable, and identity never uses index', () => {
  const base = structuredClone(review.compatibilityProof.prototypeBaseRecipeIngredients);
  const before = JSON.stringify(base);
  const sidecar = JSON.parse(JSON.stringify(review.proposedContract.prototype));

  assert.equal(review.proposedContract.identity.arrayIndexAllowed, false);
  assert.equal(sidecar.recipes['legacy-normal'], undefined);
  assert.deepEqual(base['legacy-normal'], [{ item: '豆腐', qty: 300, unit: 'g' }]);

  const expected = {
    'dz1979-p222': { 菜油: [500, 100] },
    'dz1979-p224': { 菜油: [500, 100] },
    'dz1979-p226': { 菜油: [500, 100], 干豆粉: [500, 200] },
  };
  for (const [recipeId, ingredients] of Object.entries(expected)) {
    for (const [item, [inputQty, consumedQty]] of Object.entries(ingredients)) {
      const semantics = resolveSidecar(base, sidecar, recipeId, item);
      assert.equal(semantics.input.qty, inputQty);
      assert.equal(semantics.consumed.qty, consumedQty);
      assert.notEqual(semantics.input.qty, semantics.consumed.qty);
      assert.equal(semantics.consumed.referenceQty, null);
      assert.equal(semantics.consumed.qualifier, null);
      assert.ok(semantics.rawQuantityText.includes('耗'));
      assert.equal(semantics.provenance.entryId, recipeId);
    }
  }
  assert.equal(JSON.stringify(base), before, 'sidecar processing must not mutate or reserialize base ingredients');
  assert.deepEqual(JSON.parse(JSON.stringify(sidecar)), review.proposedContract.prototype);
});

test('real old recommendation inventory behavior is unchanged when a sidecar property exists', () => {
  installLocalStorageStub();
  resetLocalStorage();
  const recipe = { id: 'dz1979-p226', name: '蛋酥花仁' };
  const pack = {
    recipes: [recipe],
    recipe_ingredients: {
      'dz1979-p226': [
        { item: '菜油', qty: 500, unit: 'g' },
        { item: '干豆粉', qty: 500, unit: 'g' },
      ],
    },
  };
  const inventory = [{ name: '干豆粉', qty: 300, unit: 'g', stockStatus: 'ok', buyDate: '2026-08-09', shelf: 365 }];
  const withoutSidecar = analyzeRecipeInventory(recipe, pack, inventory);
  const withSidecar = analyzeRecipeInventory(recipe, {
    ...pack,
    quantity_semantics: review.proposedContract.prototype,
  }, inventory);

  assert.deepEqual(withSidecar, withoutSidecar);
  assert.equal(withoutSidecar.totalCore, 0);
  assert.deepEqual(withoutSidecar.missing, []);
});

test('review preserves its historical protected-file scope after the approved promotion', () => {
  assert.deepEqual(review.protectedArtifacts, [
    'data/sichuan-recipes.json',
    'data/sichuan-recipes.curated.json',
    'data/recipe-completion-overlay.json',
    'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
  ]);
  assert.equal(review.baseline.commit, '6f6b94ba9efa5b02bb90f3eef5fec22ff9d3a48b');
});
