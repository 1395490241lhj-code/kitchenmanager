// v151 app.js - 服务逻辑模块化
import { CUSTOM_AI } from './src/config.js?v=89';
import { el, els } from './src/dom.js?v=89';
import { S, todayISO } from './src/storage.js?v=98';
import {
  DRY_GOODS,
  EGG_STOCK,
  DAILY_STOCKS,
  buildIngredientOptions,
  countStockStatus,
  dryStatusInfo,
  explodeCombinedItems,
  getCanonicalName,
  getDryPrepText,
  getDryGoodConfig,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  isSeasoning,
  nextDryStatus,
  normalizeKitchenAmount,
  buildCatalog
} from './src/ingredients.js?v=1';
import {
  addInventoryQty,
  ensureStockItem,
  findInventoryMatch,
  findStockItem,
  getStockCoverageForNeed,
  inventoryStateInfo,
  isInventoryAvailable,
  loadInventory,
  nextInventoryState,
  remainingDays,
  saveInventory,
  upsertInventory
} from './src/inventory.js?v=1';
import {
  addShoppingItem,
  genId,
  loadShoppingItems,
  saveShoppingItems
} from './src/shopping.js?v=1';
import {
  applyOverlay,
  buildKitchenBackup,
  downloadJsonFile,
  loadOverlay,
  restoreKitchenBackup,
  saveOverlay
} from './src/backup.js?v=1';
import {
  callAiForMethod,
  callAiSearchRecipe,
  callCloudAI,
  formatAiErrorMessage,
  recognizeReceipt,
  withTimeout
} from './src/ai.js?v=1';
import {
  addMissingRecipeIngredientsToShopping,
  addRecipeToPlan,
  calculateStockStatus,
  getLocalRecommendations,
  getMissingRecipeIngredients,
  hasRecipeMethod,
  isFavoriteRecipe,
  markRecipePlanned,
  markRecipeCooked,
  processAiData,
  toggleFavoriteRecipe
} from './src/recommendations.js?v=1';
import {
  DATA_SCHEMA_VERSION,
  runLocalStorageMigrations
} from './src/migrations.js?v=1';

