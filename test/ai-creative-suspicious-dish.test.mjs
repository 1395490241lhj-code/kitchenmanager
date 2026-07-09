import test from 'node:test';
import assert from 'node:assert/strict';

import { isSuspiciousAiCreativeDish, validateRecommendationResult } from '../src/ai.js';

function ing(...names) {
  return names.map(item => ({ item, qty: '', unit: '' }));
}

test('黑暗料理：菜名把 4 种食材硬拼在一起会被判定为可疑', () => {
  const suspicious = isSuspiciousAiCreativeDish({
    name: '茭笋青椒瘦肉炒蛋',
    ingredients: ing('茭笋', '青椒', '瘦肉', '鸡蛋')
  });
  assert.equal(suspicious, true);
});

test('黑暗料理：核心食材 ≥4 个（即使菜名正常）也会被判定为可疑', () => {
  const suspicious = isSuspiciousAiCreativeDish({
    name: '本周菜谱',
    ingredients: ing('茭笋', '青椒', '瘦肉', '鸡蛋')
  });
  assert.equal(suspicious, true);
});

test('正常家常菜：青椒肉丝 不会被过滤', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '青椒肉丝', ingredients: ing('青椒', '肉丝') }), false);
});

test('正常家常菜：茭笋炒肉 不会被过滤', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '茭笋炒肉', ingredients: ing('茭笋', '肉') }), false);
});

test('正常家常菜：茭笋炒蛋 不会被过滤', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '茭笋炒蛋', ingredients: ing('茭笋', '鸡蛋') }), false);
});

test('经典家常菜：番茄炒蛋 不会被过滤', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '番茄炒蛋', ingredients: ing('番茄', '鸡蛋') }), false);
});

test('经典家常菜：虾仁炒蛋 不会被过滤（不是"不寻常肉蛋组合"）', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '虾仁炒蛋', ingredients: ing('虾仁', '鸡蛋') }), false);
});

test('经典家常菜：滑蛋牛肉 不会被过滤', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '滑蛋牛肉', ingredients: ing('牛肉', '鸡蛋') }), false);
});

test('经典家常菜：木须肉/蛋炒饭 即使核心食材较多也直接放行（白名单）', () => {
  assert.equal(isSuspiciousAiCreativeDish({
    name: '木须肉',
    ingredients: ing('猪肉丝', '鸡蛋', '木耳', '黄瓜')
  }), false);
  assert.equal(isSuspiciousAiCreativeDish({ name: '蛋炒饭', ingredients: ing('米饭', '鸡蛋') }), false);
});

test('不寻常肉蛋组合：牛肉/排骨/鸡腿 + 炒蛋 会被判定为可疑', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '牛肉炒蛋', ingredients: ing('牛肉', '鸡蛋') }), true);
  assert.equal(isSuspiciousAiCreativeDish({ name: '排骨炒蛋', ingredients: ing('排骨', '鸡蛋') }), true);
});

test('mid-1 rules 组合：肉/鱼虾 + 蛋 + 2 种及以上蔬菜 会被判定为可疑', () => {
  const suspicious = isSuspiciousAiCreativeDish({
    name: '家常炒菜',
    ingredients: ing('青椒', '西兰花', '鸡腿', '鸡蛋')
  });
  assert.equal(suspicious, true);
});

test('无核心食材/空菜名：不判定为可疑（交给上层校验兜底）', () => {
  assert.equal(isSuspiciousAiCreativeDish({ name: '', ingredients: [] }), false);
  assert.equal(isSuspiciousAiCreativeDish({ name: '普通菜', ingredients: [] }), false);
});

test('validateRecommendationResult：creative 可疑时被丢弃为 null，local 推荐保留', () => {
  const result = validateRecommendationResult(JSON.stringify({
    local: [{ name: '番茄炒蛋', reason: '库存齐全' }],
    creative: {
      name: '茭笋青椒瘦肉炒蛋',
      reason: '用掉库存',
      ingredients: [
        { item: '茭笋', qty: '', unit: '' },
        { item: '青椒', qty: '', unit: '' },
        { item: '瘦肉', qty: '', unit: '' },
        { item: '鸡蛋', qty: '', unit: '' }
      ]
    }
  }));
  assert.equal(result.creative, null);
  assert.deepEqual(result.local, [{ name: '番茄炒蛋', reason: '库存齐全' }]);
});

test('validateRecommendationResult：creative 正常时保留；creative 缺省时为 null 且不报错', () => {
  const withCreative = validateRecommendationResult(JSON.stringify({
    local: [],
    creative: { name: '青椒肉丝', reason: '快手', ingredients: [{ item: '青椒' }, { item: '肉丝' }] }
  }));
  assert.equal(withCreative.creative.name, '青椒肉丝');

  const localOnly = validateRecommendationResult(JSON.stringify({
    local: [{ name: '麻婆豆腐', reason: '常备' }],
    creative: null
  }));
  assert.equal(localOnly.creative, null);
  assert.equal(localOnly.local.length, 1);
});

test('validateRecommendationResult：creative 被过滤且 local 也为空时报错（由调用方回落到本地推荐，不展示黑暗料理）', () => {
  assert.throws(() => validateRecommendationResult(JSON.stringify({
    local: [],
    creative: {
      name: '茭笋青椒瘦肉炒蛋',
      reason: '用掉库存',
      ingredients: [
        { item: '茭笋' }, { item: '青椒' }, { item: '瘦肉' }, { item: '鸡蛋' }
      ]
    }
  })), /推荐结果里没有可用菜谱/);
});
