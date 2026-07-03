import { S, todayISO } from '../storage.js?v=231';
import {
  explodeCombinedItems
} from '../ingredients.js?v=231';
import { splitIngredients } from '../utils/recipe-sanitizer.js?v=231';
import {
  hasRecipeMethod,
  isFavoriteRecipe,
  toggleFavoriteRecipe,
  calculateStockStatus
} from '../recommendations.js?v=231';
import { loadInventory } from '../inventory.js?v=231';
import { addRecipeToPlanWithMissingCheck } from './plan-missing-check.js?v=231';
import {
  callAiSearchRecipe,
  formatAiErrorMessage
} from '../ai.js?v=231';
import {
  loadOverlay,
  saveOverlay
} from '../backup.js?v=231';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  showToast
} from './status.js?v=231';
import { showRecipeQuickModal } from './recipe-quick-modal.js?v=231';

const TRASH_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>`;

function getPlanContextForRecipe(recipe, pack, inv, fallbackItems = null) {
  const items = Array.isArray(fallbackItems) ? fallbackItems : pack?.recipe_ingredients?.[recipe.id] || [];
  return {
    pack: pack || {
      recipes: [recipe],
      recipe_ingredients: { [recipe.id]: items }
    },
    inv: Array.isArray(inv) ? inv : loadInventory(),
    fallbackItems: items
  };
}

/**
 * 卡片快速删除入口：配备内联气泡确认（无需弹窗）。
 * @param {string} recipeId
 * @param {HTMLElement} cardEl - 菜谱卡片 DOM。确认删除后会动画淡出并移除该元素。
 */
function attachQuickDelete(recipeId, cardEl) {
  // 对 creative-ai-temp 或占位 id 不加删除按鈕
  if (!recipeId || String(recipeId).startsWith('creative-')) return;

  const btnWrap = document.createElement('div');
  btnWrap.className = 'recipe-card-del-wrap';
  btnWrap.innerHTML = `
    <button type="button" class="recipe-card-del-btn" aria-label="删除此菜谱" title="删除">${TRASH_SVG}</button>
    <div class="recipe-card-del-confirm" hidden>
      <span>确认删除？</span>
      <button type="button" class="recipe-card-del-yes btn bad small">删</button>
      <button type="button" class="recipe-card-del-no btn small">取消</button>
    </div>
  `;

  const trashBtn = btnWrap.querySelector('.recipe-card-del-btn');
  const confirmRow = btnWrap.querySelector('.recipe-card-del-confirm');
  const yesBtn = btnWrap.querySelector('.recipe-card-del-yes');
  const noBtn = btnWrap.querySelector('.recipe-card-del-no');
  let autoHideTimer = null;

  const hideConfirm = () => {
    confirmRow.hidden = true;
    trashBtn.hidden = false;
    clearTimeout(autoHideTimer);
  };

  trashBtn.onclick = (e) => {
    e.stopPropagation();
    trashBtn.hidden = true;
    confirmRow.hidden = false;
    // 3s 无操作自动收起确认气泡
    autoHideTimer = setTimeout(hideConfirm, 3000);
  };
  noBtn.onclick = (e) => { e.stopPropagation(); hideConfirm(); };
  yesBtn.onclick = (e) => {
    e.stopPropagation();
    clearTimeout(autoHideTimer);
    // 写入 overlay deletes
    try {
      // 使用导入的模块函数（已 import 在文件顶部）
      const ov = loadOverlay();
      ov.deletes = ov.deletes || {};
      ov.deletes[recipeId] = true;
      // 删除 overlay 中的自定义菜谱条目
      if (ov.recipes) delete ov.recipes[recipeId];
      if (ov.recipe_ingredients) delete ov.recipe_ingredients[recipeId];
      saveOverlay(ov);
      window.invalidatePackCache?.();
    } catch (_) {}
    // 动画移除卡片
    cardEl.style.transition = 'opacity 0.18s ease, transform 0.18s ease, max-height 0.20s ease';
    cardEl.style.overflow = 'hidden';
    cardEl.style.maxHeight = cardEl.offsetHeight + 'px';
    requestAnimationFrame(() => {
      cardEl.style.opacity = '0';
      cardEl.style.transform = 'translateX(10px)';
      cardEl.style.maxHeight = '0';
      cardEl.style.marginBottom = '0';
    });
    cardEl.addEventListener('transitionend', () => cardEl.remove(), { once: true });
    setTimeout(() => cardEl.remove(), 300);
  };

  return btnWrap;
}

export function recipeMethodBadge(recipe) {
  return hasRecipeMethod(recipe)
    ? '<span class="kchip method-ok">有做法</span>'
    : '<span class="kchip method-missing">缺做法</span>';
}

export function searchResultCard(r, statusData, { onRoute = () => {}, onPreviewRecipe = null, pack = null, inv = null } = {}) {
  const card = document.createElement('div'); card.className = 'card';
  let badgeHtml = '';
  if (statusData.status === 'ok') {
    badgeHtml = `<span class="kchip ok">✅ 食材够做</span>`;
  } else if (statusData.status === 'partial') {
    if (statusData.missing && statusData.missing.length > 0) {
      badgeHtml = `<span class="kchip warn">⚠️ 缺食材</span>`;
    } else if (statusData.coverageConfidence === 'unit-mismatch') {
      badgeHtml = `<span class="kchip warn">⚠️ 单位需确认</span>`;
    } else if (statusData.coverageConfidence === 'status-only') {
      badgeHtml = `<span class="kchip warn">⚠️ 状态需确认</span>`;
    } else {
      badgeHtml = `<span class="kchip warn">⚠️ 需确认</span>`;
    }
  } else {
    badgeHtml = `<span class="kchip bad">❌ 暂无食材</span>`;
  }
  card.innerHTML = `
    <div class="recipe-card-head">
      <div class="recipe-card-title-row">
        <h3 class="r-title r-title-link">${escapeHtml(r.name)}</h3>
      </div>
      <div class="recipe-card-action-row recipe-badge-stack">
        ${recipeMethodBadge(r)}${badgeHtml}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="controls">
      <button type="button" class="btn small" id="viewRecipeBtn">${hasRecipeMethod(r) ? '查看做法' : '补做法'}</button>
      <button type="button" class="btn small" id="addMissingBtn">加入计划</button>
    </div>`;
  const openRecipe = (event) => {
    event?.preventDefault();
    event?.stopPropagation();
    if (typeof onPreviewRecipe === 'function') onPreviewRecipe(r);
    else location.hash = `#recipe:${r.id}`;
  };
  card.querySelector('.r-title-link').onclick = openRecipe;
  const viewBtn = card.querySelector('#viewRecipeBtn');
  if (viewBtn) viewBtn.onclick = openRecipe;
  const addBtn = card.querySelector('#addMissingBtn');
  if (addBtn) {
    addBtn.onclick = async (event) => {
      event?.preventDefault();
      event?.stopPropagation();
      const ctx = getPlanContextForRecipe(r, pack, inv);
      await addRecipeToPlanWithMissingCheck(r.id, ctx.pack, ctx.inv, {
        recipe: r,
        fallbackItems: ctx.fallbackItems,
        source: 'search-result',
        onRoute
      });
    };
  }
  // 快速删除入口
  const delWrap = attachQuickDelete(r.id, card);
  if (delWrap) {
    const actionRow = card.querySelector('.recipe-card-action-row');
    actionRow.appendChild(delWrap);
  }
  return card;
}

