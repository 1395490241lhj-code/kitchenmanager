import { S, todayISO } from '../storage.js?v=184';
import {
  explodeCombinedItems,
  isSeasoning
} from '../ingredients.js?v=184';
import {
  hasRecipeMethod,
  isFavoriteRecipe,
  markRecipePlanned,
  toggleFavoriteRecipe,
  calculateStockStatus
} from '../recommendations.js?v=184';
import {
  callAiSearchRecipe,
  formatAiErrorMessage
} from '../ai.js?v=184';
import {
  loadOverlay,
  saveOverlay
} from '../backup.js?v=184';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus
} from './status.js?v=184';

const TRASH_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>`;

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
      const { loadOverlay: lo, saveOverlay: so } = { loadOverlay: () => (JSON.parse(localStorage.getItem('kitchen-overlay') || '{}')), saveOverlay: () => {} };
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

export function searchResultCard(r, statusData, { onRoute = () => {} } = {}) {
  const card = document.createElement('div'); card.className = 'card';
  let badgeHtml = '';
  if (statusData.status === 'ok') {
    badgeHtml = `<span class="kchip ok">✅ 库存充足</span>`;
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
      <h3 class="r-title r-title-link">${r.name}</h3>
      <div class="recipe-badge-stack">
        ${recipeMethodBadge(r)}${badgeHtml}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="controls">
      <button type="button" class="btn small" onclick="location.hash='#recipe:${r.id}'">${hasRecipeMethod(r) ? '查看做法' : '补做法'}</button>
      <button type="button" class="btn small" id="addMissingBtn">🛒 加入清单</button>
    </div>`;
  card.querySelector('.r-title-link').onclick = () => location.hash = `#recipe:${r.id}`;
  const addBtn = card.querySelector('#addMissingBtn');
  if (addBtn) {
    addBtn.onclick = () => {
      const plan = S.load(S.keys.plan, []);
      const today = todayISO();
      if (!plan.find(x => x.id === r.id && (x.date || today) === today)) { plan.push({ id: r.id, servings: 1, date: today }); S.save(S.keys.plan, plan); markRecipePlanned(r.id); alert('已加入清单。'); }
      else { alert('已在清单中。'); }
    };
  }
  // 快速删除入口
  const delWrap = attachQuickDelete(r.id, card);
  if (delWrap) {
    const head = card.querySelector('.recipe-card-head');
    head.appendChild(delWrap);
  }
  return card;
}