// 1. 全局错误捕获
window.onerror = function(msg, url, line, col, error) {
  const app = document.querySelector('body');
  if(app && !document.getElementById('global-err-console')) {
    const errDiv = document.createElement('div');
    errDiv.id = 'global-err-console';
    errDiv.style.cssText = "position:fixed;top:0;left:0;width:100%;height:100%;background:white;color:red;z-index:99999;padding:20px;overflow:auto;font-family:monospace;font-size:14px;border-bottom:2px solid red;";
    errDiv.innerHTML = `<h3>⚠️ 发生错误</h3><p>${msg}</p><p>Line: ${line}</p><button onclick="this.parentElement.remove()" style="padding:5px 10px;border:1px solid #333;margin-top:10px;">关闭</button>`;
    app.appendChild(errDiv);
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

function escapeOptionAttr(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function escapeHtml(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function brieflyConfirmButton(button, text = '已加入') {
  if(!button) return;
  const originalText = button.textContent;
  button.textContent = text;
  button.classList.add('is-confirmed');
  button.disabled = true;
  window.setTimeout(() => {
    button.disabled = false;
    button.classList.remove('is-confirmed');
    button.textContent = originalText;
  }, 900);
}
// -------- Data Loading --------
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  let pack = {recipes:[], recipe_ingredients:{}};
  try{ 
      const res = await fetch(url, { cache:'no-store' }); 
      if(res.ok) {
          pack = await res.json(); 
          if (!Array.isArray(pack.recipes)) pack.recipes = [];
          if (!pack.recipe_ingredients) pack.recipe_ingredients = {};
      }
  } catch(e){ console.error('Base pack error', e); }
  
  const staticMethods = window.RECIPE_METHODS || {};
  const existingNames = new Set(pack.recipes.map(r => r.name));
  
  Object.keys(staticMethods).forEach(name => {
    if(!existingNames.has(name)){
      const newId = 'static-' + Math.abs(name.split('').reduce((a,b)=>{a=((a<<5)-a)+b.charCodeAt(0);return a&a},0));
      pack.recipes.push({ id: newId, name: name, tags: ["家常菜", "新增"] });
      existingNames.add(name);
    }
  });

  const hocData = window.HOC_DATA || [];
  hocData.forEach(item => {
      if(!existingNames.has(item.name)){
          const newId = 'hoc-' + Math.abs(item.name.split('').reduce((a,b)=>{a=((a<<5)-a)+b.charCodeAt(0);return a&a},0));
          pack.recipes.push({
              id: newId,
              name: item.name,
              tags: item.tags || ["家常菜"],
              staticMethod: item.method
          });
          if(item.ingredients && Array.isArray(item.ingredients)){
              pack.recipe_ingredients[newId] = item.ingredients.map(ingName => ({
                  item: ingName, qty: null, unit: null
              }));
          }
          existingNames.add(item.name);
      }
  });

  return pack;
}

// 辅助函数
// 更新 badgeFor 函数，支持冷冻状态显示
function badgeFor(e){ 
  if((e.kind || 'raw') === 'dry') return `<span class="kchip dry" title="${escapeOptionAttr(getDryPrepText(e.name))}">干货 · ${escapeHtml(getDryPrepText(e.name))}</span>`;
  if(e.isFrozen) return `<span class="kchip" style="background:#5f6b78;color:white;cursor:pointer" title="点击切换为冷藏">❄️ 冷冻</span>`;
  const r=remainingDays(e); 
  let html = '';
  if(r<=1) html = `<span class="kchip bad" style="cursor:pointer" title="点击切换为冷冻">即将过期 ${r}天</span>`; 
  else if(r<=3) html = `<span class="kchip warn" style="cursor:pointer" title="点击切换为冷冻">优先消耗 ${r}天</span>`; 
  else html = `<span class="kchip ok" style="cursor:pointer" title="点击切换为冷冻">新鲜 ${r}天</span>`; 
  return html;
}

function recipeMethodBadge(recipe) {
  return hasRecipeMethod(recipe)
    ? '<span class="kchip method-ok">有做法</span>'
    : '<span class="kchip method-missing">缺做法</span>';
}

function searchResultCard(r, statusData) {
  const card = document.createElement('div'); card.className = 'card';
  let statusBadge = statusData.status === 'ok' ? `<span class="kchip ok">✅ 库存充足</span>` : (statusData.status === 'partial' ? `<span class="kchip warn">⚠️ 缺食材</span>` : `<span class="kchip bad">❌ 暂无食材</span>`);
  
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3><div class="recipe-badge-stack">${recipeMethodBadge(r)}${statusBadge}</div></div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="controls"><button type="button" class="btn small" onclick="location.hash='#recipe:${r.id}'">${hasRecipeMethod(r) ? '查看做法' : '补做法'}</button><button type="button" class="btn small" id="addMissingBtn">🛒 加入清单</button></div>`;
  
  const addBtn = card.querySelector('#addMissingBtn');
  if (addBtn) {
    addBtn.onclick = () => {
      const plan = S.load(S.keys.plan, []);
      if (!plan.find(x => x.id === r.id)) { plan.push({ id: r.id, servings: 1 }); S.save(S.keys.plan, plan); markRecipePlanned(r.id); alert(`已加入清单。`); }
      else { alert('已在清单中。'); }
    };
  }
  return card;
}

function showRecommendationCards(container, list, pack) { 
  container.innerHTML = ''; 
  if(!list || list.length===0) { 
    container.innerHTML = '<div class="card small" style="min-width:100%;text-align:center;">暂无推荐。</div>'; 
    return; 
  } 
  const map = pack.recipe_ingredients || {}; 
  list.forEach(item => { 
    const isAi = item.isAi !== undefined ? item.isAi : false;
    container.appendChild(recipeCard(item.r, item.list || map[item.r.id], {reason: item.reason, isAi: isAi})); 
  }); 
} 
function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  // [修改] 移除内联样式，使用 CSS 类
  let topHtml = (extraInfo && extraInfo.isAi) ? `<div class="ai-badge">✨ AI 推荐</div>` : '';
  
  // [修改] 移除 h3 和 div 的内联 style，完全依赖 CSS
  card.innerHTML=`${topHtml}
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 class="r-title">${r.name}</h3>
      <div class="recipe-badge-stack">
        ${recipeMethodBadge(r)}
        ${!String(r.id).startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;border:none;">编辑</button>` : ''}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ing-compact-container"></div>
    ${extraInfo && extraInfo.reason ? `<div class="ai-reason">${extraInfo.reason}</div>` : ''}
    <div class="controls" style="margin-top:16px;"></div>`;
  
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  const editBtn = card.querySelector('.btn-edit');
  if(editBtn) editBtn.onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; };
  
  const tagContainer = card.querySelector('.ing-compact-container');
  let items = explodeCombinedItems(list||[]);
  const coreItems = items.filter(it => !isSeasoning(it.item));
  const displayItems = coreItems.length > 0 ? coreItems : items; 
  const showItems = displayItems.slice(0, 4); 
  for(const it of showItems){ const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.innerHTML = `${it.item}`; tagContainer.appendChild(span); }
  
  if(!String(r.id).startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const favoriteBtn = document.createElement('button'); favoriteBtn.type = 'button'; favoriteBtn.className = `btn small favorite-btn${isFavoriteRecipe(r.id) ? ' active' : ''}`;
    favoriteBtn.textContent = isFavoriteRecipe(r.id) ? '常做' : '设为常做';
    favoriteBtn.onclick = () => { toggleFavoriteRecipe(r.id); onRoute(); };

    const btn = document.createElement('button'); btn.type = 'button'; btn.className='btn ok small'; 
    btn.textContent = plan.has(r.id) ? '已加入' : '加入清单';
    btn.onclick = () => { const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else { p.push({id:r.id, servings:1}); markRecipePlanned(r.id); } S.save(S.keys.plan,p); onRoute(); };
    
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className='btn small'; detailBtn.textContent=hasRecipeMethod(r) ? '查看' : '补做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    
    card.querySelector('.controls').appendChild(favoriteBtn);
    card.querySelector('.controls').appendChild(btn);
    card.querySelector('.controls').appendChild(detailBtn);
  }
  return card;
}

function renderRecipeDetail(id, pack) {
  let r = (pack.recipes||[]).find(x=>x.id===id);
  if (!r && id === 'creative-ai-temp') {
      const aiData = S.load(S.keys.ai_recs, null);
      if (aiData && aiData.creative) { 
        r = { id: 'creative-ai-temp', name: aiData.creative.name, tags: ['AI创意菜'], method: '', isCreative: true }; 
      }
  }
  if(!r) {
      const div = document.createElement('div');
      div.innerHTML = `<div style="padding:20px;text-align:center;">菜谱不存在。<br><button class="btn" onclick="history.back()">返回</button></div>`;
      return div;
  }
  
  const overlay = loadOverlay();
  const ovRecipe = (overlay.recipes || {})[id];
  if (ovRecipe) { r = { ...r, ...ovRecipe, method: ovRecipe.method || r.method || '' }; }
  
  let items = [];
  if (r.isCreative) { 
    const aiData = S.load(S.keys.ai_recs, null); 
    items = [{item: aiData.creative.ingredients || '请参考AI描述'}]; 
  } else { 
    const ingList = pack.recipe_ingredients[id] || []; 
    items = explodeCombinedItems(ingList); 
  }
  
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const missingIngredients = getMissingRecipeIngredients(r, pack, inv, items);
  const plan = S.load(S.keys.plan, []);
  const isPlanned = plan.some(item => item.id === id);
  const missingSummary = missingIngredients.length
    ? `还缺 ${missingIngredients.slice(0, 3).map(item => item.item).join('、')}${missingIngredients.length > 3 ? '等' : ''}`
    : '库存看起来已经够做这道菜';
  const div = document.createElement('div'); div.className = 'detail-view';
  const missingMethodContent = `<div class="ai-empty-note">暂无详细做法。可以让 AI 先生成草稿，确认后再保存。</div><button type="button" class="btn ai" id="genMethodBtn">✨ AI 生成草稿</button>`;
  const methodContent = r.method ? `<div class="method-text">${r.method}</div>` : missingMethodContent;
  
  div.innerHTML = `<div style="margin-bottom:20px;display:flex;justify-content:space-between;"><button type="button" class="btn" onclick="history.back()">← 返回</button><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 style="color:var(--text-main);font-size:24px;">${escapeHtml(r.name)}</h2><div class="tags meta" style="margin-bottom:18px;border-bottom:1px solid var(--separator);padding-bottom:10px;">${(r.tags||[]).map(escapeHtml).join(' / ')}</div><div class="recipe-action-panel"><div class="recipe-action-copy"><span>下一步</span><strong>${escapeHtml(isPlanned ? '已经在今日计划里' : '先加入今日计划')}</strong><p>${escapeHtml(missingSummary)}。做完后只记录使用，不会自动扣库存。</p></div><div class="recipe-action-buttons"><button type="button" class="btn ok" id="detailAddPlan">${isPlanned ? '已加入今日计划' : '加入今日计划'}</button><button type="button" class="btn" id="detailAddMissing">${missingIngredients.length ? '缺少食材加入清单' : '食材已齐'}</button><button type="button" class="btn favorite-btn" id="detailMarkCooked">标记为已做完</button></div><div class="recipe-action-feedback" id="recipeActionFeedback" hidden></div></div><div class="block"><h4>用料 Ingredients</h4><div class="ing-compact-container">${items.map(it => `<div class="ing-tag-pill">${escapeHtml(it.item)} ${it.qty ? `<span class="qty">${escapeHtml(it.qty)}${escapeHtml(it.unit||'')}</span>` : ''}</div>`).join('')}</div></div><div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;
  const actionFeedback = div.querySelector('#recipeActionFeedback');
  const showActionFeedback = (text) => {
    actionFeedback.hidden = false;
    actionFeedback.textContent = text;
    window.setTimeout(() => { actionFeedback.hidden = true; }, 1800);
  };
  const detailAddPlan = div.querySelector('#detailAddPlan');
  if(isPlanned) detailAddPlan.disabled = true;
  detailAddPlan.onclick = () => {
    const added = addRecipeToPlan(id);
    if(added) {
      detailAddPlan.textContent = '已加入今日计划';
      detailAddPlan.disabled = true;
      showActionFeedback('已加入今日计划，购物清单会按计划自动计算。');
    } else {
      showActionFeedback('这道菜已经在今日计划里。');
    }
  };
  const detailAddMissing = div.querySelector('#detailAddMissing');
  if(!missingIngredients.length) detailAddMissing.disabled = true;
  detailAddMissing.onclick = () => {
    const count = addMissingRecipeIngredientsToShopping(r, pack, inv, items);
    if(count > 0) {
      brieflyConfirmButton(detailAddMissing, '已加入清单');
      showActionFeedback(`已把 ${count} 项缺少食材加入购物清单。`);
    }
  };
  div.querySelector('#detailMarkCooked').onclick = (e) => {
    const result = markRecipeCooked(id);
    brieflyConfirmButton(e.currentTarget, '已记录');
    showActionFeedback(result.removedFromPlan ? '已记录做完，并从今日计划移除；库存没有自动扣减。' : '已记录做完；库存没有自动扣减。');
  };
  
  const methodArea = div.querySelector('#methodArea');
  const showMissingMethod = () => {
    methodArea.innerHTML = missingMethodContent;
    bindGenerateMethodButton();
  };
  const showMethodDraft = (text) => {
    methodArea.innerHTML = `
      <div class="ai-draft-card">
        <div class="ai-draft-title">AI 生成草稿</div>
        <div class="method-text">${escapeHtml(text)}</div>
        <div class="controls ai-draft-actions">
          <button type="button" class="btn ok" id="saveAiMethodBtn">保存到菜谱</button>
          <button type="button" class="btn" id="regenerateAiMethodBtn">重新生成</button>
          <button type="button" class="btn bad" id="cancelAiMethodBtn">取消</button>
        </div>
      </div>
    `;
    methodArea.querySelector('#saveAiMethodBtn').onclick = () => {
      const currentOverlay = loadOverlay();
      currentOverlay.recipes = currentOverlay.recipes || {};
      currentOverlay.recipes[id] = { ...(currentOverlay.recipes[id]||{}), method: text };
      saveOverlay(currentOverlay);
      r.method = text;
      methodArea.innerHTML = `<div class="method-text">${escapeHtml(text)}</div><div class="small ok" style="margin-top:10px">已保存到菜谱</div>`;
    };
    methodArea.querySelector('#regenerateAiMethodBtn').onclick = e => generateMethodDraft(e.currentTarget);
    methodArea.querySelector('#cancelAiMethodBtn').onclick = () => showMissingMethod();
  };
  const generateMethodDraft = async (triggerBtn = null) => {
      const genBtn = triggerBtn || methodArea.querySelector('#genMethodBtn');
      if(!genBtn) return;
      const resetLabel = genBtn.id === 'regenerateAiMethodBtn' ? '重新生成' : '✨ AI 生成草稿';
      genBtn.setAttribute('disabled', 'true');
      genBtn.innerHTML = '<span class="spinner"></span> 生成中...';
      
      const maxRetries = 1; // 允许自动重试1次
      let attempt = 0;
      let success = false;

      while(attempt <= maxRetries && !success) {
          try {
            attempt++;
            const text = await withTimeout(callAiForMethod(r.name, items), 30000, 'AI 生成超时');
            success = true;
            showMethodDraft(text);
          } catch(e) {
            console.warn(`Attempt ${attempt} failed:`, e);
            if (attempt > maxRetries) {
                alert(formatAiErrorMessage(e));
                genBtn.innerHTML = resetLabel;
                genBtn.removeAttribute('disabled');
            } else {
                genBtn.innerHTML = `<span class="spinner"></span> 正在重试 (${attempt}/${maxRetries})...`;
                await new Promise(r => setTimeout(r, 1000)); // 等1秒重试
            }
          }
      }
  };
  function bindGenerateMethodButton() {
    const genBtn = methodArea.querySelector('#genMethodBtn');
    if(genBtn) genBtn.onclick = generateMethodDraft;
  }
  if(!r.method) {
    bindGenerateMethodButton();
  }
  return div;
}

function renderRecipeSearchResults(query, pack, inv) {
  const container = document.createElement('div');
  container.innerHTML = `<h2 class="section-title">搜索结果：${query}</h2><div class="grid" id="search-grid"></div>`;
  const grid = container.querySelector('#search-grid');
  const results = (pack.recipes||[]).filter(r => r.name.includes(query));
  if (results.length > 0) {
    results.forEach(r => {
      const status = calculateStockStatus(r, pack, inv);
      grid.appendChild(searchResultCard(r, status));
    });
  } else {
    container.innerHTML += `<div style="text-align:center; padding:40px;"><p style="color:var(--text-secondary)">未找到相关菜谱。</p><button type="button" class="btn ai" id="aiSearchBtn">🤖 呼叫 AI 搜索并生成【${query}】</button></div>`;
    setTimeout(() => {
        const btn = container.querySelector('#aiSearchBtn');
        if(btn) {
            btn.onclick = async () => {
                btn.innerHTML = '<span class="spinner"></span> AI 搜索中...';
                try {
                    const invNames = inv.map(x=>x.name).join(',');
                    const aiRes = await callAiSearchRecipe(query, invNames);
                    const tempId = 'ai-search-' + Date.now();
                    const overlay = loadOverlay();
                    overlay.recipes = overlay.recipes || {};
                    overlay.recipes[tempId] = { name: aiRes.name, tags: ['AI搜索'], method: aiRes.method };
                    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
                    const ings = (aiRes.ingredients||'').split(/[，,]/).map(s => ({item: s.trim()}));
                    overlay.recipe_ingredients[tempId] = ings;
                    saveOverlay(overlay);
                    location.hash = `#recipe:${tempId}`; location.reload();
                } catch(e) { alert(formatAiErrorMessage(e)); btn.innerHTML = '🤖 呼叫 AI 搜索'; }
            };
        }
    }, 0);
  }
  return container;
}

function formatRemainingText(days) {
  if (days < 0) return `已过期 ${Math.abs(days)} 天`;
  if (days === 0) return '今天到期';
  return `还剩 ${days} 天`;
}

function formatInventoryAmount(item) {
  const qty = Number(item.qty);
  if (!isFinite(qty) || qty <= 0) return '未填数量';
  return `${qty}${item.unit || ''}`;
}

function getExpiringItems(inv) {
  return [...(inv || [])]
    .filter(item => remainingDays(item) <= 3)
    .sort((a, b) => remainingDays(a) - remainingDays(b))
    .slice(0, 4);
}

function hasUsableInventory(inv) {
  return (inv || []).some(isInventoryAvailable);
}

function getHomeRecipeGroups(pack, inv) {
  const rows = (pack.recipes || []).filter(hasRecipeMethod).map(r => {
    const list = explodeCombinedItems((pack.recipe_ingredients || {})[r.id] || []);
    const core = list.filter(ing => !isSeasoning(ing.item));
    if (core.length === 0) return null;
    const status = calculateStockStatus(r, pack, inv);
    const missing = status.missing || [];
    const matched = Math.max(0, core.length - missing.length);
    const expiringMatches = core
      .map(ing => findInventoryMatch(inv, ing.item))
      .filter(item => item && remainingDays(item) <= 3);
    return { r, list, status: status.status, missing, matched, total: core.length, expiringMatches };
  }).filter(Boolean);

  const ready = rows
    .filter(row => row.status === 'ok')
    .sort((a, b) => b.expiringMatches.length - a.expiringMatches.length || b.total - a.total || a.r.name.localeCompare(b.r.name, 'zh-Hans-CN'))
    .slice(0, 4)
    .map(row => {
      const reason = row.expiringMatches.length
        ? `能顺手用掉：${row.expiringMatches.slice(0, 2).map(item => item.name).join('、')}`
        : `已有 ${row.total}/${row.total} 项核心食材`;
      return { r: row.r, list: row.list, reason };
    });

  const almost = rows
    .filter(row => row.status === 'partial' && row.missing.length <= 2)
    .sort((a, b) => a.missing.length - b.missing.length || b.matched - a.matched || a.r.name.localeCompare(b.r.name, 'zh-Hans-CN'))
    .slice(0, 4)
    .map(row => ({ r: row.r, list: row.list, reason: `还缺：${row.missing.map(x => x.name).join('、')}` }));

  return { ready, almost };
}

function renderHomeStats(expiring, ready, almost, shoppingItems = []) {
  const div = document.createElement('div');
  const plan = S.load(S.keys.plan, []);
  const activeShopping = shoppingItems.filter(item => !item.done);
  let title = '今天先看厨房状态';
  let body = '不用先想吃什么，下面会按库存、快到期和常做菜自动给你排优先级。';
  if (expiring.length) {
    title = `优先用掉 ${expiring[0].name}`;
    body = expiring.slice(0, 3).map(item => `${item.name} ${formatRemainingText(remainingDays(item))}`).join('、');
  } else if (ready.length) {
    title = `现在能做 ${ready[0].r.name}`;
    body = ready[0].reason || '这道菜和当前库存匹配度最高。';
  } else if (almost.length) {
    title = `${almost[0].r.name} 只差一点`;
    body = almost[0].reason || '补一两样食材就能做。';
  } else if (activeShopping.length) {
    title = `先补 ${activeShopping[0].name}`;
    body = `购物清单还有 ${activeShopping.length} 项未完成。`;
  }
  div.className = 'card home-briefing';
  const shoppingNote = activeShopping.length
    ? `购物清单还有 ${activeShopping.length} 项未完成`
    : '购物清单目前是空的';
  div.innerHTML = `
    <div class="home-briefing-head">
      <div>
        <div class="home-eyebrow">今日建议</div>
        <h2>${escapeHtml(title)}</h2>
        <p>${escapeHtml(body)}</p>
      </div>
      <div class="home-briefing-actions">
        <a class="btn ${activeShopping.length ? 'ok' : ''}" href="#shopping">${activeShopping.length ? '去补清单' : '看购物清单'}</a>
        <a class="btn" href="#recipes">看菜谱库</a>
      </div>
    </div>
    <div class="home-stats">
      <div class="home-stat"><strong>${expiring.length}</strong><span>快用掉</span></div>
      <div class="home-stat"><strong>${ready.length}</strong><span>现在能做</span></div>
      <div class="home-stat"><strong>${activeShopping.length}</strong><span>待购买</span></div>
      <div class="home-stat"><strong>${plan.length}</strong><span>今天计划</span></div>
    </div>
    <div class="home-shopping-note">${escapeHtml(shoppingNote)}</div>
  `;
  return div;
}

function renderHomeActionBoard(expiring, ready, almost, pack, inv, onSearchIngredient) {
  const board = document.createElement('section');
  board.className = 'home-action-board';
  const expiringItem = expiring[0];
  const readyItem = ready[0];
  const almostItem = almost[0];
  board.innerHTML = `
    <div class="home-action-card is-expiring">
      <span>1</span>
      <h3>快到期食材优先处理</h3>
      <p>${escapeHtml(expiringItem ? `${expiringItem.name} ${formatRemainingText(remainingDays(expiringItem))}` : '暂时没有 3 天内到期的食材。')}</p>
      <button type="button" class="btn small"${expiringItem ? '' : ' disabled'}>${expiringItem ? '找做法' : '不用处理'}</button>
    </div>
    <div class="home-action-card is-ready">
      <span>2</span>
      <h3>当前库存能做什么</h3>
      <p>${escapeHtml(readyItem ? `${readyItem.r.name} · ${readyItem.reason || '食材已齐'}` : '还没有完全匹配库存的菜。')}</p>
      <button type="button" class="btn ok small"${readyItem ? '' : ' disabled'}>${readyItem ? '加入今日计划' : '先补库存'}</button>
    </div>
    <div class="home-action-card is-almost">
      <span>3</span>
      <h3>差一点就能做什么</h3>
      <p>${escapeHtml(almostItem ? `${almostItem.r.name} · ${almostItem.reason || '只差一两样'}` : '暂时没有只差一两样的菜。')}</p>
      <button type="button" class="btn small"${almostItem ? '' : ' disabled'}>${almostItem ? '补缺少食材' : '暂无'}</button>
    </div>
  `;
  const buttons = board.querySelectorAll('button');
  if(expiringItem) buttons[0].onclick = () => onSearchIngredient(expiringItem.name);
  if(readyItem) buttons[1].onclick = () => {
    addRecipeToPlan(readyItem.r.id);
    brieflyConfirmButton(buttons[1], '已加入');
  };
  if(almostItem) buttons[2].onclick = () => {
    const count = addMissingRecipeIngredientsToShopping(almostItem.r, pack, inv, almostItem.list);
    brieflyConfirmButton(buttons[2], count ? '已加入清单' : '已齐');
  };
  return board;
}

function renderEmptyInventoryGuide() {
  const guide = document.createElement('section');
  guide.className = 'card home-onboarding';
  guide.innerHTML = `
    <div class="home-eyebrow">第一次使用</div>
    <h2>先放一点库存进厨房</h2>
    <p>现在还没有可用库存，所以不会硬推空推荐。先录入几样真实食材，菜谱推荐和购物清单才会准。</p>
    <div class="onboarding-actions">
      <button type="button" class="btn ok" data-start="manual">手动添加食材</button>
      <button type="button" class="btn ai" data-start="receipt">拍小票识别</button>
      <button type="button" class="btn" data-start="backup">导入备份</button>
    </div>
  `;
  return guide;
}

function bindEmptyInventoryGuide(guide, container) {
  const scrollToInventory = () => {
    const target = container.querySelector('#homeInventoryPanel');
    if(target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  guide.querySelector('[data-start="manual"]').onclick = () => {
    scrollToInventory();
    const form = container.querySelector('.add-form-container');
    const toggle = container.querySelector('#toggleAddBtn');
    if(form && toggle && !form.classList.contains('open')) toggle.click();
  };
  guide.querySelector('[data-start="receipt"]').onclick = () => {
    scrollToInventory();
    const input = container.querySelector('#camInput');
    if(input) input.click();
  };
  guide.querySelector('[data-start="backup"]').onclick = () => {
    location.hash = '#settings';
  };
}

function renderExpiringSection(items, onSearchIngredient) {
  const section = document.createElement('section');
  section.className = 'home-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>快到期 / 优先使用</span></div>`;

  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'card home-empty-state';
    empty.innerHTML = '<strong>暂时没有快到期食材</strong><span>很好，今天可以优先看“现在能做”的菜。</span>';
    section.appendChild(empty);
    return section;
  }

  const list = document.createElement('div');
  list.className = 'quick-list';
  items.forEach(item => {
    const row = document.createElement('div');
    row.className = 'quick-item';

    const info = document.createElement('div');
    const title = document.createElement('div');
    title.className = 'quick-item-title';
    title.textContent = item.name;
    const meta = document.createElement('div');
    meta.className = 'small';
    meta.textContent = `${formatInventoryAmount(item)} · ${formatRemainingText(remainingDays(item))}${item.isFrozen ? ' · 冷冻' : ''}`;
    info.appendChild(title);
    info.appendChild(meta);

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn small';
    btn.textContent = '搜菜谱';
    btn.onclick = () => onSearchIngredient(item.name);

    row.appendChild(info);
    row.appendChild(btn);
    list.appendChild(row);
  });
  section.appendChild(list);
  return section;
}

function renderCookChoiceItem(item, mode, pack, inv) {
  const row = document.createElement('div');
  row.className = 'home-cook-item';
  const isAlmost = mode === 'almost';
  row.innerHTML = `
    <button type="button" class="home-cook-link">
      <span>${escapeHtml(item.r.name)}</span>
      <small>${escapeHtml(item.reason || (isAlmost ? '补一点就能做' : '库存已匹配'))}</small>
    </button>
    <button type="button" class="btn ${isAlmost ? '' : 'ok'} small">${isAlmost ? '补清单' : '加入计划'}</button>
  `;
  row.querySelector('.home-cook-link').onclick = () => { location.hash = `#recipe:${item.r.id}`; };
  row.querySelector('.btn').onclick = () => {
    if(isAlmost) {
      const count = addMissingRecipeIngredientsToShopping(item.r, pack, inv, item.list);
      brieflyConfirmButton(row.querySelector('.btn'), count ? '已加入' : '已齐');
    } else {
      addRecipeToPlan(item.r.id);
      brieflyConfirmButton(row.querySelector('.btn'), '已加入');
    }
  };
  return row;
}

function renderCookChoiceCard(title, subtitle, items, emptyTitle, emptyText, mode, pack, inv) {
  const card = document.createElement('div');
  card.className = `home-cook-card is-${mode}`;
  card.innerHTML = `
    <div class="home-cook-card-head">
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(subtitle)}</p>
    </div>
  `;
  const list = document.createElement('div');
  list.className = 'home-cook-list';
  if(!items.length) {
    const empty = document.createElement('div');
    empty.className = 'home-empty-state compact';
    empty.innerHTML = `<strong>${escapeHtml(emptyTitle)}</strong><span>${escapeHtml(emptyText)}</span>`;
    list.appendChild(empty);
  } else {
    items.slice(0, 4).forEach(item => list.appendChild(renderCookChoiceItem(item, mode, pack, inv)));
  }
  card.appendChild(list);
  return card;
}

function renderCookChoicesSection(ready, almost, pack, inv) {
  const section = document.createElement('section');
  section.className = 'home-section home-cook-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>现在能做 & 差一点能做</span></div>`;
  const grid = document.createElement('div');
  grid.className = 'home-cook-grid';
  grid.appendChild(renderCookChoiceCard(
    '现在能做',
    '不用再买菜，适合直接加入今日计划。',
    ready,
    '还没有可直接做的菜',
    '先补一点库存，或用搜索找具体食材。',
    'ready',
    pack,
    inv
  ));
  grid.appendChild(renderCookChoiceCard(
    '差一点能做',
    '只差一两样，适合顺手补进购物清单。',
    almost,
    '暂时没有接近完成的菜',
    '库存再多一点后，这里会自动出现更合适的选择。',
    'almost',
    pack,
    inv
  ));
  section.appendChild(grid);
  return section;
}

function renderHomeDetails(title, subtitle, nodes, open = false) {
  const details = document.createElement('details');
  details.className = 'home-secondary-details';
  if(open) details.open = true;
  details.innerHTML = `
    <summary>
      <span>${escapeHtml(title)}</span>
      <small>${escapeHtml(subtitle)}</small>
    </summary>
  `;
  nodes.forEach(node => details.appendChild(node));
  return details;
}

function createRadarCard(title, subtitle, items, emptyText, renderItem, accentClass = '') {
  const card = document.createElement('div');
  card.className = `home-radar-card ${accentClass}`.trim();
  card.innerHTML = `
    <div class="home-radar-label">${escapeHtml(title)}</div>
    <div class="home-radar-subtitle">${escapeHtml(subtitle)}</div>
  `;
  const list = document.createElement('div');
  list.className = 'home-radar-list';
  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'home-radar-empty';
    empty.textContent = emptyText;
    list.appendChild(empty);
  } else {
    items.slice(0, 3).forEach(item => list.appendChild(renderItem(item)));
  }
  card.appendChild(list);
  return card;
}

function createRadarIngredientItem(item, onSearchIngredient) {
  const row = document.createElement('div');
  row.className = 'home-radar-item';
  row.innerHTML = `
    <div class="home-radar-copy">
      <div class="home-radar-name">${escapeHtml(item.name)}</div>
      <div class="home-radar-meta">${escapeHtml(`${formatInventoryAmount(item)} · ${formatRemainingText(remainingDays(item))}${item.isFrozen ? ' · 冷冻' : ''}`)}</div>
    </div>
    <button type="button" class="btn small">找做法</button>
  `;
  row.querySelector('button').onclick = () => onSearchIngredient(item.name);
  return row;
}

function createRadarRecipeItem(item, buttonText = '安排') {
  const row = document.createElement('div');
  row.className = 'home-radar-item';
  row.innerHTML = `
    <button type="button" class="home-radar-copy home-radar-link">
      <span class="home-radar-name">${escapeHtml(item.r.name)}</span>
      <span class="home-radar-meta">${escapeHtml(item.reason || '适合今天看看')}</span>
    </button>
    <button type="button" class="btn small">${escapeHtml(buttonText)}</button>
  `;
  row.querySelector('.home-radar-link').onclick = () => { location.hash = `#recipe:${item.r.id}`; };
  row.querySelector('.btn').onclick = () => {
    addRecipeToPlan(item.r.id);
    onRoute();
  };
  return row;
}

function renderHomeRadar(expiring, ready, almost, forgotten, onSearchIngredient) {
  const section = document.createElement('section');
  section.className = 'home-radar-section';
  section.innerHTML = `
    <div class="home-radar-head">
      <div>
        <div class="home-radar-title">厨房雷达</div>
        <p>先处理容易被忘的，再看今天不用动脑就能做什么。</p>
      </div>
    </div>
  `;
  const grid = document.createElement('div');
  grid.className = 'home-radar-grid';
  grid.appendChild(createRadarCard(
    '今天优先用掉',
    '按保质期自动排',
    expiring,
    '暂时没有紧急食材',
    item => createRadarIngredientItem(item, onSearchIngredient),
    'is-priority'
  ));
  grid.appendChild(createRadarCard(
    '现在能直接做',
    '不用先补货',
    ready,
    '先补一点库存会更准',
    item => createRadarRecipeItem(item, '安排')
  ));
  grid.appendChild(createRadarCard(
    '只差一两样',
    '适合顺手加入清单',
    almost,
    '暂无接近完成的菜',
    item => createRadarRecipeItem(item, '加入')
  ));
  grid.appendChild(createRadarCard(
    '最近没安排',
    '防止常做菜被遗忘',
    forgotten,
    '先把喜欢的菜设为常做',
    item => createRadarRecipeItem(item, '安排'),
    'is-soft'
  ));
  section.appendChild(grid);
  return section;
}

function renderDryGoodsCabinet(inv) {
  const section = document.createElement('section');
  section.className = 'dry-goods-section';
  section.innerHTML = `
    <div class="section-title home-section-title"><span>常备货架</span></div>
    <div class="dry-goods-card card">
      <div class="dry-goods-head">
        <div>
          <h3>少记数量，多看状态</h3>
          <p class="meta">先看蛋奶，再看干货；牛奶按瓶/盒和状态管，干货看存货和泡发提醒。</p>
        </div>
      </div>
      <div class="pantry-shelf-group daily-shelf">
        <div class="pantry-shelf-title">蛋奶</div>
        <div class="daily-goods-list"></div>
      </div>
      <div class="pantry-shelf-divider"></div>
      <div class="pantry-shelf-group dry-shelf">
        <div class="pantry-shelf-title">干货</div>
        <div class="dry-goods-list"></div>
      </div>
    </div>
  `;
  const setRowStatusClass = (row, className) => {
    row.classList.remove('is-ok', 'is-low', 'is-empty', 'is-unknown');
    row.classList.add(`is-${className}`);
  };
  const updateStatusRow = (row, item, config, type = 'dry') => {
    const status = item ? (item.stockStatus || 'ok') : 'empty';
    const info = dryStatusInfo(status);
    setRowStatusClass(row, info.className);
    const stockLine = row.querySelector('.dry-good-main em');
    if(stockLine) stockLine.textContent = formatStockLine(item, config.unit);
    const statusButton = row.querySelector('.inventory-status-chip');
    if(statusButton) {
      statusButton.className = `inventory-status-chip ${info.className}`;
      statusButton.textContent = info.label;
    }
    const buyButton = row.querySelector('.dry-good-buy');
    if(buyButton && type === 'dry') buyButton.textContent = status === 'ok' ? '补一包' : '加入清单';
  };
  const list = section.querySelector('.dry-goods-list');
  DRY_GOODS.forEach(config => {
    const item = findStockItem(inv, config.name, 'dry');
    const status = item ? (item.stockStatus || 'ok') : 'empty';
    const info = dryStatusInfo(status);
    const row = document.createElement('div');
    row.className = `dry-good-row is-${info.className}`;
    row.innerHTML = `
      <div class="dry-good-main">
        <strong>${escapeHtml(config.name)}</strong>
        <span>${escapeHtml(config.prep)}</span>
        <em>${escapeHtml(formatStockLine(item, config.unit))}</em>
      </div>
      <button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button>
      <button type="button" class="btn small dry-good-buy">${status === 'ok' ? '补一包' : '加入清单'}</button>
    `;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'dry', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit;
      target.kind = 'dry';
      target.shelf = 365;
      target.dryPrep = config.prep;
      target.isFrozen = false;
      saveInventory(inv);
      updateStatusRow(row, target, config, 'dry');
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => {
      addShoppingItem(config.name, '', config.unit, '常备干货');
      brieflyConfirmButton(buyButton);
    };
    list.appendChild(row);
  });

  const dailyList = section.querySelector('.daily-goods-list');
  const eggItem = findStockItem(inv, EGG_STOCK.name, 'raw');
  const eggQty = Math.max(0, Math.round(+eggItem?.qty || 0));
  const eggStatus = countStockStatus(eggQty);
  const eggInfo = dryStatusInfo(eggStatus);
  const eggRow = document.createElement('div');
  eggRow.className = `dry-good-row daily-good-row egg-good-row is-${eggInfo.className}`;
  eggRow.innerHTML = `
    <div class="dry-good-main">
      <strong>${escapeHtml(EGG_STOCK.name)}</strong>
      <span>${escapeHtml(EGG_STOCK.note)}</span>
      <em>${eggQty > 0 ? `库存：${eggQty} 个` : '库存：没有'}</em>
    </div>
    <div class="egg-count-control" aria-label="鸡蛋个数">
      <button type="button" class="egg-step" data-egg-step="-1" aria-label="减少鸡蛋">-</button>
      <span>${eggQty}</span>
      <button type="button" class="egg-step" data-egg-step="1" aria-label="增加鸡蛋">+</button>
    </div>
    <button type="button" class="btn small dry-good-buy">${eggQty <= 3 ? '补一打' : '加入清单'}</button>
  `;
  const updateEggRow = (item) => {
    const qty = Math.max(0, Math.round(+item?.qty || 0));
    const info = dryStatusInfo(countStockStatus(qty));
    setRowStatusClass(eggRow, info.className);
    const stockLine = eggRow.querySelector('.dry-good-main em');
    if(stockLine) stockLine.textContent = qty > 0 ? `库存：${qty} 个` : '库存：没有';
    const countLabel = eggRow.querySelector('.egg-count-control span');
    if(countLabel) countLabel.textContent = qty;
    const buyButton = eggRow.querySelector('.dry-good-buy');
    if(buyButton) buyButton.textContent = qty <= 3 ? '补一打' : '加入清单';
  };
  eggRow.querySelectorAll('[data-egg-step]').forEach(btn => {
    btn.onclick = () => {
      const step = Number(btn.dataset.eggStep || 0);
      const target = ensureStockItem(inv, EGG_STOCK, 'raw', 'empty');
      const nextQty = Math.max(0, Math.round(+target.qty || 0) + step);
      target.qty = nextQty;
      target.unit = EGG_STOCK.unit;
      target.kind = 'raw';
      target.shelf = guessShelfDays(target.name, target.unit);
      target.stockStatus = countStockStatus(nextQty);
      saveInventory(inv);
      updateEggRow(target);
    };
  });
  const eggBuyButton = eggRow.querySelector('.dry-good-buy');
  eggBuyButton.onclick = () => {
    const currentEgg = findStockItem(inv, EGG_STOCK.name, 'raw');
    const currentQty = Math.max(0, Math.round(+currentEgg?.qty || 0));
    addShoppingItem(EGG_STOCK.name, currentQty <= 3 ? 12 : '', EGG_STOCK.unit, '日常补给');
    brieflyConfirmButton(eggBuyButton);
  };
  dailyList.appendChild(eggRow);

  DAILY_STOCKS.forEach(config => {
    const item = findStockItem(inv, config.name, 'raw');
    const status = item ? (item.stockStatus || 'ok') : 'empty';
    const info = dryStatusInfo(status);
    const row = document.createElement('div');
    row.className = `dry-good-row daily-good-row is-${info.className}`;
    row.innerHTML = `
      <div class="dry-good-main">
        <strong>${escapeHtml(config.name)}</strong>
        <span>${escapeHtml(config.note)}</span>
        <em>${escapeHtml(formatStockLine(item, config.unit))}</em>
      </div>
      <button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button>
      <button type="button" class="btn small dry-good-buy">${config.name === '牛奶' ? '补一瓶' : '补一点'}</button>
    `;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'raw', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit;
      target.kind = 'raw';
      target.shelf = guessShelfDays(target.name, target.unit);
      saveInventory(inv);
      updateStatusRow(row, target, config, 'daily');
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => {
      addShoppingItem(config.name, '', config.unit, '日常补给');
      brieflyConfirmButton(buyButton);
    };
    dailyList.appendChild(row);
  });
  return section;
}

function renderHomeRecipeShelf(title, items, pack, emptyText) {
  const section = document.createElement('section');
  section.className = 'home-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>${title}</span></div>`;

  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'card home-empty';
    empty.textContent = emptyText;
    section.appendChild(empty);
    return section;
  }

  const scroller = document.createElement('div');
  scroller.className = 'horizontal-scroll';
  showRecommendationCards(scroller, items, pack);
  section.appendChild(scroller);
  return section;
}

function renderMoreRecommendations(pack, inv) {
  const recDiv = document.createElement('div');
  recDiv.className = 'home-section';
  recDiv.innerHTML = `<div class="section-title home-section-title"><span>更多推荐</span><button type="button" class="btn ai small" id="callAiBtn" style="padding:6px 12px;">呼叫 AI</button></div><div id="rec-content" class="horizontal-scroll"></div>`;

  const recGrid = recDiv.querySelector('#rec-content');
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
     const savedCards = processAiData(savedAiRecs, pack);
     if (savedCards.length > 0) {
       showRecommendationCards(recGrid, savedCards, pack);
       if (!recDiv.querySelector('#clearAiBtn')) {
           const clearBtn = document.createElement('button');
           clearBtn.type = 'button';
           clearBtn.className = 'btn bad small';
           clearBtn.id = 'clearAiBtn';
           clearBtn.style.marginLeft='10px';
           clearBtn.textContent = '清除推荐';
           clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
           recDiv.querySelector('.section-title').appendChild(clearBtn);
       }
     } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }
  } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }

  const aiBtn = recDiv.querySelector('#callAiBtn');
  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;

    aiBtn.setAttribute('disabled', 'true');
    await new Promise(r => setTimeout(r, 50));
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7';

    const maxRetries = 1;
    let attempt = 0;
    let success = false;

    const safetyTimer = setTimeout(() => {
       if(!success) {
           aiBtn.innerHTML = '呼叫 AI';
           aiBtn.style.opacity = '1';
           aiBtn.removeAttribute('disabled');
           alert(formatAiErrorMessage(new Error('AI 响应超时')));
           showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack);
       }
    }, 30000);

    while(attempt <= maxRetries && !success) {
        try {
          attempt++;
          const aiResult = await callCloudAI(pack, inv);
          clearTimeout(safetyTimer);
          success = true;

          S.save(S.keys.ai_recs, aiResult);
          const newCards = processAiData(aiResult, pack);
          if(newCards.length > 0) {
              showRecommendationCards(recGrid, newCards, pack);
              if (!recDiv.querySelector('#clearAiBtn')) {
                   const clearBtn = document.createElement('button');
                   clearBtn.type = 'button';
                   clearBtn.className = 'btn bad small';
                   clearBtn.id = 'clearAiBtn';
                   clearBtn.style.marginLeft='10px';
                   clearBtn.textContent = '清除推荐';
                   clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
                   recDiv.querySelector('.section-title').appendChild(clearBtn);
              }
          }
        } catch(e) {
          console.warn(`AI Recs Attempt ${attempt} failed:`, e);
          if (attempt > maxRetries) {
              clearTimeout(safetyTimer);
              alert(formatAiErrorMessage(e) + '\n\n已切换到本地推荐。');
              showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack);
          } else {
              aiBtn.innerHTML = `<span class="spinner"></span> 正在重试...`;
              await new Promise(r => setTimeout(r, 1000));
          }
        }
    }

    if (success || attempt > maxRetries) {
        aiBtn.innerHTML = '呼叫 AI';
        aiBtn.style.opacity = '1';
        aiBtn.removeAttribute('disabled');
        aiBtn.style.display = 'none'; aiBtn.offsetHeight; aiBtn.style.display = '';
    }
  };

  return recDiv;
}

