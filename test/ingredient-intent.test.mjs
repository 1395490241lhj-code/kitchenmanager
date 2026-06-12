// test/ingredient-intent.test.mjs
// 「想用这些食材」输入解析回归：类别展开 / 库存辅助 / 调料过滤。纯函数，零存储/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseTargetIngredients } from '../src/utils/ingredient-intent.js';

const names = (out) => out.targets.map(t => t.canonical);

test('分隔符：空格 / 中英文逗号 / 顿号 / 斜杠都支持', () => {
  for (const q of ['牛肉 土豆', '牛肉，土豆', '牛肉、土豆', '牛肉/土豆', '牛肉,土豆']) {
    assert.deepEqual(names(parseTargetIngredients(q)), ['牛肉', '土豆'], q);
  }
});

test('canonical 归一：番茄 与 西红柿 同义', () => {
  const a = parseTargetIngredients('番茄 鸡蛋');
  const b = parseTargetIngredients('西红柿 鸡蛋');
  assert.deepEqual(names(a), names(b));
});

test('调料 / 非库存项被过滤：盐、高汤、水、适量、生抽不进目标', () => {
  const out = parseTargetIngredients('牛肉 土豆 盐 高汤 水 适量 生抽');
  assert.deepEqual(names(out), ['牛肉', '土豆']);
});

test('只有调料时目标为空（不启动指定推荐）', () => {
  assert.equal(parseTargetIngredients('盐 生抽 高汤').targets.length, 0);
  assert.equal(parseTargetIngredients('').targets.length, 0);
});

test('类别展开：菌菇 → 香菇/蘑菇/平菇等候选', () => {
  const t = parseTargetIngredients('菌菇 豆腐').targets[0];
  assert.equal(t.category, 'mushroom');
  for (const c of ['香菇', '蘑菇', '平菇', '金针菇']) assert.ok(t.candidates.includes(c), c);
});

test('类别展开：绿叶菜 / 辣椒 / 豆制品 / 海鲜 / 蛋', () => {
  const leafy = parseTargetIngredients('绿叶菜').targets[0];
  assert.ok(['青菜', '菠菜', '生菜'].every(c => leafy.candidates.includes(c)));
  const pepper = parseTargetIngredients('辣椒').targets[0];
  assert.ok(['青椒', '红椒'].every(c => pepper.candidates.includes(c)));
  const tofu = parseTargetIngredients('豆制品').targets[0];
  assert.ok(['豆腐', '腐竹'].every(c => tofu.candidates.includes(c)));
  const sea = parseTargetIngredients('海鲜').targets[0];
  assert.ok(['鱼', '虾'].every(c => sea.candidates.includes(c)));
  const egg = parseTargetIngredients('蛋').targets[0];
  assert.ok(egg.candidates.includes('鸡蛋'));
});

test('肉片 / 肉丝 → 猪肉类候选', () => {
  const t = parseTargetIngredients('肉片 青椒').targets[0];
  assert.equal(t.category, 'meat');
  assert.ok(t.candidates.includes('猪肉'));
});

test('库存辅助：输入「肉」，库存有牛肉 → 牛肉排到候选最前；都有则都保留', () => {
  const beefFirst = parseTargetIngredients('肉', { inventoryNames: ['牛肉'] }).targets[0];
  assert.equal(beefFirst.candidates[0], '牛肉');
  const both = parseTargetIngredients('肉', { inventoryNames: ['猪肉', '牛肉'] }).targets[0];
  assert.deepEqual(both.candidates.slice(0, 2).sort(), ['牛肉', '猪肉']);
  assert.ok(both.candidates.includes('鸡肉')); // 其余候选保留
});

test('去重 + limit 5', () => {
  const out = parseTargetIngredients('牛肉 牛肉 土豆 青椒 鸡蛋 豆腐 白菜 萝卜');
  assert.equal(out.targets.length, 5);
  assert.deepEqual(names(out).slice(0, 2), ['牛肉', '土豆']);
});
