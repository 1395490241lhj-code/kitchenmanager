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

  assert.match(home, /function renderWxStatus/);
  assert.match(home, /今天可以做 \$\{recommendationCount\} 道菜/);
  assert.match(home, /计划/);
  assert.match(home, /临期/);
  assert.match(home, /待买/);
});

test('今日页保留计划/到期/待买/推荐四个轻量 tab', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function createWeatherPanel/);
  assert.match(home, /data-tab="plan"[^>]*>📅 计划/);
  assert.match(home, /data-tab="expiry"[^>]*>⏳ 到期/);
  assert.match(home, /data-tab="shopping"[^>]*>🛒 待买/);
  assert.match(home, /data-tab="recs"[^>]*>✨ 推荐/);
});

test('推荐 tab 第一层保留找菜输入区，并复用现有搜索推荐逻辑', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderTargetRecipeSearch/);
  assert.match(home, /想做什么？/);
  assert.match(home, /输入菜名或食材，找到后可以直接加入今天。/);
  assert.match(home, /比如 番茄炒蛋 \/ 鸡蛋 番茄/);
  assert.match(home, /findRecipesByName/);
  assert.match(home, /findRecipesUsingIngredients/);
  assert.match(home, /parseTargetRecipeQuery/);
});

test('推荐 tab 直接外露用本地推荐、换一道和换几道', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /id="wxRecLocal"[\s\S]*用本地推荐/);
  assert.match(home, /id="wxRecNext"[\s\S]*换一道/);
  assert.match(home, /id="wxRecAi"[\s\S]*换几道/);
  assert.match(home, /stepRecommendation\(1\)/);
  assert.match(home, /callCloudAI/);
});

test('推荐卡第一层保留加入计划、查看和更多，并仍走缺菜检测', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function renderSuggestCard/);
  assert.match(home, /加入计划/);
  assert.match(home, /查看/);
  assert.match(home, /home-suggest-more/);
  assert.match(home, /onMoreRecommendation/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(home, /addRecipeToPlan\(/);
  assert.match(home, /function formatMissingSummary/);
});

test('更多菜单只收纳低频管理操作', () => {
  const home = read('src/views/home-view.js');
  const moreSheet = home.slice(home.indexOf('function openTodayMoreActionsSheet'), home.indexOf('function renderTodayStatusHeader'));

  assert.match(moreSheet, /查看全部推荐/);
  assert.match(moreSheet, /设为常做/);
  assert.match(moreSheet, /编辑/);
  assert.match(moreSheet, /删除/);
  assert.match(moreSheet, /toggleFavoriteRecipe/);
  assert.match(moreSheet, /deleteRecipeFromOverlay/);
  assert.doesNotMatch(moreSheet, /换一道/);
  assert.doesNotMatch(moreSheet, /换几道/);
  assert.doesNotMatch(moreSheet, /用本地推荐/);
  assert.doesNotMatch(moreSheet, /饭后记一下/);
});

test('饭后记一下保留在首页第一层和计划区域', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function renderCookedQuickStrip/);
  assert.match(home, /做完饭了？/);
  assert.match(home, /饭后记一下/);
  assert.match(home, /createRecordCookedCta/);
  assert.match(home, /openCookedMealModal/);
});

test('demo banner 逻辑仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderDemoKitchenBanner/);
  assert.match(home, /if \(isDemoMode\) \{\s*container\.appendChild\(renderDemoKitchenBanner/);
});

test('renderHome 使用顶部状态、饭后轻条、四 tab 面板和两个快捷入口', () => {
  const home = read('src/views/home-view.js');
  const renderHome = home.slice(home.indexOf('export function renderHome'));

  assert.match(renderHome, /container\.appendChild\(renderWxStatus/);
  assert.match(renderHome, /renderCookedQuickStrip/);
  assert.match(renderHome, /createWeatherPanel/);
  assert.match(renderHome, /renderQuickActions/);
});
