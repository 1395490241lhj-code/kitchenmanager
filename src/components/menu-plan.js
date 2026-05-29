/*
 * src/components/menu-plan.js
 *
 * 「菜单计划」组件——从采购页迁至首页 Dashboard。
 * 管理今日 / 未来 3 天的计划菜谱（份数调整、移除）。
 * currentPlanRange 由本模块持有，并通过 getPlanRange() 暴露给购物页的「菜谱缺货」计算复用。
 */
import { S, todayISO } from '../storage.js?v=171';
import { escapeHtml } from './status.js?v=171';

let currentPlanRange = 'today';
export function getPlanRange() { return currentPlanRange; }

export function renderMenuPlan(pack, { onRoute = () => {} } = {}) {
  const planCard = document.createElement('div');
  planCard.className = 'card shopping-plan-card menu-plan-card';
  planCard.innerHTML = `
    <div class="shopping-card-head menu-plan-head">
      <h3 class="menu-plan-title">📅 菜单计划</h3>
      <select id="planRangeSelect" class="menu-plan-range">
        <option value="today">只看今天</option>
        <option value="3days">未来 3 天</option>
      </select>
    </div>
  `;
  const rangeSelect = planCard.querySelector('#planRangeSelect');
  rangeSelect.value = currentPlanRange;
  rangeSelect.onchange = (e) => { currentPlanRange = e.target.value; onRoute(); };

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
    const empty = document.createElement('p');
    empty.className = 'small';
    empty.textContent = '该时间段暂未添加菜谱。';
    planList.appendChild(empty);
  } else {
    for (const item of filteredPlans) {
      const recipe = (pack.recipes || []).find(r => r.id === item.id);
      if (!recipe) continue;
      const row = document.createElement('div');
      row.className = 'shopping-plan-row';
      const label = getDayLabel(item.date);
      row.innerHTML = `<span class="shopping-plan-name">${escapeHtml(recipe.name)} <small style="color:var(--text-secondary);">(${label})</small></span><label class="shopping-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${item.servings || 1}"></label><a class="btn small" href="javascript:void(0)">移除</a>`;
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
