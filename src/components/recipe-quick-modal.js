/*
 * src/components/recipe-quick-modal.js —— 菜谱「快速详情」底部弹窗（Bottom Sheet 风格）
 *
 * 用途：移动端紧凑菜谱卡片被点击后，先打开此轻量弹窗（不跳转页面、不改 hash），
 *      展示比卡片更完整的信息 + 主要操作。「查看完整菜谱」才跳转 #recipe:id。
 *
 * 设计约束：
 *  - 不改菜谱数据结构 / localStorage key；只读 pack + overlay，写操作全部复用既有函数。
 *  - 复用 .km-modal-overlay / .km-modal-content 既有玻璃质感 + 动画（与待买速记等弹窗一致）。
 *  - 关闭弹窗不触发列表重渲染，保证搜索 / 分类 / 滚动状态不丢。
 */
import { S, todayISO } from '../storage.js?v=235';
import { buildCatalog, explodeCombinedItems } from '../ingredients.js?v=235';
import { splitIngredients } from '../utils/recipe-sanitizer.js?v=235';
import { loadInventory } from '../inventory.js?v=235';
import {
  calculateStockStatus,
  getMissingRecipeIngredients,
  addMissingRecipeIngredientsToShopping,
  isFavoriteRecipe,
  toggleFavoriteRecipe,
} from '../recommendations.js?v=235';
import { addRecipeToPlanWithMissingCheck } from './plan-missing-check.js?v=235';
import { loadOverlay } from '../backup.js?v=235';
import { escapeHtml } from './status.js?v=235';
import { isPlanRowOnDate } from '../plan-selectors.js?v=235';

const CLOSE_SVG = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;

function statusBadgeHtml(statusData, missingCount) {
  if (!statusData) return '';
  if (statusData.status === 'ok') return `<span class="kchip ok">✅ 食材够做</span>`;
  if (statusData.status === 'partial') {
    if (missingCount === 0) return `<span class="kchip warn">⚠️ 需确认</span>`;
    if (missingCount <= 2) return `<span class="kchip warn">⚠️ 只差 ${missingCount} 样</span>`;
    return `<span class="kchip bad">缺 ${missingCount} 样</span>`;
  }
  return `<span class="kchip bad">缺食材</span>`;
}

/**
 * 打开菜谱快速详情弹窗。
 * @param {Object}   recipe  pack.recipes 里的菜谱对象（含 id / name / tags / method…）
 * @param {Object}   pack    数据包（recipes / recipe_ingredients）
 * @param {Array}    [inv]   当前库存（不传则按 pack 现算）
 * @param {Object}   [opts]
 * @param {Function} [opts.onRoute] 仅在「收藏切换」时调用以同步外部卡片状态；关闭弹窗不会调用。
 */