function renderHome(pack){ 
  const container = document.createElement('div'); 
  const catalog = buildCatalog(pack); 
  const inv = loadInventory(catalog); 
  const expiring = getExpiringItems(inv);
  const groups = getHomeRecipeGroups(pack, inv);
  const shoppingItems = loadShoppingItems();

  const searchBar = document.createElement('div');
  searchBar.className = 'home-search';
  searchBar.innerHTML = `<input id="mainSearch" placeholder="搜菜谱或食材，比如鸡蛋、回锅肉"><button type="button" class="btn ok" id="doSearch">搜索</button>`;

  const showSearch = (query) => {
      const q = String(query || '').trim();
      if(q) {
          container.innerHTML = ''; container.appendChild(searchBar);
          searchBar.querySelector('#mainSearch').value = q; searchBar.querySelector('#doSearch').onclick = doSearch;
          container.appendChild(renderRecipeSearchResults(q, pack, inv));
      }
  };
  const doSearch = () => showSearch(searchBar.querySelector('#mainSearch').value);

  const title = document.createElement('div');
  title.className = 'main-title-center';
  title.innerHTML = '<span>厨房</span>';
  container.appendChild(title);
  searchBar.querySelector('#doSearch').onclick = doSearch;
  if(!hasUsableInventory(inv)) {
    const guide = renderEmptyInventoryGuide();
    container.appendChild(guide);
    const invTitle = document.createElement('div');
    invTitle.className = 'section-title home-section-title';
    invTitle.id = 'homeInventoryPanel';
    invTitle.innerHTML = '<span>先录入库存</span>';
    container.appendChild(invTitle);
    container.appendChild(renderInventory(pack, { showTitle: false }));
    bindEmptyInventoryGuide(guide, container);
    return container;
  }
  container.appendChild(renderHomeStats(expiring, groups.ready, groups.almost, shoppingItems));
  container.appendChild(renderExpiringSection(expiring, showSearch));
  container.appendChild(renderCookChoicesSection(groups.ready, groups.almost, pack, inv));

  const pantryNodes = [
    renderDryGoodsCabinet(inv)
  ];

  const invTitle = document.createElement('div');
  invTitle.className = 'section-title home-section-title';
  invTitle.innerHTML = '<span>完整库存</span>';
  pantryNodes.push(invTitle);
  pantryNodes.push(renderInventory(pack, { showTitle: false }));

  container.appendChild(renderHomeDetails('搜索菜谱 / 食材', '找具体菜名或某个食材', [searchBar]));
  container.appendChild(renderHomeDetails('常备货架与完整库存', '入库、拍小票、管理库存都在这里', pantryNodes));
  container.appendChild(renderHomeDetails('更多推荐和 AI', '想换换口味时再打开', [renderMoreRecommendations(pack, inv)]));
  return container; 
}

