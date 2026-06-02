// v156 app.js - 路由与初始化（页面渲染已拆分到 src/views/）
import { el, els } from './src/dom.js?v=199';
import { S } from './src/storage.js?v=199';
import { applyOverlay, loadOverlay } from './src/backup.js?v=199';
import { runLocalStorageMigrations } from './src/migrations.js?v=199';
import { escapeHtml } from './src/components/status.js?v=199';
import { renderShopping } from './src/views/shopping-view.js?v=199';
import { renderInventory } from './src/views/inventory-view.js?v=199';
import { renderRecipeEditor } from './src/views/recipe-editor-view.js?v=199';
import { renderRecipeDetail } from './src/views/recipe-detail-view.js?v=199';
import { renderHome } from './src/views/home-view.js?v=200';
import { renderRecipes } from './src/views/recipes-view.js?v=200';
import { renderSettings } from './src/views/settings-view.js?v=199';
import { applyCompletionOverlay } from './src/recipe-completion.js?v=199';
import { initTheme } from './src/theme.js?v=199';

// 尽早应用已保存的外观主题（浅色 / 深色 / 跟随系统），避免首屏闪烁。
initTheme();

// 1. 全局错误捕获
window.onerror = function(msg, url, line, col, error) {
  const body = document.querySelector('body');
  if (body && !document.getElementById('global-err-console')) {
    const errDiv = document.createElement('div');
    errDiv.id = 'global-err-console';
    errDiv.className = 'global-error-console';
    // 转义动态内容，避免把报错信息当作 HTML 注入到页面里。
    errDiv.innerHTML = `<h3>⚠️ 发生错误</h3><p>${escapeHtml(msg)}</p><p>Line: ${escapeHtml(line)}</p><button class="btn global-error-close" onclick="this.parentElement.remove()">关闭</button>`;
    body.appendChild(errDiv);
  }
};

const app = el('#app');
let migrationError = null;
try {
  runLocalStorageMigrations();
} catch (error) {
  migrationError = error;
  console.error('Data Migration Error:', error);
}

let cachedBasePack = null;
let cachedBaseWithCompletion = null;
let cachedEffectivePack = null;
let cachedQueryVersion = null;

export function invalidatePackCache() {
  cachedBasePack = null;
  cachedBaseWithCompletion = null;
  cachedEffectivePack = null;
}
window.invalidatePackCache = invalidatePackCache;

export async function getCurrentPack({ force = false } = {}) {
  const searchParams = new URLSearchParams(location.search);
  const currentVersion = searchParams.get('v') || '23';

  if (force || cachedQueryVersion !== currentVersion) {
    invalidatePackCache();
    cachedQueryVersion = currentVersion;
  }

  if (!cachedBasePack) {
    cachedBasePack = await loadBasePack(currentVersion);
  }
  if (!cachedBaseWithCompletion) {
    cachedBaseWithCompletion = await applyCompletionOverlay(cachedBasePack);
  }
  if (!cachedEffectivePack) {
    const overlay = loadOverlay();
    cachedEffectivePack = applyOverlay(cachedBaseWithCompletion, overlay);
  }
  return cachedEffectivePack;
}

// 菜谱库模式：'curated' = 精简日常库（默认），'full' = 完整原始库。
export function getLibraryMode() {
  const s = S.load(S.keys.settings, {});
  return s.recipeLibraryMode === 'full' ? 'full' : 'curated';
}

const LIBRARY_FILES = {
  curated: './data/sichuan-recipes.curated.json',
  full: './data/sichuan-recipes.json'
};

async function fetchPackFile(file, v) {
  const url = new URL(file, location).href + '?v=' + v;
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const pack = await res.json();
  if (!Array.isArray(pack.recipes)) pack.recipes = [];
  if (!pack.recipe_ingredients) pack.recipe_ingredients = {};
  return pack;
}

