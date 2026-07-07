import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

// 本周菜单逻辑已拆到 src/views/home/weekly-menu.js（模块拆分，行为不变）；
// 源码断言从 home-view.js 改指向该模块，home-view 只保留 import + 计划 Tab 调用。

test('本周菜单已模块化：home-view 导入 weekly-menu，模块导出 renderWeeklyMenuCard', () => {
  const home = read('src/views/home-view.js');
  const weekly = read('src/views/home/weekly-menu.js');
  assert.match(home, /import \{ renderWeeklyMenuCard \} from '\.\/home\/weekly-menu\.js\?v=234'/);
  assert.match(home, /renderWeeklyMenuCard\(pack, inv, \{ onRoute \}\)/);
  assert.match(weekly, /export function renderWeeklyMenuCard\(pack, inv, \{ onRoute/);
  // 核心函数确实迁入了 weekly 模块。
  for (const fn of ['openWeeklyMenuModal', 'renderWeeklyMenuSuggestions', 'buildWeeklyMenuSuggestions', 'normalizeAiWeeklyMenuEntries', 'createLocalWeeklyMenuEntries']) {
    assert.match(weekly, new RegExp(`function ${fn}\\b`), `${fn} 应在 weekly-menu.js`);
  }
  // home-view 不再自持这些定义。
  assert.doesNotMatch(home, /function renderWeeklyMenuCard\b/);
  assert.doesNotMatch(home, /function openWeeklyMenuModal\b/);
});

test('本周菜单结果：底部按钮叫“加入计划”，不再叫“加入本周计划”', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  assert.match(weekly, /weekly-menu-add-all">加入计划</);
  assert.doesNotMatch(weekly, /加入本周计划/);
});

test('本周菜单结果：meta 只保留顿数/人份，summary 单独成段', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  const fn = weekly.slice(
    weekly.indexOf('function renderWeeklyMenuSuggestions'),
    weekly.indexOf('function openWeeklyMenuModal')
  );
  // meta 行不得再拼接 summary。
  assert.doesNotMatch(fn, /人份规划\$\{aiSummary/);
  // summary/notes 单独段落，summary 优先，且经过 escapeHtml。
  assert.match(fn, /plan\?\.summary \|\| plan\?\.notes/);
  assert.match(fn, /class="weekly-menu-summary">\$\{escapeHtml\(aiSummary\)\}/);
  const styles = read('styles.css');
  assert.match(styles, /\.weekly-menu-summary \{/);
});

test('第一版不按 daySuggestion 排日期：加入路径不传 date，仅用户点击写计划', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  const modal = weekly.slice(weekly.indexOf('function openWeeklyMenuModal'));
  // 加入本周建议的调用不携带 date 选项（默认今天），也没有 daySuggestion→date 的换算。
  assert.doesNotMatch(modal, /daySuggestion[\s\S]{0,80}date:/);
  assert.doesNotMatch(modal, /date:\s*[^,\n]*daySuggestion/);
  // 结果区有轻提示，告知稍后可在计划里调整。
  assert.match(weekly, /会先加入计划，之后可在计划里调整。/);
});

test('AI 新建议先保存为菜谱，保存后才允许加入计划和查看', () => {
  const weekly = read('src/views/home/weekly-menu.js');
  const renderSuggestions = weekly.slice(
    weekly.indexOf('function renderWeeklyMenuSuggestions'),
    weekly.indexOf('function openWeeklyMenuModal')
  );
  const modal = weekly.slice(weekly.indexOf('function openWeeklyMenuModal'));

  assert.match(renderSuggestions, /AI 新建议/);
  assert.match(renderSuggestions, /data-action="save">保存为菜谱/);
  assert.match(renderSuggestions, /recipeId[\s\S]*weekly-menu-add[\s\S]*加入计划[\s\S]*weekly-menu-view[\s\S]*查看/);
  assert.match(modal, /btn\.dataset\.action === 'save'/);
  assert.match(modal, /createUserRecipe\(pack, recipeDraft\)/);
  assert.match(modal, /attachSavedWeeklyAiSuggestion\(item, newId, recipeDraft\)/);
  assert.match(modal, /addRecipeToPlanWithMissingCheck\(recipeId, pack, inv/);
  assert.match(weekly, /method: '按家常做法处理食材并炒熟调味。'/);
  assert.match(weekly, /source: 'weekly-menu-ai'/);
});