// ★★★ 修复：购物清单 + 常备品检查 (renderShopping) + [新]支持无数量食材 ★★★
function renderShopping(pack){
  const catalog = buildCatalog(pack);
  const inv=loadInventory(catalog); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const ingredientOptions = buildIngredientOptions(catalog);
  const shoppingItems = loadShoppingItems();
  const need={};
  const addNeed=(n,q,u,source='菜谱')=>{
    const canonicalName = getCanonicalName(n || '');
    const k=canonicalName+'|'+(u||'g');
    if(!need[k]) need[k]={qty:0, sources:[]};
    need[k].qty += (+q||0);
    if(source && !need[k].sources.includes(source)) need[k].sources.push(source);
  };
  
  for(const p of plan){ 
    const recipe = (pack.recipes || []).find(r => r.id === p.id);
    const ingList = explodeCombinedItems(map[p.id]||[]);
    
    // [修复] 如果菜谱没有食材列表(比如AI生成的空壳)，则将菜谱名作为待办加入
    if (!ingList || ingList.length === 0) {
       if (recipe) {
          addNeed(recipe.name + " (原料)", p.servings||1, "份", recipe.name);
       }
    } else {
        for(const it of ingList){ 
           // [修复] 即使qty不是数字(null/undefined)，也默认按1处理，防止漏买
           let qty = 1;
           if(typeof it.qty === 'number' && isFinite(it.qty)) {
             qty = it.qty;
           }
           addNeed(it.item, qty*(p.servings||1), it.unit, recipe ? recipe.name : '菜谱');
        }
    }
  }
  
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=getStockCoverageForNeed(inv,n,req.qty,u); const m=Math.max(0, Math.round((req.qty-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m, source:req.sources.join('、')}); }
  const d=document.createElement('div'); d.className='shopping-page'; const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const manualCard=document.createElement('div'); manualCard.className='card shopping-manual-card';
  manualCard.innerHTML=`
    <h3>手动添加</h3>
    <div class="shopping-add-row">
      <input id="shoppingAddName" list="shoppingCatalogList" placeholder="想买什么">
      <datalist id="shoppingCatalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      <input id="shoppingAddQty" type="number" min="0" step="1" placeholder="数量">
      <select id="shoppingAddUnit"><option value="">无单位</option><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份">份</option><option value="g">g</option><option value="ml">ml</option></select>
      <button type="button" class="btn ok" id="shoppingAddBtn">加入</button>
    </div>
  `;
  manualCard.querySelector('#shoppingAddName').addEventListener('input', e => {
    const val = e.target.value.trim();
    if(val) manualCard.querySelector('#shoppingAddUnit').value = guessKitchenUnit(getCanonicalName(val));
  });
  manualCard.querySelector('#shoppingAddBtn').onclick = () => {
    const name = manualCard.querySelector('#shoppingAddName').value.trim();
    if(!name) return alert('请输入要买的东西');
    addShoppingItem(name, manualCard.querySelector('#shoppingAddQty').value || '', manualCard.querySelector('#shoppingAddUnit').value || '', '手动');
    onRoute();
  };
  d.appendChild(manualCard);
  const pd=document.createElement('div'); pd.className='card shopping-plan-card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pl.className='shopping-plan-list'; pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。去“菜谱/推荐”点“加入购物计划”。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='shopping-plan-row';
      row.innerHTML=`<span class="shopping-plan-name">${r.name}</span><label class="shopping-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}"></label><a class="btn small" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }} drawPlan(); d.appendChild(pd);
  const needCard=document.createElement('div'); needCard.className='card shopping-missing-card'; needCard.innerHTML='<h3>菜谱缺货</h3>';
  const tbl=document.createElement('table'); tbl.className='table shopping-table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>缺少数量</th><th>来源</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，不需要购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${escapeHtml(m.name)}</td><td>${m.qty}${escapeHtml(m.unit || '')}</td><td class="small">${escapeHtml(m.source || '菜谱')}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购 → 入库</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  needCard.appendChild(tbl); d.appendChild(needCard);

  const itemCard=document.createElement('div'); itemCard.className='card shopping-items-card'; itemCard.innerHTML='<h3>我的购物项</h3>';
  const itemList=document.createElement('div'); itemList.className='shopping-item-list';
  if(shoppingItems.length===0) {
    const empty=document.createElement('p'); empty.className='small'; empty.textContent='还没有手动添加的购物项。'; itemList.appendChild(empty);
  } else {
    shoppingItems.forEach(item => {
      const row=document.createElement('div'); row.className=`shopping-item-row${item.done ? ' done' : ''}`;
      const amount = [item.qty, item.unit].filter(Boolean).join('');
      row.innerHTML=`
        <label class="shopping-check"><input type="checkbox" ${item.done ? 'checked' : ''}><span>${escapeHtml(item.name)}</span></label>
        <span class="shopping-item-amount">${escapeHtml(amount || '按需')}</span>
        <span class="shopping-source">${escapeHtml(item.source || '手动')}</span>
        <button type="button" class="btn small bad">删</button>
      `;
      row.querySelector('input').onchange = e => {
        const items = loadShoppingItems();
        const target = items.find(x => x.id === item.id);
        if(target) target.done = e.target.checked;
        saveShoppingItems(items);
        onRoute();
      };
      row.querySelector('button').onclick = () => {
        saveShoppingItems(loadShoppingItems().filter(x => x.id !== item.id));
        onRoute();
      };
      itemList.appendChild(row);
    });
  }
  itemCard.appendChild(itemList); d.appendChild(itemCard);

  // --- [修改] 分类且美化的常备品面板 ---
  const staplesPanel = document.createElement('div');
  staplesPanel.className = 'card staples-card';
  // 去除原来的硬边框，改用更有质感的头部设计
  staplesPanel.innerHTML = `
    <h3 style="margin-top:0; color:var(--text-main); display:flex; align-items:center;">
      <span style="margin-right:8px;">🧂</span> 家中常备品检查
    </h3>
    <p class="meta" style="margin-bottom:16px;">点击缺少的常备品，它们会加入“我的购物项”。</p>
    <div id="stapleContainer"></div>
  `;
  
  // 重新定义 UI 展示用的精简分类列表 (区别于逻辑用的 SEASONINGS 集合)
  const categories = [
    { name: "生鲜/蛋", items: ["葱", "姜", "蒜", "大葱", "香菜", "小米辣", "鸡蛋"] },
    { name: "基础调味", items: ["盐", "糖", "醋", "生抽", "老抽", "料酒", "米酒", "蚝油", "香油", "味精", "鸡精"] },
    { name: "酱料/腌菜", items: ["豆瓣酱", "甜面酱", "豆豉", "酸菜", "酸豆角", "泡椒"] },
    { name: "香料/干粉", items: ["淀粉", "花椒", "干辣椒", "胡椒粉", "八角", "桂皮", "香叶", "五香粉", "孜然", "茴香"] },
    { name: "食用油", items: ["菜油", "猪油"] }
  ];

  const container = staplesPanel.querySelector('#stapleContainer');

  categories.forEach(cat => {
    const groupDiv = document.createElement('div');
    groupDiv.style.marginBottom = '16px';
    
    const title = document.createElement('div');
    title.textContent = cat.name;
    title.style.fontSize = '12px';
    title.style.fontWeight = '600';
    title.style.color = 'var(--text-secondary)';
    title.style.marginBottom = '8px';
    groupDiv.appendChild(title);

    const pillContainer = document.createElement('div');
    pillContainer.className = 'ing-compact-container';
    
    cat.items.forEach(name => {
      const span = document.createElement('span');
      span.className = 'ing-tag-pill staple-item'; // 增加 staple-item 类方便查找
      span.style.cursor = 'pointer';
      span.style.userSelect = 'none';
      span.style.transition = 'all 0.2s cubic-bezier(0.4, 0, 0.2, 1)';
      span.style.border = '1px solid transparent';
      span.textContent = name;
      const alreadyAdded = shoppingItems.some(item => item.name === getCanonicalName(name) && item.source === '常备品' && !item.done);
      if(alreadyAdded) span.classList.add('active');

      span.onclick = () => {
        const items = loadShoppingItems();
        const canonical = getCanonicalName(name);
        const existing = items.find(item => item.name === canonical && item.source === '常备品' && !item.done);
        if(existing) {
          saveShoppingItems(items.filter(item => item.id !== existing.id));
        } else {
          items.push({ id: genId(), name: canonical, qty: '', unit: '', source: '常备品', done: false });
          saveShoppingItems(items);
        }
        onRoute();
      };
      pillContainer.appendChild(span);
    });
    
    groupDiv.appendChild(pillContainer);
    container.appendChild(groupDiv);
  });
  d.appendChild(staplesPanel);
  // --- [修改结束] ---

  const tools=document.createElement('div'); tools.className='controls shopping-tools';
  const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单';
  
  copy.onclick=()=>{ 
    const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}（${m.source || '菜谱'}）`);
    const activeItems = loadShoppingItems().filter(item => !item.done);
    if(activeItems.length > 0) {
      lines.push('--- 我的购物项 ---');
      lines.push(...activeItems.map(item => `${item.name}${item.qty ? ' ' + item.qty : ''}${item.unit || ''}（${item.source || '手动'}）`));
    }
    
    if(lines.length === 0) return alert('清单是空的');
    navigator.clipboard.writeText(lines.join('\n')).then(()=>alert('已复制到剪贴板')); 
  }; 
  tools.appendChild(copy); d.appendChild(tools);
  return d;
}