/**
 * 紧凑菜谱卡片状态徽标：能做 / 只差 N 样 / 缺 N 样。
 */
function compactStatusBadge(statusData) {
  if (!statusData) return '';
  if (statusData.status === 'ok') return `<span class="kchip ok rc-badge">能做</span>`;
  if (statusData.status === 'partial') {
    const n = (statusData.missing && statusData.missing.length) || 0;
    if (n === 0) return `<span class="kchip warn rc-badge">需确认</span>`;
    if (n <= 2) return `<span class="kchip warn rc-badge">只差${n}样</span>`;
    return `<span class="kchip bad rc-badge">缺${n}样</span>`;
  }
  return `<span class="kchip bad rc-badge">缺食材</span>`;
}

/**
 * 移动端高密度菜谱卡片：外部只显示菜名 / 1-2 标签 / 匹配状态 / 收藏快捷键 / 一行命中原因。
 * 点击卡片主体打开「快速详情」弹窗（不跳转、不改 hash）；详细信息与主要操作都在弹窗里。
 */
function compactRecipeCard(r, extraInfo, { onRoute, statusData, pack, inv }) {
  const card = document.createElement('div');
  card.className = 'card recipe-card-compact';
  card.setAttribute('role', 'button');
  card.setAttribute('tabindex', '0');
  const isCreative = String(r.id).startsWith('creative-');
  const tags = (r.tags || []).slice(0, 2);
  const reasonText = extraInfo && extraInfo.reason ? String(extraInfo.reason) : '';
  card.innerHTML = `
    <div class="rc-compact-main">
      <h3 class="rc-compact-title">${escapeHtml(r.name)}</h3>
      <div class="rc-compact-sub">
        ${compactStatusBadge(statusData)}
        ${tags.map(t => `<span class="rc-compact-tag">${escapeHtml(t)}</span>`).join('')}
      </div>
      ${reasonText ? `<div class="rc-compact-reason">${escapeHtml(reasonText)}</div>` : ''}
    </div>
    <div class="rc-compact-actions"></div>
  `;
  const actions = card.querySelector('.rc-compact-actions');
  if (!isCreative) {
    const favBtn = document.createElement('button');
    favBtn.type = 'button';
    const setFav = () => {
      const active = isFavoriteRecipe(r.id);
      favBtn.className = `rc-compact-fav${active ? ' active' : ''}`;
      favBtn.textContent = active ? '★' : '☆';
      const label = active ? '取消常做' : '设为常做';
      favBtn.setAttribute('aria-label', label);
      favBtn.title = label;
    };
    setFav();
    favBtn.onclick = (e) => { e.stopPropagation(); toggleFavoriteRecipe(r.id); onRoute(); };
    actions.appendChild(favBtn);
    const delWrap = attachQuickDelete(r.id, card);
    if (delWrap) actions.appendChild(delWrap);
  }
  const open = () => showRecipeQuickModal(r, pack, inv, { onRoute });
  card.addEventListener('click', open);
  card.addEventListener('keydown', (e) => {
    // 仅当焦点在卡片本身（而非内部收藏/删除按钮）时才触发，避免按钮 Enter 冒泡误开弹窗。
    if (e.target !== card) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
  });
  return card;
}

