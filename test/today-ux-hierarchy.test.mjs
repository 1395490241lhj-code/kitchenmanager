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
  assert.match(home, /function bindWxStatusActions/);
  assert.match(home, /今天可以做 \$\{recommendationCount\} 道菜/);
  assert.match(home, /临期/);
  assert.match(home, /待买/);
  assert.match(home, /wx-stat-chevron/);
  assert.match(home, /data-status="\$\{escapeHtml\(tone\)\}"/);
  // 顶部角标只保留「临期 / 待买」：计划入口在主面板的计划 Tab，不在顶部重复。
  assert.match(home, /\['expiry', '临期', expiringCount\],\s*\['shopping', '待买', shoppingCount\]/);
  assert.doesNotMatch(home, /\['plan', '计划'/);
  assert.doesNotMatch(home, /\[data-status="plan"\]/);
  assert.match(home, /openExpiryListModal\(inv, pack/);
  assert.match(home, /showPendingShoppingModal\(\{[\s\S]*onGoShopping:/);
  assert.match(home, /bindWxStatusActions\(statusHeader, panel, pack, inv/);
});

test('今日页主面板只保留计划和推荐两个轻量 tab', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function createWeatherPanel/);
  assert.match(home, /is-two-tab/);
  assert.match(home, /data-tab="plan"[^>]*>📅 计划/);
  assert.match(home, /data-tab="recs"[^>]*>✨ 推荐/);
  assert.doesNotMatch(home, /data-tab="expiry"[^>]*>⏳ 到期/);
  assert.doesNotMatch(home, /data-tab="shopping"[^>]*>🛒 待买/);
  assert.doesNotMatch(home, /const renderExpiryTab/);
  assert.doesNotMatch(home, /const renderShoppingTab/);
  assert.doesNotMatch(home, /switchTab\('expiry'\)/);
  assert.doesNotMatch(home, /switchTab\('shopping'\)/);
  assert.match(home, /const TAB_RENDERERS = \{ plan: renderPlanTab, recs: renderRecsTab \};/);
});

test('推荐 tab 第一层保留找菜输入区，并复用现有搜索推荐逻辑', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderTargetRecipeSearch/);
  assert.match(home, /想做什么？/);
  assert.doesNotMatch(home, /输入菜名或食材，找到后可以直接加入今天。/);
  assert.match(home, /比如 番茄炒蛋 \/ 鸡蛋 番茄/);
  assert.match(home, /findRecipesByName/);
  assert.match(home, /findRecipesUsingIngredients/);
  assert.match(home, /parseTargetRecipeQuery/);
});

test('搜索结果统一进入推荐大卡片，不再渲染找到这些菜列表', () => {
  const home = read('src/views/home-view.js');
  const renderRecsTab = home.slice(home.indexOf('const renderRecsTab'), home.indexOf('export function renderHome'));

  assert.match(home, /function mergeTodayFocusCards/);
  assert.match(renderRecsTab, /const nameCards = nameMatches\.map\(item => recipeMatchToFocusCard\(item, pack\)\)\.filter\(Boolean\);/);
  assert.match(renderRecsTab, /mode: nameCards\.length \? 'search' : 'search-empty', cards: nameCards/);
  assert.doesNotMatch(home, /找到这些菜/);
  assert.doesNotMatch(home, /function renderRecipeNameResults/);
  assert.doesNotMatch(renderRecsTab, /renderRecipeNameResults\(nameMatches\)/);
  assert.match(renderRecsTab, /找到的推荐/);
  assert.match(renderRecsTab, /第 \$\{idx \+ 1\} \/ \$\{cards\.length\} 道/);
});

