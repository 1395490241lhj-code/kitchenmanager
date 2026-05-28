import { S, todayISO } from '../storage.js?v=98';
import {
  DRY_GOODS, EGG_STOCK, DAILY_STOCKS,
  countStockStatus, dryStatusInfo,
  guessShelfDays, nextDryStatus, buildCatalog,
  getCanonicalName
} from '../ingredients.js?v=1';
import {
  ensureStockItem, findStockItem, formatStockLine,
  isInventoryAvailable, loadInventory, remainingDays, saveInventory
} from '../inventory.js?v=1';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=2';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  getLocalRecommendations, hasRecipeMethod,
  processAiData, rankRecipesForRecommendation
} from '../recommendations.js?v=3';
import { callCloudAI, formatAiErrorMessage } from '../ai.js?v=2';
import { renderInventory } from './inventory-view.js?v=1';
import { showRecommendationCards, renderRecipeSearchResults } from '../components/recipe-card.js?v=1';
import { escapeHtml, brieflyConfirmButton, setInlineStatus } from '../components/status.js?v=1';

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
    .filter(item => isInventoryAvailable(item) && remainingDays(item) <= 3)
    .sort((a, b) => remainingDays(a) - remainingDays(b))
    .slice(0, 4);
}

function hasUsableInventory(inv) {
  return (inv || []).some(isInventoryAvailable);
}

function getRecommendationUiContext() {
  return {
    favoriteIds: S.load(S.keys.favorite_recipes, []),
    recipeUsage: S.load(S.keys.recipe_usage, {}),
    recipeActivity: S.load(S.keys.recipe_activity, {}),
    plan: S.load(S.keys.plan, []),
    today: todayISO()
  };
}

function formatMissingShort(missing, limit = 2) {
  const names = (missing || []).map(item => item.name || item.item).filter(Boolean);
  return `${names.slice(0, limit).join('、')}${names.length > limit ? '等' : ''}`;
}

function getTodayDecisionGroups(pack, inv) {
  const ranked = rankRecipesForRecommendation(pack, inv, getRecommendationUiContext())
    .filter(item => hasRecipeMethod(item.r));
  
  const priorityList = [];
  const readyList = [];
  const confirmList = [];
  const almostList = [];

  for (const row of ranked) {
    if (row.expiringMatches && row.expiringMatches.length > 0) {
      const first = row.expiringMatches[0];
      let timeText = '';
      if (first.days < 0) {
        timeText = `已过期 ${Math.abs(first.days)} 天`;
      } else if (first.days === 0) {
        timeText = '今天到期';
      } else {
        timeText = `还剩 ${first.days} 天到期`;
      }
      row.reason = `${first.name}${timeText}，建议优先用`;
      priorityList.push(row);
    } else if (row.coverageConfidence === 'exact') {
      row.reason = '食材已齐';
      readyList.push(row);
    } else if (row.coverageConfidence === 'unit-mismatch' || row.coverageConfidence === 'status-only') {
      const firstConfirm = row.needsConfirm && row.needsConfirm[0];
      if (firstConfirm) {
        if (firstConfirm.reason === 'unit-mismatch') {
          row.reason = `${firstConfirm.name}库存单位不同，数量需确认`;
        } else {
          row.reason = `${firstConfirm.name}库存状态需确认`;
        }
      } else {
        const firstUncertain = row.uncertain && row.uncertain[0];
        if (firstUncertain) {
          if (firstUncertain.reason === 'unit-mismatch') {
            row.reason = `${firstUncertain.name}库存单位不同，数量需确认`;
          } else {
            row.reason = `${firstUncertain.name}库存状态需确认`;
          }
        } else {
          row.reason = '库存单位或状态需确认';
        }
      }
      confirmList.push(row);
    } else if (row.missing && row.missing.length > 0 && row.missing.length <= 2) {
      const missingNames = row.missing.map(m => m.name || m.item).filter(Boolean);
      row.reason = `只缺 ${missingNames.join('、')}`;
      almostList.push(row);
    }
  }

  return {
    priority: priorityList.slice(0, 3),
    ready: readyList.slice(0, 3),
    confirm: confirmList.slice(0, 3),
    almost: almostList.slice(0, 3)
  };
}

