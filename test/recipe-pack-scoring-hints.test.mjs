import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { rankRecipesForRecommendation, scoreRecipe } from '../src/recommendations.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const BASE_CONTEXT = {
  plan: [],
  recipeActivity: {},
  favoriteIds: [],
  today: '2026-06-11'
};

const PACK = {
  recipes: [
    { id: 'local-steamed-egg', name: '蒸蛋羹', method: '蒸熟即可' },
    { id: 'local-plain-egg', name: '家常鸡蛋羹', method: '蒸熟即可' },
    { id: 'local-noodle', name: '葱油拌面', method: '拌匀即可' }
  ],
  recipe_ingredients: {
    'local-steamed-egg': [{ item: '鸡蛋', qty: 2, unit: '个' }],
    'local-plain-egg': [{ item: '鸡蛋', qty: 2, unit: '个' }],
    'local-noodle': [{ item: '鸡蛋', qty: 2, unit: '个' }]
  }
};

const INV = [{ name: '鸡蛋', qty: 6, unit: '个', stockStatus: 'ok' }];

test('settings missing uses default enabled packs and keeps existing candidate count', () => {
  const ranked = rankRecipesForRecommendation(PACK, INV, BASE_CONTEXT);

  assert.equal(ranked.length, PACK.recipes.length);
  assert.equal(ranked.find(item => item.r.name === '蒸蛋羹').scoreParts.recipePackPreferenceBonus, 3);
  assert.equal(ranked.find(item => item.r.name === '葱油拌面').scoreParts.recipePackPreferenceBonus, 3);
  assert.ok(ranked.every(item => PACK.recipes.some(recipe => recipe.id === item.r.id)));
  assert.ok(!ranked.some(item => item.r.name === '番茄炒蛋'));
});

test('quick-solo preference lightly boosts matching existing candidates', () => {
  const ranked = rankRecipesForRecommendation(PACK, INV, {
    ...BASE_CONTEXT,
    settings: { enabledRecipePackIds: ['quick-solo'] }
  });

  assert.equal(ranked[0].r.name, '葱油拌面');
  assert.equal(ranked[0].scoreParts.recipePackPreferenceBonus, 3);
  assert.equal(ranked.find(item => item.r.name === '蒸蛋羹').scoreParts.recipePackPreferenceBonus, 0);
});

test('explicit empty recipe pack preference adds no bonus and never empties recommendations', () => {
  const ranked = rankRecipesForRecommendation(PACK, INV, {
    ...BASE_CONTEXT,
    settings: { enabledRecipePackIds: [] }
  });

  assert.equal(ranked.length, PACK.recipes.length);
  assert.ok(ranked.every(item => item.scoreParts.recipePackPreferenceBonus === 0));
});

test('unmatched recipe pack metadata does not affect scoring', () => {
  const recipe = { id: 'not-in-recipe-pack-data', name: '不存在的测试菜', method: '炒熟即可' };
  const pack = {
    recipes: [recipe],
    recipe_ingredients: {
      'not-in-recipe-pack-data': [{ item: '鸡蛋', qty: 1, unit: '个' }]
    }
  };

  const scored = scoreRecipe(recipe, pack, INV, {
    ...BASE_CONTEXT,
    settings: { enabledRecipePackIds: ['quick-solo'] }
  });

  assert.equal(scored.recipePackPreference.matched, false);
  assert.equal(scored.scoreParts.recipePackPreferenceBonus, 0);
});

test('recipe pack scoring does not change missing ingredient detection', () => {
  const recipe = { id: 'local-steamed-egg', name: '蒸蛋羹', method: '蒸熟即可' };
  const scored = scoreRecipe(recipe, PACK, [], {
    ...BASE_CONTEXT,
    settings: { enabledRecipePackIds: ['basic-home'] }
  });

  assert.equal(scored.scoreParts.recipePackPreferenceBonus, 3);
  assert.deepEqual(scored.missing.map(item => item.name || item.item), ['鸡蛋']);
});
