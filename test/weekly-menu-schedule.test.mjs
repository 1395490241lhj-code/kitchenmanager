import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import { getWeeklyPlannedDate, updateWeeklyPlanServings } from '../src/views/home/weekly-menu.js';

const root = process.cwd();
const read = rel => readFileSync(join(root, rel), 'utf8');

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// UTC-safe：与实现里的 addDaysISO/isoDayOfWeek 口径一致，避免测试受本机时区影响。
function addDays(iso, n) {
  const [y, m, d] = iso.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}
function dow(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

const TODAY = '2026-07-08'; // 周三

test('daySuggestion=周一 解析到未来 7 天内的周一', () => {
  const date = getWeeklyPlannedDate({ daySuggestion: '周一晚餐' }, 0, TODAY);
  assert.equal(dow(date), 1);
  assert.ok(date >= TODAY && date <= addDays(TODAY, 6), '必须落在未来 7 天窗口');
});

test('daySuggestion=明天 解析到 today+1；今天/后天同理', () => {
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '明天' }, 0, TODAY), addDays(TODAY, 1));
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '今天做' }, 3, TODAY), TODAY);
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '后天' }, 0, TODAY), addDays(TODAY, 2));
});

test('今天已是周三时，daySuggestion=周三 视为今天（offset 0）', () => {
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '周三' }, 0, TODAY), TODAY);
});

test('daySuggestion=周二（今天周三，已过）取下一周同一天，仍在 7 天内', () => {
  const date = getWeeklyPlannedDate({ daySuggestion: '星期二' }, 0, TODAY);
  assert.equal(dow(date), 2);
  assert.equal(date, addDays(TODAY, 6)); // 周三→下个周二 = +6
  assert.ok(date <= addDays(TODAY, 6));
});

test('无法识别的 daySuggestion 按 index 均匀铺开（index*2，封顶第 6 天）', () => {
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '随便' }, 0, TODAY), TODAY);
  assert.equal(getWeeklyPlannedDate({}, 1, TODAY), addDays(TODAY, 2));
  assert.equal(getWeeklyPlannedDate({}, 2, TODAY), addDays(TODAY, 4));
  assert.equal(getWeeklyPlannedDate({}, 3, TODAY), addDays(TODAY, 6));
  assert.equal(getWeeklyPlannedDate({}, 9, TODAY), addDays(TODAY, 6)); // 封顶
});

test('updateWeeklyPlanServings 只改目标 date 的 row，不误改今天/别的日期', () => {
  const d2 = addDays(new Date().toISOString().slice(0, 10), 2);
  const today = new Date().toISOString().slice(0, 10);
  S.save(S.keys.plan, [
    { id: 'x', servings: 1, date: today },
    { id: 'x', servings: 1, date: d2 }
  ]);
  const changed = updateWeeklyPlanServings('x', 4, d2);
  assert.equal(changed, true);
  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.find(r => r.date === d2).servings, 4, '目标日期已更新');
  assert.equal(plan.find(r => r.date === today).servings, 1, '今天那条未被误改');
});

test('源码接线：单个与批量加入都传 plannedDate，且不按 daySuggestion 直接写 date', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  const modal = weekly.slice(weekly.indexOf('function openWeeklyMenuModal'));
  // 两处 addRecipeToPlanWithMissingCheck 调用都带 date: plannedDate。
  const calls = [...modal.matchAll(/addRecipeToPlanWithMissingCheck\(recipeId, pack, inv, \{\s*\n\s*date: plannedDate,/g)];
  assert.equal(calls.length, 2, '单个 + 批量各一处');
  // plannedDate 来自 getWeeklyPlannedDate（helper 内部才做 daySuggestion→date），不在调用处直接换算。
  assert.match(modal, /getWeeklyPlannedDate\(entry\.meal, index, today\)/);
  assert.match(modal, /getWeeklyPlannedDate\(item\.meal, safeIndex, todayISO\(\)\)/);
  assert.doesNotMatch(modal, /date:\s*[^,\n]*daySuggestion/);
});

test('保存 AI 新建议为菜谱不写 plan，只在保存分支创建菜谱', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  const saveBlock = weekly.slice(
    weekly.indexOf("if (btn.dataset.action === 'save')"),
    weekly.indexOf("recipeId = recipeId || getWeeklyEntryRecipeId(item)")
  );
  assert.match(saveBlock, /createUserRecipe\(pack, recipeDraft\)/);
  assert.doesNotMatch(saveBlock, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(saveBlock, /S\.save\(S\.keys\.plan/);
});

test('§8 清理：home-view 不再残留 weekly 专属 import', () => {
  const home = read('src/views/home-view.js');
  assert.doesNotMatch(home, /callAiWeeklyMenuPlan/);
  assert.doesNotMatch(home, /getPendingPlanRowsInRange/);
  assert.doesNotMatch(home, /\bgetPlanMissingItems\b/);
  assert.doesNotMatch(home, /\bisPendingPlanRow\b/);
});