function showReceiptConfirmationModal(items, onConfirm, onCancel) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const unitOptions = ['个', '盒', '袋', '瓶', '把', '份', 'g', 'ml'];
  const rows = items.map((item, index) => {
    const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit);
    const name = normalized.name;
    const unit = normalized.unit;
    const qty = normalized.qty;
    return `
      <div class="receipt-confirm-row" data-index="${index}">
        <input class="receipt-name" value="${escapeOptionAttr(name)}" placeholder="食材名">
        <input class="receipt-qty" type="number" min="0" step="0.1" value="${qty}">
        <select class="receipt-unit">
          ${unitOptions.map(u => `<option value="${u}"${u === unit ? ' selected' : ''}>${u}</option>`).join('')}
        </select>
        <button type="button" class="btn bad small receipt-remove">删</button>
      </div>
    `;
  }).join('');

  overlay.innerHTML = `
    <div class="card receipt-confirm-card">
      <h3>确认识别结果</h3>
      <p class="meta">AI 识别只作为草稿，确认后才会入库。</p>
      <div class="receipt-confirm-list">${rows}</div>
      <div class="controls receipt-confirm-actions">
        <button type="button" class="btn" id="cancelReceiptConfirm">取消</button>
        <button type="button" class="btn ok" id="saveReceiptConfirm">确认入库</button>
      </div>
    </div>
  `;

  const close = () => overlay.remove();
  overlay.querySelectorAll('.receipt-remove').forEach(btn => {
    btn.onclick = () => btn.closest('.receipt-confirm-row').remove();
  });
  overlay.querySelector('#cancelReceiptConfirm').onclick = () => {
    close();
    if(onCancel) onCancel();
  };
  overlay.querySelector('#saveReceiptConfirm').onclick = () => {
    const confirmed = Array.from(overlay.querySelectorAll('.receipt-confirm-row')).map(row => {
      const normalized = normalizeKitchenAmount(row.querySelector('.receipt-name').value.trim(), row.querySelector('.receipt-qty').value, row.querySelector('.receipt-unit').value);
      return normalized.name ? normalized : null;
    }).filter(Boolean);
    close();
    onConfirm(confirmed);
  };
  overlay.onclick = e => {
    if(e.target === overlay) {
      close();
      if(onCancel) onCancel();
    }
  };
  document.body.appendChild(overlay);
}

