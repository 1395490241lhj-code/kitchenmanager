// v156 app.js - 路由与初始化（页面渲染已拆分到 src/views/）
import { el, els } from './src/dom.js?v=230';
import { S } from './src/storage.js?v=230';
import { applyOverlay, loadOverlay } from './src/backup.js?v=230';
import { runLocalStorageMigrations } from './src/migrations.js?v=230';
import { escapeHtml } from './src/components/status.js?v=230';
import { renderShopping } from './src/views/shopping-view.js?v=230';
import { renderInventory } from './src/views/inventory-view.js?v=230';
import { renderRecipeEditor } from './src/views/recipe-editor-view.js?v=230';
import { renderRecipeDetail } from './src/views/recipe-detail-view.js?v=230';
import { renderHome } from './src/views/home-view.js?v=230';
import { renderRecipes } from './src/views/recipes-view.js?v=230';
import { renderSettings } from './src/views/settings-view.js?v=230';
import { applyCompletionOverlay } from './src/recipe-completion.js?v=230';
import { initTheme } from './src/theme.js?v=230';
import { maybeStartOnboarding } from './src/onboarding.js?v=230';
import { initPwaInstallPrompt } from './src/pwa-install.js?v=230';

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

function renderInventoryTab(pack, onRoute) {
  const wrap = document.createElement('div');
  wrap.innerHTML = '<h2 class="section-title">我的食材</h2>';
  wrap.appendChild(renderInventory(pack, { showTitle: false, onInventoryChanged: onRoute }));
  return wrap;
}

/*
Current route map:
- #today: today dashboard, rendered by the existing home view.
- #inventory: inventory tab. This preserves the old hash as a valid deep link.
- #shopping: shopping list.
- #recipes: recipe list.
- #settings: "Me" tab, currently rendered by the settings view.
- #recipe:id: recipe detail.
- #recipe-edit:id: recipe editor.
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
    if (!hash) {
      location.replace('#today');
      return;
    }

    els('nav a').forEach(a => a.classList.remove('active'));
    if (hash === 'recipes' || hash.startsWith('recipe:') || hash.startsWith('recipe-edit:')) el('#nav-recipe')?.classList.add('active');
    else if (hash === 'shopping') el('#nav-shop')?.classList.add('active');
    else if (hash === 'settings') el('#nav-me')?.classList.add('active');
    else if (hash === 'inventory') el('#nav-inventory')?.classList.add('active');
    else el('#nav-today')?.classList.add('active');

    let view;
    if (hash.startsWith('recipe-edit:')) {
      const id = hash.split(':')[1];
      // Use baseWithCompletion so the editor shows the same method/ingredients as the detail page.
      // User localStorage overlay is still applied inside renderRecipeEditor on top of this.
      view = renderRecipeEditor(id, baseWithCompletion, { replaceView: nextView => app.replaceChildren(nextView) });
    } else if (hash.startsWith('recipe:')) {
      const id = hash.split(':')[1];
      view = renderRecipeDetail(id, pack, { onRoute });
    } else if (hash === 'today') {
      view = renderHome(pack, { onRoute });
    } else if (hash === 'inventory') {
      view = renderInventoryTab(pack, onRoute);
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
initPwaInstallPrompt({
  onChange: () => {
    const hash = location.hash.replace('#', '') || 'today';
    if (hash === 'today') onRoute();
  }
});
onRoute();

/* ──────────────────────────────────────────────────────────────────────────
 * 移动端底部 Dock 紧凑态：向下滚收缩成纯图标，向上滚 / 靠近顶部 / 切换页面 / 点击展开。
 * 纯 UI（只切 body class，不写 localStorage、不动路由）。仅 ≤720px 生效；桌面不受影响。
 * ────────────────────────────────────────────────────────────────────────── */
(() => {
  const mobile = window.matchMedia('(max-width: 720px)');
  const setCompact = (on) => document.body.classList.toggle('is-dock-compact', on && mobile.matches);
  const isCompact = () => document.body.classList.contains('is-dock-compact');
  const TOP_EXPAND_Y = 64;
  const DOWN_COMPACT_Y = 96;
  const DOWN_SCROLL_DELTA = 6;
  const UP_SCROLL_DELTA = 32;
  const BOTTOM_GUARD = 120;
  let lastY = window.scrollY || 0;
  let upwardAnchorY = lastY;
  let ticking = false;

  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      const y = window.scrollY || 0;
      const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      const nearBottom = maxY > 0 && y >= maxY - BOTTOM_GUARD;
      const scrollingDown = y > lastY + DOWN_SCROLL_DELTA;
      const scrollingUp = y < lastY;
      if (!mobile.matches) { setCompact(false); upwardAnchorY = y; }
      else if (maxY <= DOWN_COMPACT_Y) { setCompact(false); upwardAnchorY = y; } // 短页面没有必要收缩
      else if (y < TOP_EXPAND_Y) { setCompact(false); upwardAnchorY = y; }       // 靠近顶部 → 展开
      else if (scrollingDown && y > DOWN_COMPACT_Y) { upwardAnchorY = y; setCompact(true); }
      else if (nearBottom && isCompact()) setCompact(true); // iOS 底部回弹：保持紧凑，避免误判向上滚
      else if (scrollingUp && y < upwardAnchorY - UP_SCROLL_DELTA) { setCompact(false); upwardAnchorY = y; }
      lastY = y;
      ticking = false;
    });
  };
  window.addEventListener('scroll', onScroll, { passive: true });

  // 切换页面（hashchange）后总是展开；scrollY 复位由各视图重渲染负责。
  window.addEventListener('hashchange', () => { lastY = 0; upwardAnchorY = 0; setCompact(false); });
  // 点击底部导航：先展开再跳转（跳转本身由 a[href] 完成）。
  el('nav')?.addEventListener('click', () => setCompact(false));
  // 视口跨过 720px 断点时清掉紧凑态，保证桌面始终展开。
  mobile.addEventListener('change', () => setCompact(false));
})();

// 首次进入时启动新手引导（内部已判断 km_onboarded_v1，并略延迟等首屏渲染）。
maybeStartOnboarding();
