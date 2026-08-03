import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

import { applyOverlay } from '../src/backup.js';
import { mergeRecipeMethods } from '../src/recipe-library.js';

const root = process.cwd();

function readJson(relativePath) {
  return JSON.parse(readFileSync(join(root, relativePath), 'utf8'));
}

function loadWindowGlobal(relativePath, key) {
  const context = { window: {} };
  vm.createContext(context);
  vm.runInContext(readFileSync(join(root, relativePath), 'utf8'), context, {
    filename: relativePath
  });
  return context.window[key];
}

const STATIC_METHODS = loadWindowGlobal('data/recipe-methods.js', 'RECIPE_METHODS');
const CURATED = readJson('data/sichuan-recipes.curated.json');
const FULL = readJson('data/sichuan-recipes.json');

function assertPackIdentityAndMaps(before, after) {
  const beforeIds = new Set(before.recipes.map(recipe => recipe.id));
  const afterIds = new Set(after.recipes.map(recipe => recipe.id));
  const afterNames = after.recipes.map(recipe => recipe.name);

  for (const id of beforeIds) assert.ok(afterIds.has(id), `recipe id disappeared: ${id}`);
  assert.equal(afterIds.size, after.recipes.length, 'recipe ids must remain unique');
  assert.equal(new Set(afterNames).size, afterNames.length, 'recipe names must remain unique');

  for (const id of Object.keys(after.recipe_ingredients || {})) {
    assert.ok(afterIds.has(id), `ingredient map is orphaned: ${id}`);
  }
}

test('curated 审计列出的 13 道空做法菜获得静态做法', () => {
  const blankNames = CURATED.recipes
    .filter(recipe => !String(recipe.method || '').trim())
    .map(recipe => recipe.name);
  assert.equal(blankNames.length, 13);
  assert.ok(blankNames.every(name => STATIC_METHODS[name]), 'all 13 names must have a static method source');

  const merged = mergeRecipeMethods(CURATED, STATIC_METHODS);
  for (const name of blankNames) {
    const recipe = merged.recipes.find(item => item.name === name);
    assert.equal(recipe?.method, STATIC_METHODS[name], `${name} should receive its static method`);
  }
});

test('静态新增菜谱有 method，且不减少既有 ID、不产生重复或孤立映射', () => {
  for (const base of [CURATED, FULL]) {
    const merged = mergeRecipeMethods(base, STATIC_METHODS);
    const baseNames = new Set(base.recipes.map(recipe => recipe.name));
    const addedNames = Object.keys(STATIC_METHODS).filter(name => !baseNames.has(name));

    assert.ok(addedNames.length > 0);
    for (const name of addedNames) {
      const recipe = merged.recipes.find(item => item.name === name);
      assert.ok(recipe, `${name} should be present`);
      assert.equal(String(recipe.method || '').trim(), String(STATIC_METHODS[name]).trim());
    }
    assertPackIdentityAndMaps(base, merged);
  }
});

test('base/completion/user 做法优先级保持不变', () => {
  const completedPack = {
    recipes: [
      { id: 'base-method', name: '基础做法', method: 'base method' },
      { id: 'completed-method', name: '完成包做法', method: 'completion method' },
      { id: 'static-fallback', name: '静态兜底', method: '' }
    ],
    recipe_ingredients: {
      'base-method': [],
      'completed-method': [],
      'static-fallback': []
    }
  };
  const merged = mergeRecipeMethods(completedPack, {
    '基础做法': 'static replacement',
    '完成包做法': 'static replacement',
    '静态兜底': 'static method'
  });

  assert.equal(merged.recipes.find(recipe => recipe.id === 'base-method').method, 'base method');
  assert.equal(merged.recipes.find(recipe => recipe.id === 'completed-method').method, 'completion method');
  assert.equal(merged.recipes.find(recipe => recipe.id === 'static-fallback').method, 'static method');

  const withUserOverlay = applyOverlay(merged, {
    version: 1,
    recipes: { 'completed-method': { method: 'user method' } },
    recipe_ingredients: {},
    deletes: {}
  });
  assert.equal(
    withUserOverlay.recipes.find(recipe => recipe.id === 'completed-method').method,
    'user method'
  );
});

test('酿萝卜核心食材映射包含做法需要的猪肉馅且不批量引入数量单位', () => {
  const id = 'ex--514e3fd8';
  const ingredients = FULL.recipe_ingredients[id];
  assert.deepEqual(ingredients.map(item => item.item), ['白萝卜', '猪肉馅']);
  assert.ok(ingredients.every(item => !Object.hasOwn(item, 'qty') && !Object.hasOwn(item, 'unit')));
});