// [新增] 弹出编辑库存详情的 Modal
function showEditInventoryModal(item, onSave) {
  const overlay = document.createElement('div');
  overlay.style.cssText = "position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:999;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(2px);";
  
  const dialog = document.createElement('div');
  dialog.className = 'card';
  dialog.style.cssText = "width:90%;max-width:320px;background:var(--bg-card);padding:24px;border-radius:16px;box-shadow:0 10px 25px rgba(0,0,0,0.2);animation:fadeIn 0.2s ease-out;";
  
  // 增加简单的出现动画
  const style = document.createElement('style');
  style.innerHTML = `@keyframes fadeIn { from { opacity: 0; transform: scale(0.95); } to { opacity: 1; transform: scale(1); } }`;
  document.head.appendChild(style);

  dialog.innerHTML = `
    <h3 style="margin-top:0;color:var(--text-main);font-size:18px;">📝 编辑库存: ${item.name}</h3>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">购买日期 (补录用)</label>
      <input type="date" id="editDate" value="${item.buyDate || todayISO()}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">保质期 (天)</label>
      <input type="number" id="editShelf" value="${item.shelf || 7}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:24px;display:flex;align-items:center;padding:10px;background:var(--bg-main);border-radius:8px;">
      <input type="checkbox" id="editFrozen" ${item.isFrozen ? 'checked' : ''} style="width:20px;height:20px;accent-color:var(--accent);cursor:pointer;">
      <label for="editFrozen" style="margin-left:10px;flex:1;cursor:pointer;font-weight:500;">❄️ 冷冻保存 (延长保质)</label>
    </div>
    <div style="display:flex;gap:12px;justify-content:flex-end;">
      <button class="btn" id="cancelBtn" style="background:transparent;border:1px solid var(--separator);color:var(--text-main);">取消</button>
      <button class="btn ok" id="saveBtn" style="flex:1;">保存修改</button>
    </div>
  `;
  
  overlay.appendChild(dialog);
  document.body.appendChild(overlay);
  
  const close = () => {
    overlay.style.opacity = '0';
    setTimeout(() => document.body.removeChild(overlay), 200);
  };
  
  overlay.querySelector('#cancelBtn').onclick = close;
  overlay.querySelector('#saveBtn').onclick = () => {
    item.buyDate = overlay.querySelector('#editDate').value;
    item.shelf = Number(overlay.querySelector('#editShelf').value) || 7;
    item.isFrozen = overlay.querySelector('#editFrozen').checked;
    onSave();
    close();
  };
  
  overlay.onclick = (e) => { if(e.target === overlay) close(); };
}

