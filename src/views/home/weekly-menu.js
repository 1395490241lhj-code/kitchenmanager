/*
 * src/views/home/weekly-menu.js —— 「本周菜单」AI 规划（从 home-view 抽出）。
 * 入口 renderWeeklyMenuCard；做几顿/每顿几道/几人/补充要求 → AI 规划（本地建议兜底）→ 分顿展示 →
 * 加入计划 / 补齐待买 / AI 新建议保存为菜谱。mealIndex 只用于建议分组，不改 plan 结构。
 */
import { S, todayISO, addDaysISO } from '../../storage.js?v=236';
import { getCanonicalName, guessKitchenUnit } from '../../ingredients.js?v=236';
import { isInventoryAvailable, remainingDays } from '../../inventory.js?v=236';
import { addShoppingItem, loadShoppingItems } from '../../shopping.js?v=236';
import { hasRecipeMethod, isFavoriteRecipe, rankRecipesForRecommendation } from '../../recommendations.js?v=236';
import { classifyRecipeIngredient } from '../../utils/recipe-sanitizer.js?v=236';
import { getPendingPlanRowsInRange, isPlanRowOnDate } from '../../plan-selectors.js?v=236';
import { addRecipeToPlanWithMissingCheck, getPlanMissingItems } from '../../components/plan-missing-check.js?v=236';
import { callAiWeeklyMenuPlan, formatAiErrorMessage, withTimeout } from '../../ai.js?v=236';
import { createUserRecipe } from '../../components/recipe-create-modal.js?v=236';
import { brieflyConfirmButton, escapeHtml, escapeOptionAttr, showToast } from '../../components/status.js?v=236';
import { createHomeModal } from './home-modal.js?v=236';
import { getExpiringItems, getRecommendationUiContext, isExpiryTracked } from './home-data.js?v=236';
import { isDemoKitchenMode, markDemoPlanAdded } from './demo-kitchen.js?v=236';

export const WEEKLY_MENU_MAX_DISHES = 12;

function formatWeeklySuggestionMeta(item) {
  const used = item?.meal?.uses || getWeeklyMatchedNames(item.row);
  const missing = item?.meal?.missing || getWeeklyMissingNames(item.row);
  if (used.length) return `用到：${used.join('、')}`;
  if (!missing.length) return '食材基本齐';
  return '适合加入本周菜单';
}

function formatWeeklySuggestionMissing(item) {
  const missing = item?.meal?.missing || getWeeklyMissingNames(item.row);
  if (!missing.length) return '食材基本齐';
  return `还缺：${missing.join('、')}${(item.row?.missing || []).length > missing.length ? '等' : ''}`;
}

function getWeeklyEntryRecipeId(entry) {
  return String(entry?.meal?.recipeId || entry?.recipe?.id || '').trim();
}

function getWeeklyAiSuggestionIngredientNames(meal = {}) {
  return Array.from(new Set([
    ...(Array.isArray(meal.uses) ? meal.uses : []),
    ...(Array.isArray(meal.missing) ? meal.missing : [])
  ].map(name => String(name || '').trim()).filter(Boolean)));
}

function buildWeeklyAiSuggestionRecipeDraft(entry) {
  const meal = entry?.meal || {};
  const tags = new Set((Array.isArray(meal.balanceTags) ? meal.balanceTags : [])
    .map(tag => String(tag || '').trim())
    .filter(Boolean));
  if (Array.from(tags).some(tag => /带饭/.test(tag))) tags.add('带饭');
  if (/简单/.test(String(meal.difficulty || ''))) tags.add('快手');
  tags.add('AI 本周菜单');
  const ingredients = getWeeklyAiSuggestionIngredientNames(meal).map(name => ({
    item: getCanonicalName(name) || name,
    unit: ''
  }));
  return {
    name: String(meal.name || entry?.recipe?.name || 'AI 本周菜单建议').trim(),
    tags: Array.from(tags),
    ingredients,
    method: '按家常做法处理食材并炒熟调味。',
    source: 'weekly-menu-ai'
  };
}

function attachSavedWeeklyAiSuggestion(entry, newId, recipeDraft) {
  const missingNames = Array.isArray(entry?.meal?.missing) ? entry.meal.missing : [];
  entry.meal = entry.meal || {};
  entry.meal.recipeId = newId;
  entry.recipe = {
    id: newId,
    name: recipeDraft.name,
    tags: recipeDraft.tags,
    method: recipeDraft.method
  };
  entry.row = entry.row || {};
  entry.row.r = entry.recipe;
  entry.row.list = recipeDraft.ingredients;
  entry.row.missing = missingNames.map(name => ({ name, item: name, unit: guessKitchenUnit(name) || '' }));
}

export function getWeeklyTargetDishCount(mealCount, dishesPerMeal) {
  return Math.min(
    WEEKLY_MENU_MAX_DISHES,
    normalizeWeeklyMealCount(mealCount, 4) * normalizeWeeklyDishesPerMeal(dishesPerMeal, 2)
  );
}

function getWeeklyEntryMealIndex(entry, index, dishesPerMeal = 2) {
  const parsed = Math.trunc(Number(entry?.meal?.mealIndex));
  if (Number.isInteger(parsed) && parsed > 0) return parsed;
  const safeDishesPerMeal = normalizeWeeklyDishesPerMeal(dishesPerMeal, 2);
  return Math.floor(Math.max(0, Number(index) || 0) / safeDishesPerMeal) + 1;
}

export function getWeeklyEntryPlannedDate(entry, index, today = todayISO(), dishesPerMeal = 2) {
  return entry?.plannedDate || getWeeklyPlannedDate(
    entry?.meal,
    getWeeklyEntryMealIndex(entry, index, dishesPerMeal) - 1,
    today
  );
}

export function groupWeeklyMenuEntries(suggestions, { today = todayISO(), dishesPerMeal = 2 } = {}) {
  const groups = new Map();
  for (const [index, entry] of (suggestions || []).entries()) {
    const mealIndex = getWeeklyEntryMealIndex(entry, index, dishesPerMeal);
    const meal = entry?.meal || {};
    const group = groups.get(mealIndex) || {
      mealIndex,
      mealLabel: meal.mealLabel || `第${mealIndex}顿`,
      daySuggestion: meal.daySuggestion || getWeeklyDaySuggestion(mealIndex - 1),
      plannedDate: getWeeklyEntryPlannedDate(entry, index, today, dishesPerMeal),
      entries: []
    };
    // 同一顿优先使用第一道菜的日期；正常路径会由日期选择器同步写入整组。
    group.entries.push({ entry, index, plannedDate: entry?.plannedDate || group.plannedDate });
    groups.set(mealIndex, group);
  }
  return Array.from(groups.values()).sort((a, b) => a.mealIndex - b.mealIndex);
}

