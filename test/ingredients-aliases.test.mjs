// test/ingredients-aliases.test.mjs
// 食材级同义并入 INGREDIENT_ALIASES 后，库存 canonical 与搜索口径一致（豆制品三组安全映射）。
// 纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { getCanonicalName } from '../src/ingredients.js';

test('getCanonicalName 豆制品同义归一一致', () => {
  // 豆干组
  assert.equal(getCanonicalName('香干'), getCanonicalName('豆干'));
  assert.equal(getCanonicalName('豆腐干'), getCanonicalName('豆干'));
  assert.equal(getCanonicalName('白干'), getCanonicalName('豆干'));
  // 豆皮组
  assert.equal(getCanonicalName('豆皮'), getCanonicalName('千张'));
  assert.equal(getCanonicalName('百叶'), getCanonicalName('千张'));
  // 腐竹组
  assert.equal(getCanonicalName('腐竹'), getCanonicalName('支竹'));
});

test('getCanonicalName 不误伤其它食材语义', () => {
  // 豆腐仍是豆腐，未被新增的「豆皮」键经后缀剥离误改
  assert.equal(getCanonicalName('豆腐'), '豆腐');
  assert.notEqual(getCanonicalName('豆腐'), getCanonicalName('豆皮'));
  // 腐乳不等于腐竹
  assert.notEqual(getCanonicalName('腐乳'), getCanonicalName('腐竹'));
  // 豆瓣酱不等于豆干
  assert.notEqual(getCanonicalName('豆瓣酱'), getCanonicalName('豆干'));
});
