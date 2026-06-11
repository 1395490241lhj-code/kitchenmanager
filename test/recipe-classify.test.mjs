// test/recipe-classify.test.mjs
// 菜谱用料三分类口径回归（core / seasoning / non-stock）。纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { classifyRecipeIngredient, splitRecipeIngredients, splitIngredients, isSeasoningName } from '../src/utils/recipe-sanitizer.js';

const roleOf = (n) => classifyRecipeIngredient(n).role;

test('core：真实核心食材', () => {
  for (const n of ['牛肉', '豆腐', '土豆', '木耳', '香菇', '酸菜', '鸡蛋', '面条', '腐竹', '海带', '泡菜', '榨菜', '白菜', '虾']) {
    assert.equal(roleOf(n), 'core', `${n} 应为 core`);
  }
});

test('core：水发X 归一后仍是核心食材；带汤字的真实食物不误杀', () => {
  for (const n of ['水发木耳', '水发香菇', '水发海带', '汤圆', '汤面', '汤粉', '粉丝']) {
    assert.equal(roleOf(n), 'core', `${n} 应为 core`);
  }
});

test('seasoning：调料与淀粉勾芡类', () => {
  for (const n of ['盐', '生抽', '老抽', '豆瓣酱', '淀粉', '水淀粉', '湿淀粉', '姜', '蒜', '食用油', '郫县豆瓣', '芡汁'.replace('芡汁', '生粉')]) {
    assert.equal(roleOf(n), 'seasoning', `${n} 应为 seasoning`);
  }
});

test('non-stock：水 / 汤 / 汁与量词', () => {
  for (const n of ['水', '清水', '开水', '沸水', '温水', '高汤', '清汤', '鲜汤', '肉汤', '鸡汤', '骨汤', '汤', '汤汁', '适量', '少许', '老母鸡汤', '猪骨高汤']) {
    assert.equal(roleOf(n), 'non-stock', `${n} 应为 non-stock`);
  }
});

test('splitRecipeIngredients：三分流', () => {
  const out = splitRecipeIngredients([
    { item: '牛肉' }, { item: '盐' }, { item: '高汤' }, { item: '木耳' }, { item: '水淀粉' }
  ]);
  assert.deepEqual(out.foods.map(x => x.item), ['牛肉', '木耳']);
  assert.deepEqual(out.seasonings.map(x => x.item), ['盐', '水淀粉']);
  assert.deepEqual(out.nonStock.map(x => x.item), ['高汤']);
  assert.ok(out.foods.every(x => x.role === 'core' && x.isSeasoning === false));
});

test('splitIngredients 兼容：foods=core，seasonings 合并 seasoning+nonStock', () => {
  const out = splitIngredients([{ item: '牛肉' }, { item: '盐' }, { item: '高汤' }]);
  assert.deepEqual(out.foods.map(x => x.item), ['牛肉']);
  assert.deepEqual(out.seasonings.map(x => x.item), ['盐', '高汤']);
});

test('seasoning：扩展写法（姜片/蒜末/郫县豆瓣/油类/腐乳/淀粉勾芡）', () => {
  for (const n of ['姜片', '姜丝', '姜末', '蒜片', '蒜末', '葱段', '郫县豆瓣', '郫县豆瓣酱', '食用油', '红油', '花椒油', '醪糟汁', '腐乳', '豆腐乳', '化猪油', '芡汁', '勾芡汁', '水淀粉', '湿淀粉', '绍酒', '绍兴酒']) {
    assert.equal(roleOf(n), 'seasoning', `${n} 应为 seasoning`);
  }
});

test('non-stock：汤底/锅底/冰水与汤类变体', () => {
  for (const n of ['汤料', '汤底', '锅底', '冰水', '热水', '凉水', '原汤', '牛骨汤', '猪骨高汤']) {
    assert.equal(roleOf(n), 'non-stock', `${n} 应为 non-stock`);
  }
});

test('core：带汤/粉字的真实食物与腌渍核心菜不误杀', () => {
  for (const n of ['汤圆', '汤面', '汤粉', '米粉', '河粉', '凉粉', '粉丝', '酸菜', '酸豆角', '泡菜', '榨菜', '盐菜']) {
    assert.equal(roleOf(n), 'core', `${n} 应为 core`);
  }
});

test('isSeasoningName：非 core 一律 true（扣减/备菜的排除过滤口径）', () => {
  assert.equal(isSeasoningName('盐'), true);
  assert.equal(isSeasoningName('高汤'), true);
  assert.equal(isSeasoningName('适量'), true);
  assert.equal(isSeasoningName(''), true);
  assert.equal(isSeasoningName('牛肉'), false);
  assert.equal(isSeasoningName('酸菜'), false);
});
