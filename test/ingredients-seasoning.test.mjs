// test/ingredients-seasoning.test.mjs
// 统一调料判定回归：isSeasoning 现为单一宽口径（含高汤/清水/十三香/咖喱粉等），
// 同时不误伤真实核心食材。纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isSeasoning } from '../src/ingredients.js';
import { isSeasoningName } from '../src/utils/recipe-sanitizer.js';

// ── 应判定为调料 / 非追踪物资 ──
test('isSeasoning 覆盖高汤/清水/十三香/咖喱等（统一宽口径）', () => {
  for (const s of ['高汤', '清水', '开水', '十三香', '胡椒粉', '黑胡椒', '孜然粉', '咖喱', '咖喱粉', '生粉']) {
    assert.equal(isSeasoning(s), true, `${s} 应为调料`);
  }
  // 既有调料仍成立
  for (const s of ['盐', '生抽', '老抽', '料酒', '香油', '淀粉', '花椒', '五香粉']) {
    assert.equal(isSeasoning(s), true, `${s} 应为调料`);
  }
});

// ── 不应误伤真实核心食材 ──
test('isSeasoning 不误伤核心食材 / 含相同字的菜名', () => {
  for (const f of ['鸡肉', '豆腐', '土豆', '猪肉', '牛肉', '番茄']) {
    assert.equal(isSeasoning(f), false, `${f} 不应为调料`);
  }
  // 含「高」「咖喱」「水」等字的多字菜名不应被误判
  assert.equal(isSeasoning('高笋'), false);     // 莴笋/茭白类，非调料
  assert.equal(isSeasoning('咖喱鸡'), false);   // 菜名而非「咖喱」本身
  assert.equal(isSeasoning('咖喱牛肉'), false);
  assert.equal(isSeasoning('高汤鱼'), false);   // 菜名而非「高汤」本身
});

// ── recipe-sanitizer 的 isSeasoningName 现复用 isSeasoning，二者一致 ──
test('isSeasoningName 与 isSeasoning 口径一致', () => {
  for (const n of ['高汤', '清水', '十三香', '咖喱粉', '盐', '生抽', '淀粉']) {
    assert.equal(isSeasoningName(n), isSeasoning(n), `${n} 两口径应一致`);
    assert.equal(isSeasoningName(n), true);
  }
  for (const f of ['鸡肉', '豆腐', '土豆', '高笋']) {
    assert.equal(isSeasoningName(f), isSeasoning(f));
    assert.equal(isSeasoningName(f), false);
  }
  // 空名兜底：按调料处理
  assert.equal(isSeasoningName(''), true);
});
