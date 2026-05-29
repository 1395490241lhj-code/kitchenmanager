import { loadOverlay, saveOverlay } from '../backup.js?v=163';
import { genId } from '../shopping.js?v=163';
import { hasRecipeMethod } from '../recommendations.js?v=163';
import { recipeCard, renderRecipeSearchResults } from '../components/recipe-card.js?v=163';
import { buildCatalog } from '../ingredients.js?v=163';
import { loadInventory } from '../inventory.js?v=163';

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
  wrap.innerHTML = `
    <h2 class="section-title">菜谱</h2>
    <div class="recipe-toolbar">
      <input id="search" placeholder="搜菜谱..." class="recipe-search-input">
      <label class="recipe-filter-toggle"><input type="checkbox" id="methodOnly" checked>只看有做法</label>
      <span class="recipe-count" id="recipeCount"></span>
      <div class="recipe-actions">
        <a class="btn ok icon-only" id="addBtn" title="新建菜谱">
           <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
        </a>
        <a class="btn" id="exportBtn">导出</a>
        <label class="btn"><input type="file" id="importFile" hidden>导入</label>
      </div>
    </div>
    <div class="grid" id="grid"></div>
  `;
  const grid = wrap.querySelector('#grid');
  const map = pack.recipe_ingredients || {};
  const recipeCount = wrap.querySelector('#recipeCount');

  // 从首页迁入的「搜索菜谱 / 食材」组件（置顶）。逻辑（renderRecipeSearchResults）保持不变。
  const inv = loadInventory(buildCatalog(pack));
  const searchResultsContainer = document.createElement('div');
  searchResultsContainer.className = 'search-results-container';
  const searchBar = document.createElement('div');
  searchBar.className = 'home-search recipe-top-search';
  searchBar.innerHTML = `
    <input id="recipeFinder" placeholder="找具体菜名或某个食材，比如鸡蛋、回锅肉">
    <div class="home-search-buttons">
      <button type="button" class="btn ok" id="recipeFinderGo">搜索</button>
      <button type="button" class="btn is-hidden" id="recipeFinderClear">清空</button>
    </div>`;
  const finderInput = searchBar.querySelector('#recipeFinder');
  const finderClear = searchBar.querySelector('#recipeFinderClear');
  const clearFinder = () => {
    finderInput.value = '';
    searchResultsContainer.innerHTML = '';
    finderClear.classList.add('is-hidden');
  };
  const runFinder = () => {
    const q = finderInput.value.trim();
    if (!q) { clearFinder(); return; }
    searchResultsContainer.innerHTML = '';
    searchResultsContainer.appendChild(renderRecipeSearchResults(q, pack, inv, { onRoute }));
    finderClear.classList.remove('is-hidden');
  };
  finderInput.onkeydown = (e) => { if (e.key === 'Enter') runFinder(); };
  searchBar.querySelector('#recipeFinderGo').onclick = runFinder;
  finderClear.onclick = clearFinder;
  const searchSection = document.createElement('section');
  searchSection.className = 'recipe-finder-section';
  searchSection.appendChild(searchBar);
  searchSection.appendChild(searchResultsContainer);
  wrap.insertBefore(searchSection, wrap.querySelector('.recipe-toolbar'));

  function draw(filter = '') {
    grid.innerHTML = '';
    const f = filter.trim();
    const methodOnly = wrap.querySelector('#methodOnly').checked;
    const rows = (pack.recipes || []).filter(r => (!f || r.name.includes(f)) && (!methodOnly || hasRecipeMethod(r)));
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
  wrap.querySelector('#addBtn').onclick = () => {
    const id = genId(); const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] };
    overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{ item: '', qty: null, unit: 'g' }];
    saveOverlay(overlay); window.invalidatePackCache?.(); location.hash = `#recipe-edit:${id}`;
  };
  wrap.querySelector('#exportBtn').onclick = () => {
    const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], { type: 'application/json' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'kitchen-overlay.json'; a.click();
  };
  wrap.querySelector('#importFile').onchange = (e) => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const inc = JSON.parse(reader.result); const cur = loadOverlay();
        const result = mergeOverlayPreservingCurrent(cur, inc);
        saveOverlay(result.overlay); window.invalidatePackCache?.();
        const conflictText = result.conflicts.length ? `，${result.conflicts.length} 个冲突已保留当前版本` : '';
        alert(`导入成功：新增 ${result.imported.length} 项${conflictText}。`); location.reload();
      } catch (err) { alert('导入失败：' + (err.message || err)); }
    };
    reader.readAsText(file);
  };
  return wrap;
}