function renderHomeStats(expiring, ready, almost, shoppingItems = [], hasInv = true, pack = null) {
  const div = document.createElement('div');
  const plan = S.load(S.keys.plan, []);
  const today = todayISO();
  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate);
  tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate);
  dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const todayPlans = plan.filter(item => (item.date || today) === today);
  const tomorrowPlans = plan.filter(item => item.date === tomorrowISO);
  const dayAfterPlans = plan.filter(item => item.date === dayAfterISO);

  const activeShopping = shoppingItems.filter(item => !item.done);
  let title = '今天先看厨房状态';
  let body = '不用先想吃什么，下面会按库存、快到期和常做菜自动给你排优先级。';
  let actionsHtml = '';

  if (!hasInv) {
    title = '先录入一些库存';
    body = '录入后即可获得精准 of 今日推荐 and 快到期提醒。';
    actionsHtml = `
      <button type="button" class="btn ok" id="btnManualAdd">立即入库</button>
      <button type="button" class="btn" id="btnReceiptAdd">拍小票</button>
      <button type="button" class="btn" id="btnImportBackup">导入备份</button>
    `;
  } else if (expiring.length > 0) {
    title = `优先用掉 ${expiring[0].name}`;
    body = expiring.slice(0, 3).map(item => `${item.name} ${formatRemainingText(remainingDays(item))}`).join('、');
    actionsHtml = `
      <button type="button" class="btn ok" id="btnFindRecipe">找做法</button>
      <button type="button" class="btn" id="btnAddToPlan">加入今日计划</button>
      <button type="button" class="btn" id="btnViewInventory">看库存</button>
    `;
  } else if (ready.length > 0) {
    title = `现在能做 ${ready[0].r.name}`;
    body = ready[0].reason || '这道菜和当前库存匹配度最高。';
    actionsHtml = `
      <button type="button" class="btn ok" id="btnAddToPlan">加入今日计划</button>
      <button type="button" class="btn" id="btnViewRecipe">看做法</button>
      <button type="button" class="btn" id="btnViewShopping">看购物清单</button>
    `;
  } else if (activeShopping.length > 0) {
    title = `先补 ${activeShopping[0].name}`;
    body = `购物清单还有 ${activeShopping.length} 项未完成。`;
    actionsHtml = `
      <button type="button" class="btn ok" id="btnGoShopping">去补清单</button>
      <button type="button" class="btn" id="btnCopyShopping">复制清单</button>
    `;
  } else {
    title = '今天先看厨房状态';
    body = '不用先想吃什么，可以搜索具体食材，或者生成 AI 推荐。';
    actionsHtml = `
      <button type="button" class="btn ok" id="btnFocusSearch">搜索食材</button>
      <button type="button" class="btn" id="btnCallAiRec">生成 AI 草稿</button>
    `;
  }

  div.className = 'card home-briefing';
  const shoppingNote = activeShopping.length ? `购物清单还有 ${activeShopping.length} 项未完成` : '购物清单目前是空的';

  let planSummaryHtml = '';
  if (pack) {
    const getNames = (plansList) => {
      const names = plansList
        .map(item => {
          const r = (pack.recipes || []).find(x => x.id === item.id);
          return r ? r.name : null;
        })
        .filter(Boolean);
      return names.length > 0 ? names.join('、') : '暂无计划';
    };
    planSummaryHtml = `
      <div class="home-plan-summary" style="margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--separator); font-size: 13px;">
        <div style="font-weight: 700; color: var(--text-main); margin-bottom: 6px;">📅 3天计划：</div>
        <div style="display: flex; flex-direction: column; gap: 4px; color: var(--text-secondary); line-height: 1.5;">
          <div><strong>今天：</strong><span>${escapeHtml(getNames(todayPlans))}</span></div>
          <div><strong>明天：</strong><span>${escapeHtml(getNames(tomorrowPlans))}</span></div>
          <div><strong>后天：</strong><span>${escapeHtml(getNames(dayAfterPlans))}</span></div>
        </div>
      </div>
    `;
  }

  div.innerHTML = `
    <div class="home-briefing-head">
      <div>
        <div class="home-eyebrow">今日建议</div>
        <h2>${escapeHtml(title)}</h2>
        <p>${escapeHtml(body)}</p>
      </div>
      <div class="home-briefing-actions">
        ${actionsHtml}
      </div>
    </div>
    <div class="home-stats">
      <div class="home-stat"><strong>${expiring.length}</strong><span>快用掉</span></div>
      <div class="home-stat"><strong>${ready.length}</strong><span>现在能做</span></div>
      <div class="home-stat"><strong>${activeShopping.length}</strong><span>待购买</span></div>
      <div class="home-stat"><strong>${todayPlans.length}</strong><span>今天计划</span></div>
    </div>
    ${planSummaryHtml}
    <div class="home-shopping-note">${escapeHtml(shoppingNote)}</div>
  `;
  return div;
}