export function recipeCard(r, list, extraInfo = null, { onRoute = () => {} } = {}) {
  const card = document.createElement('div'); card.className = 'card';
  const topHtml = (extraInfo && extraInfo.isAi) ? `<div class="ai-badge">✨ AI 推荐</div>` : '';
  const reasonText = extraInfo && extraInfo.reason ? String(extraInfo.reason) : '';
  const explainText = extraInfo && Array.isArray(extraInfo.explain) && extraInfo.explain.length
    ? extraInfo.explain.join('；') : reasonText;
  card.innerHTML = `${topHtml}
    <div class="recipe-card-head">
      <h3 class="r-title">${r.name}</h3>
      <div class="recipe-badge-stack">
        ${recipeMethodBadge(r)}
        ${!String(r.id).startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}">编辑</button>` : ''}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ing-compact-container"></div>
    ${reasonText ? `<div class="ai-reason" title="${escapeOptionAttr(explainText)}">${escapeHtml(reasonText)}</div>` : ''}
    <div class="controls recipe-card-controls"></div>`;
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  const editBtn = card.querySelector('.btn-edit');
  if (editBtn) editBtn.onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; };
  const tagContainer = card.querySelector('.ing-compact-container');
  const items = explodeCombinedItems(list || []);
  const coreItems = items.filter(it => !isSeasoning(it.item));
  const displayItems = coreItems.length > 0 ? coreItems : items;
  displayItems.slice(0, 4).forEach(it => { const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.textContent = it.item; tagContainer.appendChild(span); });
  if (!String(r.id).startsWith('creative-')) {
    const plan = new Set((S.load(S.keys.plan, [])).map(x => x.id));
    const favoriteBtn = document.createElement('button'); favoriteBtn.type = 'button';
    favoriteBtn.className = `btn small favorite-btn${isFavoriteRecipe(r.id) ? ' active' : ''}`;
    favoriteBtn.textContent = isFavoriteRecipe(r.id) ? '常做' : '设为常做';
    favoriteBtn.onclick = () => { toggleFavoriteRecipe(r.id); onRoute(); };
    const btn = document.createElement('button'); btn.type = 'button'; btn.className = 'btn ok small';
    btn.textContent = plan.has(r.id) ? '已加入' : '加入清单';
    btn.onclick = () => {
      const p = S.load(S.keys.plan, []);
      const i = p.findIndex(x => x.id === r.id);
      if (i >= 0) {
        const nextP = p.filter(x => x.id !== r.id);
        S.save(S.keys.plan, nextP);
      } else {
        p.push({ id: r.id, servings: 1, date: todayISO() });
        markRecipePlanned(r.id);
        S.save(S.keys.plan, p);
      }
      onRoute();
    };
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className = 'btn small';
    detailBtn.textContent = hasRecipeMethod(r) ? '查看' : '补做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    card.querySelector('.controls').appendChild(favoriteBtn);
    card.querySelector('.controls').appendChild(btn);
    card.querySelector('.controls').appendChild(detailBtn);
    // 快速删除入口（右上角垃圾桶 + 内联确认）
    const delWrap = attachQuickDelete(r.id, card);
    if (delWrap) {
      card.querySelector('.recipe-badge-stack').appendChild(delWrap);
    }
  }
  return card;
}

export function showRecommendationCards(container, list, pack, { onRoute = () => {} } = {}) {
  container.innerHTML = '';
  if (!list || list.length === 0) {
    container.innerHTML = '<div class="card small rec-empty-card">暂无推荐。</div>';
    return;
  }
  const map = pack.recipe_ingredients || {};
  list.forEach(item => {
    const isAi = item.isAi !== undefined ? item.isAi : false;
    container.appendChild(recipeCard(item.r, item.list || map[item.r.id], { reason: item.reason, explain: item.explain, score: item.score, isAi }, { onRoute }));
  });
}

export function renderAiRecipeDraftCard(draft) {
  const card = document.createElement('div');
  card.className = 'card ai-draft-card';
  card.innerHTML = `
    <div class="ai-draft-title">AI 菜谱草稿</div>
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
    location.hash = goEdit ? `#recipe-edit:${tempId}` : `#recipe:${tempId}`;
    location.reload();
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
      grid.appendChild(searchResultCard(r, status, { onRoute }));
    });
  } else {
    container.innerHTML += `<div class="search-empty-state"><p class="text-secondary">未找到相关菜谱。</p><button type="button" class="btn ai" id="aiSearchBtn">🤖 生成 AI 草稿【${query}】</button><div id="aiSearchStatus" class="small inline-status" hidden></div></div><div id="aiDraftResult"></div>`;
    setTimeout(() => {
      const btn = container.querySelector('#aiSearchBtn');
      const status = container.querySelector('#aiSearchStatus');
      const draftHost = container.querySelector('#aiDraftResult');
      if (btn) {
        btn.onclick = async () => {
          btn.disabled = true;
          btn.innerHTML = '<span class="spinner"></span> AI 搜索中...';
          try {
            const invNames = inv.map(x => x.name).join(',');
            const aiRes = await callAiSearchRecipe(query, invNames);
            draftHost.innerHTML = '';
            draftHost.appendChild(renderAiRecipeDraftCard(aiRes));
            setInlineStatus(status, '已生成草稿，请确认后再保存。', 'ok');
          } catch (e) {
            setInlineStatus(status, formatAiErrorMessage(e), 'bad');
          } finally {
            btn.disabled = false;
            btn.innerHTML = `🤖 生成 AI 草稿【${query}】`;
          }
        };
      }
    }, 0);
  }
  return container;
}