export function recipeCard(r, list, extraInfo = null, opts = {}) {
  const { onRoute = () => {}, compact = false, statusData = null, pack = null, inv = null, onPreviewRecipe = null } = opts;
  if (compact) return compactRecipeCard(r, extraInfo, { onRoute, statusData, pack, inv });
  const card = document.createElement('div'); card.className = 'card';
  const isCreative = String(r.id).startsWith('creative-');
  const canPreview = Boolean(typeof onPreviewRecipe === 'function' && !isCreative);
  const openPreview = (event) => {
    event?.preventDefault();
    event?.stopPropagation();
    if (canPreview) onPreviewRecipe(r);
  };
  const topHtml = (extraInfo && extraInfo.isAi) ? `<div class="ai-badge">✨ 今日推荐</div>` : '';
  const reasonText = extraInfo && extraInfo.reason ? String(extraInfo.reason) : '';
  const explainText = extraInfo && Array.isArray(extraInfo.explain) && extraInfo.explain.length
    ? extraInfo.explain.join('；') : reasonText;
  card.innerHTML = `${topHtml}
    <div class="recipe-card-head">
      <div class="recipe-card-title-row">
        <h3 class="r-title">${escapeHtml(r.name)}</h3>
      </div>
      <div class="recipe-card-action-row recipe-badge-stack">
        ${recipeMethodBadge(r)}
        ${!String(r.id).startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}">编辑</button>` : ''}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ing-compact-container"></div>
    ${reasonText ? `<div class="ai-reason" title="${escapeOptionAttr(explainText)}">${escapeHtml(reasonText)}</div>` : ''}
    <div class="controls recipe-card-controls"></div>`;
  const titleEl = card.querySelector('.r-title');
  if (!canPreview) {
    titleEl.onclick = () => location.hash = `#recipe:${r.id}`;
  }
  const editBtn = card.querySelector('.btn-edit');
  if (editBtn) editBtn.onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; };
  const tagContainer = card.querySelector('.ing-compact-container');
  const items = explodeCombinedItems(list || []);
  // 食材 / 调料结构化分流：核心食材渲染为药丸，调料以轻量内敛的一行单列。
  const { foods, seasonings } = splitIngredients(items);
  const displayItems = foods.length > 0 ? foods : items;
  displayItems.slice(0, 4).forEach(it => { const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.textContent = it.item; tagContainer.appendChild(span); });
  if (seasonings.length) {
    const seasoningLine = document.createElement('div');
    seasoningLine.className = 'ing-seasoning-line';
    seasoningLine.textContent = '🧂 ' + seasonings.slice(0, 6).map(s => s.item).join('、');
    tagContainer.insertAdjacentElement('afterend', seasoningLine);
  }
  if (!String(r.id).startsWith('creative-')) {
    // 复合判定：结合「今天的计划项 + 是否已做完」决定按钮状态。
    // 关键：只有「今天已加入且尚未做完」才锁为「已加入」；一旦今天已做完(isCooked)，
    // 按钮彻底释放回默认的「加入清单」，让用户可重新排程（明后天）。
    const today = todayISO();
    const todayRow = (S.load(S.keys.plan, [])).find(x => x.id === r.id && (x.date || today) === today);
    const isCookedToday = !!(todayRow && todayRow.isCooked);
    const isPlannedToday = !!todayRow && !isCookedToday; // 已加入今天且尚未做 → 锁「已加入」
    const favoriteBtn = document.createElement('button'); favoriteBtn.type = 'button';
    favoriteBtn.className = `btn small favorite-btn${isFavoriteRecipe(r.id) ? ' active' : ''}`;
    favoriteBtn.textContent = isFavoriteRecipe(r.id) ? '常做' : '设为常做';
    favoriteBtn.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      toggleFavoriteRecipe(r.id);
      onRoute();
    };
    const btn = document.createElement('button'); btn.type = 'button';
    btn.className = 'btn ok small';
    // 已加入未做 → 「已加入」；其余（含今日已做完）→ 默认「加入清单」，完全释放锁定。
    btn.textContent = isPlannedToday ? '已加入' : '加入计划';
    btn.onclick = async (event) => {
      event.preventDefault();
      event.stopPropagation();
      const p = S.load(S.keys.plan, []);
      const row = p.find(x => x.id === r.id && (x.date || today) === today);
      if (row && !row.isCooked) {
        // 已加入未做 → 再次点击取消今天的排程（仅针对今天，不动明后天）。
        S.save(S.keys.plan, p.filter(x => x !== row));
      } else if (row && row.isCooked) {
        // 今天已做完 → 重新走加入今日计划流程，避免绕过缺食材确认。
        S.save(S.keys.plan, p.filter(x => x !== row));
        const ctx = getPlanContextForRecipe(r, pack, inv, list);
        await addRecipeToPlanWithMissingCheck(r.id, ctx.pack, ctx.inv, {
          recipe: r,
          fallbackItems: ctx.fallbackItems,
          source: 'recipe-card-replan'
        });
      } else {
        // 今天尚未排程 → 加入今日计划。
        const ctx = getPlanContextForRecipe(r, pack, inv, list);
        await addRecipeToPlanWithMissingCheck(r.id, ctx.pack, ctx.inv, {
          recipe: r,
          fallbackItems: ctx.fallbackItems,
          source: 'recipe-card'
        });
      }
      onRoute();
    };
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className = 'btn small';
    detailBtn.textContent = hasRecipeMethod(r) ? '查看' : '补做法';
    detailBtn.onclick = event => {
      if (canPreview) openPreview(event);
      else {
        event.preventDefault();
        event.stopPropagation();
        location.hash = `#recipe:${r.id}`;
      }
    };
    card.querySelector('.controls').appendChild(favoriteBtn);
    card.querySelector('.controls').appendChild(btn);
    card.querySelector('.controls').appendChild(detailBtn);
    // 快速删除入口（右上角垃圾桶 + 内联确认）
    const delWrap = attachQuickDelete(r.id, card);
    if (delWrap) {
      card.querySelector('.recipe-card-action-row').appendChild(delWrap);
    }
  }
  return card;
}

