import test from 'node:test';
import assert from 'node:assert/strict';

import {
  areCreativeRecipeNamesSimilar,
  filterAiDraftCoreIngredients,
  pickNextCreativeDishMode
} from '../src/ai.js';

test('AI 创意做法：鸡肉片/丁/丝这种刀工变化应判定为相似', () => {
  assert.equal(areCreativeRecipeNamesSimilar('芦笋蘑菇炒鸡肉片', '芦笋蘑菇炒鸡肉丁'), true);
});

test('AI 创意做法：炒菜和焖饭属于不同菜品形态', () => {
  assert.equal(areCreativeRecipeNamesSimilar('芦笋蘑菇炒鸡肉', '芦笋蘑菇鸡肉焖饭'), false);
});

test('AI 创意做法：连续换一种优先选择未用过的 dishMode', () => {
  const first = pickNextCreativeDishMode([]);
  const second = pickNextCreativeDishMode([first.key], first.key);
  assert.notEqual(second.key, first.key);
});

test('AI 创意做法：ingredients 只保留核心食材，过滤盐水高汤葱姜蒜', () => {
  const out = filterAiDraftCoreIngredients({
    name: '芦笋蘑菇鸡肉焖饭',
    method: '1. 焖熟。',
    ingredients: [
      { item: '鸡肉' },
      { item: '芦笋' },
      { item: '蘑菇' },
      { item: '盐' },
      { item: '水' },
      { item: '高汤' },
      { item: '葱' },
      { item: '姜' },
      { item: '蒜' }
    ]
  });
  assert.deepEqual(out.ingredients.map(item => item.item), ['鸡肉', '芦笋', '蘑菇']);
});