// ★★★ 修复：使用 SVG 图标 + 强制隐藏 Input + 冷冻功能 + 防止负数 + [新增]详情编辑 + [修复]按钮重叠(使用Grid) ★★★
function renderInventory(pack, options = {}){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); 
  const ingredientOptions = buildIngredientOptions(catalog);
  // [修改] 使用新的 main-title-center 样式, 且明确使用 span
  const header = document.createElement('div'); 
  header.className = 'main-title-center'; 
  header.innerHTML = '<span>厨房</span>'; 
  if (options.showTitle !== false) wrap.appendChild(header);
  
  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
  
  // SVG + visually-hidden input (添加 style="display:none!important" 双重保险)
  searchDiv.innerHTML = `
    <div style="display:flex; gap:8px; width:100%; justify-content:flex-end;">
      <button type="button" class="btn small" id="exportInventoryBtn" title="导出库存" style="gap:6px;">
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        <span>导出库存</span>
      </button>
      <label class="btn ai icon-only" style="cursor:pointer;">
        <input type="file" id="camInput" accept="image/*" capture="environment" class="visually-hidden" style="display:none!important">
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
      </label>
      <button type="button" class="btn ok icon-only" id="toggleAddBtn">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </button>
    </div>
    <div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>
  `; 
  wrap.appendChild(searchDiv);

  searchDiv.querySelector('#exportInventoryBtn').onclick = () => {
    const payload = {
      type: 'kitchen-inventory',
      version: 1,
      exportedAt: new Date().toISOString(),
      inventory: inv.map(item => ({...item}))
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], {type: 'application/json'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `kitchen-inventory-${todayISO()}.json`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  };
  
  // [修改] 彻底使用 Grid 布局修复对齐问题
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; 
  formContainer.innerHTML = `
    <div class="form-grid">
      <div class="full-width">
        <input id="addName" list="catalogList" placeholder="食材名称 (必填)" style="width:100%;">
        <datalist id="catalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      </div>
      <div class="full-width add-state-row">
        <span class="add-state-label">类型</span>
        <div class="add-state-options" id="addItemKind">
          <button type="button" class="add-state-option active" data-kind="raw">普通食材</button>
          <button type="button" class="add-state-option" data-kind="dry">常备干货</button>
        </div>
      </div>
      <div class="full-width add-state-row">
        <span class="add-state-label">状态</span>
        <div class="add-state-options" id="addStockStatus">
          <button type="button" class="add-state-option active" data-status="ok">够用</button>
          <button type="button" class="add-state-option" data-status="low">快没了</button>
          <button type="button" class="add-state-option" data-status="unknown">不确定</button>
        </div>
      </div>
      <div class="qty-group">
        <input id="addQty" type="number" min="0" step="1" placeholder="数量（可选）" style="width:60%;">
        <select id="addUnit" style="width:40%;"><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份" selected>份</option><option value="g">g</option><option value="ml">ml</option></select>
      </div>
      <input id="addDate" type="date" value="${todayISO()}" style="width:100%;">
      <div class="full-width" style="margin-top:4px;">
         <label style="display:flex;align-items:center;font-size:14px;cursor:pointer;margin-right:auto;">
           <input type="checkbox" id="addFrozen" style="width:18px;height:18px;margin-right:6px;accent-color:var(--accent);">冷冻
         </label>
         <button id="addBtn" class="btn ok" style="min-width:100px;">入库</button>
      </div>
    </div>`; 
  wrap.appendChild(formContainer);
  
  searchDiv.querySelector('#toggleAddBtn').onclick = () => { 
    formContainer.classList.toggle('open'); 
    const btn = searchDiv.querySelector('#toggleAddBtn');
    if (formContainer.classList.contains('open')) {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    } else {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    }
  };
  let selectedKind = 'raw';
  const setAddKind = (kind) => {
    selectedKind = kind === 'dry' ? 'dry' : 'raw';
    els('#addItemKind .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.kind === selectedKind));
    formContainer.querySelector('#addFrozen').closest('label').style.display = selectedKind === 'dry' ? 'none' : 'flex';
  };
  els('#addItemKind .add-state-option', formContainer).forEach(btn => {
    btn.onclick = () => setAddKind(btn.dataset.kind);
  });
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{
    const val = e.target.value.trim();
    if(val){
      const canonical = getCanonicalName(val);
      formContainer.querySelector('#addUnit').value = guessKitchenUnit(canonical);
      if(isDryGoodName(canonical)) setAddKind('dry');
    }
  }); 
  let selectedStockStatus = 'ok';
  els('#addStockStatus .add-state-option', formContainer).forEach(btn => {
    btn.onclick = () => {
      selectedStockStatus = btn.dataset.status || 'ok';
      els('#addStockStatus .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x === btn));
    };
  });
  
  // [修改] 强制数量非负 + 冷冻逻辑
  formContainer.querySelector('#addBtn').onclick=()=>{ 
    const rawName=formContainer.querySelector('#addName').value.trim(); 
    if(!rawName) return alert('请输入食材名称'); 
    const name=getCanonicalName(rawName);
    
    // 获取数值，如果是负数则强制归0
    let qty = +formContainer.querySelector('#addQty').value || 1; 
    if (qty < 0) qty = 0;

    const unit=formContainer.querySelector('#addUnit').value; 
    const date=formContainer.querySelector('#addDate').value||todayISO(); 
    const itemKind = selectedKind === 'dry' || isDryGoodName(name) ? 'dry' : 'raw';
    const isFrozen = itemKind === 'dry' ? false : formContainer.querySelector('#addFrozen').checked; // 获取冷冻状态

    // 如果冷冻，保质期设为180天，否则自动推算
    const shelfDays = itemKind === 'dry' ? 365 : (isFrozen ? 180 : guessShelfDays(name, unit));
    
    upsertInventory(inv,{name, qty, unit, buyDate:date, kind:itemKind, shelf:shelfDays, isFrozen: isFrozen, stockStatus:selectedStockStatus, ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(name)} : {})});
    
    formContainer.querySelector('#addName').value = ''; 
    formContainer.querySelector('#addQty').value = ''; 
    formContainer.querySelector('#addFrozen').checked = false; // 重置
    setAddKind('raw');
    selectedStockStatus = 'ok';
    els('#addStockStatus .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.status === 'ok'));
    renderTable(); 
  };
  
  const tbl=document.createElement('table'); tbl.className='table inventory-table'; tbl.innerHTML=`<thead><tr><th style="width:35%">食材</th><th style="width:25%">厨房状态</th><th style="width:25%">保质</th><th class="right">操作</th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 识别中...';
    try {
      const rawItems = await withTimeout(recognizeReceipt(file), 30000, 'AI 识别超时');
      const items = (Array.isArray(rawItems) ? rawItems : []).filter(it => it && it.name).map(it => normalizeKitchenAmount(it.name, it.qty, it.unit));
      if(items.length === 0) {
        scanStatus.innerHTML = '<span style="color:var(--danger)">没有识别到可入库食材</span>';
        return;
      }
      scanStatus.innerHTML = `识别到 ${items.length} 项，请确认后入库`;
      showReceiptConfirmationModal(items, confirmed => {
        for(const it of confirmed) {
          const unit = it.unit || guessKitchenUnit(it.name);
          const itemKind = isDryGoodName(it.name) ? 'dry' : 'raw';
          upsertInventory(inv, { name: it.name, qty: Number(it.qty) || 1, unit, buyDate: todayISO(), kind: itemKind, shelf: itemKind === 'dry' ? 365 : guessShelfDays(it.name, unit), stockStatus:'ok', ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(it.name), isFrozen:false} : {}) });
        }
        scanStatus.innerHTML = `✅ 已确认入库 ${confirmed.length} 项`;
        setTimeout(() => { scanStatus.style.display = 'none'; renderTable(); }, 1200);
      }, () => {
        scanStatus.innerHTML = '已取消入库';
        setTimeout(() => { scanStatus.style.display = 'none'; }, 1200);
      });
    } catch(err) { scanStatus.innerHTML = `<span style="color:var(--danger)">❌ ${formatAiErrorMessage(err)}</span>`; }
    finally { e.target.value = ''; }
  };
  function renderTable(){ 
    const tb=tbl.querySelector('tbody'); tb.innerHTML=''; 
    const filteredInv = inv; 
    filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b)); 
    if(filteredInv.length === 0) { tb.innerHTML = `<tr><td colspan="4" class="small" style="text-align:center;padding:20px;">${inv.length===0 ? '库存空空如也，快去进货！' : '未找到'}</td></tr>`; return; } 
    for(const e of filteredInv){ 
      const tr=document.createElement('tr'); 
      const stockInfo = inventoryStateInfo(e.stockStatus);
      // [修改] 增加点击名字编辑功能 + 显示购买日期
      tr.innerHTML=`
        <td class="name-cell" style="cursor:pointer;position:relative;">
          <span style="font-weight:600;color:var(--text-main)">${e.name}</span>
          <br><small style="color:var(--text-secondary);font-size:10px;">${e.buyDate||'未知'}</small>
        </td>
        <td class="kitchen-status-cell"><button type="button" class="inventory-status-chip ${stockInfo.className}" title="点击切换厨房状态">${stockInfo.label}</button><div class="inventory-amount-control"><span>存量</span><input class="qty-input" type="number" min="0" step="1" value="${+e.qty||0}"><small>${e.unit}</small></div></td>
        <td class="status-cell">${badgeFor(e)}</td>
        <td class="right"><button class="btn bad small" style="padding:4px 8px;" type="button">删</button></td>`; 
      
      // 绑定编辑弹窗事件
      tr.querySelector('.name-cell').onclick = () => {
        showEditInventoryModal(e, () => {
          saveInventory(inv);
          renderTable();
        });
      };

      const qtyInput = tr.querySelector('input'); 
      const stockBtn = tr.querySelector('.inventory-status-chip');
      stockBtn.onclick = () => {
        e.stockStatus = nextInventoryState(e.stockStatus);
        saveInventory(inv);
        renderTable();
      };

      // [修改] 强制列表输入框非负
      qtyInput.onchange = () => { 
        let newQty = +qtyInput.value || 0;
        if(newQty < 0) newQty = 0;
        e.qty = newQty; 
        saveInventory(inv); 
        // 如果用户输入了负数，重置输入框显示为0
        if(+qtyInput.value < 0) qtyInput.value = 0;
      };

      // [新增] 点击状态标签切换冷冻/冷藏
      const statusCell = tr.querySelector('.status-cell');
      if(statusCell) {
        statusCell.onclick = () => {
          if((e.kind || 'raw') === 'dry') return;
          e.isFrozen = !e.isFrozen; // 切换状态
          // 重新计算保质期：冷冻=180天，冷藏=按规则计算
          e.shelf = e.isFrozen ? 180 : guessShelfDays(e.name, e.unit);
          saveInventory(inv);
          renderTable(); // 刷新显示
        };
      }
      
      els('.btn',tr)[0].onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); 
    } 
  } 
  renderTable(); return wrap; 
}

function renderRecipes(pack){ 
  const wrap = document.createElement('div'); 
  const methodReadyCount = (pack.recipes || []).filter(hasRecipeMethod).length;
  const missingMethodCount = Math.max(0, (pack.recipes || []).length - methodReadyCount);
  wrap.innerHTML = `
    <h2 class="section-title">菜谱</h2>
    <div class="recipe-toolbar">
      <input id="search" placeholder="搜菜谱..." style="flex:1;min-width:150px;padding:12px;border-radius:12px;border:1px solid var(--separator);">
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
  const map = pack.recipe_ingredients||{}; 
  const recipeCount = wrap.querySelector('#recipeCount');
  
  function draw(filter=''){ 
    grid.innerHTML = ''; 
    const f = filter.trim(); 
    const methodOnly = wrap.querySelector('#methodOnly').checked;
    const rows = (pack.recipes||[]).filter(r => (!f || r.name.includes(f)) && (!methodOnly || hasRecipeMethod(r)));
    recipeCount.textContent = `显示 ${rows.length} 道 · 有做法 ${methodReadyCount} · 缺做法 ${missingMethodCount}`;
    if(rows.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'card small';
      empty.textContent = methodOnly ? '没有符合条件的菜。可以关闭“只看有做法”查看缺做法菜谱。' : '没有符合条件的菜。';
      grid.appendChild(empty);
      return;
    }
    rows.forEach(r=>{
      grid.appendChild(recipeCard(r, map[r.id])); 
    }); 
  } 
  draw(); 
  
  wrap.querySelector('#search').oninput = e => draw(e.target.value); 
  wrap.querySelector('#methodOnly').onchange = () => draw(wrap.querySelector('#search').value);
  
  // 绑定新建、导出、导入逻辑
  wrap.querySelector('#addBtn').onclick = () => { 
    const id = genId(); 
    const overlay = loadOverlay(); 
    overlay.recipes = overlay.recipes || {}; 
    overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] }; 
    overlay.recipe_ingredients = overlay.recipe_ingredients || {}; 
    overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}]; 
    saveOverlay(overlay); 
    location.hash = `#recipe-edit:${id}`; 
  }; 
  
  wrap.querySelector('#exportBtn').onclick = ()=>{ 
    const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); 
    const a = document.createElement('a'); 
    a.href = URL.createObjectURL(blob); 
    a.download = 'kitchen-overlay.json'; 
    a.click(); 
  }; 
  
  wrap.querySelector('#importFile').onchange = (e)=>{ 
    const file = e.target.files[0]; 
    if(!file) return; 
    const reader = new FileReader(); 
    reader.onload = ()=>{ 
      try{ 
        const inc = JSON.parse(reader.result); 
        const cur = loadOverlay(); 
        const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; 
        saveOverlay(m); 
        alert('导入成功'); 
        location.reload(); 
      }catch(err){ alert('导入失败'); } 
    }; 
    reader.readAsText(file); 
  }; 
  
  return wrap; 
}

