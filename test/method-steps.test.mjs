// test/method-steps.test.mjs
// 做法分步解析回归。纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { splitMethodSteps } from '../src/utils/method-steps.js';

test('标准 1. / 2. 多步骤（剥编号，无双重编号）', () => {
  assert.deepEqual(
    splitMethodSteps('1. 切菜\n2. 下锅\n3. 调味'),
    ['切菜', '下锅', '调味']
  );
});

test('中文顿号编号 1、2、', () => {
  assert.deepEqual(splitMethodSteps('1、切菜\n2、下锅'), ['切菜', '下锅']);
});

test('中文/英文括号编号 1）/ 1) / （1）', () => {
  assert.deepEqual(splitMethodSteps('1）切菜\n2）下锅'), ['切菜', '下锅']);
  assert.deepEqual(splitMethodSteps('1) 切菜\n2) 下锅'), ['切菜', '下锅']);
  assert.deepEqual(splitMethodSteps('（1）切菜\n（2）下锅'), ['切菜', '下锅']);
});

test('第一步 / 第二步（含冒号）', () => {
  assert.deepEqual(splitMethodSteps('第一步 切菜\n第二步 下锅'), ['切菜', '下锅']);
  assert.deepEqual(splitMethodSteps('第一步：切菜\n第二步：下锅'), ['切菜', '下锅']);
});

test('一、二、中文数字编号', () => {
  assert.deepEqual(splitMethodSteps('一、切菜\n二、下锅\n三、装盘'), ['切菜', '下锅', '装盘']);
});

test('多余空行被忽略', () => {
  assert.deepEqual(splitMethodSteps('1. 切菜\n\n\n2. 下锅\n   \n'), ['切菜', '下锅']);
});

test('无编号多行：每行一步', () => {
  assert.deepEqual(splitMethodSteps('切菜\n下锅\n调味'), ['切菜', '下锅', '调味']);
});

test('无编号单段：兜底成 1 步', () => {
  assert.deepEqual(splitMethodSteps('蒸柜上汽后蒸10-15分钟。'), ['蒸柜上汽后蒸10-15分钟。']);
});

test('空字符串 / null / undefined → []', () => {
  assert.deepEqual(splitMethodSteps(''), []);
  assert.deepEqual(splitMethodSteps('   '), []);
  assert.deepEqual(splitMethodSteps(null), []);
  assert.deepEqual(splitMethodSteps(undefined), []);
});

test('步骤内容里的数字不被误切', () => {
  // 「焖 3 分钟」「煮2分钟」「18分钟」中的数字不应被当编号切开
  assert.deepEqual(
    splitMethodSteps('1. 下锅焖 3 分钟\n2. 大火煮2分钟收汁'),
    ['下锅焖 3 分钟', '大火煮2分钟收汁']
  );
  // 单段含内部数字 → 仍 1 步
  assert.deepEqual(splitMethodSteps('加水没过食材，烧开转小火炖40分钟。'), ['加水没过食材，烧开转小火炖40分钟。']);
});

test('真实 overlay 多步骤样例', () => {
  const m = '1. 鲫鱼治净，两面打浅花刀，用盐、料酒抹匀，下油煎至两面金黄定型。\n2. 锅留底油，下郫县豆瓣、姜蒜末炒出红油。\n3. 加料酒、酱油、少许糖和半碗汤，下鱼小火干烧入味。\n4. 中途翻面，烧至汤汁将干、亮油，撒葱花起锅。';
  const steps = splitMethodSteps(m);
  assert.equal(steps.length, 4);
  assert.ok(steps[0].startsWith('鲫鱼治净'));
  assert.ok(!steps[0].startsWith('1'));
});

test('输出为纯文本数组，不包含 HTML / 不改原串', () => {
  const src = '1. 切菜\n2. <b>下锅</b>';
  const steps = splitMethodSteps(src);
  // 原样保留文本（含尖括号），不转义、不注入 HTML 标签结构
  assert.deepEqual(steps, ['切菜', '<b>下锅</b>']);
  assert.equal(src, '1. 切菜\n2. <b>下锅</b>'); // 原串未被修改
  steps.forEach(s => assert.equal(typeof s, 'string'));
});