function renderExpiringSection(items, onSearchIngredient) {
  const section = document.createElement('section'); section.className = 'home-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>快到期 / 优先使用</span></div>`;
  if (!items.length) {
    const empty = document.createElement('div'); empty.className = 'card home-empty-state';
    empty.innerHTML = '<strong>暂时没有快到期食材</strong><span>很好，今天可以优先看"现在能做"的菜。</span>';
    section.appendChild(empty); return section;
  }
  const list = document.createElement('div'); list.className = 'quick-list';
  items.forEach(item => {
    const row = document.createElement('div'); row.className = 'quick-item';
    const info = document.createElement('div');
    const title = document.createElement('div'); title.className = 'quick-item-title'; title.textContent = item.name;
    const meta = document.createElement('div'); meta.className = 'small';
    meta.textContent = `${formatInventoryAmount(item)} · ${formatRemainingText(remainingDays(item))}${item.isFrozen ? ' · 冷冻' : ''}`;
    info.appendChild(title); info.appendChild(meta);
    const btn = document.createElement('button'); btn.type = 'button'; btn.className = 'btn small'; btn.textContent = '搜菜谱';
    btn.onclick = () => onSearchIngredient(item.name);
    row.appendChild(info); row.appendChild(btn); list.appendChild(row);
  });
  section.appendChild(list); return section;
}

function renderCookChoiceItem(item, mode, pack, inv) {
  const row = document.createElement('div'); row.className = 'home-cook-item';
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
    if (isAlmost) {
      const count = addMissingRecipeIngredientsToShopping(item.r, pack, inv, item.list);
      brieflyConfirmButton(row.querySelector('.btn'), count ? '已加入' : '已齐');
    } else {
      addRecipeToPlan(item.r.id);
      brieflyConfirmButton(row.querySelector('.btn'), '已加入');
    }
  };
  return row;
}

function renderCookChoiceCard(title, subtitle, items, mode, pack, inv) {
  const card = document.createElement('div'); card.className = `home-cook-card is-${mode}`;
  card.innerHTML = `<div class="home-cook-card-head"><h3>${escapeHtml(title)}</h3><p>${escapeHtml(subtitle)}</p></div>`;
  const list = document.createElement('div'); list.className = 'home-cook-list';
  items.forEach(item => list.appendChild(renderCookChoiceItem(item, mode, pack, inv)));
  card.appendChild(list); return card;
}

