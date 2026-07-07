import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S, todayISO } from '../src/storage.js';
import {
  getPendingPlanRowsInRange,
  getTodayPendingPlanCount,
  getTodayPendingPlanRows,
  getTodayPlanRows,
  isPendingPlanRow,
  isPlanRowOnDate
} from '../src/plan-selectors.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

function seedPlan(today) {
  S.save(S.keys.plan, [
    { id: 'a', servings: 1, date: today },                  // 今日待做
    { id: 'b', servings: 1, date: today, isCooked: true },  // 今日已做完
    { id: 'c', servings: 1 },                               // 旧数据无 date → 按今天算
    { id: 'd', servings: 1, date: '2020-01-01' },           // 过去
    { id: 'e', servings: 1, date: '2099-01-02' }            // 远期
  ]);
}

test('isPlanRowOnDate：无 date 旧数据按今天归属，其余按 date 精确匹配', () => {
  const today = todayISO();
  assert.equal(isPlanRowOnDate({ id: 'x', date: today }, today, today), true);
  assert.equal(isPlanRowOnDate({ id: 'x' }, today, today), true);
  assert.equal(isPlanRowOnDate({ id: 'x' }, '2099-01-02', today), false);
  assert.equal(isPlanRowOnDate(null, today, today), false);
});

test('isPendingPlanRow：归属当日且未记录消耗才算待做', () => {
  const today = todayISO();
  assert.equal(isPendingPlanRow({ id: 'x', date: today }, today, today), true);
  assert.equal(isPendingPlanRow({ id: 'x', date: today, isCooked: true }, today, today), false);
});

test('今日选择器：待做/全部/计数口径一致', () => {
  const today = todayISO();
  seedPlan(today);
  assert.deepEqual(getTodayPendingPlanRows().map(r => r.id), ['a', 'c']);
  assert.deepEqual(getTodayPlanRows().map(r => r.id), ['a', 'b', 'c']);
  assert.equal(getTodayPendingPlanCount(), 2);
});

test('日期区间选择器：含端点、排除已做完、旧数据按今天参与', () => {
  const today = todayISO();
  seedPlan(today);
  const rows = getPendingPlanRowsInRange(today, '2099-12-31');
  assert.deepEqual(rows.map(r => r.id), ['a', 'c', 'e']);
  assert.deepEqual(getPendingPlanRowsInRange('2020-01-01', '2020-01-01').map(r => r.id), ['d']);
});