export function showRecipeQuickModal(recipe, pack, inv = null, { onRoute = () => {} } = {}) {
  if (!recipe || !pack) return;
  const id = recipe.id;
  const isCreative = String(id).startsWith('creative-');

  // 合并 overlay（自定义菜谱 / AI 草稿的做法可能只在 overlay 里），不改原对象。
  const overlay = loadOverlay();
  // creative-* 是一次性推荐占位，不读取旧 overlay，避免新推荐串到旧草稿做法。
  const ovRecipe = isCreative ? null : (overlay.recipes || {})[id];
  const r = ovRecipe ? { ...recipe, ...ovRecipe, method: ovRecipe.method || recipe.method || '' } : recipe;

  const inventory = inv || loadInventory(buildCatalog(pack));
  const items = explodeCombinedItems((pack.recipe_ingredients || {})[id] || []);
  const statusData = calculateStockStatus(r, pack, inventory);
  const missing = getMissingRecipeIngredients(r, pack, inventory, items);
  const missingNames = new Set(missing.map(m => m.item || m.name));

  const { foods } = splitIngredients(items);
  const ownedFoods = (foods.length ? foods : items).filter(f => !missingNames.has(f.item));

  const today = todayISO();
  const plannedToday = (S.load(S.keys.plan, [])).some(x => x.id === id && isPlanRowOnDate(x, today, today));

  const tags = (r.tags || []).slice(0, 4);
  const methodText = String(r.method || '').trim();
  const methodSummary = methodText
    ? (methodText.length > 160 ? methodText.slice(0, 160) + '…' : methodText)
    : '';

  // ── DOM ──
  const overlayEl = document.createElement('div');
  overlayEl.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content recipe-quick-modal';

  const ownedBlock = ownedFoods.length
    ? `<div class="rqm-section"><h4>已有食材</h4><div class="rqm-pills">${ownedFoods.slice(0, 12).map(it => `<span class="rqm-pill">${escapeHtml(it.item)}</span>`).join('')}</div></div>`
    : '';
  const missingBlock = missing.length
    ? `<div class="rqm-section"><h4>还缺 ${missing.length} 样</h4><div class="rqm-pills">${missing.slice(0, 12).map(it => `<span class="rqm-pill missing">${escapeHtml(it.item || it.name)}</span>`).join('')}</div></div>`
    : '';
  const methodBlock = methodSummary
    ? `<div class="rqm-section"><h4>做法摘要</h4><div class="rqm-method">${escapeHtml(methodSummary)}</div></div>`
    : `<div class="rqm-section"><div class="rqm-method rqm-method-empty">暂无做法。可在完整菜谱里补充。</div></div>`;

  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title rqm-title">${escapeHtml(r.name)}</span>
      <button type="button" class="km-modal-close" aria-label="关闭">${CLOSE_SVG}</button>
    </div>
    <div class="km-modal-body recipe-quick-body">
      <div class="rqm-meta-row">
        ${statusBadgeHtml(statusData, missing.length)}
        ${!isCreative ? `<button type="button" class="rqm-fav${isFavoriteRecipe(id) ? ' active' : ''}" id="rqmFav">${isFavoriteRecipe(id) ? '★ 常做' : '☆ 设为常做'}</button>` : ''}
      </div>
      ${tags.length ? `<div class="rqm-tags">${tags.map(t => `<span class="rc-compact-tag">${escapeHtml(t)}</span>`).join('')}</div>` : ''}
      ${ownedBlock}
      ${missingBlock}
      ${methodBlock}
      <div class="rqm-feedback" id="rqmFeedback" hidden></div>
    </div>
    <div class="km-modal-actions rqm-actions">
      ${!isCreative ? `<button type="button" class="btn ok rqm-primary" id="rqmPlan" ${plannedToday ? 'disabled' : ''}>${plannedToday ? '今天已计划' : '加入今日计划'}</button>` : ''}
      <button type="button" class="btn" id="rqmAddMissing" ${missing.length ? '' : 'disabled'}>${missing.length ? '缺的加入买菜' : '食材已齐'}</button>
      <button type="button" class="btn" id="rqmFull">${isCreative ? '补做法' : '查看完整菜谱'}</button>
      ${!isCreative ? `<button type="button" class="btn rqm-edit" id="rqmEdit">编辑</button>` : ''}
    </div>
  `;

  overlayEl.appendChild(panel);
  document.body.appendChild(overlayEl);
  requestAnimationFrame(() => overlayEl.classList.add('open'));

  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    overlayEl.classList.add('closing');
    setTimeout(() => overlayEl.remove(), 220);
  };
  panel.querySelector('.km-modal-close').onclick = close;
  overlayEl.onclick = e => { if (e.target === overlayEl) close(); };

  const feedback = panel.querySelector('#rqmFeedback');
  const showFeedback = (text) => {
    if (!feedback) return;
    feedback.hidden = false;
    feedback.textContent = text;
  };

  // 收藏切换：更新弹窗按钮 + 通知外部卡片刷新（onRoute 重渲染会保持搜索/分类上下文）。
  const favBtn = panel.querySelector('#rqmFav');
  if (favBtn) {
    favBtn.onclick = () => {
      toggleFavoriteRecipe(id);
      const active = isFavoriteRecipe(id);
      favBtn.classList.toggle('active', active);
      favBtn.textContent = active ? '★ 常做' : '☆ 设为常做';
      onRoute();
    };
  }

  // 加入今日计划：统一经过缺食材检查。
  const planBtn = panel.querySelector('#rqmPlan');
  if (planBtn) {
    planBtn.onclick = async () => {
      const result = await addRecipeToPlanWithMissingCheck(id, pack, inventory, {
        date: today,
        recipe: r,
        fallbackItems: items,
        source: 'quick-modal'
      });
      planBtn.disabled = true;
      planBtn.textContent = '今天已计划';
      if (!result.added) showFeedback('已在今日计划中。');
      else if (result.missing.length && result.shoppingAddedCount) showFeedback('已加入今日计划，缺的食材已加入买菜清单。');
      else if (result.missing.length) showFeedback('已加入今日计划，缺的食材可稍后处理。');
      else showFeedback('已加入今日计划。');
    };
  }

  // 缺少食材加入购物清单（复用 addMissingRecipeIngredientsToShopping）。
  const addMissingBtn = panel.querySelector('#rqmAddMissing');
  if (addMissingBtn && missing.length) {
    addMissingBtn.onclick = () => {
      const count = addMissingRecipeIngredientsToShopping(r, pack, inventory, items);
      addMissingBtn.disabled = true;
      addMissingBtn.textContent = '已加入买菜';
      showFeedback(count > 0 ? `已把 ${count} 项缺少食材加入买菜清单。` : '没有需要补的食材。');
    };
  }

  // 查看完整菜谱：唯一会改 hash 的入口。
  panel.querySelector('#rqmFull').onclick = () => { close(); location.hash = `#recipe:${id}`; };
  const editBtn = panel.querySelector('#rqmEdit');
  if (editBtn) editBtn.onclick = () => { close(); location.hash = `#recipe-edit:${id}`; };
}
