import { isIngredientMatch, isInventoryAvailable, loadInventory } from '../inventory.js?v=236';
import { addMissingRecipeIngredientsToShopping, addRecipeToPlan, getRecipeCoreIngredients } from '../recommendations.js?v=236';
import { STORAGE_WRITE_FAILED_MESSAGE } from '../storage.js?v=236';
import { escapeHtml, showToast } from './status.js?v=236';

function uniqueMissingItems(items = []) {
  const seen = new Set();
  const out = [];
  for (const item of items || []) {
    const name = String(item?.item || item?.name || '').trim();
    if (!name || seen.has(name)) continue;
    seen.add(name);
    out.push({ ...item, item: name, name });
  }
  return out;
}

export function getPlanMissingItems(recipe, pack, inv, { fallbackItems = null, missing = null } = {}) {
  if (!recipe) return [];
  return uniqueMissingItems(Array.isArray(missing)
    ? missing
    : getMissingCoreItemsByPresence(recipe, pack, inv, fallbackItems));
}

export function formatMissingNames(items, limit = 5) {
  const names = uniqueMissingItems(items).map(item => item.name || item.item);
  const head = names.slice(0, limit).join('、');
  return `${head}${names.length > limit ? '等' : ''}`;
}

export function showMissingPlanConfirm({ recipeName = '这道菜', planLabel = '计划', missing = [] } = {}) {
  return new Promise(resolve => {
    if (typeof document === 'undefined') {
      resolve(false);
      return;
    }
    const overlay = document.createElement('div');
    overlay.className = 'km-modal-overlay plan-missing-overlay open';
    overlay.innerHTML = `
      <div class="km-modal-content plan-missing-modal" role="dialog" aria-modal="true" aria-labelledby="planMissingTitle">
        <div class="km-modal-header">
          <span class="km-modal-title" id="planMissingTitle">还缺几样食材</span>
        </div>
        <div class="km-modal-body plan-missing-body">
          <p class="km-modal-subtitle">「${escapeHtml(recipeName)}」已经加入${escapeHtml(planLabel)}。下面这些可以顺手加入买菜清单。</p>
          <div class="plan-missing-list">${uniqueMissingItems(missing).map(item => `<span>${escapeHtml(item.name || item.item)}</span>`).join('')}</div>
          <p class="km-modal-note">取消后也会保留计划，可以稍后再处理。</p>
        </div>
        <div class="km-modal-actions plan-missing-actions">
          <button type="button" class="btn km-action-weak" id="planMissingSkip">暂时不用</button>
          <button type="button" class="btn ok km-action-primary" id="planMissingAdd">加入买菜清单</button>
        </div>
      </div>
    `;
    const close = value => {
      overlay.classList.add('closing');
      setTimeout(() => overlay.remove(), 180);
      resolve(value);
    };
    overlay.querySelector('#planMissingAdd').onclick = () => close(true);
    overlay.querySelector('#planMissingSkip').onclick = () => close(false);
    overlay.onclick = event => {
      if (event.target === overlay) close(false);
    };
    document.body.appendChild(overlay);
    overlay.querySelector('#planMissingAdd')?.focus();
  });
}

export async function addRecipeToPlanWithMissingCheck(recipeId, pack, inv, options = {}) {
  const {
    date = null,
    recipe = null,
    fallbackItems = null,
    missing = null,
    planLabel = '计划',
    confirmMissing = showMissingPlanConfirm,
    onPlanAdded = null,
    onRoute = null,
    source = '',
    toast = true
  } = options;

  let added;
  try {
    added = addRecipeToPlan(recipeId, date);
  } catch (err) {
    if (err && err.code === 'STORAGE_WRITE_FAILED') {
      if (toast) showToast(STORAGE_WRITE_FAILED_MESSAGE, { tone: 'error' });
      return { added: false, recipe: null, missing: [], shoppingAddedCount: 0, confirmedShopping: false, source };
    }
    throw err;
  }
  const planPack = normalizePlanPack(recipe, pack, fallbackItems);
  const planInv = Array.isArray(inv) ? inv : loadInventory();
  const targetRecipe = recipe || (planPack?.recipes || []).find(r => r.id === recipeId) || null;
  if (typeof onPlanAdded === 'function') onPlanAdded(added);

  const result = {
    added,
    recipe: targetRecipe,
    missing: [],
    shoppingAddedCount: 0,
    confirmedShopping: false,
    source
  };

  if (!added || !targetRecipe) {
    if (toast) showToast(added ? `已加入${planLabel}` : '已在今天', { tone: added ? 'success' : 'info' });
    if (typeof onRoute === 'function') onRoute(result);
    return result;
  }

  result.missing = getPlanMissingItems(targetRecipe, planPack, planInv, { fallbackItems, missing });
  if (!result.missing.length) {
    if (toast) showToast(`已加入${planLabel}`, { tone: 'success' });
    if (typeof onRoute === 'function') onRoute(result);
    return result;
  }

  const confirmed = await confirmMissing({
    recipe: targetRecipe,
    recipeName: targetRecipe.name || '这道菜',
    planLabel,
    missing: result.missing
  });
  result.confirmedShopping = !!confirmed;

  if (confirmed) {
    result.shoppingAddedCount = addMissingRecipeIngredientsToShopping(targetRecipe, planPack, planInv, fallbackItems, result.missing);
    if (toast) showToast(`已加入${planLabel}，缺的食材已加入买菜清单`, { tone: 'success' });
  } else if (toast) {
    showToast(`已加入${planLabel}，缺的食材可稍后处理`, { tone: 'info' });
  }

  if (typeof onRoute === 'function') onRoute(result);
  return result;
}

function normalizePlanPack(recipe, pack, fallbackItems = null) {
  if (pack) return pack;
  if (!recipe) return null;
  return {
    recipes: [recipe],
    recipe_ingredients: {
      [recipe.id]: Array.isArray(fallbackItems) ? fallbackItems : []
    }
  };
}

function getMissingCoreItemsByPresence(recipe, pack, inv, fallbackItems = null) {
  const corePack = normalizePlanPack(recipe, pack, fallbackItems);
  // 复用推荐 / 买菜同一套核心食材定义（getRecipeCoreIngredients：菜名先归一化再统一分类），
  // 让加入计划弹窗与推荐卡的「核心食材」口径、显示名、写入买菜的 qty/unit 保持一致。
  // 仍保持「只看有没有、不因数量不足打扰」的语义——这是刻意设计（见本目录测试），故只做存在性过滤。
  const coreItems = uniqueMissingItems(getRecipeCoreIngredients(recipe, corePack));
  const inventory = Array.isArray(inv) ? inv : loadInventory();
  return coreItems.filter(item => {
    const name = item.item || item.name;
    return !inventory.some(entry => isInventoryAvailable(entry) && isIngredientMatch(name, entry.name));
  });
}