function renderCookChoicesSection(groups, pack, inv) {
  const section = document.createElement('section'); section.className = 'home-section home-cook-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>今日厨房状态</span></div>`;
  const grid = document.createElement('div'); grid.className = 'home-cook-grid';
  
  let hasAny = false;
  if (groups.priority && groups.priority.length > 0) {
    grid.appendChild(renderCookChoiceCard('优先做', '快到期食材，建议优先烹饪', groups.priority, 'priority', pack, inv));
    hasAny = true;
  }
  if (groups.ready && groups.ready.length > 0) {
    grid.appendChild(renderCookChoiceCard('现在能做', '核心食材已齐，可直接烹饪', groups.ready, 'ready', pack, inv));
    hasAny = true;
  }
  if (groups.confirm && groups.confirm.length > 0) {
    grid.appendChild(renderCookChoiceCard('需要确认', '单位或状态不同，数量需确认', groups.confirm, 'confirm', pack, inv));
    hasAny = true;
  }
  if (groups.almost && groups.almost.length > 0) {
    grid.appendChild(renderCookChoiceCard('差一点能做', '缺 1-2 个核心食材，适合补货', groups.almost, 'almost', pack, inv));
    hasAny = true;
  }
  
  if (!hasAny) {
    const emptyCard = document.createElement('div');
    emptyCard.className = 'card home-empty-state';
    emptyCard.innerHTML = '<strong>暂无推荐菜谱</strong><span>录入更多库存或丰富菜谱库后，厨房决策推荐会自动显示在这里。</span>';
    section.appendChild(emptyCard);
  } else {
    section.appendChild(grid);
  }
  
  return section;
}

function renderHomeDetails(title, subtitle, nodes, open = false) {
  const details = document.createElement('details'); details.className = 'home-secondary-details';
  if (open) details.open = true;
  details.innerHTML = `<summary><span>${escapeHtml(title)}</span><small>${escapeHtml(subtitle)}</small></summary>`;
  nodes.forEach(node => details.appendChild(node)); return details;
}

