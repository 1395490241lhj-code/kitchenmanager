import { S } from '../storage.js?v=98';
import {
  explodeCombinedItems,
  isSeasoning
} from '../ingredients.js?v=1';
import {
  hasRecipeMethod,
  isFavoriteRecipe,
  markRecipePlanned,
  toggleFavoriteRecipe,
  calculateStockStatus
} from '../recommendations.js?v=3';
import {
  callAiSearchRecipe,
  formatAiErrorMessage
} from '../ai.js?v=2';
import {
  loadOverlay,
  saveOverlay
} from '../backup.js?v=2';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus
} from './status.js?v=1';

export function recipeMethodBadge(recipe) {
  return hasRecipeMethod(recipe)
    ? '<span class="kchip method-ok">有做法</span>'
    : '<span class="kchip method-missing">缺做法</span>';
}

export function searchResultCard(r, statusData, { onRoute = () => {} } = {}) {
  const card = document.createElement('div'); card.className = 'card';
  const statusBadge = statusData.status === 'ok'
    ? `<span class="kchip ok">✅ 库存充足</span>`
    : (statusData.status === 'partial'
      ? `<span class="kchip warn">⚠️ 缺食材</span>`
      : `<span class="kchip bad">❌ 暂无食材</span>`);
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3><div class="recipe-badge-stack">${recipeMethodBadge(r)}${statusBadge}</div></div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="controls"><button type="button" class="btn small" onclick="location.hash='#recipe:${r.id}'">${hasRecipeMethod(r) ? '查看做法' : '补做法'}</button><button type="button" class="btn small" id="addMissingBtn">🛒 加入清单</button></div>`;
  const addBtn = card.querySelector('#addMissingBtn');
  if (addBtn) {
    addBtn.onclick = () => {
      const plan = S.load(S.keys.plan, []);
      if (!plan.find(x => x.id === r.id)) { plan.push({ id: r.id, servings: 1 }); S.save(S.keys.plan, plan); markRecipePlanned(r.id); alert('已加入清单。'); }
      else { alert('已在清单中。'); }
    };
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
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 class="r-title">${r.name}</h3>
      <div class="recipe-badge-stack">
        ${recipeMethodBadge(r)}
        ${!String(r.id).startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;border:none;">编辑</button>` : ''}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ing-compact-container"></div>
    ${reasonText ? `<div class="ai-reason" title="${escapeOptionAttr(explainText)}">${escapeHtml(reasonText)}</div>` : ''}
    <div class="controls" style="margin-top:16px;"></div>`;
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
    btn.onclick = () => { const p = S.load(S.keys.plan, []); const i = p.findIndex(x => x.id === r.id); if (i >= 0) p.splice(i, 1); else { p.push({ id: r.id, servings: 1 }); markRecipePlanned(r.id); } S.save(S.keys.plan, p); onRoute(); };
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className = 'btn small';
    detailBtn.textContent = hasRecipeMethod(r) ? '查看' : '补做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    card.querySelector('.controls').appendChild(favoriteBtn);
    card.querySelector('.controls').appendChild(btn);
    card.querySelector('.controls').appendChild(detailBtn);
  }
  return card;
}

export function showRecommendationCards(container, list, pack, { onRoute = () => {} } = {}) {
  container.innerHTML = '';
  if (!list || list.length === 0) {
    container.innerHTML = '<div class="card small" style="min-width:100%;text-align:center;">暂无推荐。</div>';
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
    container.innerHTML += `<div style="text-align:center; padding:40px;"><p style="color:var(--text-secondary)">未找到相关菜谱。</p><button type="button" class="btn ai" id="aiSearchBtn">🤖 生成 AI 草稿【${query}】</button><div id="aiSearchStatus" class="small inline-status" hidden></div></div><div id="aiDraftResult"></div>`;
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
