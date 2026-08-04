import test from 'node:test';
import assert from 'node:assert/strict';

import {
  RECIPE_UNIT_WHITELIST,
  normalizeIngredientAmount
} from '../src/ingredients.js';

test('Curated quantity units use the minimal canonical whitelist', () => {
  assert.deepEqual(normalizeIngredientAmount(1, 'KG'), { qty: 1000, unit: 'g' });
  assert.deepEqual(normalizeIngredientAmount(2, '两'), { qty: 100, unit: 'g' });
  assert.deepEqual(normalizeIngredientAmount(0.5, 'L'), { qty: 500, unit: 'ml' });
  assert.deepEqual(normalizeIngredientAmount(2, 'pieces'), { qty: 2, unit: '个' });
  assert.deepEqual(normalizeIngredientAmount(1, 'boxes'), { qty: 1, unit: '盒' });
  assert.deepEqual(normalizeIngredientAmount(1, 'BUNCH'), { qty: 1, unit: '把' });

  for (const unit of ['g', 'ml', '个', '盒', '把']) {
    assert.equal(RECIPE_UNIT_WHITELIST.includes(unit), true);
  }
});

test('missing values stay empty and unsupported measures remain safely incompatible', () => {
  assert.deepEqual(normalizeIngredientAmount(null, null), { qty: '', unit: '' });
  assert.deepEqual(normalizeIngredientAmount(undefined, '克'), { qty: '', unit: 'g' });
  assert.deepEqual(normalizeIngredientAmount('', ''), { qty: '', unit: '' });
  assert.deepEqual(normalizeIngredientAmount(1, '勺'), { qty: 1, unit: '勺' });

  for (const unsafe of ['适量', '少许', '碗', '勺', '撮', '杯', '茶匙', '汤匙']) {
    assert.equal(RECIPE_UNIT_WHITELIST.includes(unsafe), false);
  }
});
