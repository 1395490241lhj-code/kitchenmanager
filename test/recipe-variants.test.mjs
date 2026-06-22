import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { addRecipeToPlan } from '../src/recommendations.js';
import {
  buildVariantMethodDraft,
  getGenericIngredientRecipeRecommendations,
  getRecipeVariantRecommendations,
  getVariantIngredientFamilyKey
} from '../src/utils/recipe-variants.js';
import { loadOverlay } from '../src/backup.js';
import { createUserRecipe } from '../src/components/recipe-create-modal.js';
import { S } from '../src/storage.js';

const N = {
  greenPepper: '\u9752\u6912',
  beef: '\u725b\u8089',
  pork: '\u732a\u8089',
  tofu: '\u8c46\u8150',
  soySauce: '\u751f\u62bd',
  piece: '\u4e2a',
  serving: '\u4efd',
  porkPepperRecipe: '\u9752\u6912\u7092\u732a\u8089\u4e1d',
  beefPepperRecipe: '\u9752\u6912\u7092\u725b\u8089\u4e1d',
  porkDumplings: '\u732a\u8089\u767d\u83dc\u997a\u5b50',
  variantTag: '\u53d8\u5316\u83dc',
  simpleTag: '\u7b80\u5355\u505a\u6cd5',
  muerCai: '\u6728\u8033\u83dc',
  egg: '\u9e21\u86cb',
  tofu: '\u8c46\u8150',
  garlicStirFryMuerCai: '\u849c\u84c9\u6e05\u7092\u6728\u8033\u83dc',
  muerCaiEggSoup: '\u6728\u8033\u83dc\u86cb\u82b1\u6c64',
  muerCaiTofuSoup: '\u6728\u8033\u83dc\u8c46\u8150\u6c64',
  handful: '\u628a',
  quickFry: '\u5feb\u7092',
  starch: '\u6dc0\u7c89'
};

function makeBasePack() {
  return {
    recipes: [
      {
        id: 'pork-pepper',
        name: N.porkPepperRecipe,
        method: '\u732a\u8089\u5207\u4e1d\uff0c\u548c\u9752\u6912\u4e00\u8d77\u5feb\u7092\u3002'
      }
    ],
    recipe_ingredients: {
      'pork-pepper': [
        { item: N.greenPepper, qty: 2, unit: N.piece },
        { item: N.pork, qty: 1, unit: N.serving },
        { item: N.soySauce, qty: '', unit: '' }
      ]
    }
  };
}

function makeBeefPepperInventory() {
  return [
    { name: N.greenPepper, qty: 2, unit: N.piece, stockStatus: 'ok' },
    { name: N.beef, qty: 1, unit: N.serving, stockStatus: 'ok' }
  ];
}

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
  globalThis.window = { invalidatePackCache() {} };
});

test('variant recommendations can replace same-family pork with beef from inventory', () => {
  const variants = getRecipeVariantRecommendations(makeBasePack(), makeBeefPepperInventory());
  assert.equal(variants.length, 1);
  assert.match(variants[0].name, new RegExp(`${N.greenPepper}.*${N.beef}|${N.greenPepper}.*${N.quickFry}.*${N.beef}`));
  assert.deepEqual(variants[0].replacements.map(item => [item.from, item.to]), [[N.pork, N.beef]]);
  assert.match(variants[0].sourceLabel, new RegExp(`${N.variantTag}.*${N.porkPepperRecipe}`));
});

test('existing formal recipes with the same variant name are not duplicated', () => {
  const pack = makeBasePack();
  pack.recipes.push({ id: 'beef-pepper', name: N.beefPepperRecipe, method: '\u5feb\u7092\u3002' });
  const variants = getRecipeVariantRecommendations(pack, makeBeefPepperInventory());
  assert.deepEqual(variants, []);
});

test('unrelated ingredient families are not swapped by default', () => {
  const variants = getRecipeVariantRecommendations(makeBasePack(), [
    { name: N.greenPepper, stockStatus: 'ok' },
    { name: N.tofu, stockStatus: 'ok' }
  ]);
  assert.deepEqual(variants, []);
});

test('processed food does not participate in variant replacement', () => {
  const variants = getRecipeVariantRecommendations(makeBasePack(), [
    { name: N.greenPepper, stockStatus: 'ok' },
    { name: N.porkDumplings, stockStatus: 'ok' }
  ]);
  assert.deepEqual(variants, []);
});

test('variant recommendations respect the requested limit', () => {
  const pack = { recipes: [], recipe_ingredients: {} };
  const baseRows = makeBasePack().recipe_ingredients['pork-pepper'];
  for (let i = 0; i < 8; i++) {
    const id = `pork-pepper-${i}`;
    pack.recipes.push({ id, name: `${N.porkPepperRecipe}${i}`, method: '\u5feb\u7092\u3002' });
    pack.recipe_ingredients[id] = baseRows.map(item => ({ ...item }));
  }
  const variants = getRecipeVariantRecommendations(pack, makeBeefPepperInventory(), { limit: 3 });
  assert.ok(variants.length <= 3);
});