// 本周菜单的日期选择只修改建议内存态；同一顿的每道菜都跟随，真正加入时才逐条写 plan。
export function syncWeeklyMealPlannedDate(suggestions, mealIndex, plannedDate, dishesPerMeal = 2) {
  let changed = 0;
  for (const [index, entry] of (suggestions || []).entries()) {
    if (getWeeklyEntryMealIndex(entry, index, dishesPerMeal) !== mealIndex) continue;
    entry.plannedDate = plannedDate;
    changed += 1;
  }
  return changed;
}

// 批量加入时仍是一道菜一条计划记录；这个映射只保证同一顿共用日期。
export function getWeeklyPlanEntries(suggestions, { today = todayISO(), dishesPerMeal = 2 } = {}) {
  return (suggestions || []).map((entry, index) => ({
    entry,
    index,
    plannedDate: getWeeklyEntryPlannedDate(entry, index, today, dishesPerMeal)
  }));
}

function renderWeeklyMenuSuggestions(suggestions, addedIds = new Set(), {
  hasGenerated = false,
  mode = 'idle',
  plan = null,
  error = '',
  requestedCount = 4,
  dishesPerMeal = 2,
  peopleCount = 2,
  lunchboxFriendly = false
} = {}) {
  const today = todayISO();
  if (!hasGenerated) {
    return '';
  }
  if (mode === 'error') {
    return `
      <div class="weekly-menu-results weekly-menu-error">
        <h4>AI 暂时不可用</h4>
        <p class="weekly-menu-empty">${escapeHtml(error || '可以先用本地推荐规划。')}</p>
        <div class="weekly-menu-results-actions">
          <button type="button" class="btn weekly-menu-local">用本地建议</button>
          <button type="button" class="btn ok weekly-menu-retry">重试</button>
        </div>
      </div>
    `;
  }
  if (!suggestions.length) {
    return `
      <div class="weekly-menu-results">
        <h4>${mode === 'local' ? '本地建议' : 'AI 本周建议'}</h4>
        <p class="weekly-menu-empty">暂时没有合适建议</p>
        <div class="weekly-menu-results-actions">
          <button type="button" class="btn weekly-menu-fill-shopping">补齐待买</button>
          <button type="button" class="btn weekly-menu-retry">重新规划</button>
        </div>
      </div>
    `;
  }
  const title = mode === 'local' ? '本地建议' : 'AI 本周建议';
  // summary 优先于 notes；单独成段展示，避免挤在每道菜的 meta 行里。
  const aiSummary = mode === 'local' ? '' : String(plan?.summary || plan?.notes || '').trim();
  const safeMealCount = normalizeWeeklyMealCount(requestedCount, 4);
  const safeDishesPerMeal = normalizeWeeklyDishesPerMeal(dishesPerMeal, 2);
  const targetDishCount = getWeeklyTargetDishCount(safeMealCount, safeDishesPerMeal);
  const note = `已规划 ${safeMealCount} 顿 · 每顿约 ${safeDishesPerMeal} 道 · ${normalizeWeeklyPeopleCount(peopleCount, 2)} 人${lunchboxFriendly ? ' · 适合带饭' : ''}`;
  const isIncomplete = suggestions.length < targetDishCount;
  const groups = groupWeeklyMenuEntries(suggestions, { today, dishesPerMeal: safeDishesPerMeal });
  return `
    <div class="weekly-menu-results">
      <div class="weekly-menu-results-head">
        <h4>${title}</h4>
        <p>${escapeHtml(note)}</p>
      </div>
      ${aiSummary ? `<p class="weekly-menu-summary">${escapeHtml(aiSummary)}</p>` : ''}
      ${isIncomplete ? `<p class="weekly-menu-incomplete">本次仅规划 ${suggestions.length} 道，低于约 ${targetDishCount} 道的目标；已保留合理搭配，不会硬凑。</p>` : ''}
      <div class="weekly-menu-meal-groups">
        ${groups.map(group => `
          <section class="weekly-menu-meal-group" data-meal-index="${group.mealIndex}">
            <div class="weekly-menu-meal-heading">
              <h5>${escapeHtml(group.mealLabel)} · ${escapeHtml(group.daySuggestion)}</h5>
            </div>
            <div class="weekly-menu-suggestion-list">
        ${group.entries.map(({ entry, index, plannedDate }) => {
          const { recipe, meal } = entry;
          const recipeId = getWeeklyEntryRecipeId(entry);
          const added = recipeId && addedIds.has(weeklyAddedKey(recipeId, plannedDate));
          const tags = Array.isArray(meal?.balanceTags) ? meal.balanceTags.slice(0, 3) : [];
          const servings = normalizeWeeklyServingCount(meal?.servings, peopleCount);
          return `
            <article class="weekly-menu-suggestion" data-index="${index}" data-recipe-id="${escapeOptionAttr(recipeId)}" data-planned-date="${escapeOptionAttr(plannedDate)}">
              <div class="weekly-menu-suggestion-main">
                <strong class="weekly-menu-name">${escapeHtml(meal?.name || recipe?.name || '本周菜谱')}${recipeId ? '' : '<span class="weekly-menu-ai-note">AI 新建议</span>'}</strong>
                <small class="weekly-menu-meta">${escapeHtml([
                  `${servings} 人份`,
                  meal?.difficulty || getWeeklyRecipeDifficulty(recipe),
                  ...tags.slice(0, 2)
                ].filter(Boolean).join(' · '))}</small>
                ${meal?.reason ? `<span class="weekly-menu-reason">${escapeHtml(meal.reason)}</span>` : ''}
                <small class="weekly-menu-uses">${escapeHtml(formatWeeklySuggestionMeta(entry))}</small>
                <small class="weekly-menu-shortage">${escapeHtml(formatWeeklySuggestionMissing(entry))}</small>
              </div>
              <div class="weekly-menu-suggestion-actions">
                <label class="weekly-menu-date-field">计划到
                  <select class="weekly-menu-date" aria-label="计划日期">${buildWeeklyDateOptions(plannedDate, today)}</select>
                </label>
                <div class="weekly-menu-action-buttons">
                  ${recipeId
                    ? `<button type="button" class="btn small weekly-menu-add" data-action="add"${added ? ' disabled' : ''}>${added ? '已加入' : '加入计划'}</button>
                      <button type="button" class="btn small weekly-menu-view" data-action="view">查看</button>`
                    : '<button type="button" class="btn small weekly-menu-save" data-action="save">保存为菜谱</button>'}
                </div>
              </div>
            </article>
          `;
        }).join('')}
            </div>
          </section>
        `).join('')}
      </div>
      <p class="weekly-menu-hint">会先加入计划，之后可在计划里调整。</p>
      <div class="weekly-menu-results-actions">
        <button type="button" class="btn ok weekly-menu-add-all">加入计划</button>
        <button type="button" class="btn weekly-menu-fill-shopping">补齐待买</button>
        <button type="button" class="btn weekly-menu-retry">重新规划</button>
      </div>
    </div>
  `;
}

