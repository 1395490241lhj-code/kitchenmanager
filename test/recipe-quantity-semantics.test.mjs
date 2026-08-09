import test from 'node:test';
import assert from 'node:assert/strict';
import {
  RECIPE_QUANTITY_SEMANTICS_SCHEMA,
  assertValidRecipeQuantitySemantics,
  validateRecipeQuantitySemantics,
} from '../scripts/recipe-quantity-semantics.mjs';

const base = {
  recipes: [{ id: 'r1', name: '测试菜' }],
  recipe_ingredients: { r1: [{ item: '菜油', qty: '500', unit: 'g' }] },
};
const exact = {
  schema: RECIPE_QUANTITY_SEMANTICS_SCHEMA,
  recipes: {
    r1: { ingredients: {
      菜油: {
        input: { qty: 500, unit: 'g' },
        consumed: { qty: 100, unit: 'g', referenceQty: null, qualifier: null },
        rawQuantityText: '一斤耗二两',
        provenance: { sourceId: 'test-source', entryId: 'r1', pdfPage: 1, bookPage: 1 },
      },
    } },
  },
};

test('exact and future approximate contracts validate without mutating base bytes', () => {
  const before = JSON.stringify(base);
  const result = assertValidRecipeQuantitySemantics(exact, base);
  assert.deepEqual(result.joins, [{ recipeId: 'r1', item: '菜油' }]);
  assert.equal(JSON.stringify(base), before);

  const approximate = structuredClone(exact);
  approximate.recipes.r1.ingredients.菜油.consumed = {
    qty: null, unit: 'g', referenceQty: 90, qualifier: '约',
  };
  assert.equal(validateRecipeQuantitySemantics(approximate, base).valid, true);
});

test('orphan, duplicate, and array-index identities hard fail', () => {
  const orphan = structuredClone(exact);
  orphan.recipes.r2 = orphan.recipes.r1;
  delete orphan.recipes.r1;
  assert.match(validateRecipeQuantitySemantics(orphan, base).problems.join('|'), /orphan-recipe/);

  const duplicateBase = structuredClone(base);
  duplicateBase.recipe_ingredients.r1.push({ item: '菜油', qty: 500, unit: 'g' });
  assert.match(validateRecipeQuantitySemantics(exact, duplicateBase).problems.join('|'), /duplicate-base-item/);

  const indexed = structuredClone(exact);
  indexed.recipes.r1.ingredients['0'] = indexed.recipes.r1.ingredients.菜油;
  delete indexed.recipes.r1.ingredients.菜油;
  assert.match(validateRecipeQuantitySemantics(indexed, base).problems.join('|'), /array-index-item-key/);
});

test('input mismatch and malformed or nonfinite consumed quantities hard fail', () => {
  const mismatch = structuredClone(exact);
  mismatch.recipes.r1.ingredients.菜油.input.qty = 100;
  assert.match(validateRecipeQuantitySemantics(mismatch, base).problems.join('|'), /input-base-mismatch/);

  const nonfinite = structuredClone(exact);
  nonfinite.recipes.r1.ingredients.菜油.consumed.qty = 'Infinity';
  assert.match(validateRecipeQuantitySemantics(nonfinite, base).problems.join('|'), /invalid-exact-consumed/);

  const mixed = structuredClone(exact);
  mixed.recipes.r1.ingredients.菜油.consumed.referenceQty = 100;
  assert.match(validateRecipeQuantitySemantics(mixed, base).problems.join('|'), /invalid-exact-consumed/);
});
