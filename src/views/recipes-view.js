import { S } from '../storage.js?v=222';
import { hasRecipeMethod, calculateStockStatus, loadFavoriteRecipeIds, loadRecipeActivity } from '../recommendations.js?v=222';
import { recipeCard } from '../components/recipe-card.js?v=223';
import { buildCatalog } from '../ingredients.js?v=222';
import { loadInventory } from '../inventory.js?v=222';
import { RECIPE_CATEGORIES, searchRecipes, matchesCategory } from '../recipe-search.js?v=222';
import { showRecipeCreateModal } from '../components/recipe-create-modal.js?v=222';
import { openRecipeImportModal } from '../components/recipe-import-modal.js?v=223';

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
// 场景 chip + 「查看更多菜谱」展开状态：仅页面内存，不写 localStorage。
let activeRecipeScenario = '全部';
let showFullLibrary = false;

// ── 新手友好首屏：场景 chips + 白名单家常菜（轻量规则，零 AI、零新数据字段）──

const RECIPE_SCENARIOS = ['全部', '快手', '下饭', '清淡', '省钱', '消耗鸡蛋', '消耗蔬菜', '一个人吃'];

// 新手友好优先候选菜名（必须在当前库里真实存在才展示，缺失自动跳过）。
const STARTER_NAME_WHITELIST = [
  '番茄炒蛋', '麻婆豆腐', '土豆丝', '家常豆腐', '鱼香茄子', '土豆烧牛肉',
  '青椒皮蛋', '干煸豆角', '青椒肉丝', '红烧茄子', '西红柿鸡蛋面', '蛋炒饭',
  '酸辣土豆丝', '蚝油生菜', '清炒时蔬', '蒜蓉青菜', '可乐鸡翅', '红烧肉',
  '回锅肉', '水煮肉片', '宫保鸡丁', '鱼香肉丝', '紫菜蛋花汤', '煎鸡蛋'
];

// 统一拿食材信息：兼容 recipe_ingredients 映射 / r.ingredients 数组 / 字符串 / 缺失。
function ingredientsInfo(r, map) {
  const raw = (map && map[r?.id]) ?? r?.ingredients;
  if (Array.isArray(raw)) {
    const names = raw.map(it => typeof it === 'string' ? it : (it?.item || it?.name || '')).filter(Boolean);
    return { count: raw.length, text: names.join(' ') };
  }
  if (typeof raw === 'string') return { count: 0, text: raw };
  return { count: 0, text: '' };
}

// 生活化场景轻量匹配（初版规则：菜名/标签/食材关键词 + 食材数量，不做复杂算法）。
function recipeMatchesScenario(r, scenario, map) {
  if (scenario === '全部') return true;
  const name = String(r?.name || '');
  const tags = Array.isArray(r?.tags) ? r.tags.join(' ') : '';
  const info = ingredientsInfo(r, map);
  const nameTags = name + ' ' + tags;
  const nameIngs = name + ' ' + info.text;
  switch (scenario) {
    case '快手': return /[炒煎拌汤蛋]|青菜|土豆丝/.test(nameTags) || (info.count > 0 && info.count <= 6);
    case '下饭': return /麻婆|红烧|鱼香|回锅|宫保|肉丝|茄子|豆腐|辣/.test(name);
    case '清淡': return /清炒|蒜蓉|青菜|生菜|汤|蒸|蛋花/.test(name);
    case '省钱': return /鸡蛋|土豆|豆腐|青菜|面|饭|白菜|萝卜/.test(name);
    case '消耗鸡蛋': return /鸡蛋|蛋/.test(nameIngs);
    case '消耗蔬菜': return /青菜|白菜|生菜|土豆|番茄|西红柿|茄子|豆角|胡萝卜|包菜/.test(nameIngs);
    case '一个人吃': return /面|饭|蛋|炒饭|汤|盖饭/.test(name) || (info.count > 0 && info.count <= 5);
    default: return true;
  }
}