export function showRecommendationCards(container, list, pack, { onRoute = () => {}, onPreviewRecipe = null, inv = null } = {}) {
  container.innerHTML = '';
  if (!list || list.length === 0) {
    container.innerHTML = '<div class="card small rec-empty-card">暂无推荐。</div>';
    return;
  }
  const map = pack.recipe_ingredients || {};
  list.forEach(item => {
    const isAi = item.isAi !== undefined ? item.isAi : false;
    container.appendChild(recipeCard(item.r, item.list || map[item.r.id], { reason: item.reason, explain: item.explain, score: item.score, isAi }, { onRoute, onPreviewRecipe, pack, inv }));
  });
}

export function renderAiRecipeDraftCard(draft) {
  const card = document.createElement('div');
  card.className = 'card ai-draft-card';
  card.innerHTML = `
    <div class="ai-draft-title">菜谱草稿</div>
    <h3>${escapeHtml(draft.name)}</h3>
    <p class="meta">这还不是正式菜谱。请确认后保存，或保存后继续编辑。</p>
    <div class="ing-compact-container">${draft.ingredients.map(item => `<span class="ing-tag-pill">${escapeHtml(item.item)}</span>`).join('')}</div>
    <div class="method-text">${escapeHtml(draft.method)}</div>
    <div class="controls ai-draft-actions">
      <button type="button" class="btn ok" id="saveAiRecipeDraft">保存草稿</button>
      <button type="button" class="btn" id="editAiRecipeDraft">保存并编辑</button>
      <button type="button" class="btn bad" id="cancelAiRecipeDraft">取消</button>
    </div>
  `;
  const saveDraft = (goEdit = false) => {
    const tempId = 'ai-search-' + Date.now();
    const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {};
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    overlay.recipes[tempId] = { name: draft.name, tags: ['AI草稿', 'AI搜索'], method: draft.method, isAiDraft: true };
    overlay.recipe_ingredients[tempId] = draft.ingredients.map(item => ({ item: item.item, qty: item.qty || null, unit: item.unit || null }));
    saveOverlay(overlay);
    window.invalidatePackCache?.();
    showToast('AI 草稿已保存', { tone: 'success' });
    location.hash = goEdit ? `#recipe-edit:${tempId}` : `#recipe:${tempId}`;
  };
  card.querySelector('#saveAiRecipeDraft').onclick = () => saveDraft(false);
  card.querySelector('#editAiRecipeDraft').onclick = () => saveDraft(true);
  card.querySelector('#cancelAiRecipeDraft').onclick = () => card.remove();
  return card;
}

