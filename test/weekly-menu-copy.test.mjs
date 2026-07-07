import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('本周菜单结果：底部按钮叫“加入计划”，不再叫“加入本周计划”', () => {
  const home = read('src/views/home-view.js');
  assert.match(home, /weekly-menu-add-all">加入计划</);
  assert.doesNotMatch(home, /加入本周计划/);
});

test('本周菜单结果：meta 只保留顿数/人份，summary 单独成段', () => {
  const home = read('src/views/home-view.js');
  const fn = home.slice(
    home.indexOf('function renderWeeklyMenuSuggestions'),
    home.indexOf('function openWeeklyMenuModal')
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
  const home = read('src/views/home-view.js');
  const modal = home.slice(home.indexOf('function openWeeklyMenuModal'));
  // 加入本周建议的调用不携带 date 选项（默认今天），也没有 daySuggestion→date 的换算。
  assert.doesNotMatch(modal, /daySuggestion[\s\S]{0,80}date:/);
  assert.doesNotMatch(modal, /date:\s*[^,\n]*daySuggestion/);
  // 结果区有轻提示，告知稍后可在计划里调整。
  assert.match(home, /会先加入计划，之后可在计划里调整。/);
});