// 新手卡片的轻量理由标签（渲染时现算，最多一个，不新增数据字段）。
function starterBadge(r, map) {
  const name = String(r?.name || '');
  const info = ingredientsInfo(r, map);
  if (/[炒煎拌]|土豆丝/.test(name)) return '适合快手';
  if (/麻婆|红烧|鱼香|回锅|宫保|肉丝|辣/.test(name)) return '很下饭';
  if (/清炒|蒜蓉|青菜|生菜|汤|蒸|蛋花/.test(name)) return '清淡一点';
  if (/鸡蛋|土豆|豆腐|白菜|萝卜|面|饭/.test(name)) return '省钱好做';
  if (info.count > 0 && info.count <= 6) return '步骤简单';
  return '食材常见';
}

// 新手友好家常菜：白名单命中优先；不足 12 道时按简单规则从当前库补足，最多 24 道。
function getStarterRecipes(pack) {
  const all = Array.isArray(pack?.recipes) ? pack.recipes : [];
  const map = pack?.recipe_ingredients || {};
  const picked = [];
  const pickedIds = new Set();
  for (const wanted of STARTER_NAME_WHITELIST) {
    const r = all.find(x => x?.name === wanted);
    if (r && !pickedIds.has(r.id)) { picked.push(r); pickedIds.add(r.id); }
    if (picked.length >= 24) break;
  }
  if (picked.length < 12) {
    for (const r of all) {
      if (picked.length >= 24) break;
      if (!r || pickedIds.has(r.id)) continue;
      if (!hasRecipeMethod(r)) continue;                       // 有做法
      const info = ingredientsInfo(r, map);
      if (!(info.count > 0 && info.count <= 8)) continue;       // 食材常见、数量不夸张
      if (String(r.name || '').length > 8) continue;            // 菜名别太生僻冗长
      picked.push(r); pickedIds.add(r.id);
    }
  }
  return picked.slice(0, 24);
}

