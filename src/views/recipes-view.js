import { S } from '../storage.js?v=219';
import { hasRecipeMethod, calculateStockStatus, loadFavoriteRecipeIds, loadRecipeActivity } from '../recommendations.js?v=219';
import { recipeCard } from '../components/recipe-card.js?v=219';
import { buildCatalog } from '../ingredients.js?v=219';
import { loadInventory } from '../inventory.js?v=219';
import { RECIPE_CATEGORIES, searchRecipes, matchesCategory } from '../recipe-search.js?v=219';
import { showRecipeCreateModal } from '../components/recipe-create-modal.js?v=219';
import { openRecipeImportModal } from '../components/recipe-import-modal.js?v=219';

function mergeOverlayPreservingCurrent(currentOverlay, incomingOverlay) {
  const current = currentOverlay || {};
  const incoming = incomingOverlay || {};
  const next = {
    ...current,
    recipes: { ...(current.recipes || {}) },
    recipe_ingredients: { ...(current.recipe_ingredients || {}) },
    deletes: { ...(current.deletes || {}) }
  };
  const conflicts = []; const imported = [];
  const incomingIds = new Set([
    ...Object.keys(incoming.recipes || {}),
    ...Object.keys(incoming.recipe_ingredients || {}),
    ...Object.keys(incoming.deletes || {})
  ]);
  const hasCurrentPatch = id =>
    Object.prototype.hasOwnProperty.call(current.recipes || {}, id)
    || Object.prototype.hasOwnProperty.call(current.recipe_ingredients || {}, id)
    || Object.prototype.hasOwnProperty.call(current.deletes || {}, id);
  incomingIds.forEach(id => {
    if (hasCurrentPatch(id)) { conflicts.push(id); return; }
    if (Object.prototype.hasOwnProperty.call(incoming.recipes || {}, id)) next.recipes[id] = incoming.recipes[id];
    if (Object.prototype.hasOwnProperty.call(incoming.recipe_ingredients || {}, id)) next.recipe_ingredients[id] = incoming.recipe_ingredients[id];
    if (Object.prototype.hasOwnProperty.call(incoming.deletes || {}, id)) next.deletes[id] = incoming.deletes[id];
    imported.push(id);
  });
  return { overlay: next, conflicts, imported };
}

// 模块级：分类筛选 + 搜索词状态（跨重渲染保持）。
// 收藏 / 加入清单等操作会触发 onRoute 整页重渲染，持久化这两项可避免筛选 / 搜索上下文丢失。
let activeRecipeCategory = '全部';
let activeRecipeQuery = '';

