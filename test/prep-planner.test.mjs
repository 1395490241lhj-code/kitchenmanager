// test/prep-planner.test.mjs
// 「明天备菜」任务生成回归。纯本地规则，零网络/零 localStorage 写入/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { getTomorrowPrepTasks, getPrepTasksForPlanItems, nextDateISO } from '../src/utils/prep-planner.js';

const TODAY = '2026-06-10';
const TOMORROW = '2026-06-11';

const PACK = {
  recipes: [
    { id: 'r-beef', name: '土豆烧牛肉', method: '1. 牛肉切块焯水。\n2. 加土豆炖煮。' },
    { id: 'r-muer', name: '木耳炒肉', method: '1. 木耳泡发。\n2. 下锅同炒。' },
    { id: 'r-wing', name: '可乐鸡翅', method: '1. 鸡翅用料酒腌制 20 分钟。\n2. 加可乐烧。' },
    { id: 'r-veg', name: '清炒生菜', method: '1. 生菜洗净。\n2. 大火快炒。' },
    { id: 'r-nomethod', name: '神秘鸡腿', method: '' }
  ],
  recipe_ingredients: {
    'r-beef': [{ item: '牛肉', qty: 1, unit: '斤' }, { item: '土豆', qty: 2, unit: '个' }, { item: '生抽', qty: 1, unit: '勺' }],
    'r-muer': [{ item: '木耳', qty: 1, unit: '把' }, { item: '猪肉', qty: 100, unit: 'g' }],
    'r-wing': [{ item: '鸡翅', qty: 8, unit: '个' }, { item: '可乐', qty: 1, unit: '瓶' }],
    'r-veg': [{ item: '生菜', qty: 1, unit: '颗' }],
    'r-nomethod': [{ item: '鸡腿', qty: 2, unit: '个' }]
  }
};

const planFor = (...ids) => ids.map(id => ({ id, date: TOMORROW }));

test('nextDateISO：今天 +1 天（含跨月）', () => {
  assert.equal(nextDateISO('2026-06-10'), '2026-06-11');
  assert.equal(nextDateISO('2026-06-30'), '2026-07-01');
});

test('明天没有计划 → planCount 0、无任务', () => {
  const out = getTomorrowPrepTasks({ pack: PACK, inv: [], plan: [], today: TODAY });
  assert.equal(out.targetDate, TOMORROW);
  assert.equal(out.planCount, 0);
  assert.deepEqual(out.tasks, []);
});

test('明天计划普通快手菜 → 有计划但无任务', () => {
  const out = getTomorrowPrepTasks({ pack: PACK, inv: [], plan: planFor('r-veg'), today: TODAY });
  assert.equal(out.planCount, 1);
  assert.deepEqual(out.tasks, []);
});

test('冷冻牛肉 → 解冻任务（id 稳定，含来源菜谱）', () => {
  const inv = [{ name: '牛肉', qty: 1, unit: '斤', stockStatus: 'ok', isFrozen: true }];
  const out = getTomorrowPrepTasks({ pack: PACK, inv, plan: planFor('r-beef'), today: TODAY });
  const thaw = out.tasks.filter(t => t.kind === 'thaw');
  assert.equal(thaw.length, 1);
  assert.equal(thaw[0].title, '牛肉');
  assert.equal(thaw[0].icon, '🧊');
  assert.equal(thaw[0].recipeName, '土豆烧牛肉');
  assert.equal(thaw[0].id, `${TOMORROW}:r-beef:thaw:牛肉`);
});

test('牛肉未冷冻 → 不提醒解冻；土豆/生抽不生成任何任务', () => {
  const inv = [{ name: '牛肉', qty: 1, unit: '斤', stockStatus: 'ok', isFrozen: false }];
  const out = getTomorrowPrepTasks({ pack: PACK, inv, plan: planFor('r-beef'), today: TODAY });
  assert.deepEqual(out.tasks, []);
});

test('木耳 → 泡发任务；同菜的猪肉无库存不提醒解冻', () => {
  const out = getTomorrowPrepTasks({ pack: PACK, inv: [], plan: planFor('r-muer'), today: TODAY });
  assert.equal(out.tasks.length, 1);
  assert.equal(out.tasks[0].kind, 'soak');
  assert.equal(out.tasks[0].title, '木耳');
  assert.equal(out.tasks[0].icon, '💧');
});

test('做法含「腌」的鸡翅 → 腌制任务；无 method 的鸡腿绝不猜腌制', () => {
  const out = getTomorrowPrepTasks({ pack: PACK, inv: [], plan: planFor('r-wing', 'r-nomethod'), today: TODAY });
  const marinate = out.tasks.filter(t => t.kind === 'marinate');
  assert.equal(marinate.length, 1);
  assert.equal(marinate[0].title, '鸡翅');
  assert.equal(marinate[0].icon, '🧂');
  assert.ok(!out.tasks.some(t => t.ingredientName === '鸡腿'));
});

test('解冻和腌制可同时命中同一食材；同 kind+食材全局不重复', () => {
  const inv = [{ name: '鸡翅', qty: 8, unit: '个', stockStatus: 'ok', isFrozen: true }];
  const plan = [...planFor('r-wing'), { id: 'r-wing', date: TOMORROW }]; // 重复计划项
  const out = getTomorrowPrepTasks({ pack: PACK, inv, plan, today: TODAY });
  const kinds = out.tasks.map(t => t.kind).sort();
  assert.deepEqual(kinds, ['marinate', 'thaw']);
});

test('getPrepTasksForPlanItems：通用入口直接吃已筛好的计划项', () => {
  const inv = [{ name: '牛肉', qty: 1, unit: '斤', stockStatus: 'ok', isFrozen: true }];
  const out = getPrepTasksForPlanItems({
    pack: PACK, inv,
    planItems: [{ id: 'r-beef', date: TOMORROW }],
    targetDate: TOMORROW
  });
  assert.equal(out.planCount, 1);
  assert.equal(out.tasks.length, 1);
  assert.equal(out.tasks[0].kind, 'thaw');
  assert.equal(out.tasks[0].targetDate, TOMORROW);
});

test('已做完 / 非明天 / 库中不存在的计划项一律忽略', () => {
  const plan = [
    { id: 'r-beef', date: TOMORROW, isCooked: true },
    { id: 'r-muer', date: TODAY },
    { id: 'r-ghost', date: TOMORROW }
  ];
  const out = getTomorrowPrepTasks({ pack: PACK, inv: [], plan, today: TODAY });
  assert.equal(out.planCount, 0);
  assert.deepEqual(out.tasks, []);
});