export function renderRecipeSearchResults(query, pack, inv, { onRoute = () => {} } = {}) {
  const container = document.createElement('div');
  container.innerHTML = `<h2 class="section-title">搜索结果：${query}</h2><div class="grid" id="search-grid"></div>`;
  const grid = container.querySelector('#search-grid');
  const results = (pack.recipes || []).filter(r => r.name.includes(query));
  if (results.length > 0) {
    results.forEach(r => {
      const status = calculateStockStatus(r, pack, inv);
      grid.appendChild(searchResultCard(r, status, { onRoute, pack, inv }));
    });
  } else {
    container.innerHTML += `<div class="search-empty-state"><p class="text-secondary">未找到相关菜谱。</p><button type="button" class="btn ai" id="aiSearchBtn">生成菜谱草稿【${query}】</button><div id="aiSearchStatus" class="small inline-status" hidden></div></div><div id="aiDraftResult"></div>`;
    setTimeout(() => {
      const btn = container.querySelector('#aiSearchBtn');
      const status = container.querySelector('#aiSearchStatus');
      const draftHost = container.querySelector('#aiDraftResult');
      if (btn) {
        btn.onclick = async () => {
          btn.disabled = true;
          btn.innerHTML = '<span class="spinner"></span> 正在整理...';
          try {
            const invNames = inv.map(x => x.name).join(',');
            const aiRes = await callAiSearchRecipe(query, invNames);
            draftHost.innerHTML = '';
            draftHost.appendChild(renderAiRecipeDraftCard(aiRes));
            setInlineStatus(status, '已生成草稿，请确认后再保存。', 'ok');
          } catch (e) {
            setInlineStatus(status, formatAiErrorMessage(e), 'bad');
            showToast('AI 暂不可用', { tone: 'error' });
          } finally {
            btn.disabled = false;
            btn.innerHTML = `生成菜谱草稿【${query}】`;
          }
        };
      }
    }, 0);
  }
  return container;
}