function renderSettings(){
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const displayUrl = s.apiUrl || CUSTOM_AI.URL;
  const displayKey = s.apiKey || CUSTOM_AI.KEY;
  const displayModel = s.model || CUSTOM_AI.MODEL;
  
  const div = document.createElement('div');
  div.innerHTML = `
    <h2 class="section-title">设置</h2>
    <div class="section-title home-section-title"><span>AI 设置</span></div>
    <div class="card">
      <div class="setting-group">
        <label>快速预设</label>
        <select id="sPreset">
          <option value="">请选择...</option>
          <option value="silicon">SiliconFlow (硅基流动 - 推荐)</option>
          <option value="groq">Groq</option>
          <option value="openai">OpenAI</option>
        </select>
      </div>
      <hr style="border:0;border-top:1px solid var(--separator);margin:16px 0">
      <div class="setting-group"><label>API 地址</label><input id="sUrl" value="${displayUrl}"></div>
      <div class="setting-group"><label>模型名称</label><input id="sModel" value="${displayModel}"></div>
      <div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${displayKey}"></div>
      <div class="right"><a class="btn ok" id="saveSet">保存</a></div>
    </div>
    <div class="section-title home-section-title"><span>厨房备份</span></div>
    <div class="card backup-card">
      <p class="meta">导出会包含库存、今日计划、购物项、常做菜、安排记录、菜谱补丁和 AI 设置。当前数据结构版本：v${DATA_SCHEMA_VERSION}。</p>
      <div class="backup-actions">
        <button type="button" class="btn ok" id="exportKitchenBackup">导出整个厨房</button>
        <label class="btn"><input type="file" id="importKitchenBackup" accept="application/json,.json" hidden>导入整个厨房</label>
      </div>
    </div>
  `;
  
  const presets = { 
    silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' }, 
    groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' }, 
    openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' } 
  };
  
  div.querySelector('#sPreset').onchange = (e) => { 
    const val = e.target.value; 
    if(presets[val]) { 
      div.querySelector('#sUrl').value = presets[val].url; 
      div.querySelector('#sModel').value = presets[val].model; 
    } 
  };
  
  div.querySelector('#saveSet').onclick = () => { 
    const newS = { 
      apiUrl: div.querySelector('#sUrl').value.trim(), 
      apiKey: div.querySelector('#sKey').value.trim(), 
      model: div.querySelector('#sModel').value.trim() 
    }; 
    S.save(S.keys.settings, newS); 
    alert('已保存，刷新后生效。'); 
    location.reload();
  };
  div.querySelector('#exportKitchenBackup').onclick = () => {
    downloadJsonFile(buildKitchenBackup(), `kitchen-backup-${todayISO()}.json`);
  };
  div.querySelector('#importKitchenBackup').onchange = e => {
    const file = e.target.files[0];
    if(!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        restoreKitchenBackup(JSON.parse(reader.result));
        alert('厨房备份已导入，页面将刷新。');
        location.reload();
      } catch(err) {
        alert('导入失败：' + err.message);
      }
    };
    reader.readAsText(file);
  };
  return div;
}

function renderRecipeEditor(id, base){
  const overlay = loadOverlay();
  const baseIng = base.recipe_ingredients || {};
  const overIng = overlay.recipe_ingredients || {};
  const ingredientOptions = buildIngredientOptions(buildCatalog(base));
  // merged recipe
  const rBase = (base.recipes||[]).find(x => x.id===id);
  const rOv = (overlay.recipes||{})[id] || {};
  const r = {...(rBase||{id}), ...rOv};
  const items = (overIng[id] ?? baseIng[id] ?? []).map(x => ({...x}));
  const isNew = /^u-/.test(id) && !rBase;

  const wrap = document.createElement('div'); wrap.className = 'card'; wrap.style.padding = '20px';
  wrap.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
      <h2 style="margin:0">编辑菜谱</h2>
      <a class="btn" onclick="history.back()">返回</a>
    </div>
    <div class="controls" style="flex-direction:column;align-items:stretch;gap:12px;">
      <div><label class="small">菜名</label><input id="rName" value="${r.name||''}" style="width:100%;"></div>
      <div><label class="small">标签 (逗号分隔)</label><input id="rTags" value="${(r.tags||[]).join(',')}" style="width:100%;"></div>
      <div class="small badge">${isNew?'[自定义菜谱]':'[基于系统数据]'}</div>
    </div>
    
    <h3 style="margin-top:20px">用料表</h3>
    <table class="table">
      <thead><tr><th>用料</th><th>数量</th><th>单位</th><th class="right"><a class="btn small" id="addRow">新增</a></th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
    <datalist id="recipeIngredientList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
    
    <h3 style="margin-top:20px">做法 (Method)</h3>
    <textarea id="rMethod" rows="8" placeholder="请输入烹饪步骤..." style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);">${r.method || ''}</textarea>

    <div class="controls" style="margin-top:30px;border-top:1px solid var(--separator);padding-top:20px;justify-content:space-between;">
       <div>
         <a class="btn bad" id="hideBtn">${(overlay.deletes||{})[id]?'取消隐藏':'删除/隐藏'}</a>
         ${!isNew ? '<a class="btn" id="resetBtn">重置</a>' : ''}
       </div>
       <a class="btn ok" id="saveBtn">保存</a>
    </div>
  `;
  const tbody = wrap.querySelector('#rows');

  function addRow(item='', qty='', unit='g'){
    const tr = document.createElement('tr');
    const unitChoices = Array.from(new Set([unit || 'g', '份', '个', '盒', '袋', '瓶', '把', 'g', 'ml', 'pcs']));
    const unitHtml = unitChoices.map(u => `<option value="${escapeOptionAttr(u)}"${unit===u?' selected':''}>${escapeHtml(u)}</option>`).join('');
    tr.innerHTML = `
      <td><input list="recipeIngredientList" placeholder="食材名" value="${escapeOptionAttr(item)}"></td>
      <td><input type="number" step="1" placeholder="" value="${qty}"></td>
      <td><select>${unitHtml}</select></td>
      <td class="right"><a class="btn bad small">删</a></td>`;
    els('.btn', tr)[0].onclick = ()=> tr.remove();
    els('input', tr)[0].addEventListener('input', e => {
      const val = e.target.value.trim();
      if(val) els('select', tr)[0].value = guessKitchenUnit(getCanonicalName(val));
    });
    tbody.appendChild(tr);
  }
  items.forEach(it => addRow(it.item || '', (typeof it.qty==='number' && isFinite(it.qty))? it.qty : '', it.unit || 'g'));
  wrap.querySelector('#addRow').onclick = ()=> addRow();

  wrap.querySelector('#saveBtn').onclick = ()=>{
    const name = wrap.querySelector('#rName').value.trim();
    if(!name) return alert('菜名不能为空');
    const tags = wrap.querySelector('#rTags').value.split(/[，,]/).map(s=>s.trim()).filter(Boolean);
    const method = wrap.querySelector('#rMethod').value;
    
    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = { name, tags, method };
    
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    const arr = [];
    els('tbody#rows tr', wrap).forEach(tr => {
      const [i1,i2] = els('input', tr);
      const sel = els('select', tr)[0];
      const item = getCanonicalName(i1.value.trim());
      if(!item) return;
      const qty = i2.value === '' ? null : Number(i2.value);
      const unit = sel.value || null;
      arr.push({ item, ...(qty===null?{}:{qty}), ...(unit?{unit}:{}) });
    });
    overlay.recipe_ingredients[id] = arr;
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    alert('已保存');
    history.back();
  };

  wrap.querySelector('#hideBtn').onclick = ()=>{
    if(!confirm('确定隐藏？')) return;
    overlay.deletes = overlay.deletes || {};
    if(overlay.deletes[id]) delete overlay.deletes[id];
    else overlay.deletes[id] = true;
    saveOverlay(overlay);
    history.back();
  };

  const rBtn = wrap.querySelector('#resetBtn');
  if(rBtn) rBtn.onclick = ()=>{
    if(!confirm('确定重置？')) return;
    if(overlay.recipes) delete overlay.recipes[id];
    if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id];
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    // refresh
    const newView = renderRecipeEditor(id, base);
    app.innerHTML = ''; app.appendChild(newView);
  };

  return wrap;
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
async function onRoute(){ 
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
    let hash = location.hash.replace('#',''); 
    els('nav a').forEach(a=>a.classList.remove('active')); 
    if(hash==='recipes' || hash.startsWith('recipe:') || hash.startsWith('recipe-edit:')) el('#nav-recipe').classList.add('active');
    else if(hash==='shopping') el('#nav-shop').classList.add('active'); 
    else if(hash==='settings') el('#nav-set').classList.add('active'); 
    else if(!hash || hash==='inventory') el('#nav-home').classList.add('active'); 
    
    let view;
    if(hash.startsWith('recipe-edit:')){ const id = hash.split(':')[1]; view = renderRecipeEditor(id, base); }
    else if(hash.startsWith('recipe:')){ const id = hash.split(':')[1]; view = renderRecipeDetail(id, pack); }
    else if(hash==='shopping'){ view = renderShopping(pack); }
    else if(hash==='recipes'){ view = renderRecipes(pack); }
    else if(hash==='settings'){ view = renderSettings(); }
    else { view = renderHome(pack); }
    app.replaceChildren(view);
  } catch(e) {
    console.error('Routing Error:', e);
    app.innerHTML = `<div style="padding:20px;text-align:center;color:red;">页面加载出错：${e.message}<br><button class="btn" onclick="location.reload()">重试</button></div>`;
  }
} 
window.addEventListener('hashchange', onRoute); onRoute();
