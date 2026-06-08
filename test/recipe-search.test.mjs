// test/recipe-search.test.mjs
// 纯函数回归：菜谱本地搜索 / canonical 同义 / 分类。零网络、零 localStorage、零 DOM。
// 用 node:test + node:assert；运行：npm test（node --test）。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeIngredientName,
  areIngredientsRelated,
  searchRecipes,
  matchesCategory,
  expandQuery
} from '../src/recipe-search.js';

// ── 内存 mock pack（不读真实 data JSON）──
const recipes = [
  { id: 'r1', name: '宫保鸡丁', tags: ['川菜', '鸡肉'] },
  { id: 'r2', name: '红烧鸡翅', tags: ['家常菜'] },
  { id: 'r3', name: '白菜豆腐汤', tags: ['汤'] },     // 含「鸡精」调料：不应被搜「鸡」污染
  { id: 'r4', name: '鱼香肉丝', tags: ['川菜'] },     // 「鱼香」味型但无鱼：不应被搜「鱼」误判
  { id: 'r5', name: '红烧鲫鱼', tags: ['鱼虾类'] },
  { id: 'r6', name: '麻婆豆腐', tags: ['川菜'] }
];
const recipe_ingredients = {
  r1: [{ item: '鸡肉' }, { item: '花生米' }, { item: '干辣椒' }],
  r2: [{ item: '鸡翅' }, { item: '姜' }],
  r3: [{ item: '白菜' }, { item: '豆腐' }, { item: '鸡精' }],
  r4: [{ item: '猪肉' }, { item: '木耳' }, { item: '泡椒' }],
  r5: [{ item: '鲫鱼' }, { item: '豆瓣' }],
  r6: [{ item: '豆腐' }, { item: '郫县豆瓣酱' }, { item: '肉末' }]
};
const pack = { recipes, recipe_ingredients };
const resultNames = (q) => searchRecipes(recipes, q, pack).map(x => x.recipe.name);

// ── 1) normalizeIngredientName ──
test('normalizeIngredientName 归一化同义食材/调料', () => {
  assert.equal(normalizeIngredientName('郫县豆瓣酱'), '豆瓣酱');
  assert.equal(normalizeIngredientName('西红柿'), '番茄');
  assert.equal(normalizeIngredientName('马铃薯'), '土豆');
  assert.equal(normalizeIngredientName('洋芋'), '土豆');
  assert.equal(normalizeIngredientName('香干'), '豆干');
  assert.equal(normalizeIngredientName('干香菇'), '香菇');
});

// ── 2) areIngredientsRelated ──
test('areIngredientsRelated 相关性判定', () => {
  assert.equal(areIngredientsRelated('豆腐', '豆干'), true);   // 同豆制品大类 → 相关
  assert.equal(areIngredientsRelated('黄豆酱', '豆瓣酱'), false); // 不同 canonical、不同大类 → 不等价
});

// ── 3) searchRecipes（内存 pack，断言用包含关系，不锁分数）──
test('搜「鸡」命中鸡肉菜，且不被「鸡精」污染', () => {
  const names = resultNames('鸡');
  assert.ok(names.includes('宫保鸡丁'), '应命中 宫保鸡丁');
  assert.ok(names.includes('红烧鸡翅'), '应命中 红烧鸡翅');
  assert.ok(!names.includes('白菜豆腐汤'), '含「鸡精」的菜不应被搜「鸡」命中');
});

test('搜「鱼」不把「鱼香」当鱼类误判', () => {
  const names = resultNames('鱼');
  assert.ok(names.includes('红烧鲫鱼'), '应命中 红烧鲫鱼');
  assert.ok(!names.includes('鱼香肉丝'), '「鱼香」味型且无鱼不应被搜「鱼」命中');
});

test('搜「豆腐」命中豆腐类', () => {
  const names = resultNames('豆腐');
  assert.ok(names.includes('麻婆豆腐'), '应命中 麻婆豆腐');
  assert.ok(names.includes('白菜豆腐汤'), '应命中 白菜豆腐汤');
});

// ── 4) matchesCategory / expandQuery（基础断言，不深挖权重）──
test('matchesCategory 基础命中', () => {
  assert.equal(matchesCategory(recipes[0], '全部', pack), true);   // 全部恒真
  assert.equal(matchesCategory(recipes[0], '鸡肉', pack), true);   // 宫保鸡丁(tag/食材) ∈ 鸡肉
  assert.equal(matchesCategory(recipes[3], '鸡肉', pack), false);  // 鱼香肉丝 ∉ 鸡肉
});

test('expandQuery 基础扩展', () => {
  const e = expandQuery('豆瓣酱');
  assert.equal(e.canonical, '豆瓣酱');
  assert.ok(e.terms.includes('郫县豆瓣酱'), 'terms 应含别名 郫县豆瓣酱');
  assert.equal(expandQuery('鸡').proteinGroup, '鸡肉');
});