async function loadBasePack(v = '23') {
  const mode = getLibraryMode();
  let pack = { recipes: [], recipe_ingredients: {} };
  try {
    pack = await fetchPackFile(LIBRARY_FILES[mode], v);
  } catch (e) {
    if (mode === 'curated') {
      // 精简库加载失败时自动回退到完整库，避免白屏。
      console.warn('[library] 精简菜谱库加载失败，回退到完整库：', e.message);
      try { pack = await fetchPackFile(LIBRARY_FILES.full, v); }
      catch (e2) { console.error('Base pack error', e2); }
    } else {
      console.error('Base pack error', e);
    }
  }

  const staticMethods = window.RECIPE_METHODS || {};
  const existingNames = new Set(pack.recipes.map(r => r.name));
  Object.keys(staticMethods).forEach(name => {
    if (!existingNames.has(name)) {
      const newId = 'static-' + Math.abs(name.split('').reduce((a, b) => { a = ((a << 5) - a) + b.charCodeAt(0); return a & a; }, 0));
      pack.recipes.push({ id: newId, name: name, tags: ['家常菜', '新增'] });
      existingNames.add(name);
    }
  });

  const hocData = window.HOC_DATA || [];
  hocData.forEach(item => {
    if (!existingNames.has(item.name)) {
      const newId = 'hoc-' + Math.abs(item.name.split('').reduce((a, b) => { a = ((a << 5) - a) + b.charCodeAt(0); return a & a; }, 0));
      pack.recipes.push({ id: newId, name: item.name, tags: item.tags || ['家常菜'], staticMethod: item.method });
      if (item.ingredients && Array.isArray(item.ingredients)) {
        pack.recipe_ingredients[newId] = item.ingredients.map(ingName => ({ item: ingName, qty: null, unit: null }));
      }
      existingNames.add(item.name);
    }
  });
  return pack;
}

/*
Hash 路由说明：
- #inventory：厨房首页，保留旧 hash，避免破坏已有链接。
- #shopping：购物清单。
- #recipes：菜谱列表。
- #settings：设置。
- #recipe:id：菜谱详情。
- #recipe-edit:id：菜谱编辑。
*/
async function onRoute() {
  try {
    if (migrationError) {
      app.innerHTML = `
        <div class="card migration-error-card">
          <h2>数据升级没有完成</h2>
          <p class="meta">原来的厨房数据没有被清空。请先不要继续录入，建议导出浏览器数据备份后再刷新重试。</p>
          <p class="text-danger">${escapeHtml(migrationError.message || migrationError)}</p>
          <button type="button" class="btn ok" onclick="location.reload()">刷新重试</button>
        </div>`;
      return;
    }
    const pack = await getCurrentPack();
    const baseWithCompletion = cachedBaseWithCompletion;
    const hash = location.hash.replace('#', '');

    els('nav a').forEach(a => a.classList.remove('active'));
    if (hash === 'recipes' || hash.startsWith('recipe:') || hash.startsWith('recipe-edit:')) el('#nav-recipe').classList.add('active');
    else if (hash === 'shopping') el('#nav-shop').classList.add('active');
    else if (hash === 'settings') el('#nav-set').classList.add('active');
    else el('#nav-home').classList.add('active');

    let view;
    if (hash.startsWith('recipe-edit:')) {
      const id = hash.split(':')[1];
      // Use baseWithCompletion so the editor shows the same method/ingredients as the detail page.
      // User localStorage overlay is still applied inside renderRecipeEditor on top of this.
      view = renderRecipeEditor(id, baseWithCompletion, { replaceView: nextView => app.replaceChildren(nextView) });
    } else if (hash.startsWith('recipe:')) {
      const id = hash.split(':')[1];
      view = renderRecipeDetail(id, pack, { onRoute });
    } else if (hash === 'shopping') {
      view = renderShopping(pack, { onRoute });
    } else if (hash === 'recipes') {
      view = renderRecipes(pack, { onRoute });
    } else if (hash === 'settings') {
      view = renderSettings();
    } else {
      view = renderHome(pack, { onRoute });
    }
    app.replaceChildren(view);
  } catch (e) {
    console.error('Routing Error:', e);
    app.innerHTML = `<div class="route-error-panel">页面加载出错：${e.message}<br><button class="btn" onclick="location.reload()">重试</button></div>`;
  }
}

window.addEventListener('hashchange', onRoute);
onRoute();
