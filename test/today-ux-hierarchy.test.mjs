import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('今日页顶部状态区按计划/推荐/空状态展示清晰文案', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function renderTodayStatusHeader/);
  assert.match(home, /function getGreetingLabel/);
  assert.match(home, /今天可以做 \$\{recommendationCount\} 道菜/);
  assert.match(home, /先选一道加入今日计划/);
  assert.match(home, /先记录几样食材/);
  assert.match(home, /计划/);
  assert.match(home, /临期/);
  assert.match(home, /待买/);
});

test('首页只选择一个主卡状态，并按临期/计划/待买/推荐/空状态优先级展示', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function chooseTodayMainCard/);
  assert.match(home, /if \(expiring\.length\) return \{ type: 'expiry'/);
  assert.match(home, /if \(planItems\.length\) return \{ type: 'plan'/);
  assert.match(home, /if \(activeShopping\.length && !recommendation\) return \{ type: 'shopping'/);
  assert.match(home, /if \(recommendation\) return \{ type: 'recommendation'/);
  assert.match(home, /return \{ type: 'empty' \}/);
});

test('单主卡保留加入计划主操作，并仍走缺菜检测', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function createTodayMainCard/);
  assert.match(home, /today-focus-card/);
  assert.match(home, /今日推荐/);
  assert.match(home, /加入计划/);
  assert.match(home, /查看/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(home, /addRecipeToPlan\(/);
  assert.match(home, /function formatMissingSummary/);
  assert.match(home, /missing\.length === 1 \? '缺 1 样' : `缺 \$\{missing\.length\} 样`/);
});

test('单主卡覆盖关键日常厨房状态，demo banner 逻辑仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /优先用掉/);
  assert.match(home, /今晚计划/);
  assert.match(home, /待买提醒/);
  assert.match(home, /先记录食材/);
  assert.match(home, /renderDemoKitchenBanner/);
  assert.match(home, /if \(isDemoMode\) \{\s*container\.appendChild\(renderDemoKitchenBanner/);
});

test('renderHome 使用顶部状态、单主卡和两个快捷入口，不再渲染多 tab 主面板', () => {
  const home = read('src/views/home-view.js');
  const renderHome = home.slice(home.indexOf('export function renderHome'));

  assert.match(renderHome, /container\.appendChild\(renderTodayStatusHeader/);
  assert.match(renderHome, /chooseTodayMainCard/);
  assert.match(renderHome, /createTodayMainCard/);
  assert.match(renderHome, /renderQuickActions/);
  assert.doesNotMatch(renderHome, /createWeatherPanel/);
  assert.doesNotMatch(renderHome, /renderWxStatus/);
});
