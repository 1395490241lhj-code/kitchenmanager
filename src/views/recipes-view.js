import { loadOverlay, saveOverlay } from '../backup.js?v=219';
import { genId } from '../shopping.js?v=219';
import { hasRecipeMethod, calculateStockStatus, loadFavoriteRecipeIds, loadRecipeActivity } from '../recommendations.js?v=219';
import { recipeCard } from '../components/recipe-card.js?v=219';
import { buildCatalog } from '../ingredients.js?v=219';
import { loadInventory } from '../inventory.js?v=219';
import { importRecipeFromSource, formatAiErrorMessage } from '../ai.js?v=219';
import { escapeHtml, setInlineStatus } from '../components/status.js?v=219';
import { RECIPE_CATEGORIES, searchRecipes, matchesCategory } from '../recipe-search.js?v=219';

// 【内存暂存】AI 解析出的草稿只存入 sessionStorage，不写 overlay/localStorage。
// 仅当用户在编辑器里点击「保存」时才真正落地。用户取消/关闭则草稿被销毁，不留脏数据。
const AI_DRAFT_SESSION_KEY = 'kitchen-ai-draft-pending';

function openEditorWithAiDraft(draft) {
  const tags = Array.from(new Set(['AI草稿', 'AI导入', ...(Array.isArray(draft.tags) ? draft.tags : [])]));
  const seasonings = (Array.isArray(draft.seasonings) ? draft.seasonings : [])
    .map(i => ({ item: i.item || '', qty: i.qty || '', unit: i.unit || '' }))
    .filter(i => i.item);
  const pending = {
    name: draft.name || 'AI 导入菜谱草稿',
    tags,
    method: draft.method || '',
    seasonings,
    ingredients: (draft.ingredients || []).map(i => ({ item: i.item || '', qty: i.qty ?? null, unit: i.unit ?? null })),
    isAiDraft: true,
  };
  try {
    sessionStorage.setItem(AI_DRAFT_SESSION_KEY, JSON.stringify(pending));
  } catch (e) {
    console.warn('[AI导入] sessionStorage 写入失败，回退为直接写 overlay', e);
    // 降级：直接写 overlay（旧行为）
    const id = genId();
    const ov = loadOverlay();
    ov.recipes = ov.recipes || {};
    ov.recipe_ingredients = ov.recipe_ingredients || {};
    ov.recipes[id] = { name: pending.name, tags: pending.tags, method: pending.method, seasonings: pending.seasonings, isAiDraft: true };
    ov.recipe_ingredients[id] = pending.ingredients;
    saveOverlay(ov);
    window.invalidatePackCache?.();
    location.hash = `#recipe-edit:${id}`;
    return;
  }
  // 用固定占位 id 跳转，编辑器读 sessionStorage 预填，不污染 overlay
  location.hash = '#recipe-edit:ai-import-draft';
}