test('AI 生成新菜作为同一张推荐卡内的兜底状态', () => {
  const home = read('src/views/home-view.js');
  const renderRecsTab = home.slice(home.indexOf('const renderRecsTab'), home.indexOf('export function renderHome'));

  assert.match(home, /const renderInlineAiEntry/);
  assert.match(home, /const renderInlineAiDraftCard/);
  assert.match(home, /AI 生成新菜/);
  assert.match(home, /AI 新菜草稿/);
  assert.match(home, /保存草稿/);
  assert.match(home, /保存并编辑/);
  assert.match(home, /重新生成/);
  assert.match(home, /取消/);
  assert.match(home, /已保存为菜谱/);
  assert.match(renderRecsTab, /suggestCard\.appendChild\(renderInlineAiEntry/);
  assert.match(renderRecsTab, /cardWrap\.appendChild\(renderInlineAiDraftCard/);
  assert.match(renderRecsTab, /cardWrap\.appendChild\(renderInlineAiEntry/);
  assert.doesNotMatch(renderRecsTab, /renderTargetCreativeBox/);
  assert.doesNotMatch(renderRecsTab, /renderDishDraftBox/);
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
  assert.match(home, /function getSuggestKickerLabel/);
  assert.match(home, /home-suggest-details/);
  assert.match(home, /加入计划/);
  assert.doesNotMatch(home, /<button type="button" class="btn ok small home-suggest-cook">加入今日计划<\/button>/);
  assert.match(home, /查看/);
  assert.match(home, /补到买菜/);
  assert.match(home, /home-suggest-more/);
  assert.match(home, /onMoreRecommendation/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(home, /addRecipeToPlan\(/);
  assert.match(home, /function formatMissingSummary/);
});

test('临期和待买弹窗第一层操作保持精简', () => {
  const home = read('src/views/home-view.js');
  const modal = read('src/components/modal.js');
  const expiryModal = home.slice(home.indexOf('function buildExpiryModal'), home.indexOf('// 打开「到期食材」弹窗'));
  const pendingModal = modal.slice(modal.indexOf('export function showPendingShoppingModal'));

  assert.match(expiryModal, /用它做菜/);
  assert.match(expiryModal, /标记用完/);
  assert.doesNotMatch(expiryModal, /km-expiry-edit/);
  assert.match(pendingModal, /标记已买/);
  assert.doesNotMatch(pendingModal, /km-pending-del/);
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

test('今日计划页去掉重复消耗横条和冗余筛选', () => {
  const home = read('src/views/home-view.js');
  const renderHome = home.slice(home.indexOf('export function renderHome'));
  const renderPlanTab = home.slice(home.indexOf('const renderPlanTab'), home.indexOf('// ── ✨ 推荐'));

  assert.doesNotMatch(renderHome, /renderCookedQuickStrip/);
  assert.doesNotMatch(renderPlanTab, /createRecordCookedCta/);
  assert.doesNotMatch(renderPlanTab, /renderPlanRangeSelect/);
  assert.match(renderPlanTab, /还没有安排今天吃什么/);
  assert.match(renderPlanTab, />看看推荐</);
  assert.doesNotMatch(renderPlanTab, /可以从下面推荐里选一道/);
  assert.doesNotMatch(renderPlanTab, /计划就是今天\/明天准备吃什么/);
  assert.doesNotMatch(renderPlanTab, /饭后记一下/);
  assert.match(home, /openCookedMealModal/);
});

test('计划 Tab 提供 AI 优先本周菜单入口且不新增后端接口', () => {
  const home = read('src/views/home-view.js');
  const weekly = read('src/views/home/weekly-menu.js');
  const ai = read('src/ai.js');
  const renderPlanTab = home.slice(home.indexOf('const renderPlanTab'), home.indexOf('// ── ✨ 推荐'));

  // 本周菜单已拆到独立模块：home-view 只保留 import + 计划 Tab 里的调用。
  assert.match(home, /import \{ renderWeeklyMenuCard \} from '\.\/home\/weekly-menu\.js\?v=\d+'/);
  assert.match(renderPlanTab, /renderWeeklyMenuCard\(pack, inv, \{ onRoute \}\)/);
  assert.match(renderPlanTab, /renderMenuPlan\(pack, \{ onRoute, hideHeader: true, inventory: inv \}\)/);

  assert.match(weekly, /export function renderWeeklyMenuCard/);
  assert.match(weekly, /function openWeeklyMenuModal/);
  assert.match(weekly, /function buildWeeklyMenuSuggestions/);
  assert.match(weekly, /function addWeeklyPlanShortagesToShopping/);
  assert.match(weekly, /callAiWeeklyMenuPlan/);
  // summary 优先于 notes，单独成段（详见 weekly-menu-copy.test.mjs）。
  assert.match(weekly, /String\(plan\?\.summary \|\| plan\?\.notes \|\| ''\)\.trim\(\)/);
  assert.match(weekly, /本周菜单/);
  assert.match(weekly, /规划本周/);
  assert.match(weekly, /补齐待买/);
  // 输入态改紧凑：问题文案精简，加一句短说明，快捷选择/自定义并排。
  assert.match(weekly, /class="weekly-menu-question">做几顿</);
  assert.match(weekly, /class="weekly-menu-question">几个人</);
  assert.match(weekly, /class="weekly-menu-intro">根据库存、临期和偏好，先规划几顿。/);
  // 快捷按钮与「自定义」输入在同一行（choice-row）。
  assert.match(weekly, /class="weekly-menu-choice-row"/);
  assert.match(weekly, /class="weekly-menu-custom-inline"/);
  assert.doesNotMatch(weekly, /weekly-menu-field-row/);
  assert.doesNotMatch(weekly, /快捷选择/);
  assert.match(weekly, /补充要求/);
  assert.match(weekly, /AI 规划本周菜单/);
  assert.match(weekly, /用本地建议/);
  assert.match(weekly, /function normalizeWeeklyMealCount/);
  assert.match(weekly, /function normalizeWeeklyPeopleCount/);
  assert.match(weekly, /class="weekly-menu-meal-input"/);
  assert.match(weekly, /class="weekly-menu-people-input"/);
  assert.match(weekly, /min="1" max="10" step="1"/);
  assert.match(weekly, /min="1" max="8" step="1"/);
  assert.match(weekly, /mealsCount: normalizeWeeklyMealCount\(mealCount, 4\)/);
  assert.match(weekly, /peopleCount: normalizeWeeklyPeopleCount\(peopleCount, 2\)/);
  assert.match(weekly, /updateWeeklyPlanServings\(recipeId, entry\.meal\?\.servings \|\| peopleCount, plannedDate\)/);
  assert.match(ai, /mealsCount: Math\.max\(1, Math\.min\(10/);
  assert.match(ai, /peopleCount: Math\.max\(1, Math\.min\(8/);
  assert.match(ai, /"summary": "这周安排 4 顿/);
  assert.match(ai, /summary 用一句话说明规划逻辑/);
  assert.match(ai, /servings/);
  assert.match(ai, /\.filter\(Boolean\)\.slice\(0, 10\)/);
  assert.match(weekly, /rankRecipesForRecommendation\(pack, inv/);
  assert.match(weekly, /getPlanMissingItems\(recipe, pack, inv\)/);
  assert.match(weekly, /本周菜单缺货/);
  assert.match(weekly, /addRecipeToPlanWithMissingCheck\(recipeId, pack, inv/);
  assert.match(weekly, /AI 新建议/);
  assert.match(weekly, /data-action="save">保存为菜谱/);
  assert.match(weekly, /function buildWeeklyAiSuggestionRecipeDraft/);
  assert.match(weekly, /source: 'weekly-menu-ai'/);
  assert.match(weekly, /createUserRecipe\(pack, recipeDraft\)/);
  assert.match(weekly, /attachSavedWeeklyAiSuggestion\(item, newId, recipeDraft\)/);
  assert.match(weekly, /showToast\('已保存为菜谱'/);
  assert.match(weekly, /showToast\('保存失败，请稍后重试'/);
  assert.match(weekly, /entry\.meal\.recipeId = newId/);
  assert.doesNotMatch(weekly, /选择偏好后生成建议/);
  const weeklyModal = weekly.slice(weekly.indexOf('function openWeeklyMenuModal'), weekly.indexOf('export function renderWeeklyMenuCard'));
  const generateRowTemplate = weeklyModal.match(/<div class="weekly-menu-generate-row">([\s\S]*?)<\/div>/)?.[1] || '';
  assert.doesNotMatch(generateRowTemplate, /weekly-menu-fill-shopping/);
  assert.doesNotMatch(weeklyModal, /callCloudAI/);
  const styles = read('styles.css');
  assert.match(styles, /\.weekly-menu-card/);
  assert.match(styles, /\.weekly-menu-sheet/);
  assert.match(styles, /\.weekly-menu-modal/);
  assert.match(styles, /\.weekly-menu-request/);
  assert.match(styles, /\.weekly-menu-meal-input/);
  assert.match(styles, /\.weekly-menu-people-input/);
  // 偏好 chip 改为自动换行的 flex，不再是两列大胶囊；顿数/人数按钮更轻。
  assert.match(styles, /\.weekly-menu-checks \{[\s\S]*?flex-wrap: wrap/);
  assert.doesNotMatch(styles, /\.weekly-menu-checks[\s\S]{0,120}grid-template-columns: repeat\(2/);
  assert.match(styles, /\.weekly-menu-option \{[\s\S]*?font-size: 15px/);
  assert.match(styles, /\.weekly-menu-suggestion/);
});

test('demo banner 逻辑仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderDemoKitchenBanner/);
  assert.match(home, /if \(isDemoMode\) \{\s*container\.appendChild\(renderDemoKitchenBanner/);
});

test('renderHome 使用顶部状态、两 tab 面板和两个快捷入口', () => {
  const home = read('src/views/home-view.js');
  const renderHome = home.slice(home.indexOf('export function renderHome'));

  assert.match(renderHome, /const statusHeader = renderWxStatus/);
  assert.match(renderHome, /container\.appendChild\(statusHeader\)/);
  assert.doesNotMatch(renderHome, /renderCookedQuickStrip/);
  assert.match(renderHome, /createWeatherPanel/);
  assert.match(renderHome, /renderQuickActions/);
});