function openWeeklyMenuModal(pack, inv, { onRoute = () => {} } = {}) {
  const content = document.createElement('div');
  content.className = 'km-modal-body weekly-menu-modal';
  let closeWeeklyModal = () => {};
  let mealCount = 4;
  let dishesPerMeal = 2;
  let dishesPerMealLocked = false;
  let peopleCount = 2;
  let priorities = {
    expiring: true,
    inventory: true,
    quick: false,
    lunchbox: false
  };
  let suggestions = [];
  let planResult = null;
  let hasGeneratedSuggestions = false;
  let renderMode = 'idle';
  let errorMessage = '';
  let userRequest = '';
  // 已加入去重按「recipeId|date」记，未来 7 天窗口内逐日区分——同一道菜不同日期互不影响。
  const today0 = todayISO();
  const addedIds = new Set(
    getPendingPlanRowsInRange(today0, addDaysISO(today0, WEEKLY_PLAN_MAX_OFFSET))
      .filter(row => row && row.id)
      .map(row => weeklyAddedKey(row.id, row.date || today0))
  );
  const resetGeneratedState = () => {
    hasGeneratedSuggestions = false;
    suggestions = [];
    planResult = null;
    renderMode = 'idle';
    errorMessage = '';
  };
  const readMealCountFromInput = () => {
    const input = content.querySelector('.weekly-menu-meal-input');
    mealCount = normalizeWeeklyMealCount(input?.value, 4);
    if (input) input.value = String(mealCount);
    return mealCount;
  };
  const readPeopleCountFromInput = () => {
    const input = content.querySelector('.weekly-menu-people-input');
    peopleCount = normalizeWeeklyPeopleCount(input?.value, 2);
    if (input) input.value = String(peopleCount);
    return peopleCount;
  };
  const readDishesPerMealFromInput = () => {
    const input = content.querySelector('.weekly-menu-dishes-input');
    dishesPerMeal = normalizeWeeklyDishesPerMeal(input?.value, 2);
    if (input) input.value = String(dishesPerMeal);
    return dishesPerMeal;
  };
  const generateLocalSuggestions = () => {
    readMealCountFromInput();
    readDishesPerMealFromInput();
    readPeopleCountFromInput();
    const localRows = buildWeeklyMenuSuggestions(pack, inv, { mealCount, dishesPerMeal, priorities });
    suggestions = createLocalWeeklyMenuEntries(localRows, mealCount, dishesPerMeal, peopleCount);
    planResult = { notes: '已用本地推荐生成建议。' };
    renderMode = 'local';
    hasGeneratedSuggestions = true;
    errorMessage = '';
  };
  const generateAiSuggestions = async () => {
    readMealCountFromInput();
    readDishesPerMealFromInput();
    readPeopleCountFromInput();
    renderMode = 'loading';
    hasGeneratedSuggestions = true;
    errorMessage = '';
    render();
    try {
      const payload = buildAiWeeklyMenuPlanPayload(pack, inv, {
        mealCount,
        dishesPerMeal,
        dishesPerMealLocked,
        peopleCount,
        priorities,
        userRequest
      });
      const result = await withTimeout(callAiWeeklyMenuPlan(payload), 45000, 'AI 规划超时，请稍后重试。');
      planResult = result;
      suggestions = normalizeAiWeeklyMenuEntries(result, pack, { mealCount, dishesPerMeal });
      renderMode = 'ai';
      errorMessage = '';
    } catch (error) {
      suggestions = [];
      planResult = null;
      renderMode = 'error';
      errorMessage = formatAiErrorMessage(error).replace(/^AI 暂不可用：?/, '') || '可以先用本地推荐规划。';
    } finally {
      render();
    }
  };
  const render = () => {
    content.innerHTML = `
      <p class="weekly-menu-intro">“做几顿”是用餐批次；“每顿几道菜”决定每个批次的搭配。</p>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">做几顿</p>
        <div class="weekly-menu-choice-row">
          <div class="weekly-menu-options" role="group" aria-label="选择本周做饭顿数">
            ${[3, 4, 5].map(value => `
              <button type="button" class="weekly-menu-option${mealCount === value ? ' is-active' : ''}" data-meal-count="${value}">${value} 顿</button>
            `).join('')}
          </div>
          <label class="weekly-menu-custom-inline">
            <span>自定义</span>
            <input class="weekly-menu-meal-input" type="number" inputmode="numeric" min="1" max="10" step="1" value="${mealCount}" aria-label="自定义本周做饭顿数">
            <span>顿</span>
          </label>
        </div>
      </section>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">每顿几道菜</p>
        <div class="weekly-menu-choice-row">
          <div class="weekly-menu-options" role="group" aria-label="选择每顿菜数">
            ${[1, 2, 3].map(value => `
              <button type="button" class="weekly-menu-option${dishesPerMeal === value ? ' is-active' : ''}" data-dishes-per-meal="${value}">${value} 道</button>
            `).join('')}
          </div>
          <label class="weekly-menu-custom-inline">
            <span>自定义</span>
            <input class="weekly-menu-dishes-input" type="number" inputmode="numeric" min="1" max="3" step="1" value="${dishesPerMeal}" aria-label="自定义每顿菜数">
            <span>道</span>
          </label>
        </div>
      </section>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">几个人</p>
        <div class="weekly-menu-choice-row">
          <div class="weekly-menu-options" role="group" aria-label="选择用餐人数">
            ${[1, 2, 3, 4].map(value => `
              <button type="button" class="weekly-menu-option${peopleCount === value ? ' is-active' : ''}" data-people-count="${value}">${value} 人</button>
            `).join('')}
          </div>
          <label class="weekly-menu-custom-inline">
            <span>自定义</span>
            <input class="weekly-menu-people-input" type="number" inputmode="numeric" min="1" max="8" step="1" value="${peopleCount}" aria-label="自定义用餐人数">
            <span>人</span>
          </label>
        </div>
      </section>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">优先考虑</p>
        <div class="weekly-menu-checks">
          ${[
            ['expiring', '用掉临期'],
            ['inventory', '利用现有食材'],
            ['quick', '快手菜'],
            ['lunchbox', '适合带饭']
          ].map(([key, label]) => `
            <label class="weekly-menu-check${priorities[key] ? ' is-active' : ''}">
              <input type="checkbox" value="${key}"${priorities[key] ? ' checked' : ''}>
              <span>${priorities[key] ? '✓ ' : ''}${label}</span>
            </label>
          `).join('')}
        </div>
      </section>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">补充要求</p>
        <textarea class="weekly-menu-request" rows="3" placeholder="例如：少油、两道能带饭、不想吃鸡肉、想消耗牛肉">${escapeHtml(userRequest)}</textarea>
      </section>
      <div class="weekly-menu-generate-row">
        <button type="button" class="btn ok weekly-menu-generate"${renderMode === 'loading' ? ' disabled' : ''}>${renderMode === 'loading' ? '规划中…' : 'AI 规划本周菜单'}</button>
      </div>
      ${renderWeeklyMenuSuggestions(suggestions, addedIds, {
        hasGenerated: hasGeneratedSuggestions,
        mode: renderMode,
        plan: planResult,
        error: errorMessage,
        requestedCount: mealCount,
        dishesPerMeal,
        peopleCount,
        lunchboxFriendly: priorities.lunchbox
      })}
    `;
    content.querySelectorAll('[data-meal-count]').forEach(btn => {
      btn.onclick = () => {
        mealCount = normalizeWeeklyMealCount(btn.dataset.mealCount, 4);
        resetGeneratedState();
        render();
      };
    });
    const mealInput = content.querySelector('.weekly-menu-meal-input');
    if (mealInput) {
      mealInput.oninput = () => {
        const raw = String(mealInput.value || '').trim();
        const parsed = raw ? normalizeWeeklyMealCount(raw, mealCount) : mealCount;
        mealCount = raw ? parsed : 4;
        if (raw && Number(mealInput.value) > 10) mealInput.value = '10';
        if (raw && Number(mealInput.value) < 1) mealInput.value = '1';
        const shouldRender = hasGeneratedSuggestions || renderMode !== 'idle';
        content.querySelectorAll('[data-meal-count]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.mealCount) === mealCount);
        });
        resetGeneratedState();
        if (shouldRender) render();
      };
      mealInput.onblur = () => {
        mealCount = normalizeWeeklyMealCount(mealInput.value, 4);
        mealInput.value = String(mealCount);
        content.querySelectorAll('[data-meal-count]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.mealCount) === mealCount);
        });
      };
    }
    content.querySelectorAll('[data-dishes-per-meal]').forEach(btn => {
      btn.onclick = () => {
        dishesPerMeal = normalizeWeeklyDishesPerMeal(btn.dataset.dishesPerMeal, 2);
        dishesPerMealLocked = true;
        resetGeneratedState();
        render();
      };
    });
    const dishesInput = content.querySelector('.weekly-menu-dishes-input');
    if (dishesInput) {
      dishesInput.oninput = () => {
        const raw = String(dishesInput.value || '').trim();
        const parsed = raw ? normalizeWeeklyDishesPerMeal(raw, dishesPerMeal) : dishesPerMeal;
        dishesPerMeal = raw ? parsed : 2;
        dishesPerMealLocked = Boolean(raw);
        if (raw && Number(dishesInput.value) > 3) dishesInput.value = '3';
        if (raw && Number(dishesInput.value) < 1) dishesInput.value = '1';
        const shouldRender = hasGeneratedSuggestions || renderMode !== 'idle';
        content.querySelectorAll('[data-dishes-per-meal]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.dishesPerMeal) === dishesPerMeal);
        });
        resetGeneratedState();
        if (shouldRender) render();
      };
      dishesInput.onblur = () => {
        dishesPerMeal = normalizeWeeklyDishesPerMeal(dishesInput.value, 2);
        dishesInput.value = String(dishesPerMeal);
        content.querySelectorAll('[data-dishes-per-meal]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.dishesPerMeal) === dishesPerMeal);
        });
      };
    }
    content.querySelectorAll('[data-people-count]').forEach(btn => {
      btn.onclick = () => {
        peopleCount = normalizeWeeklyPeopleCount(btn.dataset.peopleCount, 2);
        resetGeneratedState();
        render();
      };
    });
    const peopleInput = content.querySelector('.weekly-menu-people-input');
    if (peopleInput) {
      peopleInput.oninput = () => {
        const raw = String(peopleInput.value || '').trim();
        const parsed = raw ? normalizeWeeklyPeopleCount(raw, peopleCount) : peopleCount;
        peopleCount = raw ? parsed : 2;
        if (raw && Number(peopleInput.value) > 8) peopleInput.value = '8';
        if (raw && Number(peopleInput.value) < 1) peopleInput.value = '1';
        const shouldRender = hasGeneratedSuggestions || renderMode !== 'idle';
        content.querySelectorAll('[data-people-count]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.peopleCount) === peopleCount);
        });
        resetGeneratedState();
        if (shouldRender) render();
      };
      peopleInput.onblur = () => {
        peopleCount = normalizeWeeklyPeopleCount(peopleInput.value, 2);
        peopleInput.value = String(peopleCount);
        content.querySelectorAll('[data-people-count]').forEach(btn => {
          btn.classList.toggle('is-active', Number(btn.dataset.peopleCount) === peopleCount);
        });
      };
    }
    content.querySelectorAll('.weekly-menu-check input').forEach(input => {
      input.onchange = () => {
        priorities = { ...priorities, [input.value]: input.checked };
        input.closest('.weekly-menu-check')?.classList.toggle('is-active', input.checked);
        const label = input.closest('.weekly-menu-check')?.querySelector('span');
        if (label) label.textContent = `${input.checked ? '✓ ' : ''}${label.textContent.replace(/^✓\s*/, '')}`;
      };
    });
    const requestInput = content.querySelector('.weekly-menu-request');
    if (requestInput) {
      requestInput.oninput = () => {
        userRequest = requestInput.value;
      };
    }
    content.querySelector('.weekly-menu-generate').onclick = () => {
      userRequest = content.querySelector('.weekly-menu-request')?.value || '';
      generateAiSuggestions();
    };
    const fillShoppingBtn = content.querySelector('.weekly-menu-fill-shopping');
    if (fillShoppingBtn) {
      fillShoppingBtn.onclick = () => {
        const result = suggestions.length
          ? addWeeklyMenuEntriesMissingToShopping(suggestions, peopleCount)
          : addWeeklyPlanShortagesToShopping(pack, inv);
        showWeeklyShoppingResult(result, { onRoute });
      };
    }
    const localBtn = content.querySelector('.weekly-menu-local');
    if (localBtn) {
      localBtn.onclick = () => {
        generateLocalSuggestions();
        render();
      };
    }
    const retryBtn = content.querySelector('.weekly-menu-retry');
    if (retryBtn) {
      retryBtn.onclick = () => {
        userRequest = content.querySelector('.weekly-menu-request')?.value || userRequest;
        generateAiSuggestions();
      };
    }
    const addAllBtn = content.querySelector('.weekly-menu-add-all');
    if (addAllBtn) {
      addAllBtn.onclick = async () => {
        addAllBtn.disabled = true;
        const today = todayISO();
        let added = 0;
        for (const { entry, index, plannedDate } of getWeeklyPlanEntries(suggestions, { today, dishesPerMeal })) {
          const recipeId = getWeeklyEntryRecipeId(entry);
          if (!recipeId) continue;
          const result = await addRecipeToPlanWithMissingCheck(recipeId, pack, inv, {
            date: plannedDate,
            recipe: entry.recipe,
            fallbackItems: entry.row?.list,
            missing: entry.row?.missing,
            source: isDemoKitchenMode() ? 'demo' : 'weekly-menu',
            onPlanAdded: markDemoPlanAdded
          });
          if (result.added) {
            added += 1;
            addedIds.add(weeklyAddedKey(recipeId, plannedDate));
            updateWeeklyPlanServings(recipeId, entry.meal?.servings || peopleCount, plannedDate);
          }
        }
        showToast(added ? `已加入 ${added} 道计划` : '可加入的菜已在计划里', { tone: added ? 'success' : 'info' });
        onRoute();
        render();
      };
    }
    // 「计划到」下拉：不写 plan；同一 mealIndex 的建议同步日期，真正加入时才逐条写入。
    content.querySelectorAll('.weekly-menu-suggestion .weekly-menu-date').forEach(select => {
      select.onchange = () => {
        const article = select.closest('.weekly-menu-suggestion');
        const index = Number(article?.dataset.index ?? -1);
        const entry = suggestions[index];
        if (!entry) return;
        const nextDate = select.value;
        const mealIndex = getWeeklyEntryMealIndex(entry, index, dishesPerMeal);
        syncWeeklyMealPlannedDate(suggestions, mealIndex, nextDate, dishesPerMeal);
        render();
      };
    });
    content.querySelectorAll('.weekly-menu-suggestion [data-action]').forEach(btn => {
      btn.onclick = async () => {
        const row = btn.closest('.weekly-menu-suggestion');
        const index = Number(row?.dataset.index || -1);
        let recipeId = row?.dataset.recipeId || '';
        const item = suggestions[index] || suggestions.find(entry => getWeeklyEntryRecipeId(entry) === recipeId);
        if (!item) return;
        if (btn.dataset.action === 'save') {
          btn.disabled = true;
          try {
            const recipeDraft = buildWeeklyAiSuggestionRecipeDraft(item);
            const newId = createUserRecipe(pack, recipeDraft);
            attachSavedWeeklyAiSuggestion(item, newId, recipeDraft);
            showToast('已保存为菜谱', { tone: 'success' });
            render();
          } catch (error) {
            btn.disabled = false;
            showToast('保存失败，请稍后重试', { tone: 'error' });
          }
          return;
        }
        recipeId = recipeId || getWeeklyEntryRecipeId(item);
        if (!recipeId) {
          showToast('这道是 AI 新建议，先保存为菜谱后再加入计划', { tone: 'info' });
          return;
        }
        if (btn.dataset.action === 'view') {
          closeWeeklyModal();
          location.hash = `#recipe:${recipeId}`;
          return;
        }
        btn.disabled = true;
        const safeIndex = index >= 0 ? index : suggestions.indexOf(item);
        const plannedDate = item.plannedDate || row?.dataset.plannedDate || getWeeklyEntryPlannedDate(item, safeIndex, todayISO(), dishesPerMeal);
        const result = await addRecipeToPlanWithMissingCheck(recipeId, pack, inv, {
          date: plannedDate,
          recipe: item.recipe,
          fallbackItems: item.row?.list,
          missing: item.row?.missing,
          source: isDemoKitchenMode() ? 'demo' : 'weekly-menu',
          onPlanAdded: markDemoPlanAdded
        });
        if (result.added) {
          addedIds.add(weeklyAddedKey(recipeId, plannedDate));
          updateWeeklyPlanServings(recipeId, item.meal?.servings || peopleCount, plannedDate);
        }
        brieflyConfirmButton(btn, result.added ? '已加入' : '已在计划');
        onRoute();
        render();
      };
    });
  };
  render();
  const modal = createHomeModal(content, '本周菜单');
  modal.overlay.querySelector('.km-modal-content')?.classList.add('weekly-menu-sheet');
  closeWeeklyModal = modal.close;
}

