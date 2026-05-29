import { S, todayISO } from '../storage.js?v=162';
import {
  DRY_GOODS, EGG_STOCK, DAILY_STOCKS,
  countStockStatus, dryStatusInfo,
  guessShelfDays, nextDryStatus, buildCatalog,
  getCanonicalName
} from '../ingredients.js?v=162';
import {
  ensureStockItem, findStockItem, formatStockLine,
  isInventoryAvailable, loadInventory, remainingDays, saveInventory
} from '../inventory.js?v=162';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=162';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  getLocalRecommendations, hasRecipeMethod,
  processAiData, rankRecipesForRecommendation,
  getCleanFridgeRecommendations
} from '../recommendations.js?v=162';
import { callCloudAI, formatAiErrorMessage } from '../ai.js?v=162';
import { renderInventory } from './inventory-view.js?v=162';
import { showRecommendationCards, renderRecipeSearchResults } from '../components/recipe-card.js?v=162';
import { escapeHtml, brieflyConfirmButton, setInlineStatus } from '../components/status.js?v=162';
import { showCleanFridgeModal } from '../components/modal.js?v=162';

/*
 * ──────────────────────────────────────────────────────────────────────────
 *  Section 1 数据源（AI 灵感面板）—— 未来替换为 AI / Ollama 调用的唯一入口。
 *
 *  卡片结构（getInspirationCards 与 mockAiRecommendations 共用同一形状）：
 *    {
 *      id:        菜谱 id（真实推荐时有值；纯灵感/示例时为 null）
 *      name:      菜名
 *      matchLabel:右上角小标签，如 "库存匹配 100%" / "只差 1 样" / "AI 灵感"
 *      missing:   缺少的核心食材名数组（可空）
 *      reason:    一句话推荐理由
 *      tone:      'priority' | 'ready' | 'almost' | 'idea'（决定配色与按钮文案）
 *      row:       （可选）原始推荐行，用于「补清单」时计算缺料
 *    }
 *
 *  接入真实 AI 时：把 getInspirationCards() 换成一个返回上述形状数组的
 *  async 函数（例如 fetch 本地 Ollama），其余渲染代码无需改动。
 * ──────────────────────────────────────────────────────────────────────────
 */
const mockAiRecommendations = {
  greeting: null, // 传 null 时由 buildGreeting() 按时间 + 库存自动生成
  cards: [
    { id: null, name: '番茄炒蛋', matchLabel: '库存匹配 100%', missing: [], reason: '鸡蛋和番茄都在，十分钟上桌', tone: 'ready' },
    { id: null, name: '青椒肉丝', matchLabel: '只差 1 样', missing: ['青椒'], reason: '补个青椒就能下锅', tone: 'almost' },
    { id: null, name: '麻婆豆腐', matchLabel: 'AI 灵感', missing: [], reason: '今晚想吃点麻辣的？', tone: 'idea' }
  ]
};

