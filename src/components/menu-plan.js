/*
 * src/components/menu-plan.js
 *
 * 「菜单计划」组件——从采购页迁至首页 Dashboard。
 * 管理今日 / 未来 3 天的计划菜谱（份数调整、移除）。
 * currentPlanRange 由本模块持有，并通过 getPlanRange() 暴露给购物页的「菜谱缺货」计算复用。
 */
import { S, todayISO } from '../storage.js?v=199';
import { explodeCombinedItems, guessKitchenUnit } from '../ingredients.js?v=199';
import { analyzeRecipeInventory } from '../recommendations.js?v=199';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=199';
import { escapeHtml } from './status.js?v=199';

let currentPlanRange = 'today';
export function getPlanRange() { return currentPlanRange; }

export function renderPlanRangeSelect({ onRoute = () => {}, id = 'planRangeSelect' } = {}) {
  const select = document.createElement('select');
  select.id = id;
  select.className = 'menu-plan-range menu-plan-range-compact';
  select.innerHTML = `
    <option value="today">只看今天</option>
    <option value="3days">未来 3 天</option>
  `;
  select.value = currentPlanRange;
  select.onchange = (e) => {
    currentPlanRange = e.target.value;
    onRoute();
  };
  return select;
}

function scaleRecipeItems(pack, recipe, servings = 1) {
  const rawItems = explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  return rawItems.map(item => {
    const qty = item.qty;
    const numericQty = qty === '' || qty === null || qty === undefined ? NaN : Number(qty);
    if (!Number.isFinite(numericQty)) return { ...item };
    return {
      ...item,
      qty: Math.round(numericQty * (servings || 1) * 100) / 100
    };
  });
}

function getRecipeShortage(recipe, pack, inv, servings = 1) {
  const scaledItems = scaleRecipeItems(pack, recipe, servings);
  if (!scaledItems.length) return [];
  return analyzeRecipeInventory(recipe, pack, inv || [], scaledItems).missing;
}

function formatMissingQty(item) {
  const rawQty = item.missingQty ?? item.qty;
  const qty = Number(rawQty);
  if (Number.isFinite(qty) && qty > 0) {
    return Math.round(qty * 100) / 100;
  }
  return rawQty || '';
}

function formatMissingAmount(item) {
  const qty = formatMissingQty(item);
  const unit = item.unit || guessKitchenUnit(item.item || item.name) || '';
  if (qty && unit) return `${qty}${unit}`;
  return qty || unit || '按菜谱适量';
}

function createMenuPlanToast(message) {
  const oldToast = document.querySelector('.km-toast');
  if (oldToast) oldToast.remove();
  const toast = document.createElement('div');
  toast.className = 'km-toast';
  toast.textContent = message;
  document.body.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('is-visible'));
  window.setTimeout(() => {
    toast.classList.remove('is-visible');
    window.setTimeout(() => toast.remove(), 220);
  }, 1600);
}

function showShortageModal(recipe, missing) {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';

  const panel = document.createElement('div');
  panel.className = 'km-modal-content menu-shortage-modal';

  const header = document.createElement('div');
  header.className = 'km-modal-header';
  header.innerHTML = `
    <span class="km-modal-title">制作「${escapeHtml(recipe.name)}」还需要：</span>
    <button type="button" class="km-modal-close" aria-label="关闭">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
      </svg>
    </button>
  `;

  const body = document.createElement('div');
  body.className = 'km-modal-body menu-shortage-body';
  body.innerHTML = `
    <p class="menu-shortage-subtitle">按当前库存和这道菜的计划份数估算，买菜前可以先确认一下。</p>
    <div class="menu-shortage-list">
      ${missing.map((item, index) => `
        <div class="menu-shortage-row${index === missing.length - 1 ? ' is-last' : ''}">
          <span class="menu-shortage-name">${escapeHtml(item.item || item.name)}</span>
          <span class="menu-shortage-amount">${escapeHtml(formatMissingAmount(item))}</span>
        </div>
      `).join('')}
    </div>
    <div class="km-modal-actions menu-shortage-actions">
      <button type="button" class="btn menu-shortage-add-btn" id="addShortageToShopping">[+] 一键加入购物清单</button>
    </div>
  `;

  panel.appendChild(header);
  panel.appendChild(body);
  overlay.appendChild(panel);
  document.body.appendChild(overlay);

  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
    panel.style.opacity = '0';
    panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
    overlay.classList.add('closing');
    window.setTimeout(() => overlay.remove(), 220);
  };

  header.querySelector('.km-modal-close').onclick = close;
  overlay.onclick = event => { if (event.target === overlay) close(); };
  body.querySelector('#addShortageToShopping').onclick = () => {
    missing.forEach(item => {
      const name = item.item || item.name;
      addShoppingItem(name, formatMissingQty(item), item.unit || guessKitchenUnit(name), `菜谱缺货：${recipe.name}`);
    });
    close();
    const metric = document.querySelector('#metricShopping .home-metric-num');
    if (metric) metric.textContent = String(loadShoppingItems().filter(item => !item.done).length);
    createMenuPlanToast('✓ 已加入清单');
  };

  requestAnimationFrame(() => overlay.classList.add('open'));
}