export function renderWeeklyMenuCard(pack, inv, { onRoute = () => {} } = {}) {
  const summary = getWeeklyMenuSummary(pack);
  const card = document.createElement('section');
  card.className = 'weekly-menu-card';
  card.innerHTML = `
    <div class="weekly-menu-card-copy">
      <strong>本周菜单</strong>
      <span>${escapeHtml(summary.label)}</span>
    </div>
    <div class="weekly-menu-card-actions">
      <button type="button" class="wx-mini-btn is-primary weekly-menu-plan-btn">规划本周</button>
      <button type="button" class="wx-mini-btn weekly-menu-shopping-btn">补齐待买</button>
    </div>
  `;
  card.querySelector('.weekly-menu-plan-btn').onclick = () => openWeeklyMenuModal(pack, inv, { onRoute });
  card.querySelector('.weekly-menu-shopping-btn').onclick = () => {
    showWeeklyShoppingResult(addWeeklyPlanShortagesToShopping(pack, inv), { onRoute });
  };
  return card;
}

// ── 弹窗内容构建 ─────────────────────────────────────────────────────────────

/** 「临期食材」弹窗：列出快到期 / 已过期食材，并提供做菜、标记用完入口。 */

function getWeeklyPlanItems(pack, { days = 7 } = {}) {
  const today = todayISO();
  const end = addDaysISO(today, Math.max(0, days - 1));
  const recipes = pack.recipes || [];
  return getPendingPlanRowsInRange(today, end, today)
    .map(item => ({
      ...item,
      date: item.date || today,
      recipe: recipes.find(recipe => recipe.id === item.id) || null
    }))
    .filter(item => item.recipe);
}

