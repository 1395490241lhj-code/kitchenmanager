/*
 * src/components/menu-plan.js
 *
 * 「菜单计划」组件——从采购页迁至首页 Dashboard。
 * 管理今日 / 未来 3 天的计划菜谱（份数调整、移除）。
 * currentPlanRange 由本模块持有，并通过 getPlanRange() 暴露给购物页的「菜谱缺货」计算复用。
 */
import { S, todayISO } from '../storage.js?v=204';
import { explodeCombinedItems, guessKitchenUnit, getCanonicalName } from '../ingredients.js?v=204';
import { analyzeRecipeInventory, markRecipeCookedKeepPlan } from '../recommendations.js?v=204';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=204';
import { computeCookDeductions, applyCookCalibration } from '../inventory.js?v=204';
import { showCalibrationModal } from './modal.js?v=204';
import { escapeHtml } from './status.js?v=204';

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

// 把若干计划菜谱的食材（按份数缩放）聚合成一份去重清单（计件量相加），供批量预扣减。
function aggregateScaledItems(targets, pack) {
  const map = new Map();
  for (const t of targets) {
    const recipe = (pack.recipes || []).find(r => r.id === t.id);
    if (!recipe) continue;
    for (const it of scaleRecipeItems(pack, recipe, t.servings || 1)) {
      if (!it || !it.item) continue;
      const key = getCanonicalName(it.item) || it.item;
      const qty = Number(it.qty);
      if (map.has(key)) {
        const e = map.get(key);
        if (Number.isFinite(qty)) e.qty = (Number.isFinite(e.qty) ? e.qty : 0) + qty;
      } else {
        map.set(key, { item: it.item, qty: Number.isFinite(qty) ? qty : it.qty, unit: it.unit });
      }
    }
  }
  return [...map.values()];
}

// 将目标计划项标记为「已做完」（保留在计划里作为成就），并记录烹饪活动。
function markPlansCooked(targets) {
  const today = todayISO();
  const plans = S.load(S.keys.plan, []);
  let changed = false;
  for (const t of targets) {
    const row = plans.find(x => x.id === t.id && (x.date || today) === (t.date || today));
    if (row && !row.isCooked) {
      row.isCooked = true;
      row.cookedAt = new Date().toISOString();
      changed = true;
    }
  }
  if (changed) S.save(S.keys.plan, plans);
  targets.forEach(t => markRecipeCookedKeepPlan(t.id));
}

// 做菜闭环：聚合食材 → 双轨预扣减 → 主厨校准舱 → 写库 + 标记已完成。
function cookPlans(targets, pack, inv, { onRoute = () => {}, title } = {}) {
  if (!targets.length) { createMenuPlanToast('今天没有待做的菜'); return; }
  const heading = title || (targets.length === 1
    ? ((pack.recipes || []).find(r => r.id === targets[0].id)?.name || '这道菜')
    : `今日 ${targets.length} 道菜`);
  const predictions = computeCookDeductions(aggregateScaledItems(targets, pack), inv);
  if (!predictions.length) {
    markPlansCooked(targets);
    createMenuPlanToast('✓ 已记录做完');
    onRoute();
    return;
  }
  showCalibrationModal(heading, predictions, (calibrations) => {
    applyCookCalibration(inv, calibrations);
    markPlansCooked(targets);
    createMenuPlanToast(targets.length > 1 ? `✓ ${targets.length} 道菜已更新冰箱` : '✓ 冰箱已更新');
    onRoute();
  }, () => {});
}

/**
 * 「✓ 全部做完」批量按钮：一次性处理今天所有未完成的计划菜谱。
 * 无待做时自动隐藏。
 */
export function renderCookAllButton(pack, { onRoute = () => {}, inventory = [] } = {}) {
  const today = todayISO();
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'menu-plan-cookall';
  btn.textContent = '✓ 全部做完';
  const hasTodo = S.load(S.keys.plan, []).some(p =>
    (p.date || today) === today && !p.isCooked && (pack.recipes || []).some(r => r.id === p.id));
  if (!hasTodo) btn.style.display = 'none';
  btn.onclick = () => {
    const targets = S.load(S.keys.plan, []).filter(p => (p.date || today) === today && !p.isCooked);
    cookPlans(targets, pack, inventory, { onRoute, title: `今日 ${targets.length} 道菜` });
  };
  return btn;
}

export function renderMenuPlan(pack, { onRoute = () => {}, hideHeader = false, inventory = [] } = {}) {
  const planCard = document.createElement('div');
  planCard.className = 'card shopping-plan-card menu-plan-card';
  if (!hideHeader) {
    const head = document.createElement('div');
    head.className = 'shopping-card-head menu-plan-head';
    head.innerHTML = '<h3 class="menu-plan-title">📅 菜单计划</h3>';
    const headActions = document.createElement('div');
    headActions.className = 'menu-plan-head-actions';
    headActions.appendChild(renderCookAllButton(pack, { onRoute, inventory }));
    headActions.appendChild(renderPlanRangeSelect({ onRoute }));
    head.appendChild(headActions);
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
      const isCooked = !!item.isCooked;
      row.className = `shopping-plan-row menu-plan-row${isCooked ? ' is-cooked' : ''}`;
      const label = getDayLabel(item.date);
      const shortage = isCooked ? [] : getRecipeShortage(recipe, pack, inventory, item.servings || 1);
      const shortageBadge = shortage.length
        ? `<button type="button" class="menu-shortage-pill" aria-label="查看 ${escapeHtml(recipe.name)} 缺少的食材">🛒 缺 ${shortage.length} 项</button>`
        : '';
      const cookBtnHtml = isCooked
        ? '<button type="button" class="menu-cook-btn is-done" disabled>已完成</button>'
        : '<button type="button" class="menu-cook-btn">🍳 做好了</button>';
      row.innerHTML = `
        <div class="menu-row-left">
          <span class="shopping-plan-name">
            <span class="shopping-plan-recipe-title">${escapeHtml(recipe.name)} <small class="shopping-plan-date-label">(${label})</small></span>
            ${shortageBadge}
          </span>
          <label class="shopping-servings menu-row-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${item.servings || 1}"${isCooked ? ' disabled' : ''}></label>
        </div>
        <div class="menu-row-actions">
          ${cookBtnHtml}
          <button type="button" class="menu-remove-btn" aria-label="移除" title="移除">✕</button>
        </div>
      `;
      const shortageBtn = row.querySelector('.menu-shortage-pill');
      if (shortageBtn) {
        shortageBtn.onclick = event => {
          event.preventDefault();
          event.stopPropagation();
          showShortageModal(recipe, shortage);
        };
      }
      const servingsInput = row.querySelector('.menu-row-servings input');
      if (servingsInput) {
        servingsInput.onchange = event => {
          const plans = S.load(S.keys.plan, []);
          const target = plans.find(x => x.id === item.id && (x.date || today) === (item.date || today));
          if (target) {
            target.servings = +event.target.value || 1;
            S.save(S.keys.plan, plans);
            onRoute();
          }
        };
      }
      const cookBtn = row.querySelector('.menu-cook-btn');
      if (cookBtn && !isCooked) {
        cookBtn.onclick = () => cookPlans([item], pack, inventory, { onRoute, title: recipe.name });
      }
      row.querySelector('.menu-remove-btn').onclick = () => {
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
