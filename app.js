// v152 app.js - 路由与初始化（页面渲染已拆分到 src/views/）
import { el, els } from './src/dom.js?v=89';
import { applyOverlay, loadOverlay } from './src/backup.js?v=2';
import { runLocalStorageMigrations } from './src/migrations.js?v=1';
import { escapeHtml } from './src/components/status.js?v=1';
import { renderShopping } from './src/views/shopping-view.js?v=1';
import { renderInventory } from './src/views/inventory-view.js?v=1';
import { renderRecipeEditor } from './src/views/recipe-editor-view.js?v=1';
import { renderRecipeDetail } from './src/views/recipe-detail-view.js?v=1';
import { renderHome } from './src/views/home-view.js?v=1';
import { renderRecipes } from './src/views/recipes-view.js?v=1';
import { renderSettings } from './src/views/settings-view.js?v=1';

// 1. 全局错误捕获
window.onerror = function(msg, url, line, col, error) {
  const body = document.querySelector('body');
  if (body && !document.getElementById('global-err-console')) {
    const errDiv = document.createElement('div');
    errDiv.id = 'global-err-console';
    errDiv.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:white;color:red;z-index:99999;padding:20px;overflow:auto;font-family:monospace;font-size:14px;border-bottom:2px solid red;';
    errDiv.innerHTML = `<h3>⚠️ 发生错误</h3><p>${msg}</p><p>Line: ${line}</p><button onclick="this.parentElement.remove()" style="padding:5px 10px;border:1px solid #333;margin-top:10px;">关闭</button>`;
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

async function loadBasePack() {
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  let pack = { recipes: [], recipe_ingredients: {} };
  try {
    const res = await fetch(url, { cache: 'no-store' });
    if (res.ok) {
      pack = await res.json();
      if (!Array.isArray(pack.recipes)) pack.recipes = [];
      if (!pack.recipe_ingredients) pack.recipe_ingredients = {};
    }
  } catch (e) { console.error('Base pack error', e); }

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
        <div class="card" style="max-width:720px;margin:40px auto;">
          <h2>数据升级没有完成</h2>
          <p class="meta">原来的厨房数据没有被清空。请先不要继续录入，建议导出浏览器数据备份后再刷新重试。</p>
          <p style="color:var(--danger)">${escapeHtml(migrationError.message || migrationError)}</p>
          <button type="button" class="btn ok" onclick="location.reload()">刷新重试</button>
        </div>`;
      return;
    }
    const base = await loadBasePack();
    const overlay = loadOverlay();
    const pack = applyOverlay(base, overlay);
    const hash = location.hash.replace('#', '');

    els('nav a').forEach(a => a.classList.remove('active'));
    if (hash === 'recipes' || hash.startsWith('recipe:') || hash.startsWith('recipe-edit:')) el('#nav-recipe').classList.add('active');
    else if (hash === 'shopping') el('#nav-shop').classList.add('active');
    else if (hash === 'settings') el('#nav-set').classList.add('active');
    else el('#nav-home').classList.add('active');

    let view;
    if (hash.startsWith('recipe-edit:')) {
      const id = hash.split(':')[1];
      view = renderRecipeEditor(id, base, { replaceView: nextView => app.replaceChildren(nextView) });
    } else if (hash.startsWith('recipe:')) {
      const id = hash.split(':')[1];
      view = renderRecipeDetail(id, pack);
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
    app.innerHTML = `<div style="padding:20px;text-align:center;color:red;">页面加载出错：${e.message}<br><button class="btn" onclick="location.reload()">重试</button></div>`;
  }
}

window.addEventListener('hashchange', onRoute);
onRoute();