function getWeeklyMenuSummary(pack) {
  const plannedCount = getWeeklyPlanItems(pack).length;
  const targetCount = 4;
  return {
    plannedCount,
    targetCount,
    missingCount: Math.max(0, targetCount - plannedCount),
    label: plannedCount >= targetCount
      ? '本周已基本安排好'
      : plannedCount === 0
        ? '买菜前先规划几顿'
        : `已安排 ${plannedCount} 顿 · 还缺 ${Math.max(0, targetCount - plannedCount)} 顿`
  };
}

function normalizeWeeklyMealCount(value, fallback = 4) {
  const raw = String(value ?? '').trim();
  if (!raw) return fallback;
  const parsed = Math.trunc(Number(raw));
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(1, Math.min(10, parsed));
}

function normalizeWeeklyDishesPerMeal(value, fallback = 2) {
  const raw = String(value ?? '').trim();
  if (!raw) return fallback;
  const parsed = Math.trunc(Number(raw));
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(1, Math.min(3, parsed));
}

function normalizeWeeklyPeopleCount(value, fallback = 2) {
  const raw = String(value ?? '').trim();
  if (!raw) return fallback;
  const parsed = Math.trunc(Number(raw));
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(1, Math.min(8, parsed));
}

function normalizeWeeklyServingCount(value, fallback = 2) {
  const parsed = Math.trunc(Number(value));
  const safeFallback = normalizeWeeklyPeopleCount(fallback, 2);
  if (!Number.isFinite(parsed) || parsed <= 0) return safeFallback;
  return Math.max(1, Math.min(12, parsed));
}

function getWeeklyMatchedNames(row, limit = 3) {
  return Array.from(new Set((row?.matches || [])
    .map(item => String(item?.inventoryItem || item?.recipeItem || '').trim())
    .filter(Boolean)))
    .slice(0, limit);
}

function getWeeklyMissingNames(row, limit = 3) {
  return Array.from(new Set((row?.missing || [])
    .map(item => String(item?.name || item?.item || '').trim())
    .filter(Boolean)))
    .slice(0, limit);
}