// AI 一键导入：移动端优先弹窗（链接 / 视频截图 → 120B 解析）。
function openImportModal() {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="card ai-import-modal">
      <h3 class="ai-import-title">✨ AI 一键导入菜谱</h3>
      <p class="meta">粘贴菜谱链接，或上传短视频 / 配料表截图，AI 自动解析为可编辑草稿。</p>
      <label class="ai-import-field">
        <span>🔗 粘贴链接</span>
        <input id="aiImportUrl" type="url" inputmode="url" placeholder="小红书 / 网页菜谱链接">
      </label>
      <label class="ai-import-field ai-import-file">
        <span>🎬 上传视频 / 截图</span>
        <input id="aiImportFile" type="file" accept="image/*,video/*" hidden>
        <span class="ai-import-filename" id="aiImportFileName">点此选择文件</span>
      </label>
      <div id="aiImportStatus" class="inline-status" hidden></div>
      <button type="button" class="btn ai-import-go" id="aiImportGo">✨ 120B AI 智能解析</button>
      <button type="button" class="btn ai-import-cancel" id="aiImportCancel">取消</button>
    </div>
  `;
  document.body.appendChild(overlay);
  const close = () => overlay.remove();
  overlay.onclick = (e) => { if (e.target === overlay) close(); };
  overlay.querySelector('#aiImportCancel').onclick = close;

  const fileInput = overlay.querySelector('#aiImportFile');
  const fileName = overlay.querySelector('#aiImportFileName');
  overlay.querySelector('.ai-import-file').onclick = (e) => { if (e.target !== fileInput) fileInput.click(); };
  fileInput.onchange = () => { fileName.textContent = fileInput.files[0] ? fileInput.files[0].name : '点此选择文件'; };

  const status = overlay.querySelector('#aiImportStatus');
  const goBtn = overlay.querySelector('#aiImportGo');
  goBtn.onclick = async () => {
    if (goBtn.getAttribute('disabled')) return;
    // 智能模糊提取：允许用户粘贴整段小红书分享语，自动捕获里面的合法 URL。
    const raw = overlay.querySelector('#aiImportUrl').value.trim();
    const match = raw.match(/https?:\/\/[^\s]+/g);
    const url = match ? match[0].replace(/[，。、,.;；]+$/, '') : '';
    const file = fileInput.files[0] || null;
    if (!raw && !file) { setInlineStatus(status, '请粘贴链接或选择一个视频/截图。', 'bad'); return; }
    if (raw && !url) { setInlineStatus(status, '没找到有效链接，请检查粘贴内容或改用截图导入。', 'bad'); return; }
    goBtn.setAttribute('disabled', 'true');
    goBtn.innerHTML = '<span class="spinner"></span> 120B 解析中…';
    try {
      const draft = await importRecipeFromSource({ url, file });
      setInlineStatus(status, '解析完成，正在打开编辑器…', 'ok');
      setTimeout(() => { close(); openEditorWithAiDraft(draft); }, 500);
    } catch (err) {
      // 抓取/输入类的友好提示直接展示；其余（API/解析错误）走统一文案。
      const msg = String(err && err.message || '');
      const friendly = /链接|截图|视频|粘贴/.test(msg) ? msg : formatAiErrorMessage(err);
      setInlineStatus(status, friendly, 'bad');
      goBtn.removeAttribute('disabled');
      goBtn.innerHTML = '✨ 120B AI 智能解析';
    }
  };
}

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
        <button type="button" class="btn primary-action-btn ai-import-btn" id="aiImportBtn">✨ AI 一键导入</button>
        <button type="button" class="btn primary-action-btn manual-add-btn" id="addBtn">➕ 手动新建菜谱</button>
      </div>
      <div class="recipe-filter-row">
        <label class="recipe-filter-toggle"><input type="checkbox" id="methodOnly" checked>只看有做法</label>
        <span class="recipe-count" id="recipeCount"></span>
      </div>
    </div>
    <div class="grid" id="grid"></div>
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
  for (const r of allRecipes) {
    const st = calculateStockStatus(r, pack, inv);
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
        grid.appendChild(empty);
        return;
      }
      recipeCount.textContent = `找到 ${results.length} 道相关菜`;
      results.forEach(({ recipe: r, reasons }) => {
        const reason = (reasons && reasons.length) ? reasons.slice(0, 2).join(' · ') : '';
        grid.appendChild(recipeCard(r, map[r.id], reason ? { reason } : null, { onRoute }));
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
    base.forEach(r => { grid.appendChild(recipeCard(r, map[r.id], null, { onRoute })); });
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
  wrap.querySelector('#aiImportBtn').onclick = openImportModal;
  wrap.querySelector('#addBtn').onclick = () => {
    const id = genId(); const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] };
    overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{ item: '', qty: null, unit: 'g' }];
    saveOverlay(overlay); window.invalidatePackCache?.(); location.hash = `#recipe-edit:${id}`;
  };
  return wrap;
}
