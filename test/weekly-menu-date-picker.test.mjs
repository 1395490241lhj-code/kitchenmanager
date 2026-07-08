import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { getWeeklyPlannedDate } from '../src/views/home/weekly-menu.js';

const root = process.cwd();
const read = rel => readFileSync(join(root, rel), 'utf8');
const weekly = read('src/views/home/weekly-menu.js');

function addDays(iso, n) {
  const [y, m, d] = iso.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}

const TODAY = '2026-07-07'; // 周二

test('每张卡片渲染「计划到」select，选项为未来 7 天，默认选中 plannedDate', () => {
  const renderFn = weekly.slice(
    weekly.indexOf('function renderWeeklyMenuSuggestions'),
    weekly.indexOf('function openWeeklyMenuModal')
  );
  // 卡片里有 select，默认值来自 plannedDate。
  assert.match(renderFn, /class="weekly-menu-date" aria-label="计划日期">\$\{buildWeeklyDateOptions\(plannedDate, today\)\}/);
  assert.match(renderFn, /计划到/);
  // plannedDate 优先取用户已选的 entry.plannedDate，否则回落默认排期。
  assert.match(renderFn, /entry\.plannedDate \|\| getWeeklyPlannedDate\(meal, index, today\)/);

  // buildWeeklyDateOptions 覆盖 0..WEEKLY_PLAN_MAX_OFFSET 天，并标记 selected。
  const builder = weekly.slice(weekly.indexOf('function buildWeeklyDateOptions'), weekly.indexOf('function weeklyAddedKey'));
  assert.match(builder, /offset <= WEEKLY_PLAN_MAX_OFFSET/);
  assert.match(builder, /iso === selectedDate \? ' selected' : ''/);
});

test('结果卡片：菜名+meta 层级，去掉重复日期徽标，计划到 select 移入操作区', () => {
  const renderFn = weekly.slice(
    weekly.indexOf('function renderWeeklyMenuSuggestions'),
    weekly.indexOf('function openWeeklyMenuModal')
  );
  const styles = read('styles.css');
  // 菜名主标题 + 单行 meta（人份/难度/标签），reason 单独一句。
  assert.match(renderFn, /class="weekly-menu-name">/);
  assert.match(renderFn, /class="weekly-menu-meta">/);
  assert.match(renderFn, /`\$\{servings\} 人份`/);
  assert.match(renderFn, /class="weekly-menu-reason">/);
  // 去掉顶部重复日期徽标。
  assert.doesNotMatch(renderFn, /class="weekly-menu-day"/);
  // 计划到 select 与操作按钮同在 suggestion-actions 内。
  const actions = renderFn.slice(renderFn.indexOf('weekly-menu-suggestion-actions'));
  assert.match(actions, /class="weekly-menu-date"/);
  assert.match(actions, /class="weekly-menu-action-buttons"/);
  // AI 新建议：小标签 + 仅保存为菜谱。
  assert.match(renderFn, /class="weekly-menu-ai-note">AI 新建议/);
  assert.match(renderFn, /data-action="save">保存为菜谱/);
  // 样式：卡片紧凑、操作区两端对齐。
  assert.match(styles, /\.weekly-menu-suggestion \{[\s\S]*?padding: 12px/);
  assert.match(styles, /\.weekly-menu-suggestion-actions \{[\s\S]*?justify-content: space-between/);
});

test('改日期只更新 entry.plannedDate 与 DOM，不写 plan；按 recipeId|date 刷新按钮', () => {
  const handler = weekly.slice(
    weekly.indexOf(".weekly-menu-date').forEach"),
    weekly.indexOf(".weekly-menu-suggestion [data-action]').forEach")
  );
  assert.match(handler, /entry\.plannedDate = nextDate/);
  assert.match(handler, /article\.dataset\.plannedDate = nextDate/);
  assert.match(handler, /addedIds\.has\(weeklyAddedKey\(recipeId, nextDate\)\)/);
  assert.doesNotMatch(handler, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(handler, /S\.save\(S\.keys\.plan/);
});

test('改日期后单个与批量加入都用 entry.plannedDate', () => {
  const modal = weekly.slice(weekly.indexOf('function openWeeklyMenuModal'));
  // 批量
  assert.match(modal, /const plannedDate = entry\.plannedDate \|\| getWeeklyPlannedDate\(entry\.meal, index, today\)/);
  // 单个
  assert.match(modal, /const plannedDate = item\.plannedDate \|\| row\?\.dataset\.plannedDate \|\| getWeeklyPlannedDate\(item\.meal, safeIndex, todayISO\(\)\)/);
});

test('保存 AI 新建议为菜谱不改 plannedDate（只绑 recipeId/recipe/row）', () => {
  const attach = weekly.slice(
    weekly.indexOf('function attachSavedWeeklyAiSuggestion'),
    weekly.indexOf('function ', weekly.indexOf('function attachSavedWeeklyAiSuggestion') + 1)
  );
  assert.doesNotMatch(attach, /plannedDate/);
});

test('默认日期仍来自 getWeeklyPlannedDate（回归护栏）', () => {
  assert.equal(getWeeklyPlannedDate({ daySuggestion: '明天' }, 0, TODAY), addDays(TODAY, 1));
  assert.equal(getWeeklyPlannedDate({}, 2, TODAY), addDays(TODAY, 4));
});