test('beef variant method draft includes a cooking reminder', () => {
  const variant = getRecipeVariantRecommendations(makeBasePack(), makeBeefPepperInventory())[0];
  assert.ok(variant, 'expected a beef variant recommendation');
  const method = buildVariantMethodDraft(variant);
  assert.ok(method.includes(N.beef));
  assert.ok(method.includes(N.quickFry) || method.includes(N.starch));
});

test('saving a variant writes overlay recipe ingredients and plan uses the new recipe id', () => {
  const variant = getRecipeVariantRecommendations(makeBasePack(), makeBeefPepperInventory())[0];
  assert.ok(variant, 'expected a beef variant recommendation');
  const id = createUserRecipe(makeBasePack(), {
    name: variant.name,
    tags: [N.variantTag],
    method: variant.methodDraft,
    ingredients: variant.recipeIngredients
  });
  assert.ok(id);
  assert.equal(addRecipeToPlan(id, '2026-06-22'), true);
  const overlay = loadOverlay();
  assert.equal(overlay.recipes[id].name, variant.name);
  assert.ok(overlay.recipe_ingredients[id].some(item => item.item === N.beef));
  assert.ok(!overlay.recipe_ingredients[id].some(item => item.item === N.pork));
  assert.deepEqual(S.load(S.keys.plan, []).map(item => item.id), [id]);
  assert.equal(localStorage.getItem('km_recipe_variants'), null);
});

test('leafy-green aliases can participate in variant and generic template families', () => {
  assert.equal(getVariantIngredientFamilyKey(N.muerCai), 'leafy_green');
});

test('generic template recommendations can make garlic stir-fried muer cai without a fixed recipe', () => {
  const cards = getGenericIngredientRecipeRecommendations({ recipes: [], recipe_ingredients: {} }, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' }
  ]);
  assert.ok(cards.some(card => card.name === N.garlicStirFryMuerCai));
  const card = cards.find(item => item.name === N.garlicStirFryMuerCai);
  assert.equal(card.matchLabel, N.simpleTag);
  assert.equal(card.sourceLabel, '\u901a\u7528\u505a\u6cd5 \u00b7 \u9002\u5408\u7eff\u53f6\u83dc');
  assert.ok(card.methodDraft.includes(N.muerCai));
});

test('generic templates prefer egg soup and tofu soup when those ingredients are available', () => {
  const eggCards = getGenericIngredientRecipeRecommendations({ recipes: [], recipe_ingredients: {} }, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: N.egg, qty: 2, unit: N.piece, stockStatus: 'ok' }
  ]);
  assert.ok(eggCards.some(card => card.name === N.muerCaiEggSoup));

  const tofuCards = getGenericIngredientRecipeRecommendations({ recipes: [], recipe_ingredients: {} }, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: N.tofu, qty: 1, unit: '\u76d2', stockStatus: 'ok' }
  ]);
  assert.ok(tofuCards.some(card => card.name === N.muerCaiTofuSoup));
});

test('generic template recommendations skip duplicate formal recipe names and respect limit', () => {
  const pack = {
    recipes: [{ id: 'garlic-muer-cai', name: N.garlicStirFryMuerCai }],
    recipe_ingredients: {}
  };
  const duplicate = getGenericIngredientRecipeRecommendations(pack, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' }
  ]);
  assert.deepEqual(duplicate, []);

  const limited = getGenericIngredientRecipeRecommendations({ recipes: [], recipe_ingredients: {} }, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: '\u7a7a\u5fc3\u83dc', qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: '\u82cb\u83dc', qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: N.egg, qty: 2, unit: N.piece, stockStatus: 'ok' }
  ], { limit: 2 });
  assert.ok(limited.length <= 2);
});

test('saving a generic template writes overlay recipe ingredients and plan uses the new recipe id', () => {
  const card = getGenericIngredientRecipeRecommendations({ recipes: [], recipe_ingredients: {} }, [
    { name: N.muerCai, qty: 1, unit: N.handful, stockStatus: 'ok' },
    { name: N.egg, qty: 2, unit: N.piece, stockStatus: 'ok' }
  ])[0];
  assert.ok(card, 'expected a generic template recommendation');
  const id = createUserRecipe({ recipes: [] }, {
    name: card.name,
    tags: card.tags,
    method: card.methodDraft,
    ingredients: card.recipeIngredients
  });
  assert.ok(id);
  assert.equal(addRecipeToPlan(id, '2026-06-22'), true);
  const overlay = loadOverlay();
  assert.equal(overlay.recipes[id].name, card.name);
  assert.ok(overlay.recipes[id].tags.includes(N.simpleTag));
  assert.ok(overlay.recipe_ingredients[id].some(item => item.item === N.muerCai));
  assert.deepEqual(S.load(S.keys.plan, []).map(item => item.id), [id]);
  assert.equal(localStorage.getItem('km_generic_recipe_templates'), null);
});