function isQuickWeeklyRecipe(recipe) {
  const text = [
    recipe?.name,
    ...(recipe?.tags || []),
    recipe?.difficulty,
    recipe?.method
  ].join(' ');
  const minutes = Number(recipe?.timeMinutes || recipe?.time_minutes || recipe?.time);
  return (Number.isFinite(minutes) && minutes <= 25) || /快手|简单|easy|quick|15|20|分钟/.test(text);
}

function isLunchboxWeeklyRecipe(recipe) {
  const text = [
    recipe?.name,
    ...(recipe?.tags || []),
    recipe?.method
  ].join(' ');
  return /便当|带饭|饭盒|盖饭|炒饭|焖饭|饭/.test(text);
}

export function buildWeeklyMenuSuggestions(pack, inv, {
  mealCount = 4,
  dishesPerMeal = 2,
  priorities = {}
} = {}) {
  return getWeeklyCandidateRows(pack, inv, {
    mealCount,
    priorities,
    limit: getWeeklyTargetDishCount(mealCount, dishesPerMeal)
  });
}

function getWeeklyCandidateRows(pack, inv, {
  mealCount = 4,
  priorities = {},
  limit = 12
} = {}) {
  const resultLimit = Math.min(WEEKLY_MENU_MAX_DISHES, Math.max(1, Math.trunc(Number(limit) || Number(mealCount) || 4)));
  const plannedIds = new Set(getWeeklyPlanItems(pack).map(item => item.id));
  const ranked = rankRecipesForRecommendation(pack, inv, {
    ...getRecommendationUiContext(),
    includeNoMatch: true
  }).filter(row => row?.r && hasRecipeMethod(row.r));
  const pool = ranked.filter(row => !plannedIds.has(row.r.id));
  const rows = pool.length ? pool : ranked;
  return rows
    .map((row, index) => {
      const recipe = row.r;
      let score = row.score - index * 0.2;
      if (priorities.expiring) score += (row.expiringMatches || []).length * 42;
      if (priorities.inventory) score += (row.coverage || 0) * 24 + (row.matchCount || 0) * 4 - (row.missing || []).length * 5;
      if (priorities.quick && isQuickWeeklyRecipe(recipe)) score += 16;
      if (priorities.lunchbox && isLunchboxWeeklyRecipe(recipe)) score += 12;
      if (row.isFavorite) score += 10;
      return { recipe, row, score };
    })
    .sort((a, b) =>
      b.score - a.score ||
      (b.row.matchCount || 0) - (a.row.matchCount || 0) ||
      (a.row.missing || []).length - (b.row.missing || []).length ||
      a.recipe.name.localeCompare(b.recipe.name, 'zh-Hans-CN')
    )
    .slice(0, resultLimit);
}

function getWeeklyDaySuggestion(index) {
  return ['周一', '周二', '周三', '周四', '周五'][index] || '本周';
}

// 未来 7 天窗口的上限偏移（今天 = 0，最多到第 6 天）。
const WEEKLY_PLAN_MAX_OFFSET = 6;

