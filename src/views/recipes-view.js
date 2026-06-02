import { loadOverlay, saveOverlay } from '../backup.js?v=199';
import { genId } from '../shopping.js?v=199';
import { hasRecipeMethod } from '../recommendations.js?v=199';
import { recipeCard, renderRecipeSearchResults } from '../components/recipe-card.js?v=200';
import { buildCatalog } from '../ingredients.js?v=199';
import { loadInventory } from '../inventory.js?v=199';
import { importRecipeFromSource, formatAiErrorMessage } from '../ai.js?v=199';
import { escapeHtml, setInlineStatus } from '../components/status.js?v=199';

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

export function renderRecipes(pack, { onRoute = () => {} } = {}) {
  const wrap = document.createElement('div');
  const methodReadyCount = (pack.recipes || []).filter(hasRecipeMethod).length;
  const missingMethodCount = Math.max(0, (pack.recipes || []).length - methodReadyCount);
  // 头部精简：单一搜索框 + 双枪并列操作（AI 一键导入 / 手动新建）+ 紧凑过滤行。
  // 导出/导入菜谱备份已迁至「设置 → 数据管理」。
  wrap.innerHTML = `
    <h2 class="section-title">菜谱</h2>
    <div class="recipe-header">
      <input id="search" placeholder="搜索菜谱、食材（如：鸡蛋、回锅肉）..." class="recipe-search-input recipe-search-main">
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

  function draw(filter = '') {
    grid.innerHTML = '';
    const f = filter.trim();
    const methodOnly = wrap.querySelector('#methodOnly').checked;
    // 兼顾「按菜名」与「按食材」搜索：菜名/标签命中 → 直接展示;否则用富搜索结果（按食材匹配）。
    if (f) {
      const nameRows = (pack.recipes || []).filter(r =>
        (r.name && r.name.includes(f)) || (Array.isArray(r.tags) && r.tags.some(t => String(t).includes(f)))
      ).filter(r => !methodOnly || hasRecipeMethod(r));
      if (nameRows.length) {
        recipeCount.textContent = `菜名命中 ${nameRows.length} 道 · 共 ${methodReadyCount} 道有做法`;
        nameRows.forEach(r => grid.appendChild(recipeCard(r, map[r.id], null, { onRoute })));
      } else {
        recipeCount.textContent = `按食材匹配：${f}`;
        grid.appendChild(renderRecipeSearchResults(f, pack, inv, { onRoute }));
      }
      return;
    }
    const rows = (pack.recipes || []).filter(r => !methodOnly || hasRecipeMethod(r));
    recipeCount.textContent = `显示 ${rows.length} 道 · 有做法 ${methodReadyCount} · 缺做法 ${missingMethodCount}`;
    if (rows.length === 0) {
      const empty = document.createElement('div'); empty.className = 'card small';
      empty.textContent = methodOnly ? '没有符合条件的菜。可以关闭"只看有做法"查看缺做法菜谱。' : '没有符合条件的菜。';
      grid.appendChild(empty); return;
    }
    rows.forEach(r => { grid.appendChild(recipeCard(r, map[r.id], null, { onRoute })); });
  }
  draw();

  wrap.querySelector('#search').oninput = e => draw(e.target.value);
  wrap.querySelector('#methodOnly').onchange = () => draw(wrap.querySelector('#search').value);
  wrap.querySelector('#aiImportBtn').onclick = openImportModal;
  wrap.querySelector('#addBtn').onclick = () => {
    const id = genId(); const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] };
    overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{ item: '', qty: null, unit: 'g' }];
    saveOverlay(overlay); window.invalidatePackCache?.(); location.hash = `#recipe-edit:${id}`;
  };
  return wrap;
}