function buildGreeting(expiringCount) {
  const h = new Date().getHours();
  const part = h < 5 ? '夜深了' : h < 11 ? '早上好' : h < 14 ? '中午好' : h < 18 ? '下午好' : '晚上好';
  const emoji = h < 5 ? '🌙' : h < 18 ? '👋' : '🌆';
  if (expiringCount > 0) {
    return `${emoji} ${part}！有 ${expiringCount} 样食材快到期了，今晚可以这样做：`;
  }
  return `${emoji} ${part}！根据你现在的库存，今晚推荐这几道：`;
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

// 把真实的「今日决策」推荐映射成 Section 1 的统一卡片形状（最多 3 张）。
function getInspirationCards(pack, inv) {
  const groups = getTodayDecisionGroups(pack, inv);
  const cards = [];
  const pushFrom = (list, tone) => {
    for (const row of (list || [])) {
      if (cards.length >= 3) break;
      if (cards.some(c => c.id === row.r.id)) continue;
      let matchLabel = '';
      let missing = [];
      if (tone === 'priority') {
        matchLabel = '优先用掉';
      } else if (tone === 'ready') {
        matchLabel = '库存匹配 100%';
      } else {
        missing = (row.missing || []).map(m => m.name || m.item).filter(Boolean);
        matchLabel = `只差 ${missing.length} 样`;
      }
      cards.push({ id: row.r.id, name: row.r.name, matchLabel, missing, reason: row.reason || '', tone, row });
    }
  };
  pushFrom(groups.priority, 'priority');
  pushFrom(groups.ready, 'ready');
  pushFrom(groups.almost, 'almost');
  return cards;
}

// ── Section 1: AI 灵感面板（Hero / 胶囊容器） ───────────────────────────────
function renderSuggestCard(card, pack, inv) {
  const el = document.createElement('article');
  el.className = `home-suggest-card tone-${card.tone || 'idea'}`;
  const missingTag = (card.missing && card.missing.length)
    ? `<span class="home-suggest-missing">缺 ${escapeHtml(card.missing.join('、'))}</span>`
    : '';
  el.innerHTML = `
    <span class="home-suggest-match">${escapeHtml(card.matchLabel || '')}</span>
    <h3 class="home-suggest-name">${escapeHtml(card.name)}</h3>
    <p class="home-suggest-reason">${escapeHtml(card.reason || '')}</p>
    ${missingTag}
    <button type="button" class="btn ok small home-suggest-cook">${card.tone === 'almost' ? '补清单' : '做这道'}</button>
  `;
  const cookBtn = el.querySelector('.home-suggest-cook');
  cookBtn.onclick = () => {
    if (!card.id) { brieflyConfirmButton(cookBtn, '示例'); return; }
    if (card.tone === 'almost' && card.row) {
      const count = addMissingRecipeIngredientsToShopping(card.row.r, pack, inv, card.row.list);
      brieflyConfirmButton(cookBtn, count ? '已入清单' : '已齐');
    } else {
      addRecipeToPlan(card.id);
      brieflyConfirmButton(cookBtn, '已加入');
    }
  };
  if (card.id) {
    const name = el.querySelector('.home-suggest-name');
    name.classList.add('is-link');
    name.onclick = () => { location.hash = `#recipe:${card.id}`; };
  }
  return el;
}

function renderInspirationPanel(pack, inv, expiringCount) {
  const section = document.createElement('section');
  section.className = 'home-hero';

  let cards = getInspirationCards(pack, inv);
  const usingMock = cards.length === 0;
  if (usingMock) cards = mockAiRecommendations.cards;

  const greeting = mockAiRecommendations.greeting || buildGreeting(expiringCount);
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <span class="home-hero-eyebrow">🧠 今日灵感</span>
      <h2 class="home-hero-greeting">${escapeHtml(greeting)}</h2>
    </div>
    <div class="home-suggest-scroll"></div>
    ${usingMock ? '<p class="home-hero-note">示例推荐 · 录入更多库存后会自动匹配你的食材</p>' : ''}
  `;
  const scroll = section.querySelector('.home-suggest-scroll');
  cards.forEach(card => scroll.appendChild(renderSuggestCard(card, pack, inv)));
  return section;
}

// ── Section 2: 紧急指标 / 雷达（2 列） ─────────────────────────────────────
function renderUrgentMetrics(inv, activeShoppingCount, { onOpenExpiring = () => {} } = {}) {
  const expiring48 = (inv || []).filter(it => isInventoryAvailable(it) && remainingDays(it) <= 2);
  const hasExpired = expiring48.some(it => remainingDays(it) < 0);
  const radarTone = expiring48.length > 0 ? (hasExpired ? 'is-bad' : 'is-warn') : 'is-ok';

  const section = document.createElement('section');
  section.className = 'home-metrics';
  section.innerHTML = `
    <button type="button" class="home-metric ${radarTone}" id="metricExpiring">
      <span class="home-metric-icon">🚨</span>
      <span class="home-metric-num">${expiring48.length}</span>
      <span class="home-metric-label">样食材 48 小时内到期</span>
    </button>
    <button type="button" class="home-metric is-info" id="metricShopping">
      <span class="home-metric-icon">🛒</span>
      <span class="home-metric-num">${activeShoppingCount}</span>
      <span class="home-metric-label">项待买 · 购物清单</span>
    </button>
  `;
  section.querySelector('#metricExpiring').onclick = () => onOpenExpiring();
  section.querySelector('#metricShopping').onclick = () => { location.hash = '#shopping'; };
  return section;
}

// ── Section 3: 快捷操作中心 + 最近动态 ─────────────────────────────────────
function renderActionHub({ onQuickInput = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-actions-hub';
  section.innerHTML = `
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="actQuickInput"><span class="home-act-emoji">📦</span><span>快速入库</span></button>
      <button type="button" class="home-act-btn" id="actQuickMemo"><span class="home-act-emoji">📝</span><span>速记清单</span></button>
    </div>
    <div class="home-memo is-hidden" id="memoRow">
      <input id="memoInput" placeholder="输入要买的东西，回车加入清单">
      <button type="button" class="btn ok small" id="memoAdd">加入</button>
    </div>
    <div class="home-activity" id="homeActivity"></div>
  `;

  const activity = section.querySelector('#homeActivity');
  const renderActivity = () => {
    const recent = loadShoppingItems().filter(i => !i.done).slice(-3).reverse();
    if (!recent.length) {
      activity.innerHTML = '<span class="home-activity-empty">还没有待买项目，用上面的「速记清单」随手记一笔</span>';
      return;
    }
    activity.innerHTML = '<div class="home-activity-title">清单最近添加</div>' + recent.map(it => {
      const qty = it.qty ? ` · ${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}` : '';
      const src = it.source ? `<small>${escapeHtml(it.source)}</small>` : '';
      return `<div class="home-activity-row"><span>📝 ${escapeHtml(it.name)}${qty}</span>${src}</div>`;
    }).join('');
  };

  section.querySelector('#actQuickInput').onclick = () => onQuickInput();

  const memoRow = section.querySelector('#memoRow');
  const memoInput = section.querySelector('#memoInput');
  section.querySelector('#actQuickMemo').onclick = () => {
    memoRow.classList.toggle('is-hidden');
    if (!memoRow.classList.contains('is-hidden')) memoInput.focus();
  };
  const commitMemo = () => {
    const name = memoInput.value.trim();
    if (!name) return;
    addShoppingItem(name, '', '', '速记');
    memoInput.value = '';
    memoInput.focus();
    renderActivity();
    // 同步更新 Section 2 的待买计数（避免整页重渲染丢失焦点）
    const numEl = document.querySelector('#metricShopping .home-metric-num');
    if (numEl) numEl.textContent = String(loadShoppingItems().filter(i => !i.done).length);
  };
  memoInput.onkeydown = (e) => { if (e.key === 'Enter') commitMemo(); };
  section.querySelector('#memoAdd').onclick = commitMemo;

  renderActivity();
  return section;
}

// ── 空库存引导 ─────────────────────────────────────────────────────────────
function renderOnboarding({ openInventoryAddForm = () => {}, fullInvDetails } = {}) {
  const section = document.createElement('section');
  section.className = 'home-hero is-onboarding';
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <span class="home-hero-eyebrow">🍳 开始使用</span>
      <h2 class="home-hero-greeting">先录入一些库存，立刻获得今日推荐和快到期提醒</h2>
    </div>
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="obManual"><span class="home-act-emoji">📦</span><span>立即入库</span></button>
      <button type="button" class="home-act-btn" id="obReceipt"><span class="home-act-emoji">🧾</span><span>拍小票</span></button>
      <button type="button" class="home-act-btn" id="obBackup"><span class="home-act-emoji">💾</span><span>导入备份</span></button>
    </div>
  `;
  section.querySelector('#obManual').onclick = () => openInventoryAddForm();
  section.querySelector('#obReceipt').onclick = () => {
    if (fullInvDetails) {
      fullInvDetails.open = true;
      const input = fullInvDetails.querySelector('#camInput');
      if (input) input.click();
      fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  };
  section.querySelector('#obBackup').onclick = () => { location.hash = '#settings'; };
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
  const expiringSoonCount = (inv || []).filter(it => isInventoryAvailable(it) && remainingDays(it) <= 3).length;
  const shoppingItems = loadShoppingItems();
  const activeShopping = shoppingItems.filter(item => !item.done);

  const title = document.createElement('div'); title.className = 'main-title-center'; title.innerHTML = '<span>厨房</span>';
  container.appendChild(title);

  // 完整库存节点（被引导、快速入库、到期雷达共用）
  const fullInventoryNode = renderInventory(pack, { showTitle: false, onInventoryChanged: onRoute });
  const fullInvDetails = renderHomeDetails('完整库存', '手动录入、拍小票及完整库存明细', [fullInventoryNode], !hasUsableInventory(inv));
  fullInvDetails.id = 'homeInventoryDetails';

  const openInventoryAddForm = () => {
    fullInvDetails.open = true;
    const form = fullInvDetails.querySelector('.add-form-container');
    const toggle = fullInvDetails.querySelector('#toggleAddBtn');
    if (form && toggle && !form.classList.contains('open')) toggle.click();
    fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  // ── 空库存：引导入库 ──
  if (!hasUsableInventory(inv)) {
    container.appendChild(renderOnboarding({ openInventoryAddForm, fullInvDetails }));
    const invTitle = document.createElement('div'); invTitle.className = 'section-title home-section-title';
    invTitle.id = 'homeInventoryPanel'; invTitle.innerHTML = '<span>先录入库存</span>';
    container.appendChild(invTitle);
    container.appendChild(fullInvDetails);
    return container;
  }

  // ── Section 1：AI 灵感面板 ──
  container.appendChild(renderInspirationPanel(pack, inv, expiringSoonCount));

  // ── Section 2：紧急指标 / 雷达 ──
  container.appendChild(renderUrgentMetrics(inv, activeShopping.length, {
    onOpenExpiring: () => { fullInvDetails.open = true; fullInvDetails.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
  }));

  // ── Section 3：快捷操作中心 ──
  container.appendChild(renderActionHub({ onQuickInput: openInventoryAddForm }));

  // ── 渐进展开：保留原有功能（清冰箱 / 搜索 / 常备货架 / 完整库存 / 更多推荐） ──
  const cleanFridgeCard = document.createElement('div');
  cleanFridgeCard.className = 'card home-clean-fridge-entry';
  cleanFridgeCard.innerHTML = `
    <div class="home-clean-fridge-entry-content">
      <h3>❄️ 帮我清冰箱</h3>
      <p>智能筛选快到期、低存量食材，一键搭配做法</p>
    </div>
    <button type="button" class="btn ok" id="btnCleanFridge" style="background: linear-gradient(180deg, #ff9500 0%, #ff7b00 100%); border-color: rgba(255,255,255,0.42); box-shadow: 0 8px 18px rgba(255, 149, 0, 0.24); color: white;">开始清冰箱</button>
  `;
  cleanFridgeCard.querySelector('#btnCleanFridge').onclick = () => {
    const recs = getCleanFridgeRecommendations(pack, inv, getRecommendationUiContext());
    showCleanFridgeModal(recs, {
      onAddPlan: (id, btn) => {
        addRecipeToPlan(id);
        brieflyConfirmButton(btn, '已加入');
        onRoute();
      },
      onAddShopping: (id, btn) => {
        const recItem = recs.find(item => item.r.id === id);
        if (recItem) {
          const count = addMissingRecipeIngredientsToShopping(recItem.r, pack, inv, recItem.list);
          brieflyConfirmButton(btn, count ? '已入清单' : '已齐');
          onRoute();
        }
      }
    });
  };
  container.appendChild(cleanFridgeCard);

  // 搜索菜谱 / 食材
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
  searchBar.querySelector('#mainSearch').onkeydown = (e) => { if (e.key === 'Enter') doSearch(); };
  searchBar.querySelector('#doSearch').onclick = doSearch;
  searchBar.querySelector('#clearSearch').onclick = clearSearch;

  searchDetails = renderHomeDetails('搜索菜谱 / 食材', '找具体菜名或某个食材', [searchBar, searchResultsContainer], false);
  container.appendChild(searchDetails);

  const cabinetOpen = hasLowOrEmptyStockInCabinet(inv);
  const cabinetDetails = renderHomeDetails('常备货架', '日常补给与常备干货存量', [renderDryGoodsCabinet(inv, { onInventoryChanged: onRoute })], cabinetOpen);
  container.appendChild(cabinetDetails);

  container.appendChild(fullInvDetails);

  const moreRecsNode = renderMoreRecommendations(pack, inv, { onRoute });
  const moreRecsDetails = renderHomeDetails('更多推荐和 AI', '想换换口味时再打开', [moreRecsNode], false);
  container.appendChild(moreRecsDetails);

  return container;
}