function renderDryGoodsCabinet(inv, options = {}) {
  const onInventoryChanged = typeof options.onInventoryChanged === 'function' ? options.onInventoryChanged : () => {};
  let debounceTimer = null;
  const notifyChange = () => {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      onInventoryChanged();
    }, 800);
  };
  const section = document.createElement('section'); section.className = 'dry-goods-section';
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
  const setRowStatusClass = (row, className) => { row.classList.remove('is-ok', 'is-low', 'is-empty', 'is-unknown'); row.classList.add(`is-${className}`); };
  const updateStatusRow = (row, item, config, type = 'dry') => {
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    setRowStatusClass(row, info.className);
    const stockLine = row.querySelector('.dry-good-main em'); if (stockLine) stockLine.textContent = formatStockLine(item, config.unit);
    const statusButton = row.querySelector('.inventory-status-chip');
    if (statusButton) { statusButton.className = `inventory-status-chip ${info.className}`; statusButton.textContent = info.label; }
    const buyButton = row.querySelector('.dry-good-buy');
    if (buyButton && type === 'dry') buyButton.textContent = status === 'ok' ? '补一包' : '加入清单';
  };
  const list = section.querySelector('.dry-goods-list');
  DRY_GOODS.forEach(config => {
    const item = findStockItem(inv, config.name, 'dry');
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    const row = document.createElement('div'); row.className = `dry-good-row is-${info.className}`;
    row.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(config.name)}</strong><span>${escapeHtml(config.prep)}</span><em>${escapeHtml(formatStockLine(item, config.unit))}</em></div><button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button><button type="button" class="btn small dry-good-buy">${status === 'ok' ? '补一包' : '加入清单'}</button>`;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'dry', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit; target.kind = 'dry'; target.shelf = 365; target.dryPrep = config.prep; target.isFrozen = false;
      saveInventory(inv); updateStatusRow(row, target, config, 'dry');
      notifyChange();
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => { addShoppingItem(config.name, '', config.unit, '常备干货'); brieflyConfirmButton(buyButton); };
    list.appendChild(row);
  });

  const dailyList = section.querySelector('.daily-goods-list');
  const eggItem = findStockItem(inv, EGG_STOCK.name, 'raw');
  const eggQty = Math.max(0, Math.round(+eggItem?.qty || 0));
  const eggStatus = countStockStatus(eggQty); const eggInfo = dryStatusInfo(eggStatus);
  const eggRow = document.createElement('div'); eggRow.className = `dry-good-row daily-good-row egg-good-row is-${eggInfo.className}`;
  eggRow.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(EGG_STOCK.name)}</strong><span>${escapeHtml(EGG_STOCK.note)}</span><em>${eggQty > 0 ? `库存：${eggQty} 个` : '库存：没有'}</em></div><div class="egg-count-control" aria-label="鸡蛋个数"><button type="button" class="egg-step" data-egg-step="-1" aria-label="减少鸡蛋">-</button><span>${eggQty}</span><button type="button" class="egg-step" data-egg-step="1" aria-label="增加鸡蛋">+</button></div><button type="button" class="btn small dry-good-buy">${eggQty <= 3 ? '补一打' : '加入清单'}</button>`;
  const updateEggRow = (item) => {
    const qty = Math.max(0, Math.round(+item?.qty || 0)); const info = dryStatusInfo(countStockStatus(qty));
    setRowStatusClass(eggRow, info.className);
    const stockLine = eggRow.querySelector('.dry-good-main em'); if (stockLine) stockLine.textContent = qty > 0 ? `库存：${qty} 个` : '库存：没有';
    const countLabel = eggRow.querySelector('.egg-count-control span'); if (countLabel) countLabel.textContent = qty;
    const buyButton = eggRow.querySelector('.dry-good-buy'); if (buyButton) buyButton.textContent = qty <= 3 ? '补一打' : '加入清单';
  };
  eggRow.querySelectorAll('[data-egg-step]').forEach(btn => {
    btn.onclick = () => {
      const step = Number(btn.dataset.eggStep || 0);
      const target = ensureStockItem(inv, EGG_STOCK, 'raw', 'empty');
      const nextQty = Math.max(0, Math.round(+target.qty || 0) + step);
      target.qty = nextQty; target.unit = EGG_STOCK.unit; target.kind = 'raw';
      target.shelf = guessShelfDays(target.name, target.unit);
      target.stockStatus = countStockStatus(nextQty);
      saveInventory(inv); updateEggRow(target);
      notifyChange();
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
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    const row = document.createElement('div'); row.className = `dry-good-row daily-good-row is-${info.className}`;
    row.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(config.name)}</strong><span>${escapeHtml(config.note)}</span><em>${escapeHtml(formatStockLine(item, config.unit))}</em></div><button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button><button type="button" class="btn small dry-good-buy">${config.name === '牛奶' ? '补一瓶' : '补一点'}</button>`;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'raw', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit; target.kind = 'raw'; target.shelf = guessShelfDays(target.name, target.unit);
      saveInventory(inv); updateStatusRow(row, target, config, 'daily');
      notifyChange();
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => { addShoppingItem(config.name, '', config.unit, '日常补给'); brieflyConfirmButton(buyButton); };
    dailyList.appendChild(row);
  });
  return section;
}

function renderMoreRecommendations(pack, inv, { onRoute = () => {} } = {}) {
  const recDiv = document.createElement('div'); recDiv.className = 'home-section';
  recDiv.innerHTML = `<div class="section-title home-section-title"><span>更多推荐</span><button type="button" class="btn ai small ai-rec-btn" id="callAiBtn">生成 AI 草稿</button></div><div id="aiRecStatus" class="small inline-status" hidden></div><div id="rec-content" class="horizontal-scroll"></div>`;
  const recGrid = recDiv.querySelector('#rec-content'); const aiStatus = recDiv.querySelector('#aiRecStatus');
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
    const savedCards = processAiData(savedAiRecs, pack);
    if (savedCards.length > 0) {
      setInlineStatus(aiStatus, '当前显示的是 AI 草稿推荐，请确认后再使用。', 'info');
      showRecommendationCards(recGrid, savedCards, pack, { onRoute });
      if (!recDiv.querySelector('#clearAiBtn')) {
        const clearBtn = document.createElement('button'); clearBtn.type = 'button'; clearBtn.className = 'btn bad small';
        clearBtn.id = 'clearAiBtn'; clearBtn.style.marginLeft = '10px'; clearBtn.textContent = '清除推荐';
        clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
        recDiv.querySelector('.section-title').appendChild(clearBtn);
      }
    } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack, { onRoute }); }
  } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack, { onRoute }); }

  const aiBtn = recDiv.querySelector('#callAiBtn');
  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;
    aiBtn.setAttribute('disabled', 'true');
    await new Promise(r => setTimeout(r, 50));
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7';
    const maxRetries = 1; let attempt = 0; let success = false;
    const safetyTimer = setTimeout(() => {
      if (!success) {
        aiBtn.innerHTML = '生成 AI 草稿'; aiBtn.style.opacity = '1'; aiBtn.removeAttribute('disabled');
        setInlineStatus(aiStatus, formatAiErrorMessage(new Error('AI 响应超时')) + ' 已切换到本地推荐。', 'bad');
        showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack, { onRoute });
      }
    }, 30000);
    while (attempt <= maxRetries && !success) {
      try {
        attempt++; const aiResult = await callCloudAI(pack, inv); clearTimeout(safetyTimer); success = true;
        S.save(S.keys.ai_recs, aiResult); const newCards = processAiData(aiResult, pack);
        if (newCards.length > 0) {
          setInlineStatus(aiStatus, 'AI 已生成草稿推荐，请确认后再安排。', 'ok');
          showRecommendationCards(recGrid, newCards, pack, { onRoute });
          if (!recDiv.querySelector('#clearAiBtn')) {
            const clearBtn = document.createElement('button'); clearBtn.type = 'button'; clearBtn.className = 'btn bad small';
            clearBtn.id = 'clearAiBtn'; clearBtn.style.marginLeft = '10px'; clearBtn.textContent = '清除推荐';
            clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
            recDiv.querySelector('.section-title').appendChild(clearBtn);
          }
        }
      } catch (e) {
        console.warn(`AI Recs Attempt ${attempt} failed:`, e);
        if (attempt > maxRetries) {
          clearTimeout(safetyTimer);
          setInlineStatus(aiStatus, formatAiErrorMessage(e) + ' 已切换到本地推荐。', 'bad');
          showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack, { onRoute });
        } else {
          aiBtn.innerHTML = `<span class="spinner"></span> 正在重试...`;
          await new Promise(r => setTimeout(r, 1000));
        }
      }
    }
    if (success || attempt > maxRetries) {
      aiBtn.innerHTML = '生成 AI 草稿'; aiBtn.style.opacity = '1'; aiBtn.removeAttribute('disabled');
      aiBtn.style.display = 'none'; aiBtn.offsetHeight; aiBtn.style.display = '';
    }
  };
  return recDiv;
}

function hasLowOrEmptyStockInCabinet(inv) {
  for (const config of DRY_GOODS) {
    const item = findStockItem(inv, config.name, 'dry');
    const status = item ? (item.stockStatus || 'ok') : 'empty';
    if (status === 'low' || status === 'empty') return true;
  }

  const eggItem = findStockItem(inv, EGG_STOCK.name, 'raw');
  const eggQty = Math.max(0, Math.round(+eggItem?.qty || 0));
  const eggStatus = countStockStatus(eggQty);
  if (eggStatus === 'low' || eggStatus === 'empty') return true;

  for (const config of DAILY_STOCKS) {
    const item = findStockItem(inv, config.name, 'raw');
    const status = item ? (item.stockStatus || 'ok') : 'empty';
    if (status === 'low' || status === 'empty') return true;
  }

  return false;
}

export function renderHome(pack, { onRoute = () => {} } = {}) {
  const container = document.createElement('div');
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const expiring = getExpiringItems(inv);
  const groups = getTodayDecisionGroups(pack, inv);
  const shoppingItems = loadShoppingItems();
  const activeShopping = shoppingItems.filter(item => !item.done);

  const searchResultsContainer = document.createElement('div');
  searchResultsContainer.className = 'search-results-container';

  const searchBar = document.createElement('div'); searchBar.className = 'home-search';
  searchBar.innerHTML = `<input id="mainSearch" placeholder="搜菜谱或食材，比如鸡蛋、回锅肉">
    <div class="home-search-buttons">
      <button type="button" class="btn ok" id="doSearch">搜索</button>
      <button type="button" class="btn is-hidden" id="clearSearch">清空</button>
    </div>`;

  let searchDetails = null;

  const clearSearch = () => {
    searchBar.querySelector('#mainSearch').value = '';
    searchResultsContainer.innerHTML = '';
    const clearBtn = searchBar.querySelector('#clearSearch');
    if (clearBtn) clearBtn.classList.add('is-hidden');
  };

  const showSearch = (query) => {
    const q = String(query || '').trim();
    if (q) {
      searchBar.querySelector('#mainSearch').value = q;
      searchResultsContainer.innerHTML = '';
      const resultsNode = renderRecipeSearchResults(q, pack, inv, { onRoute });
      searchResultsContainer.appendChild(resultsNode);
      
      const clearBtn = searchBar.querySelector('#clearSearch');
      if (clearBtn) clearBtn.classList.remove('is-hidden');
      
      if (searchDetails) {
        searchDetails.open = true;
        searchDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    } else {
      clearSearch();
    }
  };

  const doSearch = () => showSearch(searchBar.querySelector('#mainSearch').value);

  searchBar.querySelector('#mainSearch').onkeydown = (e) => {
    if (e.key === 'Enter') {
      doSearch();
    }
  };
  searchBar.querySelector('#doSearch').onclick = doSearch;
  searchBar.querySelector('#clearSearch').onclick = clearSearch;

  const title = document.createElement('div'); title.className = 'main-title-center'; title.innerHTML = '<span>厨房</span>';
  container.appendChild(title);

  // Render full inventory node
  const fullInventoryNode = renderInventory(pack, { showTitle: false, onInventoryChanged: onRoute });
  const fullInvDetails = renderHomeDetails('完整库存', '手动录入、拍小票及完整库存明细', [fullInventoryNode], !hasUsableInventory(inv));
  fullInvDetails.id = 'homeInventoryDetails';

  if (!hasUsableInventory(inv)) {
    const briefingCard = renderHomeStats(expiring, groups.ready, groups.almost, shoppingItems, false, pack);
    container.appendChild(briefingCard);

    const invTitle = document.createElement('div'); invTitle.className = 'section-title home-section-title';
    invTitle.id = 'homeInventoryPanel'; invTitle.innerHTML = '<span>先录入库存</span>';
    container.appendChild(invTitle);
    container.appendChild(fullInvDetails);

    // Bind onboarding actions on briefingCard
    const btnManualAdd = briefingCard.querySelector('#btnManualAdd');
    if (btnManualAdd) {
      btnManualAdd.onclick = () => {
        fullInvDetails.open = true;
        const form = fullInvDetails.querySelector('.add-form-container');
        const toggle = fullInvDetails.querySelector('#toggleAddBtn');
        if (form && toggle && !form.classList.contains('open')) toggle.click();
        fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
      };
    }

    const btnReceiptAdd = briefingCard.querySelector('#btnReceiptAdd');
    if (btnReceiptAdd) {
      btnReceiptAdd.onclick = () => {
        fullInvDetails.open = true;
        const input = fullInvDetails.querySelector('#camInput');
        if (input) input.click();
        fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
      };
    }

    const btnImportBackup = briefingCard.querySelector('#btnImportBackup');
    if (btnImportBackup) {
      btnImportBackup.onclick = () => { location.hash = '#settings'; };
    }

    return container;
  }

  const briefingCard = renderHomeStats(expiring, groups.ready, groups.almost, shoppingItems, true, pack);
  container.appendChild(briefingCard);

  if (expiring.length > 0) {
    container.appendChild(renderExpiringSection(expiring, showSearch));
  }
  container.appendChild(renderCookChoicesSection(groups, pack, inv));

  const searchOpen = (groups.priority.length === 0 && groups.ready.length === 0 && groups.almost.length === 0);
  searchDetails = renderHomeDetails('搜索菜谱 / 食材', '找具体菜名或某个食材', [searchBar, searchResultsContainer], searchOpen);
  container.appendChild(searchDetails);

  const cabinetOpen = hasLowOrEmptyStockInCabinet(inv);
  const cabinetDetails = renderHomeDetails('常备货架', '日常补给与常备干货存量', [renderDryGoodsCabinet(inv, { onInventoryChanged: onRoute })], cabinetOpen);
  container.appendChild(cabinetDetails);

  container.appendChild(fullInvDetails);

  const localRecs = getLocalRecommendations(pack, inv);
  const hasRealLocalRecs = localRecs.some(item => item && (item.matchCount > 0 || (item.uncertain && item.uncertain.length > 0)));
  const recsOpen = false;
  const moreRecsNode = renderMoreRecommendations(pack, inv, { onRoute });
  const moreRecsDetails = renderHomeDetails('更多推荐和 AI', '想换换口味时再打开', [moreRecsNode], recsOpen);
  container.appendChild(moreRecsDetails);

  // Bind actions for briefingCard
  const btnFindRecipe = briefingCard.querySelector('#btnFindRecipe');
  if (btnFindRecipe) {
    btnFindRecipe.onclick = () => {
      if (expiring.length > 0) {
        searchDetails.open = true;
        showSearch(expiring[0].name);
      }
    };
  }

  const btnAddToPlan = briefingCard.querySelector('#btnAddToPlan');
  if (btnAddToPlan) {
    btnAddToPlan.onclick = () => {
      let recipeId = null;
      const firstGroup = groups.priority.length > 0 ? groups.priority : (groups.ready.length > 0 ? groups.ready : (groups.confirm.length > 0 ? groups.confirm : groups.almost));
      if (firstGroup.length > 0) {
        recipeId = firstGroup[0].r.id;
      } else {
        const matchRecipe = (pack.recipes || []).find(r => {
          const list = (pack.recipe_ingredients || {})[r.id] || [];
          return list.some(ing => getCanonicalName(ing.item) === getCanonicalName(expiring[0]?.name));
        });
        recipeId = matchRecipe?.id;
      }

      if (recipeId) {
        addRecipeToPlan(recipeId);
        brieflyConfirmButton(btnAddToPlan);
        onRoute();
      } else {
        brieflyConfirmButton(btnAddToPlan, '暂无匹配菜谱');
      }
    };
  }

  const btnViewInventory = briefingCard.querySelector('#btnViewInventory');
  if (btnViewInventory) {
    btnViewInventory.onclick = () => {
      fullInvDetails.open = true;
      fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
    };
  }

  const btnViewRecipe = briefingCard.querySelector('#btnViewRecipe');
  if (btnViewRecipe) {
    btnViewRecipe.onclick = () => {
      const firstGroup = groups.priority.length > 0 ? groups.priority : (groups.ready.length > 0 ? groups.ready : groups.confirm);
      if (firstGroup.length > 0) {
        location.hash = `#recipe:${firstGroup[0].r.id}`;
      }
    };
  }

  const btnViewShopping = briefingCard.querySelector('#btnViewShopping');
  if (btnViewShopping) {
    btnViewShopping.onclick = () => { location.hash = '#shopping'; };
  }

  const btnGoShopping = briefingCard.querySelector('#btnGoShopping');
  if (btnGoShopping) {
    btnGoShopping.onclick = () => { location.hash = '#shopping'; };
  }

  const btnCopyShopping = briefingCard.querySelector('#btnCopyShopping');
  if (btnCopyShopping) {
    btnCopyShopping.onclick = () => {
      const textToCopy = activeShopping.map(item => `${item.name} ${item.qty || ''}${item.unit || ''}`).join('\n');
      navigator.clipboard.writeText(textToCopy)
        .then(() => brieflyConfirmButton(btnCopyShopping, '已复制'))
        .catch(() => brieflyConfirmButton(btnCopyShopping, '复制失败'));
    };
  }

  const btnFocusSearch = briefingCard.querySelector('#btnFocusSearch');
  if (btnFocusSearch) {
    btnFocusSearch.onclick = () => {
      searchDetails.open = true;
      const s = searchDetails.querySelector('#mainSearch');
      if (s) {
        s.scrollIntoView({ behavior: 'smooth', block: 'center' });
        s.focus();
      }
    };
  }

  const btnCallAiRec = briefingCard.querySelector('#btnCallAiRec');
  if (btnCallAiRec) {
    btnCallAiRec.onclick = () => {
      moreRecsDetails.open = true;
      const aiBtn = moreRecsDetails.querySelector('#callAiBtn');
      if (aiBtn) {
        aiBtn.click();
        moreRecsDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    };
  }

  return container;
}