export function renderMenuPlan(pack, { onRoute = () => {}, hideHeader = false, inventory = [] } = {}) {
  const planCard = document.createElement('div');
  planCard.className = 'card shopping-plan-card menu-plan-card';
  if (!hideHeader) {
    const head = document.createElement('div');
    head.className = 'shopping-card-head menu-plan-head';
    head.innerHTML = '<h3 class="menu-plan-title">📅 菜单计划</h3>';
    head.appendChild(renderPlanRangeSelect({ onRoute }));
    planCard.appendChild(head);
  }

  const today = todayISO();
  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate); tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate); dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const getDayLabel = (dateStr) => {
    const d = dateStr || today;
    if (d === today) return '今天';
    if (d === tomorrowISO) return '明天';
    if (d === dayAfterISO) return '后天';
    return d;
  };

  const plan = S.load(S.keys.plan, []);
  const filteredPlans = plan.filter(item => {
    const d = item.date || today;
    if (currentPlanRange === 'today') return d === today;
    if (currentPlanRange === '3days') return d === today || d === tomorrowISO || d === dayAfterISO;
    return true;
  });

  const planList = document.createElement('div');
  planList.className = 'shopping-plan-list';
  if (!filteredPlans.length) {
    const empty = document.createElement('div');
    empty.className = 'menu-plan-empty';
    empty.innerHTML = `
      <div class="menu-plan-empty-icon" aria-hidden="true">🍽️</div>
      <div class="menu-plan-empty-title">该时间段暂未添加菜谱</div>
      <p>可以从推荐菜谱里加入今日计划。</p>
    `;
    planList.appendChild(empty);
  } else {
    for (const item of filteredPlans) {
      const recipe = (pack.recipes || []).find(r => r.id === item.id);
      if (!recipe) continue;
      const row = document.createElement('div');
      row.className = 'shopping-plan-row';
      const label = getDayLabel(item.date);
      const shortage = getRecipeShortage(recipe, pack, inventory, item.servings || 1);
      const shortageBadge = shortage.length
        ? `<button type="button" class="menu-shortage-pill" aria-label="查看 ${escapeHtml(recipe.name)} 缺少的食材">🛒 缺 ${shortage.length} 项</button>`
        : '';
      row.innerHTML = `<span class="shopping-plan-name"><span class="shopping-plan-recipe-title">${escapeHtml(recipe.name)} <small class="shopping-plan-date-label">(${label})</small></span>${shortageBadge}</span><label class="shopping-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${item.servings || 1}"></label><a class="btn small" href="javascript:void(0)">移除</a>`;
      const shortageBtn = row.querySelector('.menu-shortage-pill');
      if (shortageBtn) {
        shortageBtn.onclick = event => {
          event.preventDefault();
          event.stopPropagation();
          showShortageModal(recipe, shortage);
        };
      }
      row.querySelector('input').onchange = event => {
        const plans = S.load(S.keys.plan, []);
        const target = plans.find(x => x.id === item.id && (x.date || today) === (item.date || today));
        if (target) {
          target.servings = +event.target.value || 1;
          S.save(S.keys.plan, plans);
          onRoute();
        }
      };
      row.querySelector('.btn').onclick = () => {
        const plans = S.load(S.keys.plan, []);
        const index = plans.findIndex(x => x.id === item.id && (x.date || today) === (item.date || today));
        if (index >= 0) {
          plans.splice(index, 1);
          S.save(S.keys.plan, plans);
          onRoute();
        }
      };
      planList.appendChild(row);
    }
  }
  planCard.appendChild(planList);
  return planCard;
}