// ISO 日期（YYYY-MM-DD）的星期几，按 UTC 计算避免时区把日期算错。0=周日…6=周六。
function isoDayOfWeek(iso) {
  const [y, m, d] = String(iso || '').split('-').map(Number);
  if (!y || !m || !d) return new Date().getDay();
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

// 解析 AI 的 daySuggestion → 未来 0..6 天偏移；无法识别返回 null。
// 「今天已过的星期」用 (目标 - 今天 + 7) % 7 折进未来 7 天内的同一天。
function parseWeeklyDayOffset(daySuggestion, today) {
  const text = String(daySuggestion || '');
  if (/今天|今日/.test(text)) return 0;
  if (/明天|明日/.test(text)) return 1;
  if (/后天/.test(text)) return 2;
  const map = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
  const m = text.match(/(?:周|星期|礼拜)\s*([一二三四五六日天])/);
  if (m) {
    const targetDow = map[m[1]];
    const offset = (targetDow - isoDayOfWeek(today) + 7) % 7;
    return offset <= WEEKLY_PLAN_MAX_OFFSET ? offset : null;
  }
  return null;
}

// 第一版日期排程：把一条本周建议落到未来 7 天内的具体日期（YYYY-MM-DD）。
// daySuggestion 能解析就用它，否则按 index 均匀铺开（index*2，封顶第 6 天）。
export function getWeeklyPlannedDate(meal, index, today = todayISO()) {
  const parsed = parseWeeklyDayOffset(meal?.daySuggestion, today);
  const offset = parsed === null
    ? Math.min(Math.max(0, Number(index) || 0) * 2, WEEKLY_PLAN_MAX_OFFSET)
    : parsed;
  return addDaysISO(today, offset);
}

// 简短日期 7/10（给结果卡片用，不占太多空间）。
function formatWeeklyShortDate(iso) {
  const [, m, d] = String(iso || '').split('-');
  return m && d ? `${Number(m)}/${Number(d)}` : '';
}

const WEEKLY_WEEKDAY_LABELS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

// 「计划到」下拉的选项文案：今天/明天/后天，其余用周几；都带简短日期，如「周五 7/10」。
function weeklyDateOptionLabel(iso, offset) {
  const rel = offset === 0 ? '今天'
    : offset === 1 ? '明天'
      : offset === 2 ? '后天'
        : WEEKLY_WEEKDAY_LABELS[isoDayOfWeek(iso)] || '本周';
  return `${rel} ${formatWeeklyShortDate(iso)}`;
}

// 未来 7 天（含今天）选项，选中 selectedDate。
function buildWeeklyDateOptions(selectedDate, today) {
  let html = '';
  for (let offset = 0; offset <= WEEKLY_PLAN_MAX_OFFSET; offset++) {
    const iso = addDaysISO(today, offset);
    const selected = iso === selectedDate ? ' selected' : '';
    html += `<option value="${escapeOptionAttr(iso)}"${selected}>${escapeHtml(weeklyDateOptionLabel(iso, offset))}</option>`;
  }
  return html;
}

function weeklyAddedKey(recipeId, date) {
  return `${recipeId}|${date}`;
}

function getWeeklyRecipeDifficulty(recipe) {
  return String(recipe?.difficulty || recipe?.difficultyLabel || '').trim() || '家常';
}

function getWeeklyRecipeTags(recipe, row) {
  const tags = [];
  if ((row?.missing || []).length === 0) tags.push('食材基本齐');
  if (isQuickWeeklyRecipe(recipe)) tags.push('快手');
  if (isLunchboxWeeklyRecipe(recipe)) tags.push('带饭');
  return tags.slice(0, 3);
}

function getWeeklyMealIndexForSuggestion(index, mealCount, targetDishCount) {
  const safeIndex = Math.max(0, Number(index) || 0);
  const safeMealCount = normalizeWeeklyMealCount(mealCount, 4);
  const firstPassCount = Math.min(safeMealCount, targetDishCount);
  return safeIndex < firstPassCount
    ? safeIndex + 1
    : (safeIndex % safeMealCount) + 1;
}

function getWeeklyRecipeProfile(recipe, row) {
  const ingredients = [
    ...(Array.isArray(recipe?.ingredients) ? recipe.ingredients : []),
    ...(Array.isArray(row?.list) ? row.list : [])
  ].map(item => String(item?.item || item?.name || item || '').trim()).filter(Boolean);
  const text = [recipe?.name, ...(recipe?.tags || []), ...ingredients].join(' ');
  const coreNames = ingredients
    .filter(name => classifyRecipeIngredient(name).role === 'core')
    .map(name => getCanonicalName(name) || name)
    .slice(0, 4);
  return {
    protein: /鸡|牛|猪|羊|肉|鱼|虾|蟹|蛋|豆腐|豆干|腐竹/.test(text),
    vegetable: /菜|椒|番茄|西兰花|花菜|瓜|豆角|豆芽|菌|菇|笋|萝卜|土豆|茄子|青菜|白菜|菠菜/.test(text),
    coreNames
  };
}

function weeklyPairScore(group, candidate, candidateIndex) {
  const profile = candidate.profile;
  let score = Number(candidate.score || 0) / 1000 - candidateIndex / 1000;
  if (!group.hasProtein && profile.protein) score += 12;
  if (!group.hasVegetable && profile.vegetable) score += 10;
  if (group.hasProtein && profile.protein) score -= 5;
  if (group.hasVegetable && profile.vegetable) score -= 4;
  if (profile.coreNames.some(name => group.coreNames.has(name))) score -= 8;
  return score;
}

function arrangeLocalWeeklySuggestions(localSuggestions, mealCount, dishesPerMeal) {
  const safeMealCount = normalizeWeeklyMealCount(mealCount, 4);
  const targetDishCount = getWeeklyTargetDishCount(safeMealCount, dishesPerMeal);
  const candidates = (localSuggestions || [])
    .filter(item => item?.recipe)
    .filter((item, index, rows) => rows.findIndex(row => row.recipe?.id === item.recipe?.id) === index)
    .slice(0, targetDishCount)
    .map(item => ({ ...item, profile: getWeeklyRecipeProfile(item.recipe, item.row) }));
  const groups = Array.from({ length: safeMealCount }, (_, index) => ({
    mealIndex: index + 1,
    entries: [],
    hasProtein: false,
    hasVegetable: false,
    coreNames: new Set()
  }));
  while (candidates.length && groups.reduce((count, group) => count + group.entries.length, 0) < targetDishCount) {
    const minSize = Math.min(...groups.map(group => group.entries.length));
    const eligibleGroups = groups.filter(group => group.entries.length === minSize);
    let chosen = null;
    for (const group of eligibleGroups) {
      candidates.forEach((candidate, candidateIndex) => {
        const score = weeklyPairScore(group, candidate, candidateIndex);
        if (!chosen || score > chosen.score) chosen = { group, candidate, candidateIndex, score };
      });
    }
    if (!chosen) break;
    chosen.group.entries.push(chosen.candidate);
    chosen.group.hasProtein ||= chosen.candidate.profile.protein;
    chosen.group.hasVegetable ||= chosen.candidate.profile.vegetable;
    chosen.candidate.profile.coreNames.forEach(name => chosen.group.coreNames.add(name));
    candidates.splice(chosen.candidateIndex, 1);
  }
  return groups.flatMap(group => group.entries.map(item => ({ ...item, mealIndex: group.mealIndex })));
}

export function createLocalWeeklyMenuEntries(localSuggestions, mealCount = 4, dishesPerMeal = 2, peopleCount = 2) {
  const servings = normalizeWeeklyPeopleCount(peopleCount, 2);
  return arrangeLocalWeeklySuggestions(localSuggestions, mealCount, dishesPerMeal).map(({ recipe, row, mealIndex }) => ({
    source: 'local',
    recipe,
    row,
    meal: {
      name: recipe.name,
      recipeId: recipe.id,
      mealIndex,
      mealLabel: `第${mealIndex}顿`,
      daySuggestion: getWeeklyDaySuggestion(mealIndex - 1),
      servings,
      reason: row?.reason || '本地菜谱匹配当前库存',
      difficulty: getWeeklyRecipeDifficulty(recipe),
      balanceTags: getWeeklyRecipeTags(recipe, row),
      uses: getWeeklyMatchedNames(row, 5),
      missing: getWeeklyMissingNames(row, 5)
    }
  }));
}

function findWeeklyRecipeForMeal(meal, pack) {
  const recipes = pack?.recipes || [];
  const recipeId = String(meal?.recipeId || '').trim();
  const name = String(meal?.name || '').trim();
  return recipes.find(recipe => recipe.id === recipeId)
    || recipes.find(recipe => recipe.name === name)
    || recipes.find(recipe => getCanonicalName(recipe.name || '') === getCanonicalName(name))
    || null;
}

export function normalizeAiWeeklyMenuEntries(plan, pack, { mealCount = 4, dishesPerMeal = 2 } = {}) {
  const safeMealCount = normalizeWeeklyMealCount(mealCount, 4);
  const targetDishCount = getWeeklyTargetDishCount(safeMealCount, dishesPerMeal);
  const daySuggestionByMeal = new Map();
  return (plan?.meals || []).slice(0, WEEKLY_MENU_MAX_DISHES).map((meal, index) => {
    const recipe = findWeeklyRecipeForMeal(meal, pack);
    const requestedMealIndex = Math.trunc(Number(meal?.mealIndex));
    const mealIndex = Number.isInteger(requestedMealIndex) && requestedMealIndex >= 1 && requestedMealIndex <= safeMealCount
      ? requestedMealIndex
      : getWeeklyMealIndexForSuggestion(index, safeMealCount, targetDishCount);
    const daySuggestion = daySuggestionByMeal.get(mealIndex) || meal.daySuggestion || getWeeklyDaySuggestion(mealIndex - 1);
    daySuggestionByMeal.set(mealIndex, daySuggestion);
    return {
      source: 'ai',
      recipe,
      row: null,
      meal: {
        ...meal,
        mealIndex,
        mealLabel: `第${mealIndex}顿`,
        recipeId: recipe?.id || String(meal.recipeId || '').trim(),
        daySuggestion,
        balanceTags: Array.isArray(meal.balanceTags) ? meal.balanceTags : [],
        uses: Array.isArray(meal.uses) ? meal.uses : [],
        missing: Array.isArray(meal.missing) ? meal.missing : []
      }
    };
  });
}

function getWeeklyInventoryPayload(inv) {
  return (inv || [])
    .filter(isInventoryAvailable)
    .map(item => ({
      name: item.name || '',
      qty: item.qty ?? '',
      unit: item.unit || '',
      expiring: isExpiryTracked(item) && remainingDays(item) <= 3,
      remainingDays: isExpiryTracked(item) ? remainingDays(item) : null
    }))
    .filter(item => item.name)
    .slice(0, 40);
}

function getWeeklyExpiringPayload(inv) {
  return getExpiringItems(inv).map(item => ({
    name: item.name || '',
    qty: item.qty ?? '',
    unit: item.unit || '',
    remainingDays: remainingDays(item)
  }));
}

function getWeeklyFavoriteRecipesPayload(pack) {
  const favoriteIds = new Set(S.load(S.keys.favorite_recipes, []));
  return (pack?.recipes || [])
    .filter(recipe => favoriteIds.has(recipe.id) || isFavoriteRecipe(recipe.id))
    .slice(0, 10)
    .map(recipe => ({ id: recipe.id, name: recipe.name, difficulty: getWeeklyRecipeDifficulty(recipe) }));
}

function getWeeklyExistingPlanPayload(pack) {
  return getWeeklyPlanItems(pack).map(item => ({
    date: item.date,
    recipeId: item.recipe?.id || item.id || '',
    name: item.recipe?.name || '',
    servings: Number(item.servings || 1) || 1
  }));
}

function getWeeklyCandidatePayload(pack, inv, mealCount, dishesPerMeal, priorities) {
  return getWeeklyCandidateRows(pack, inv, {
    mealCount,
    priorities,
    limit: getWeeklyTargetDishCount(mealCount, dishesPerMeal)
  }).map(({ recipe, row }) => ({
    recipeId: recipe.id,
    name: recipe.name,
    difficulty: getWeeklyRecipeDifficulty(recipe),
    tags: getWeeklyRecipeTags(recipe, row),
    uses: getWeeklyMatchedNames(row, 5),
    missing: getWeeklyMissingNames(row, 5),
    reason: row?.reason || ''
  }));
}

export function buildAiWeeklyMenuPlanPayload(pack, inv, {
  mealCount,
  dishesPerMeal,
  dishesPerMealLocked = false,
  peopleCount,
  priorities = {},
  userRequest = ''
}) {
  const safeMealCount = normalizeWeeklyMealCount(mealCount, 4);
  const safeDishesPerMeal = normalizeWeeklyDishesPerMeal(dishesPerMeal, 2);
  return {
    mealsCount: safeMealCount,
    dishesPerMeal: safeDishesPerMeal,
    dishesPerMealLocked: Boolean(dishesPerMealLocked),
    targetDishCount: getWeeklyTargetDishCount(safeMealCount, safeDishesPerMeal),
    peopleCount: normalizeWeeklyPeopleCount(peopleCount, 2),
    preferences: {
      useExpiring: Boolean(priorities.expiring),
      useInventory: Boolean(priorities.inventory),
      quickMeals: Boolean(priorities.quick),
      lunchboxFriendly: Boolean(priorities.lunchbox)
    },
    userRequest,
    inventory: getWeeklyInventoryPayload(inv),
    expiringItems: getWeeklyExpiringPayload(inv),
    favoriteRecipes: getWeeklyFavoriteRecipesPayload(pack),
    localCandidateRecipes: getWeeklyCandidatePayload(pack, inv, safeMealCount, safeDishesPerMeal, priorities),
    existingPlan: getWeeklyExistingPlanPayload(pack)
  };
}

function getCoreWeeklyShoppingNames(names = []) {
  return Array.from(new Set((names || [])
    .map(name => String(name || '').trim())
    .filter(name => name && classifyRecipeIngredient(name).role === 'core')
    .map(name => getCanonicalName(name) || name)
    .filter(Boolean)));
}

function addWeeklyMenuMissingNamesToShopping(names, { source = '本周菜单', remark = '本周菜单', planCount = 0 } = {}) {
  const existing = new Set(loadShoppingItems()
    .filter(item => item && !item.done)
    .map(item => getCanonicalName(item.name || ''))
    .filter(Boolean));
  const seen = new Set(existing);
  let added = 0;
  let skippedExisting = 0;
  for (const name of getCoreWeeklyShoppingNames(names)) {
    const canonical = getCanonicalName(name);
    if (!canonical) continue;
    if (seen.has(canonical)) {
      skippedExisting += 1;
      continue;
    }
    seen.add(canonical);
    addShoppingItem(name, '', guessKitchenUnit(name) || '', source, remark);
    added += 1;
  }
  return { added, skippedExisting, planCount };
}

function addWeeklyMenuEntriesMissingToShopping(entries, peopleCount = 2) {
  const names = [];
  for (const entry of entries || []) {
    (entry?.meal?.missing || []).forEach(name => names.push(name));
  }
  const people = normalizeWeeklyPeopleCount(peopleCount, 2);
  return addWeeklyMenuMissingNamesToShopping(names, {
    source: `本周菜单 · ${people} 人份`,
    remark: 'AI 本周菜单缺货',
    planCount: (entries || []).length
  });
}

// 只更新目标日期那条 plan row 的 servings（升级为按 date 定位，避免误改今天/别的日期）。
export function updateWeeklyPlanServings(recipeId, servings, date = todayISO()) {
  const safeServings = normalizeWeeklyServingCount(servings, 2);
  const today = todayISO();
  const targetDate = date || today;
  const plan = S.load(S.keys.plan, []);
  const item = [...plan].reverse().find(entry => entry && entry.id === recipeId && isPlanRowOnDate(entry, targetDate, today));
  if (!item) return false;
  if (Number(item.servings || 1) === safeServings) return false;
  item.servings = safeServings;
  S.save(S.keys.plan, plan);
  return true;
}

function addWeeklyPlanShortagesToShopping(pack, inv) {
  const existing = new Set(loadShoppingItems()
    .filter(item => item && !item.done)
    .map(item => getCanonicalName(item.name || ''))
    .filter(Boolean));
  const seen = new Set(existing);
  let added = 0;
  let skippedExisting = 0;
  const planItems = getWeeklyPlanItems(pack);
  for (const item of planItems) {
    const recipe = item.recipe;
    const missing = getPlanMissingItems(recipe, pack, inv);
    for (const miss of missing) {
      const name = String(miss.name || miss.item || '').trim();
      const canonical = getCanonicalName(name);
      if (!canonical) continue;
      if (seen.has(canonical)) {
        skippedExisting += 1;
        continue;
      }
      seen.add(canonical);
      addShoppingItem(
        name,
        miss.qty || '',
        miss.unit || guessKitchenUnit(name) || '',
        '本周菜单缺货',
        `菜谱缺货：${recipe.name || '本周菜单'}`
      );
      added += 1;
    }
  }
  return { added, skippedExisting, planCount: planItems.length };
}

function showWeeklyShoppingResult(result, { onRoute = () => {} } = {}) {
  if (result.added > 0) {
    showToast(`已补 ${result.added} 样待买`, { tone: 'success' });
    onRoute();
    return;
  }
  if (!result.planCount) {
    showToast('先规划几顿，再补齐待买', { tone: 'info' });
    return;
  }
  showToast(result.skippedExisting ? '待买清单已包含这些食材' : '本周菜单暂不缺核心食材', { tone: 'info' });
}