export function renderRecipes(pack, { onRoute = () => {} } = {}) {
  const wrap = document.createElement('div');
  const allRecipes = pack.recipes || [];
  const methodReadyCount = allRecipes.filter(hasRecipeMethod).length;
  const missingMethodCount = Math.max(0, allRecipes.length - methodReadyCount);
  // 首屏新手友好：大标题 + 轻量操作行（导入/新建降噪）+ 搜索 + 场景 chips +
  // 「新手友好家常菜」区块；完整菜谱库（分类 chips + 只看有做法 + 全量网格）默认收起。
  wrap.innerHTML = `
    <div class="recipe-page-head">
      <h2 class="section-title recipe-page-title">今天想做点什么？</h2>
      <div class="recipe-light-actions">
        <button type="button" class="recipe-light-action" id="aiImportBtn">从链接/截图导入</button>
        <button type="button" class="recipe-light-action" id="addBtn">手动新建</button>
      </div>
    </div>
    <p class="recipe-page-sub">先从几道稳妥的家常菜开始，也可以搜索食材或菜名。</p>
    <div class="recipe-header">
      <input id="search" placeholder="搜菜名或食材，比如 鸡蛋、土豆、豆腐" class="recipe-search-input recipe-search-main">
      <div class="recipe-scene-scroll">
        <div class="recipe-scene-chips" id="sceneChips" role="tablist" aria-label="场景筛选"></div>
      </div>
    </div>
    <div class="recipe-starter" id="starterSection">
      <h3 class="recipe-starter-title">新手友好家常菜</h3>
      <p class="recipe-starter-sub">步骤简单、食材常见，适合不知道吃什么的时候先看看。</p>
      <div class="grid recipe-grid" id="starterGrid"></div>
      <button type="button" class="recipe-more-toggle" id="moreToggle">查看更多菜谱 ⌄</button>
    </div>
    <div class="recipe-full-section is-hidden" id="fullSection">
      <div class="recipe-cat-scroll">
        <div class="recipe-cat-chips" id="recipeCatChips" role="tablist" aria-label="菜谱分类"></div>
      </div>
      <div class="recipe-filter-row">
        <label class="recipe-filter-toggle"><input type="checkbox" id="methodOnly" checked>只看有做法</label>
        <span class="recipe-count" id="recipeCount"></span>
      </div>
      <div class="grid recipe-grid" id="grid"></div>
    </div>
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

  // ── 新手友好区 + 场景 chips + 「查看更多菜谱」折叠 ──
  const starterSection = wrap.querySelector('#starterSection');
  const fullSection = wrap.querySelector('#fullSection');
  const starterGrid = wrap.querySelector('#starterGrid');
  const moreToggle = wrap.querySelector('#moreToggle');
  const sceneChipsBox = wrap.querySelector('#sceneChips');
  const starterList = getStarterRecipes(pack);

  // 区块可见性：有搜索词 → 直接展示搜索结果（隐藏新手区）；
  // 无搜索词 → 新手区在前，完整库按「查看更多菜谱」展开状态显示。
  const syncSections = () => {
    const q = (searchInput.value || '').trim();
    starterSection.classList.toggle('is-hidden', !!q);
    fullSection.classList.toggle('is-hidden', !q && !showFullLibrary);
    moreToggle.textContent = showFullLibrary ? '收起更多菜谱 ⌃' : '查看更多菜谱 ⌄';
  };

  // 场景筛选下的候选池：白名单新手菜优先，再从有做法的全库补足，最多 24 道。
  const scenarioPool = (scenario) => {
    if (scenario === '全部') return starterList;
    const starterIds = new Set(starterList.map(r => r.id));
    const hit = starterList.filter(r => recipeMatchesScenario(r, scenario, map));
    for (const r of allRecipes) {
      if (hit.length >= 24) break;
      if (!r || starterIds.has(r.id)) continue;
      if (!hasRecipeMethod(r)) continue;
      if (recipeMatchesScenario(r, scenario, map)) hit.push(r);
    }
    return hit.slice(0, 24);
  };

  const drawStarter = () => {
    starterGrid.innerHTML = '';
    const pool = scenarioPool(activeRecipeScenario);
    if (!pool.length) {
      const empty = document.createElement('div');
      empty.className = 'recipe-empty-state recipe-scene-empty';
      empty.innerHTML = `
        <p class="recipe-empty-title">这里暂时没有合适的菜</p>
        <p class="recipe-empty-hint">换个分类，或者搜一下你手头的食材。</p>
        <button type="button" class="btn small" id="clearSceneBtn">清除筛选</button>`;
      empty.querySelector('#clearSceneBtn').onclick = () => { activeRecipeScenario = '全部'; renderSceneChips(); drawStarter(); };
      starterGrid.appendChild(empty);
      return;
    }
    pool.forEach(r => {
      starterGrid.appendChild(recipeCard(r, map[r.id], { reason: starterBadge(r, map) }, { onRoute, compact: true, statusData: statusById.get(r.id), pack, inv }));
    });
  };

  const renderSceneChips = () => {
    sceneChipsBox.querySelectorAll('.recipe-scene-chip').forEach(c => {
      const on = c.dataset.scene === activeRecipeScenario;
      c.classList.toggle('is-active', on);
      c.setAttribute('aria-selected', on ? 'true' : 'false');
    });
  };
  RECIPE_SCENARIOS.forEach(scene => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'recipe-scene-chip';
    chip.dataset.scene = scene;
    chip.textContent = scene;
    chip.setAttribute('role', 'tab');
    chip.onclick = () => { activeRecipeScenario = scene; renderSceneChips(); drawStarter(); };
    sceneChipsBox.appendChild(chip);
  });

  moreToggle.onclick = () => { showFullLibrary = !showFullLibrary; syncSections(); draw(); };

  function draw() {
    syncSections();
    grid.innerHTML = '';
    const q = (searchInput.value || '').trim();
    activeRecipeQuery = q; // 持久化，供下次重渲染恢复
    if (!q && !showFullLibrary) return; // 完整库收起且无搜索：网格不渲染，省得白排几十张卡
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
  renderSceneChips();
  drawStarter();
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
