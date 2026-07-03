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
  assert.match(home, /计划/);
  assert.match(home, /临期/);
  assert.match(home, /待买/);
});

test('今日页第一层保留找菜输入区，并复用现有搜索推荐逻辑', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function renderTodayRecipeSearch/);
  assert.match(home, /想做什么？/);
  assert.match(home, /输入菜名或食材，找到后可以直接加入今天。/);
  assert.match(home, /比如 番茄炒蛋 \/ 鸡蛋 番茄/);
  assert.match(home, /findRecipesByName/);
  assert.match(home, /findRecipesUsingIngredients/);
  assert.match(home, /parseTargetRecipeQuery/);
});

test('首页只选择一个主卡状态，搜索结果优先，其次计划/推荐/待买/空状态', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function chooseTodayMainCard/);
  assert.match(home, /if \(focusContext\?\.rawQuery && recommendation\) return \{ type: 'recommendation'/);
  assert.match(home, /if \(planItems\.length\) return \{ type: 'plan'/);
  assert.match(home, /if \(recommendation\) return \{ type: 'recommendation'/);
  assert.match(home, /if \(activeShopping\.length && !recommendation\) return \{ type: 'shopping'/);
  assert.match(home, /return \{ type: 'empty' \}/);
});

test('推荐主卡第一层保留加入计划/查看/更多，并仍走缺菜检测', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function createTodayMainCard/);
  assert.match(home, /today-focus-card/);
  assert.match(home, /今日推荐/);
  assert.match(home, /加入计划/);
  assert.match(home, /查看/);
  assert.match(home, /todayMoreActions/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(home, /addRecipeToPlan\(/);
  assert.match(home, /function formatMissingSummary/);
  assert.match(home, /missing\.length === 1 \? '缺 1 样' : `缺 \$\{missing\.length\} 样`/);
});

test('更多菜单收纳次级推荐操作且保留饭后记一下入口', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function openTodayMoreActionsSheet/);
  assert.match(home, /换一道/);
  assert.match(home, /✨ 换几道/);
  assert.match(home, /用本地推荐/);
  assert.match(home, /查看全部推荐/);
  assert.match(home, /设为常做/);
  assert.match(home, /编辑/);
  assert.match(home, /删除/);
  assert.match(home, /openCookedMealModal/);
  assert.match(home, /callCloudAI/);
  assert.match(home, /toggleFavoriteRecipe/);
  assert.match(home, /deleteRecipeFromOverlay/);
});

test('单主卡覆盖关键日常厨房状态，demo banner 逻辑仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /今晚计划/);
  assert.match(home, /饭后记一下/);
  assert.match(home, /优先用掉/);
  assert.match(home, /待买提醒/);
  assert.match(home, /先记录食材/);
  assert.match(home, /renderTodayInlineNudge/);
  assert.match(home, /renderDemoKitchenBanner/);
  assert.match(home, /if \(isDemoMode\) \{\s*container\.appendChild\(renderDemoKitchenBanner/);
});

test('renderHome 使用顶部状态、单主卡和两个快捷入口，不再渲染多 tab 主面板', () => {
  const home = read('src/views/home-view.js');
  const renderHome = home.slice(home.indexOf('export function renderHome'));

  assert.match(renderHome, /container\.appendChild\(renderTodayStatusHeader/);
  assert.match(renderHome, /renderTodayRecipeSearch/);
  assert.match(renderHome, /chooseTodayMainCard/);
  assert.match(renderHome, /createTodayMainCard/);
  assert.match(renderHome, /renderQuickActions/);
  assert.doesNotMatch(renderHome, /createWeatherPanel/);
  assert.doesNotMatch(renderHome, /renderWxStatus/);
});