export function renderRecipes(pack, { onRoute = () => {} } = {}) {
  const wrap = document.createElement('div');
  const allRecipes = pack.recipes || [];
  const methodReadyCount = allRecipes.filter(hasRecipeMethod).length;
  const missingMethodCount = Math.max(0, allRecipes.length - methodReadyCount);
  // 头部精简：搜索框 + 分类 chips + 双枪并列操作（AI 一键导入 / 手动新建）+ 紧凑过滤行。
  wrap.innerHTML = `
    <h2 class="section-title">菜谱</h2>
    <div class="recipe-header">
      <input id="search" placeholder="搜菜名、食材、口味，比如 鸡、土豆、麻辣" class="recipe-search-input recipe-search-main">
      <div class="recipe-cat-scroll">
        <div class="recipe-cat-chips" id="recipeCatChips" role="tablist" aria-label="菜谱分类"></div>
      </div>
      <div class="recipe-primary-actions">
        <button type="button" class="btn primary-action-btn ai-import-btn" id="aiImportBtn">从链接/截图导入</button>
        <button type="button" class="btn primary-action-btn manual-add-btn" id="addBtn">➕ 手动新建菜谱</button>
      </div>
      <div class="recipe-filter-row">
        <label class="recipe-filter-toggle"><input type="checkbox" id="methodOnly" checked>只看有做法</label>
        <span class="recipe-count" id="recipeCount"></span>
      </div>
    </div>
    <div class="grid recipe-grid" id="grid"></div>
  `;
  const grid = wrap.querySelector('#grid');
  const map = pack.recipe_ingredients || {};
  const recipeCount = wrap.querySelector('#recipeCount');
  const inv = loadInventory(buildCatalog(pack));

  // ── 一次性预算分类用的 id 集合（库存能做 / 只差一点 / 收藏 / 最近做过）──
  //    放在渲染时算一次，输入搜索时不重复计算库存，保证打字不卡。
  const favoriteIds = new Set(loadFavoriteRecipeIds());
  const activity = loadRecipeActivity();
  const stockableIds = new Set();
  const almostIds = new Set();
  const recentIds = new Set();
  // 渲染时算一次完整库存状态并缓存，供紧凑卡片徽标复用（打字搜索不重复算库存）。
  const statusById = new Map();
  for (const r of allRecipes) {
    const st = calculateStockStatus(r, pack, inv);
    statusById.set(r.id, st);
    if (st.status === 'ok') stockableIds.add(r.id);
    else if (st.status === 'partial' && st.missing && st.missing.length >= 1 && st.missing.length <= 2) almostIds.add(r.id);
    const act = activity[r.id];
    if (act && (act.cookedAt || act.cookedCount > 0)) recentIds.add(r.id);
  }
  const searchContext = { favoriteIds, stockableIds, almostIds, recentIds };

  // ── 分类 chips：默认常用项靠前，整体两行横向滑动 ──
  const chipsBox = wrap.querySelector('#recipeCatChips');
  const orderedCats = [...RECIPE_CATEGORIES].sort((a, b) => (a.defaultVisible === b.defaultVisible) ? 0 : (a.defaultVisible ? -1 : 1));
  const renderChips = () => {
    chipsBox.querySelectorAll('.recipe-cat-chip').forEach(c => {
      c.classList.toggle('is-active', c.dataset.cat === activeRecipeCategory);
      c.setAttribute('aria-selected', c.dataset.cat === activeRecipeCategory ? 'true' : 'false');
    });
  };
  orderedCats.forEach(cat => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = `recipe-cat-chip cat-kind-${cat.kind}`;
    chip.dataset.cat = cat.key;
    chip.textContent = cat.label;
    chip.setAttribute('role', 'tab');
    chip.onclick = () => { activeRecipeCategory = cat.key; renderChips(); draw(); };
    chipsBox.appendChild(chip);
  });

  const searchInput = wrap.querySelector('#search');
  searchInput.value = activeRecipeQuery; // 恢复上次搜索词（onRoute 重渲染后不丢上下文）

  function draw() {
    grid.innerHTML = '';
    const q = (searchInput.value || '').trim();
    activeRecipeQuery = q; // 持久化，供下次重渲染恢复
    const methodOnly = wrap.querySelector('#methodOnly').checked;

    // ① 先按「只看有做法 + 当前分类」过滤，分类与搜索可叠加。
    const base = allRecipes.filter(r =>
      (!methodOnly || hasRecipeMethod(r)) &&
      matchesCategory(r, activeRecipeCategory, pack, searchContext)
    );

    // ② 有查询词 → 本地智能搜索（按相关性排序 + 匹配原因）；无查询词 → 保持默认顺序。
    if (q) {
      const results = searchRecipes(base, q, pack, { context: searchContext });
      if (results.length === 0) {
        recipeCount.textContent = `没找到相关菜谱`;
        const empty = document.createElement('div');
        empty.className = 'recipe-empty-state';
        empty.innerHTML = `
          <p class="recipe-empty-title">没找到相关菜谱</p>
          <p class="recipe-empty-hint">可以换个食材名试试，例如 鸡肉、土豆、豆腐</p>`;
        // 仅当前为精简库时：搜索无结果 → 引导去完整库（镜像 app.js getLibraryMode 判定，避免循环依赖）。
        const libMode = (S.load(S.keys.settings, {}) || {}).recipeLibraryMode === 'full' ? 'full' : 'curated';
        if (libMode === 'curated') {
          const more = document.createElement('div');
          more.className = 'recipe-empty-fulllib';
          more.innerHTML = `
            <p class="recipe-empty-hint">完整传统菜谱里可能还有这道菜。你可以到 设置 → 菜谱多少 切换。</p>
            <button type="button" class="btn small" id="goSettingsFullLib">去设置</button>`;
          more.querySelector('#goSettingsFullLib').onclick = () => { location.hash = '#settings'; };
          empty.appendChild(more);
        }
        grid.appendChild(empty);
        return;
      }
      recipeCount.textContent = `找到 ${results.length} 道相关菜`;
      results.forEach(({ recipe: r, reasons }) => {
        const reason = (reasons && reasons.length) ? reasons.slice(0, 2).join(' · ') : '';
        grid.appendChild(recipeCard(r, map[r.id], reason ? { reason } : null, { onRoute, compact: true, statusData: statusById.get(r.id), pack, inv }));
      });
      return;
    }

    // 无搜索词：分类过滤后的默认列表。
    const catLabel = activeRecipeCategory === '全部' ? '' : `「${activeRecipeCategory}」`;
    recipeCount.textContent = `${catLabel}显示 ${base.length} 道 · 有做法 ${methodReadyCount} · 缺做法 ${missingMethodCount}`;
    if (base.length === 0) {
      const empty = document.createElement('div'); empty.className = 'card small';
      empty.textContent = methodOnly ? '没有符合条件的菜。可以关闭"只看有做法"，或切回「全部」分类。' : '没有符合条件的菜，试试切回「全部」分类。';
      grid.appendChild(empty); return;
    }
    base.forEach(r => { grid.appendChild(recipeCard(r, map[r.id], null, { onRoute, compact: true, statusData: statusById.get(r.id), pack, inv })); });
  }

  renderChips();
  draw();

  // 搜索输入做轻量 debounce（160ms），避免逐字符重排卡顿。
  let searchTimer = null;
  searchInput.oninput = () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(draw, 160);
  };
  wrap.querySelector('#methodOnly').onchange = draw;
  wrap.querySelector('#aiImportBtn').onclick = () => openRecipeImportModal();
  // 手动新建：打开轻量「新建菜谱」弹窗（不跳转、不改 hash）；保存后整页重渲染以纳入新菜谱。
  wrap.querySelector('#addBtn').onclick = () => {
    showRecipeCreateModal(pack, { onSaved: () => onRoute() });
  };
  return wrap;
}
