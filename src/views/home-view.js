import { S, todayISO } from '../storage.js?v=219';
import { buildCatalog, getCanonicalName, buildIngredientOptions, getDryPrepText, guessKitchenUnit, guessShelfDays, isDryGoodName, getUnitType, UNIT_TYPE } from '../ingredients.js?v=219';
import { isInventoryAvailable, loadInventory, mergeInventoryEntry, remainingDays, saveInventory, getItemGear, gearInfo, GEAR_LABELS, syncOutOfStockTimestamp } from '../inventory.js?v=219';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=219';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  hasRecipeMethod, rankRecipesForRecommendation,
  getCleanFridgeRecommendations, processAiData
} from '../recommendations.js?v=219';
import { callCloudAI, formatAiErrorMessage, recognizeReceipt, withTimeout } from '../ai.js?v=219';
import { escapeHtml, escapeOptionAttr, brieflyConfirmButton, setInlineStatus } from '../components/status.js?v=219';
import { showRecommendationCards } from '../components/recipe-card.js?v=219';
import { showCleanFridgeModal, showReceiptConfirmationModal, showQuickShoppingModal, showQuickShoppingNoteModal, showPendingShoppingModal } from '../components/modal.js?v=219';
import { renderMenuPlan, renderPlanRangeSelect, renderCookAllButton } from '../components/menu-plan.js?v=219';

/*
 * ──────────────────────────────────────────────────────────────────────────
 *  Section 1 数据源（AI 灵感面板）—— 未来替换为 AI / Ollama 调用的唯一入口。
 *
 *  卡片结构（getInspirationCards 与 mockAiRecommendations 共用同一形状）：
 *    { id, name, matchLabel, missing:[], reason, tone, row? }
 *    tone: 'priority' | 'ready' | 'almost' | 'idea'
 *
 *  接入真实 AI 时：把 getInspirationCards() 换成一个返回上述形状数组的 async 函数
 *  （例如 fetch 本地 Ollama），其余渲染代码无需改动。
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

// 到期提醒不统计鸡蛋、牛奶（它们按常备品状态管理，不看保质期）。
const EXPIRY_EXCLUDE_NAMES = new Set(['鸡蛋', '牛奶']);
function isExpiryTracked(item) {
  return isInventoryAvailable(item) && !EXPIRY_EXCLUDE_NAMES.has(getCanonicalName(item.name || ''));
}

function getExpiringItems(inv) {
  return [...(inv || [])]
    .filter(item => isExpiryTracked(item) && remainingDays(item) <= 3)
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

function openCleanFridgeHelper(pack, inv, onRoute = () => {}) {
  const recs = getCleanFridgeRecommendations(pack, inv, getRecommendationUiContext());
  showCleanFridgeModal(recs, {
    onAddPlan: (id, btn) => { addRecipeToPlan(id); brieflyConfirmButton(btn, '已加入'); onRoute(); },
    onAddShopping: (id, btn) => {
      const recItem = recs.find(item => item.r.id === id);
      if (recItem) {
        const count = addMissingRecipeIngredientsToShopping(recItem.r, pack, inv, recItem.list);
        brieflyConfirmButton(btn, count ? '已入清单' : '已齐');
        onRoute();
      }
    }
  });
}

function getTodayDecisionGroups(pack, inv) {
  const ranked = rankRecipesForRecommendation(pack, inv, getRecommendationUiContext())
    .filter(item => hasRecipeMethod(item.r));

  const priorityList = [];
  const readyList = [];
  const almostList = [];

  for (const row of ranked) {
    if (row.expiringMatches && row.expiringMatches.length > 0) {
      const first = row.expiringMatches[0];
      let timeText = '';
      if (first.days < 0) timeText = `已过期 ${Math.abs(first.days)} 天`;
      else if (first.days === 0) timeText = '今天到期';
      else timeText = `还剩 ${first.days} 天到期`;
      row.reason = `${first.name}${timeText}，建议优先用`;
      priorityList.push(row);
    } else if (row.coverageConfidence === 'exact') {
      row.reason = '食材已齐';
      readyList.push(row);
    } else if (row.missing && row.missing.length > 0 && row.missing.length <= 2) {
      const missingNames = row.missing.map(m => m.name || m.item).filter(Boolean);
      row.reason = `只缺 ${missingNames.join('、')}`;
      almostList.push(row);
    }
  }

  return {
    priority: priorityList.slice(0, 3),
    ready: readyList.slice(0, 3),
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
      if (tone === 'priority') matchLabel = '优先用掉';
      else if (tone === 'ready') matchLabel = '库存匹配 100%';
      else {
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

// ── Section 1: AI 灵感面板（Hero 胶囊） ───────────────────────────────────────
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

/*
 * renderInspirationPanel — 合并卡结构（is-combo 模式）
 *
 * ⚠️ 布局已翻转：菜单计划置顶，AI 灵感卡片居底。
 *
 *  ┌─ .home-hero.is-combo ──────────────────────┐
 *  │  [标题 + 计划范围筛选]                      │ ← home-hero-head
 *  │  菜单计划 (extraNode)                       │ ← 置顶
 *  │  🧠 今日灵感 问候语                          │ ← 移至底部
 *  │  [横向滑动推荐卡片流]                        │
 *  │  [注释文字]                                  │
 *  └───────────────────────────────────────────┘
 */
function renderInspirationPanel(pack, inv, expiringCount, { onRoute = () => {}, extraNode = null, headerAction = null } = {}) {
  const section = document.createElement('section');
  section.className = `home-hero${extraNode ? ' is-combo' : ''}`;

  const eyebrow = extraNode ? '📅 今日计划' : '🧠 今日灵感';

  // 标题行：计划范围筛选器由外层注入，避免卡片内部再出现一层标题。
  const headEl = document.createElement('div');
  headEl.className = 'home-hero-glow-wrap';
  headEl.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <div class="home-hero-top">
        <span class="home-hero-eyebrow">${eyebrow}</span>
      </div>
    </div>
    <div id="heroAiStatus" class="small inline-status" hidden></div>
  `;
  section.appendChild(headEl);
  if (headerAction) {
    const topEl = headEl.querySelector('.home-hero-top');
    const actionWrap = document.createElement('div');
    actionWrap.className = 'home-hero-head-action';
    actionWrap.appendChild(headerAction);
    topEl.appendChild(actionWrap);
  }

  if (extraNode) {
    // ── 菜单计划区（置顶） ──
    const planSlot = document.createElement('div');
    planSlot.className = 'home-combo-plan';
    planSlot.appendChild(extraNode);
    section.appendChild(planSlot);
  }

  // ── AI 灵感折叠区 ──────────────────────────────────────────────────────────
  // 1. 展开触发按钮（默认可见）
  const toggleBtn = document.createElement('button');
  toggleBtn.type = 'button';
  toggleBtn.className = 'home-inspi-toggle-btn';
  toggleBtn.id = 'heroInspiToggle';
  // 卡片数量稍后更新
  toggleBtn.innerHTML = `<span class="home-inspi-toggle-icon">✨</span><span class="home-inspi-toggle-text">查看今日 AI 智能灵感推荐</span><span class="home-inspi-toggle-arrow">›</span>`;
  section.appendChild(toggleBtn);

  // 2. 折叠内容容器（默认隐藏）
  const inspiWrap = document.createElement('div');
  inspiWrap.className = 'home-inspi-bottom is-collapsed';
  inspiWrap.setAttribute('aria-hidden', 'true');

  // 面板内部：问候语行（含「换一批」按钮） + 状态行 + 滚动卡片 + 注释
  inspiWrap.innerHTML = `
    <div class="home-inspi-panel-head">
      <p class="home-hero-greeting">🔮 结合当前厨房库存，为你定制的今日烹饪灵感：</p>
      <button type="button" class="home-mini-btn home-ai-btn" id="heroAiBtn">✨ AI 换一批</button>
    </div>
    <div class="home-suggest-scroll"></div>
    <p class="home-hero-note" id="heroNote"></p>
  `;
  section.appendChild(inspiWrap);

  const scroll = inspiWrap.querySelector('.home-suggest-scroll');
  const note = inspiWrap.querySelector('#heroNote');
  const aiStatus = section.querySelector('#heroAiStatus');
  const aiBtn = inspiWrap.querySelector('#heroAiBtn');

  // 折叠状态切换
  let inspiExpanded = false;
  const updateToggleLabel = (count) => {
    const text = toggleBtn.querySelector('.home-inspi-toggle-text');
    const arrow = toggleBtn.querySelector('.home-inspi-toggle-arrow');
    if (text) text.textContent = inspiExpanded
      ? '收起灵感推荐'
      : `查看今日 AI 智能灵感推荐${count ? ` (${count})` : ''}`;
    if (arrow) arrow.textContent = '›';
    toggleBtn.setAttribute('aria-expanded', String(inspiExpanded));
  };

  toggleBtn.onclick = () => {
    inspiExpanded = !inspiExpanded;
    if (inspiExpanded) {
      inspiWrap.classList.remove('is-collapsed');
      inspiWrap.removeAttribute('aria-hidden');
    } else {
      inspiWrap.classList.add('is-collapsed');
      inspiWrap.setAttribute('aria-hidden', 'true');
    }
    updateToggleLabel(scroll.querySelectorAll('.home-suggest-card, .card').length);
  };
  updateToggleLabel(0);

  // 默认：本地/示例推荐
  const showLocal = () => {
    let cards = getInspirationCards(pack, inv);
    const usingMock = cards.length === 0;
    if (usingMock) cards = mockAiRecommendations.cards;
    scroll.innerHTML = '';
    cards.forEach(card => scroll.appendChild(renderSuggestCard(card, pack, inv)));
    note.textContent = usingMock ? '示例推荐 · 录入更多库存后会自动匹配你的食材' : '';
    note.hidden = !usingMock;
    updateToggleLabel(cards.length);
  };

  // AI 推荐：最多展示 4 张
  const showAi = (aiCards) => {
    showRecommendationCards(scroll, (aiCards || []).slice(0, 4), pack, { onRoute });
    note.hidden = false;
    note.innerHTML = 'AI 草稿推荐，请确认后再安排。<button type="button" class="home-note-clear" id="heroAiClear">用本地推荐</button>';
    const clearBtn = note.querySelector('#heroAiClear');
    if (clearBtn) clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); showLocal(); setInlineStatus(aiStatus, '', 'info'); };
    updateToggleLabel((aiCards || []).slice(0, 4).length);
  };

  // 初次渲染：若已有保存的 AI 推荐则展示，否则本地推荐
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  const savedCards = savedAiRecs ? processAiData(savedAiRecs, pack) : [];
  if (savedCards.length > 0) showAi(savedCards); else showLocal();

  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;
    aiBtn.setAttribute('disabled', 'true');
    const original = aiBtn.textContent;
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中…';
    const safety = setTimeout(() => {
      aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled');
      setInlineStatus(aiStatus, formatAiErrorMessage(new Error('AI 响应超时')), 'bad');
    }, 30000);
    try {
      const aiResult = await callCloudAI(pack, inv);
      clearTimeout(safety);
      const cards = processAiData(aiResult, pack);
      if (cards.length > 0) {
        S.save(S.keys.ai_recs, aiResult);
        showAi(cards);
        setInlineStatus(aiStatus, 'AI 已生成草稿推荐。', 'ok');
        // 自动展开（刷新后）
        if (!inspiExpanded) toggleBtn.click();
      } else {
        setInlineStatus(aiStatus, 'AI 没有返回可用菜谱，已保留本地推荐。', 'info');
      }
    } catch (e) {
      clearTimeout(safety);
      setInlineStatus(aiStatus, formatAiErrorMessage(e), 'bad');
    } finally {
      aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled');
    }
  };

  return section;
}

// ── 原地弹窗工具函数 ─────────────────────────────────────────────────────────
/**
 * 创建一个半透明遮罩 + 居中/底部弹出的 Modal 层。
 * @param {HTMLElement} contentEl - 弹窗内容节点
 * @param {string} [title] - 弹窗标题（显示在 X 按钮左侧）
 * @returns {{ overlay, close }}
 */
function createHomeModal(contentEl, title = '') {
  // 统一模态外壳骨架（背景毛玻璃 + 圆角面板 + 右上角 X + 入场动画）。
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';

  const panel = document.createElement('div');
  panel.className = 'km-modal-content';

  // 标题行 + X 关闭按钮
  const header = document.createElement('div');
  header.className = 'km-modal-header';
  header.innerHTML = `
    <span class="km-modal-title">${escapeHtml(title)}</span>
    <button type="button" class="km-modal-close" aria-label="关闭">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
      </svg>
    </button>
  `;
  panel.appendChild(header);
  panel.appendChild(contentEl);
  overlay.appendChild(panel);

  let isClosing = false;
  const close = () => {
    if (isClosing) return;
    isClosing = true;
    panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
    panel.style.opacity = '0';
    panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
    overlay.classList.add('closing');
    setTimeout(() => overlay.remove(), 220);
  };

  header.querySelector('.km-modal-close').onclick = close;
  overlay.onclick = (e) => { if (e.target === overlay) close(); };

  document.body.appendChild(overlay);
  // 触发入场动画
  requestAnimationFrame(() => overlay.classList.add('open'));

  return { overlay, close };
}

// ── 弹窗内容构建 ─────────────────────────────────────────────────────────────

/** 「到期食材」弹窗：列出快到期 / 已过期食材（名称·数量单位·到期状态），支持逐项加入购物清单。 */
function buildExpiryModal(inv, pack, { onClose = () => {}, onCleanFridge = () => {}, onChange = () => {} } = {}) {
  const expiring = (inv || [])
    .filter(it => isExpiryTracked(it) && remainingDays(it) <= 3)
    .sort((a, b) => remainingDays(a) - remainingDays(b));

  const wrap = document.createElement('div');
  wrap.className = 'km-modal-body';

  if (!expiring.length) {
    wrap.innerHTML = '<p class="km-modal-empty">✅ 最近没有快到期的食材。</p>';
    const footer = document.createElement('div');
    footer.className = 'km-modal-actions';
    footer.innerHTML = '<button type="button" class="btn ok" id="expiryCloseBtn">关闭</button>';
    footer.querySelector('#expiryCloseBtn').onclick = onClose;
    wrap.appendChild(footer);
    return wrap;
  }

  const list = document.createElement('ul');
  list.className = 'km-expiry-list';
  expiring.forEach(it => {
    const d = remainingDays(it);
    const li = document.createElement('li');
    li.className = `km-expiry-item${d < 0 ? ' is-expired' : d <= 1 ? ' is-urgent' : ''}`;
    const dayText = d < 0 ? `已过期 ${Math.abs(d)} 天` : d === 0 ? '今天到期' : `还剩 ${d} 天`;
    const qty = (+it.qty > 0) ? `${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}` : '';
    li.innerHTML = `
      <span class="km-expiry-main">
        <span class="km-expiry-name">${escapeHtml(it.name)}</span>
        ${qty ? `<span class="km-expiry-qty">${qty}</span>` : ''}
      </span>
      <span class="km-expiry-days">${dayText}</span>
      <button type="button" class="btn small km-expiry-add">加入清单</button>
    `;
    li.querySelector('.km-expiry-add').onclick = (e) => {
      addShoppingItem(it.name, (+it.qty > 0 ? it.qty : ''), it.unit || '', '临期补货');
      const btn = e.currentTarget;
      btn.textContent = '已加入';
      btn.disabled = true;
      onChange();
    };
    list.appendChild(li);
  });
  wrap.appendChild(list);

  const footer = document.createElement('div');
  footer.className = 'km-modal-actions';
  footer.innerHTML = expiring.length >= 2
    ? '<button type="button" class="btn" id="expiryCloseBtn">关闭</button><button type="button" class="btn km-modal-ai-btn" id="expiryCleanFridgeBtn">✨ 帮我清冰箱</button>'
    : '<button type="button" class="btn ok" id="expiryCloseBtn">关闭</button>';
  footer.querySelector('#expiryCloseBtn').onclick = onClose;
  const cleanBtn = footer.querySelector('#expiryCleanFridgeBtn');
  if (cleanBtn) cleanBtn.onclick = onCleanFridge;
  wrap.appendChild(footer);

  return wrap;
}

// 打开「到期食材」弹窗。
function openExpiryListModal(inv, pack, { onRoute = () => {}, onChange = () => {} } = {}) {
  let closeFn = () => {};
  const body = buildExpiryModal(inv, pack, {
    onClose: () => closeFn(),
    onCleanFridge: () => { closeFn(); openCleanFridgeHelper(pack, inv, onRoute); },
    onChange
  });
  const { close } = createHomeModal(body, '⏳ 到期食材');
  closeFn = close;
}

/* 旧版「批量入库」单件添加弹窗 buildBatchStockModal 已彻底删除。
   现在所有 📦 批量入库点击都进入 openBatchInputModal（双 Tab：📸 拍小票识别 + ✍️ 文本批量记），
   入口在 renderActionHub 内点击 #actQuickInput 时触发；切勿在此处复活旧表单。 */

/** 「随手记」弹窗 */
function buildMemoModal(onClose) {
  const wrap = document.createElement('div');
  wrap.className = 'km-modal-body';
  wrap.innerHTML = `
    <p class="km-modal-hint" style="margin-top:0">输入名字后回车，快速加入购物清单。</p>
    <div class="km-modal-add-row">
      <input class="km-modal-input" id="memoModalInput" placeholder="要买什么？">
      <button type="button" class="btn ok small" id="memoModalAdd">加入</button>
    </div>
    <ul class="km-memo-log" id="memoLog"></ul>
    <div class="km-modal-actions">
      <button type="button" class="btn ok" id="gotoShoppingFromMemo">前往购物清单 →</button>
    </div>
  `;

  const input = wrap.querySelector('#memoModalInput');
  const log = wrap.querySelector('#memoLog');

  const refreshLog = () => {
    const recent = loadShoppingItems().filter(i => !i.done).slice(-5).reverse();
    log.innerHTML = '';
    if (!recent.length) {
      log.innerHTML = '<li class="km-modal-empty">还没有待买项</li>';
      return;
    }
    recent.forEach(it => {
      const li = document.createElement('li');
      li.className = 'km-shopping-item';
      li.innerHTML = `<span>📝 ${escapeHtml(it.name)}</span><small>${escapeHtml(it.source || '')}</small>`;
      log.appendChild(li);
    });
  };
  refreshLog();

  const doAdd = () => {
    const name = input.value.trim();
    if (!name) return;
    addShoppingItem(name, '', '', '速记');
    input.value = '';
    input.focus();
    refreshLog();
    // 更新首页 metric 数字
    const numEl = document.querySelector('#metricShopping .home-metric-num');
    if (numEl) numEl.textContent = String(loadShoppingItems().filter(i => !i.done).length);
  };

  input.onkeydown = (e) => { if (e.key === 'Enter') doAdd(); };
  wrap.querySelector('#memoModalAdd').onclick = doAdd;
  wrap.querySelector('#gotoShoppingFromMemo').onclick = () => { onClose(); location.hash = '#shopping'; };

  return wrap;
}

// ── Section 2: 紧急指标 / 雷达（2 列） ─────────────────────────────────────
function renderUrgentMetrics(pack, inv, activeShoppingCount, { onRoute = () => {} } = {}) {
  const expiring48 = (inv || []).filter(it => isExpiryTracked(it) && remainingDays(it) <= 2);
  const hasExpired = expiring48.some(it => remainingDays(it) < 0);
  const radarTone = expiring48.length > 0 ? (hasExpired ? 'is-bad' : 'is-warn') : 'is-ok';

  const section = document.createElement('section');
  section.className = 'home-metrics';
  // 视觉顺序：标签置顶（首要锚点）→ 大数字（结果）。Icon 移至标签旁辅助定位。
  section.innerHTML = `
    <button type="button" class="home-metric ${radarTone}" id="metricExpiring">
      <span class="home-metric-header">
        <span class="home-metric-icon">🚨</span>
        <span class="home-metric-label">48h 临期</span>
      </span>
      <span class="home-metric-num">${expiring48.length}</span>
      <span class="home-metric-sub">种食材</span>
    </button>
    <button type="button" class="home-metric is-info" id="metricShopping">
      <span class="home-metric-header">
        <span class="home-metric-icon">🛒</span>
        <span class="home-metric-label">待买清单</span>
      </span>
      <span class="home-metric-num">${activeShoppingCount}</span>
      <span class="home-metric-sub">项未完成</span>
    </button>
  `;

  // ── 原地弹窗（不再硬跳转到 #shopping 页面）──
  section.querySelector('#metricExpiring').onclick = () => {
    let closeModal = () => {};
    const modalBody = buildExpiryModal(inv, pack, {
      onClose: () => closeModal(),
      onCleanFridge: () => {
        closeModal();
        openCleanFridgeHelper(pack, inv, onRoute);
      }
    });
    const { overlay, close } = createHomeModal(modalBody, '🚨 临期食材明细');
    closeModal = close;
    setTimeout(() => overlay.querySelector('#memoModalInput, input')?.focus?.(), 80);
  };
  section.querySelector('#metricShopping').onclick = () => showQuickShoppingModal();

  return section;
}

// ── Section 3: 极速操作组（批量入库 / 随手记 / 微型清冰箱） ──────────────────
function renderActionHub(pack, inv, { onQuickInput = () => {}, onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-actions-hub';
  section.innerHTML = `
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="actQuickInput"><span class="home-act-emoji">📦</span><span>采购存入</span></button>
      <button type="button" class="home-act-btn" id="actQuickMemo"><span class="home-act-emoji">📝</span><span>速加待买</span></button>
    </div>
    <div class="home-activity" id="homeActivity"></div>
  `;

  const activity = section.querySelector('#homeActivity');
  const renderActivity = () => {
    const recent = loadShoppingItems().filter(i => !i.done).slice(-3).reverse();
    if (!recent.length) {
      activity.innerHTML = '<span class="home-activity-empty">还没有待买项目，用上面的「随手记」随手记一笔</span>';
      return;
    }
    activity.innerHTML = '<div class="home-activity-title">清单最近添加</div>' + recent.map(it => {
      const qty = it.qty ? ` · ${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}` : '';
      const src = it.source ? `<small>${escapeHtml(it.source)}</small>` : '';
      return `<div class="home-activity-row"><span>📝 ${escapeHtml(it.name)}${qty}</span>${src}</div>`;
    }).join('');
  };

  // ── 批量入库 → 全新【双 Tab 弹窗】（📸 拍小票识别 / ✍️ 文本批量记） ──
  //   直接在此处调用 openBatchInputModal 是为了消灭历史 bug：
  //   早期版本曾在这里硬编码绑定到旧的「单件添加表单」(buildBatchStockModal)，
  //   会覆盖外部 onQuickInput 回调，导致点击 📦 时仍弹出旧表单。
  section.querySelector('#actQuickInput').onclick = () => {
    openBatchInputModal(pack, { onRoute, initialTab: 'receipt' });
  };

  // ── 随手记 → 原地弹窗 ──
  section.querySelector('#actQuickMemo').onclick = () => {
    const { overlay, close } = createHomeModal(buildMemoModal(() => close()), '📝 添加待买物品');
    setTimeout(() => {
      overlay.querySelector('#memoModalInput')?.focus?.();
      renderActivity(); // 关闭后刷新动态列
    }, 80);
  };

  renderActivity();
  return section;
}

// ── 空库存引导（库存录入已在「清单」页，引导跳转过去） ──────────────────────
function renderOnboarding(pack, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-hero is-onboarding';
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <span class="home-hero-eyebrow">🍳 开始使用</span>
      <h2 class="home-hero-greeting">先到「清单」页录入一些库存，立刻获得今日推荐和快到期提醒</h2>
    </div>
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="obManual"><span class="home-act-emoji">📦</span><span>立即入库</span></button>
      <button type="button" class="home-act-btn" id="obReceipt"><span class="home-act-emoji">🧾</span><span>拍小票</span></button>
      <button type="button" class="home-act-btn" id="obBackup"><span class="home-act-emoji">💾</span><span>导入备份</span></button>
    </div>
  `;
  // 引导页：手动入库仍跳转到库存页的完整表单；拍小票直接在首页弹出统一批量入库弹窗。
  section.querySelector('#obManual').onclick = () => { location.hash = '#shopping'; };
  section.querySelector('#obReceipt').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'receipt' });
  section.querySelector('#obBackup').onclick = () => { location.hash = '#settings'; };
  return section;
}

// ── 批量入库统一写入：所有模式（小票 / 文本）共用同一条数据落地路径 ──────────
function writeItemsToInventory(items, pack) {
  if (!Array.isArray(items) || !items.length) return 0;
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const today = todayISO();
  let count = 0;
  for (const it of items) {
    const name = getCanonicalName(it.name || it.item || '');
    if (!name) continue;
    const qty = Number(it.qty);
    const safeQty = Number.isFinite(qty) && qty > 0 ? qty : 1;
    const unit = (it.unit && String(it.unit).trim()) || guessKitchenUnit(name) || '份';
    const kind = isDryGoodName(name) ? 'dry' : 'raw';
    const shelf = kind === 'dry' ? 365 : guessShelfDays(name, unit);
    const entry = { name, qty: safeQty, unit, buyDate: today, kind, shelf, stockStatus: 'ok' };
    if (kind === 'dry') { entry.dryPrep = getDryPrepText(name); entry.isFrozen = false; }
    mergeInventoryEntry(inv, entry, { mode: 'add' });
    count++;
  }
  return count;
}

// 文本批量录入解析器：每行「名称 数量 单位」，单位可省略；兼容「西红柿 3个」「鸡蛋 6」等写法。
function parseTextBatchInput(text) {
  const lines = String(text || '').split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  const out = [];
  for (const line of lines) {
    let m = line.match(/^(.+?)\s+(\d+(?:\.\d+)?)\s*(\S+)?$/);                      // 「西红柿 3 个」/ 「鸡蛋 6」
    if (!m) m = line.match(/^([^\d\s]+?)(\d+(?:\.\d+)?)\s*(\S+)?$/);                // 「西红柿3个」（无空格）
    if (m) {
      out.push({ name: m[1].trim(), qty: Number(m[2]) || 1, unit: (m[3] || '').trim() });
    } else {
      out.push({ name: line, qty: 1, unit: '' });
    }
  }
  return out;
}

/**
 * 📦 批量入库统一弹窗：双 Tab 切换（📸 拍小票识别 / ✍️ 文本批量记），最终都走同一条写库逻辑。
 */
function openBatchInputModal(pack, { onRoute = () => {}, initialTab = 'receipt' } = {}) {
  // 内容只承载业务（双 Tab 切换 + 拍小票区 + 文本区 + 底部操作行），
  // 外壳（毛玻璃遮罩、圆角面板、右上角 X 关闭、入场动画）统一由 createHomeModal 提供。
  const body = document.createElement('div');
  body.className = 'km-modal-body batch-input-body';
  body.innerHTML = `
    <div class="batch-tab-switcher" role="tablist">
      <button type="button" class="batch-tab" data-tab="receipt" role="tab">📸 拍小票识别</button>
      <button type="button" class="batch-tab" data-tab="text" role="tab">✍️ 文本批量记</button>
    </div>

    <div class="batch-tab-panel" id="batch-panel-receipt" role="tabpanel">
      <label class="receipt-drop-zone" for="batchReceiptFile">
        <input type="file" id="batchReceiptFile" accept="image/*" capture="environment" class="visually-hidden">
        <span class="receipt-camera-icon" aria-hidden="true">📷</span>
        <strong>点此拍摄 / 选择小票</strong>
        <small>AI 自动识别食材并预览确认</small>
      </label>
      <div id="batchReceiptStatus" class="small inline-status" hidden></div>
    </div>

    <div class="batch-tab-panel is-hidden" id="batch-panel-text" role="tabpanel">
      <p class="meta">每行一项，格式 <code>食材名 数量 单位</code>，单位可省略。</p>
      <textarea id="batchTextInput" rows="6" class="batch-text-area" placeholder="西红柿 3 个&#10;牛肉 1 斤&#10;鸡蛋 6&#10;土豆 2"></textarea>
      <div id="batchTextStatus" class="small inline-status" hidden></div>
    </div>

    <div class="km-modal-actions">
      <button type="button" class="btn" id="batchCancel">取消</button>
      <button type="button" class="btn ok" id="batchConfirm">确认入库</button>
    </div>
  `;
  const { overlay, close } = createHomeModal(body, '📦 采购物品入库登记');

  let currentTab = (initialTab === 'text' ? 'text' : 'receipt');
  const setTab = (name) => {
    currentTab = name;
    overlay.querySelectorAll('.batch-tab').forEach(t => t.classList.toggle('is-active', t.dataset.tab === name));
    overlay.querySelectorAll('.batch-tab-panel').forEach(p => p.classList.toggle('is-hidden', p.id !== `batch-panel-${name}`));
    // 拍小票模式：主按钮文案改为「打开相机」式提示；文本模式：恢复「确认入库」。
    const confirmBtn = overlay.querySelector('#batchConfirm');
    confirmBtn.textContent = name === 'receipt' ? '选取小票图片' : '确认入库';
  };
  setTab(currentTab);
  overlay.querySelectorAll('.batch-tab').forEach(t => { t.onclick = () => setTab(t.dataset.tab); });

  overlay.querySelector('#batchCancel').onclick = close;

  // ── 模式 A：拍小票识别 ──
  const receiptFileInput = overlay.querySelector('#batchReceiptFile');
  const receiptStatus = overlay.querySelector('#batchReceiptStatus');
  receiptFileInput.onchange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    receiptStatus.hidden = false;
    receiptStatus.className = 'small inline-status info';
    receiptStatus.innerHTML = '<span class="spinner"></span> AI 识别中…';
    try {
      const items = await withTimeout(recognizeReceipt(file), 30000, 'AI 识别超时');
      if (!items || !items.length) {
        receiptStatus.className = 'small inline-status bad';
        receiptStatus.textContent = '没有识别到可入库食材';
        return;
      }
      // 借用既有的确认弹窗渲染可编辑预览列表，确认后再写库 → 统一走 writeItemsToInventory。
      close();
      showReceiptConfirmationModal(
        items.map(it => ({ name: it.name, qty: it.qty, unit: it.unit, originalName: it.originalName || it.name })),
        (confirmed) => {
          const n = writeItemsToInventory(confirmed, pack);
          if (n > 0) onRoute();
        },
        () => { /* 用户取消：不写库 */ }
      );
    } catch (err) {
      receiptStatus.className = 'small inline-status bad';
      receiptStatus.textContent = '❌ ' + formatAiErrorMessage(err);
    } finally {
      e.target.value = '';
    }
  };

  // ── 模式 B：文本批量记 ──
  overlay.querySelector('#batchConfirm').onclick = () => {
    if (currentTab === 'receipt') {
      receiptFileInput.click(); // 在拍小票 Tab 下，主按钮直接打开相机/相册选择
      return;
    }
    const text = overlay.querySelector('#batchTextInput').value;
    const parsed = parseTextBatchInput(text);
    const statusEl = overlay.querySelector('#batchTextStatus');
    if (!parsed.length) {
      statusEl.hidden = false;
      statusEl.className = 'small inline-status bad';
      statusEl.textContent = '没有解析出任何条目，请检查格式。';
      return;
    }
    const n = writeItemsToInventory(parsed, pack);
    if (n > 0) {
      statusEl.hidden = false;
      statusEl.className = 'small inline-status ok';
      statusEl.textContent = `✓ 已入库 ${n} 项`;
      setTimeout(() => { close(); onRoute(); }, 600);
    } else {
      statusEl.hidden = false;
      statusEl.className = 'small inline-status bad';
      statusEl.textContent = '入库失败：所有条目都无法识别为食材。';
    }
  };
}

// 把档位值写回食材并同步 stockStatus / qty / 断货时间戳（与库存编辑保持一致）。
function applyGearImpromptu(e, value) {
  e.gear = value;
  e.unitType = UNIT_TYPE.GEAR;
  if (value === 0) { e.stockStatus = 'empty'; e.qty = 0; }
  else if (value <= 25) { e.stockStatus = 'low'; if (!(+e.qty > 0)) e.qty = 1; }
  else { e.stockStatus = 'ok'; if (!(+e.qty > 0)) e.qty = 1; }
  syncOutOfStockTimestamp(e);
}

/**
 * 🍳 即兴烹饪：今日餐单标题行的快捷入口 + 就地展开的「冰箱物资微调盘点舱」。
 * 返回 { button, tray }，由调用方分别塞进头部动作组与头部下方。
 * 闭环：就地微调 inv → [✓ 记录完成] → 持久化冰箱 + 推虚拟 48h 卡 + 食材实体反疲劳计数 + 收起。
 */
// 🧪 万能加料白名单：只放行适合下面 / 煮螺蛳粉 / 麻辣烫等场景的快熟百搭配料。
const IMPROMPTU_ALLOWED_REGEX = /(菜|茼蒿|菠菜|韭菜|肠|午餐肉|培根|香肠|火腿|丸|棒|饺|千层肚|菇|豆腐|豆皮|腐竹|木耳|蛋|面条|粉|年糕|水饺)/;

// 即兴面板前置过滤器：有货（isInventoryAvailable）且命中百搭白名单，才进面板。
function isImpromptuCandidate(e) {
  return isInventoryAvailable(e) && IMPROMPTU_ALLOWED_REGEX.test(String(e.name || ''));
}

function buildImpromptuCooking(inv, { onRoute = () => {} } = {}) {
  let showImpromptuTray = false;
  const consumed = new Set(); // 本次会话被改动过的食材实体

  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'home-mini-btn impromptu-btn';
  button.textContent = '🍳 即兴烹饪';

  const tray = document.createElement('div');
  tray.className = 'km-inline-tray is-collapsed';

  const renderTrayBody = () => {
    tray.innerHTML = '';
    // 前置白名单过滤：只展示有货且属于百搭快熟配料的资产。
    const items = (inv || []).filter(isImpromptuCandidate);
    if (!items.length) {
      tray.innerHTML = '<div class="km-tray-empty">冰箱里暂无适合即兴下厨的快熟配料。</div>';
      return;
    }
    // 极其紧凑的 3~4 列高密度网格，界面极度压扁。
    const grid = document.createElement('div');
    grid.className = 'km-tray-grid';
    for (const e of items) {
      const unitType = e.unitType || getUnitType(e.name, e.unit);
      const cell = document.createElement('div');
      cell.className = 'km-tray-cell';
      cell.innerHTML = `<span class="km-tray-name">${escapeHtml(e.name)}</span>`;
      const ctrl = document.createElement('div');
      ctrl.className = 'km-tray-ctrl';
      if (unitType === UNIT_TYPE.GEAR) {
        const cur = gearInfo(getItemGear(e)).value;
        ctrl.innerHTML = `<div class="km-gear-dots" role="group" aria-label="档位">${
          [100, 75, 50, 25, 0].map(g => `<button type="button" class="km-gear-dot gear-${g}${g === cur ? ' is-active' : ''}" data-gear="${g}" title="${GEAR_LABELS[g]}" aria-label="${GEAR_LABELS[g]}"></button>`).join('')
        }</div>`;
        cell.appendChild(ctrl);
        const dots = ctrl.querySelectorAll('.km-gear-dot');
        dots.forEach(dot => {
          dot.onclick = () => {
            applyGearImpromptu(e, +dot.dataset.gear);
            consumed.add(e);
            dots.forEach(d => d.classList.toggle('is-active', d === dot));
          };
        });
      } else {
        const qty = +e.qty || 0;
        ctrl.innerHTML = `<div class="km-piece-step"><button type="button" class="km-step-minus" aria-label="减少">−</button><span class="km-piece-qty">${qty}</span><button type="button" class="km-step-plus" aria-label="增加">+</button></div>`;
        cell.appendChild(ctrl);
        const qtyEl = ctrl.querySelector('.km-piece-qty');
        const setQty = (next) => {
          e.qty = next;
          e.unitType = UNIT_TYPE.PIECE;
          e.stockStatus = next <= 0 ? 'empty' : 'ok';
          syncOutOfStockTimestamp(e);
          consumed.add(e);
          qtyEl.textContent = next;
        };
        ctrl.querySelector('.km-step-minus').onclick = () => setQty(Math.max(0, (+e.qty || 0) - 1));
        ctrl.querySelector('.km-step-plus').onclick = () => setQty((+e.qty || 0) + 1);
      }
      grid.appendChild(cell);
    }
    const footer = document.createElement('div');
    footer.className = 'km-tray-footer';
    const doneBtn = document.createElement('button');
    doneBtn.type = 'button';
    doneBtn.className = 'btn ok small km-tray-done';
    doneBtn.textContent = '✓ 记录完成';
    doneBtn.onclick = commit;
    footer.appendChild(doneBtn);
    tray.appendChild(grid);
    tray.appendChild(footer);
  };

  function commit() {
    // 3.3 刷新「食材实体」反疲劳权重：被消耗食材 cookedCount++ / lastCookedAt
    const now = Date.now();
    consumed.forEach(e => {
      e.cookedCount = (e.cookedCount || 0) + 1;
      e.lastCookedAt = now;
    });
    // 3.1 更新冰箱主库持久化
    saveInventory(inv);
    // 3.2 生成虚拟排程卡片（触发 48h 自动下线逻辑）
    const plans = S.load(S.keys.plan, []);
    plans.push({ id: 'adhoc_' + Date.now(), name: '[即兴配餐] (空心菜、火腿肠等)', isCooked: true, cookedAt: Date.now(), date: todayISO() });
    S.save(S.keys.plan, plans);
    // 3.4 关闭并刷新整页
    showImpromptuTray = false;
    onRoute();
  }

  button.onclick = () => {
    showImpromptuTray = !showImpromptuTray;
    button.classList.toggle('is-active', showImpromptuTray);
    if (showImpromptuTray) {
      renderTrayBody();
      tray.classList.remove('is-collapsed');
    } else {
      tray.classList.add('is-collapsed');
    }
  };

  return { button, tray };
}

// ══════════════════════════════════════════════════════════════════════════
//  「今日」决策页：用户打开即知「今晚吃什么 / 优先用掉什么 / 计划是什么 / 缺什么」。
//  全部复用既有数据逻辑（getTodayDecisionGroups / getInspirationCards /
//  getExpiringItems / renderSuggestCard / renderMenuPlan / openCleanFridgeHelper…），
//  本段只负责信息层级与 UI 组装，不重写推荐算法。
// ══════════════════════════════════════════════════════════════════════════

// ① 顶部双状态卡：到期食材 / 待购买（复用 .home-metrics 紧凑两栏；点击只弹窗、不跳转）。
//   返回 { el, refresh }：refresh 用于弹窗里增删后实时更新卡片数字。
function createStatusCards(inv, pack, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-metrics today-status';

  const render = () => {
    const expiringAll = (inv || []).filter(it => isExpiryTracked(it) && remainingDays(it) <= 3);
    const expCount = expiringAll.length;
    const expiredCount = expiringAll.filter(it => remainingDays(it) < 0).length;
    const shopCount = loadShoppingItems().filter(i => !i.done).length;
    const expTone = expCount === 0 ? 'is-ok' : (expiredCount > 0 ? 'is-bad' : 'is-warn');
    const expSub = expCount === 0 ? '暂无到期' : (expiredCount > 0 ? `${expiredCount} 样已过期` : '样快到期');
    const shopSub = shopCount === 0 ? '清单为空' : '项待买';

    section.innerHTML = `
      <button type="button" class="home-metric ${expTone}" id="statExpiring">
        <span class="home-metric-header"><span class="home-metric-icon">⏳</span><span class="home-metric-label">到期食材</span></span>
        <span class="home-metric-num">${expCount}</span>
        <span class="home-metric-sub">${escapeHtml(expSub)}</span>
      </button>
      <button type="button" class="home-metric is-info" id="statShopping">
        <span class="home-metric-header"><span class="home-metric-icon">🛒</span><span class="home-metric-label">待购买</span></span>
        <span class="home-metric-num">${shopCount}</span>
        <span class="home-metric-sub">${escapeHtml(shopSub)}</span>
      </button>
    `;
    section.querySelector('#statExpiring').onclick = () => openExpiryListModal(inv, pack, { onRoute, onChange: render });
    // 待购买卡：弹出「待购买食材」列表弹窗（查看当前清单待买项，可标记完成/删除），不跳转、不改 hash。
    section.querySelector('#statShopping').onclick = () => showPendingShoppingModal({ onChange: render });
  };
  render();
  return { el: section, refresh: render };
}

// AI 智能推荐（合并进今日主卡的下半部分）：默认收起。复用 getInspirationCards /
//   renderSuggestCard / callCloudAI，只把展示改成「紧凑折叠入口 + 摘要计数」，展开后逻辑不变。
function buildAiRecommendations(pack, inv, { onRoute = () => {} } = {}) {
  const wrap = document.createElement('div');
  wrap.className = 'today-ai';

  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'today-ai-toggle';
  toggle.id = 'aiToggle';
  toggle.setAttribute('aria-expanded', 'false');
  toggle.innerHTML = `
    <span class="today-ai-toggle-icon">✨</span>
    <span class="today-ai-toggle-text">
      <span class="today-ai-toggle-title">AI 智能推荐</span>
      <span class="today-ai-toggle-sub" id="aiSummary">根据库存生成晚餐灵感</span>
    </span>
    <span class="today-ai-toggle-arrow" aria-hidden="true">›</span>
  `;
  wrap.appendChild(toggle);

  const body = document.createElement('div');
  body.className = 'today-ai-body is-collapsed';
  body.setAttribute('aria-hidden', 'true');
  body.innerHTML = `
    <div class="today-ai-head">
      <button type="button" class="home-mini-btn today-ai-btn" id="todayAiBtn">✨ AI 换一批</button>
    </div>
    <div class="today-picks-grid" id="todayPicksGrid"></div>
    <p class="today-picks-note" id="todayPicksNote" hidden></p>
  `;
  wrap.appendChild(body);

  const grid = body.querySelector('#todayPicksGrid');
  const note = body.querySelector('#todayPicksNote');
  const aiBtn = body.querySelector('#todayAiBtn');
  const summary = toggle.querySelector('#aiSummary');
  const setSummary = (n) => { summary.textContent = n > 0 ? `有 ${n} 个推荐` : '根据库存生成晚餐灵感'; };

  const renderLocal = () => {
    const cards = getInspirationCards(pack, inv);
    grid.innerHTML = '';
    note.hidden = true;
    if (!cards.length) { grid.appendChild(buildPicksEmptyState()); setSummary(0); return; }
    cards.forEach(card => grid.appendChild(renderSuggestCard(card, pack, inv)));
    setSummary(cards.length);
  };

  const showAi = (aiCards) => {
    const list = (aiCards || []).slice(0, 3);
    grid.innerHTML = '';
    showRecommendationCards(grid, list, pack, { onRoute });
    note.hidden = false;
    note.innerHTML = 'AI 草稿推荐，确认后再安排。<button type="button" class="home-note-clear" id="todayAiClear">用本地推荐</button>';
    const clearBtn = note.querySelector('#todayAiClear');
    if (clearBtn) clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); renderLocal(); };
    setSummary(list.length);
  };

  // 初次：有保存的 AI 推荐则展示，否则本地推荐（都只是预渲染进折叠体，默认不展开）。
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  const savedCards = savedAiRecs ? processAiData(savedAiRecs, pack) : [];
  if (savedCards.length > 0) showAi(savedCards); else renderLocal();

  let expanded = false;
  toggle.onclick = () => {
    expanded = !expanded;
    body.classList.toggle('is-collapsed', !expanded);
    if (expanded) body.removeAttribute('aria-hidden'); else body.setAttribute('aria-hidden', 'true');
    toggle.classList.toggle('is-open', expanded);
    toggle.setAttribute('aria-expanded', String(expanded));
  };

  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;
    aiBtn.setAttribute('disabled', 'true');
    const original = aiBtn.textContent;
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中…';
    const safety = setTimeout(() => { aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled'); }, 30000);
    try {
      const aiResult = await callCloudAI(pack, inv);
      clearTimeout(safety);
      const cards = processAiData(aiResult, pack);
      if (cards.length > 0) { S.save(S.keys.ai_recs, aiResult); showAi(cards); }
    } catch (e) {
      clearTimeout(safety); // 静默失败：保留本地推荐
    } finally {
      aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled');
    }
  };

  return wrap;
}

// 无推荐时的可行动空状态。
function buildPicksEmptyState() {
  const box = document.createElement('div');
  box.className = 'today-empty';
  box.innerHTML = `
    <p class="today-empty-text">还没有匹配到现在能做的菜。补点常见食材，或去菜谱挑一道。</p>
    <div class="today-empty-actions">
      <button type="button" class="btn ok small" id="emptyAddStock">➕ 添加食材</button>
      <button type="button" class="btn small" id="emptyBrowse">📖 去菜谱</button>
    </div>`;
  box.querySelector('#emptyAddStock').onclick = () => { location.hash = '#inventory'; };
  box.querySelector('#emptyBrowse').onclick = () => { location.hash = '#recipes'; };
  return box;
}

// ② 今日主卡：把「今日计划」（上，默认展开）与「AI 智能推荐」（下，默认收起）合并进同一大卡片。
function renderMainCard(pack, inv, { onRoute = () => {} } = {}) {
  const card = document.createElement('section');
  card.className = 'today-main-card';

  // 头部：今日计划标题 + 动作组（🍳即兴 / ✓全部做完 / 范围筛选）
  const head = document.createElement('div');
  head.className = 'today-section-head today-main-head';
  head.innerHTML = '<h2 class="today-section-title">📅 今日计划</h2>';
  const actions = document.createElement('div');
  actions.className = 'menu-plan-head-actions';
  const impromptu = buildImpromptuCooking(inv, { onRoute });
  actions.appendChild(impromptu.button);
  actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
  actions.appendChild(renderPlanRangeSelect({ onRoute, id: 'homePlanRangeSelect' }));
  head.appendChild(actions);
  card.appendChild(head);
  card.appendChild(impromptu.tray); // 即兴托盘紧随头部，点按钮就地展开

  // 上半部分：今日计划（复用 renderMenuPlan，保留进详情 / 做完 / 扣库存）
  const planNode = renderMenuPlan(pack, { onRoute, hideHeader: true, inventory: inv });
  card.appendChild(planNode);
  // 计划空状态由 renderMenuPlan 自带「该时间段暂未添加菜谱」轻提示承载，此处不再额外加说明文案。

  // 分隔线
  const divider = document.createElement('div');
  divider.className = 'today-main-divider';
  card.appendChild(divider);

  // 下半部分：AI 智能推荐（默认收起，折叠入口在同一大卡片内）
  card.appendChild(buildAiRecommendations(pack, inv, { onRoute }));

  return card;
}

// ③ 快捷操作区（两个轻量入口）：食材入库（直接打开采购物品入库登记弹窗）+ 待买速记（速记弹窗）。
function renderQuickActions(pack, inv, { onRoute = () => {}, refreshStatus = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'today-section today-quick';
  section.innerHTML = `
    <div class="today-quick-row">
      <button type="button" class="today-quick-btn is-primary" id="qaStock"><span class="tq-emoji">📦</span><span>食材入库</span></button>
      <button type="button" class="today-quick-btn" id="qaMemo"><span class="tq-emoji">📝</span><span>待买速记</span></button>
    </div>
  `;
  // 食材入库：直接打开现有「采购物品入库登记」弹窗（📸 拍小票识别 + ✍️ 文本批量记），不再多一层选择。
  section.querySelector('#qaStock').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'receipt' });
  // 待买速记：弹「批量文本」速记弹窗（一行一项，不展示完整清单，不跳转）；添加后刷新顶部待购买数字。
  section.querySelector('#qaMemo').onclick = () => showQuickShoppingNoteModal({ onAdd: refreshStatus });
  return section;
}

// ══════════════════════════════════════════════════════════════════════════
//  Weather-style 首页：顶部固定主状态 + 单一 glass 信息面板（tab 切换数据维度）。
//  类比 iOS 天气：顶部城市/温度区固定不动，下方同一块面板用小图标切换不同数据。
//  全部复用既有数据与弹窗函数，不新增推荐算法 / 持久化状态 / localStorage key。
// ══════════════════════════════════════════════════════════════════════════

// 今日计划项数（只读 plan key，按 date===今天计数，不改任何计划逻辑）。
function getTodayPlanCount() {
  const today = todayISO();
  return S.load(S.keys.plan, []).filter(p => p && p.date === today).length;
}

function getExpiringItemCount(inv) {
  return (inv || []).filter(it => isExpiryTracked(it) && remainingDays(it) <= 3).length;
}

function getTodaySummaryStats(pack, inv) {
  return {
    planCount: getTodayPlanCount(),
    expiringCount: getExpiringItemCount(inv),
    shoppingCount: loadShoppingItems().filter(item => item && !item.done).length,
    recommendationCount: getInspirationCards(pack, inv).length
  };
}

// 顶部固定主状态区：问候 + 决策主文案 + 一行副文案。
// 不是卡片：直接铺在页面背景上；下方面板 tab 切换不影响这里。
function renderWxStatus({ planCount, expiringCount, shoppingCount, recommendationCount }) {
  const section = document.createElement('section');
  section.className = 'wx-status';
  const greeting = buildGreeting(expiringCount).split('！')[0]; // 「🌆 晚上好」——复用现有问候逻辑
  const title = planCount > 0 ? `今天计划了 ${planCount} 道菜` : '今天还没决定吃什么';
  const stats = [
    ['plan', '计划', planCount],
    ['expiry', '临期', expiringCount],
    ['shopping', '待买', shoppingCount],
    ['recs', '推荐', recommendationCount]
  ];
  section.innerHTML = `
    <p class="wx-greeting">${escapeHtml(greeting)}</p>
    <h2 class="wx-title">${escapeHtml(title)}</h2>
    <div class="wx-summary-stats" aria-label="今日厨房状态">
      ${stats.map(([tone, label, value]) => `
        <span class="wx-stat-pill is-${tone}">
          <span>${escapeHtml(label)}</span><b>${escapeHtml(String(value || 0))}</b>
        </span>
      `).join('')}
    </div>
  `;
  return section;
}

// 当前 tab 的页内记忆（仅内存，不持久化）：范围筛选等触发整页重渲染时不丢所在 tab。
let lastWxTab = null;

// 单一主信息面板：顶部 segmented tabs（📅计划 / ⏳到期 / 🛒待买 / ✨推荐），
// 下方同一块 .wx-body 区域按 tab 重渲染内容——巧妙复用同一块屏幕空间。
function createWeatherPanel(pack, inv, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'wx-panel glass-panel';
  section.innerHTML = `
    <div class="wx-tabs" role="tablist">
      <button type="button" class="wx-tab" data-tab="plan" role="tab">📅 计划</button>
      <button type="button" class="wx-tab" data-tab="expiry" role="tab">⏳ 到期</button>
      <button type="button" class="wx-tab" data-tab="shopping" role="tab">🛒 待买</button>
      <button type="button" class="wx-tab" data-tab="recs" role="tab">✨ 推荐</button>
    </div>
    <div class="wx-body" role="tabpanel"></div>
  `;
  const body = section.querySelector('.wx-body');

  // 推荐 tab 状态（仅内存）：local=本地灵感卡 / ai=云端草稿；idx=「换一道」游标。
  let recsState = null;
  const initRecsState = () => {
    const savedAi = S.load(S.keys.ai_recs, null);
    const aiCards = savedAi ? processAiData(savedAi, pack) : [];
    if (aiCards.length) return { mode: 'ai', cards: aiCards, idx: 0 };
    return { mode: 'local', cards: getInspirationCards(pack, inv), idx: 0 };
  };
  const stepRecommendation = (delta = 1) => {
    if (!recsState || !recsState.cards || recsState.cards.length <= 1) return;
    const total = recsState.cards.length;
    recsState.idx = (recsState.idx + delta + total) % total;
    switchTab('recs');
  };
  const isCardControlTarget = (target) => Boolean(target && target.closest('button, a, input, select, textarea, [data-no-card-swipe], .home-suggest-name'));
  const bindRecommendationCycling = (cardWrap) => {
    if (!recsState || !recsState.cards || recsState.cards.length <= 1) return;
    let touchStart = null;
    let lastSwipeAt = 0;
    cardWrap.classList.add('is-cyclable');
    cardWrap.setAttribute('role', 'button');
    cardWrap.setAttribute('tabindex', '0');
    cardWrap.setAttribute('aria-label', '轻点或左右滑动切换下一道推荐');
    cardWrap.onclick = (event) => {
      if (Date.now() - lastSwipeAt < 350 || isCardControlTarget(event.target)) return;
      stepRecommendation(1);
    };
    cardWrap.onkeydown = (event) => {
      if (event.target !== cardWrap || !['Enter', ' '].includes(event.key)) return;
      event.preventDefault();
      stepRecommendation(1);
    };
    cardWrap.onpointerdown = (event) => {
      if (isCardControlTarget(event.target)) return;
      touchStart = { x: event.clientX, y: event.clientY };
    };
    cardWrap.onpointerup = (event) => {
      if (!touchStart || isCardControlTarget(event.target)) return;
      const dx = event.clientX - touchStart.x;
      const dy = event.clientY - touchStart.y;
      touchStart = null;
      if (Math.abs(dx) < 48 || Math.abs(dx) < Math.abs(dy) * 1.35 || Math.abs(dy) > 48) return;
      lastSwipeAt = Date.now();
      stepRecommendation(dx < 0 ? 1 : -1);
    };
    cardWrap.onpointercancel = () => { touchStart = null; };
  };

  // ── 📅 计划：动作组（即兴/全部做完/范围）+ 即兴托盘 + 计划列表，全部复用现有组件 ──
  const renderPlanTab = () => {
    const actions = document.createElement('div');
    actions.className = 'menu-plan-head-actions wx-plan-actions';
    const impromptu = buildImpromptuCooking(inv, { onRoute });
    actions.appendChild(impromptu.button);
    actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
    actions.appendChild(renderPlanRangeSelect({ onRoute, id: 'homePlanRangeSelect' }));
    body.appendChild(actions);
    body.appendChild(impromptu.tray);

    const planNode = renderMenuPlan(pack, { onRoute, hideHeader: true, inventory: inv });
    // 空态瘦身：一行轻提示 + 「看推荐」切 tab（原空态是纯静态节点、无事件绑定，见 menu-plan.js）。
    const empty = planNode.querySelector('.menu-plan-empty');
    if (empty) {
      empty.innerHTML = `
        <span class="plan-empty-line">还没有加入今日计划，可以从推荐里挑一道</span>
        <button type="button" class="wx-mini-btn" id="wxGoRecs">✨ 看推荐</button>
      `;
      empty.querySelector('#wxGoRecs').onclick = () => switchTab('recs');
    }
    body.appendChild(planNode);
  };

  // ── ⏳ 到期：最多 3 行（名称+剩余天数），「查看全部」沿用原到期弹窗 ──
  const renderExpiryTab = () => {
    const items = getExpiringItems(inv).slice(0, 3);
    if (!items.length) {
      body.innerHTML = '<div class="wx-empty">✅ 最近没有快到期的食材</div>';
      return;
    }
    const list = document.createElement('div');
    list.className = 'wx-list';
    list.innerHTML = items.map(it => {
      const d = remainingDays(it);
      const dayText = d < 0 ? `已过期 ${Math.abs(d)} 天` : d === 0 ? '今天到期' : `还剩 ${d} 天`;
      const tone = d < 0 ? ' is-bad' : d <= 1 ? ' is-warn' : '';
      const qty = (+it.qty > 0) ? `<span class="wx-row-qty">${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}</span>` : '';
      return `<div class="wx-row${tone}"><span class="wx-row-main">${escapeHtml(it.name)}${qty}</span><span class="wx-row-side">${escapeHtml(dayText)}</span></div>`;
    }).join('');
    body.appendChild(list);
    const foot = document.createElement('div');
    foot.className = 'wx-actions';
    foot.innerHTML = '<button type="button" class="wx-mini-btn">查看全部 ›</button>';
    foot.querySelector('button').onclick = () => openExpiryListModal(inv, pack, { onRoute, onChange: () => switchTab('expiry') });
    body.appendChild(foot);
  };

  // ── 🛒 待买：最近 3 项（名称+数量），「查看全部」沿用原待买弹窗 ──
  const renderShoppingTab = () => {
    const items = loadShoppingItems().filter(i => !i.done);
    if (!items.length) {
      body.innerHTML = '<div class="wx-empty">🧺 购物清单是空的</div>';
      return;
    }
    const recent = items.slice(-3).reverse();
    const list = document.createElement('div');
    list.className = 'wx-list';
    list.innerHTML = recent.map(it => {
      const qty = it.qty ? `<span class="wx-row-qty">${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}</span>` : '';
      const src = it.source ? `<span class="wx-row-side">${escapeHtml(it.source)}</span>` : '';
      return `<div class="wx-row"><span class="wx-row-main">${escapeHtml(it.name)}${qty}</span>${src}</div>`;
    }).join('');
    body.appendChild(list);
    const foot = document.createElement('div');
    foot.className = 'wx-actions';
    foot.innerHTML = `<span class="wx-count-note">共 ${items.length} 项待买</span><button type="button" class="wx-mini-btn">查看全部 ›</button>`;
    foot.querySelector('button').onclick = () => showPendingShoppingModal({ onChange: () => switchTab('shopping') });
    body.appendChild(foot);
  };

  // ── ✨ 推荐：一次只展示 1 个主推荐（不摊开三张卡）。
  //    「换一道」在已有推荐里轮换；「AI 换一批」沿用原 callCloudAI → processAiData 流程。──
  const renderRecsTab = () => {
    if (!recsState) recsState = initRecsState();
    const { mode, cards, idx } = recsState;

    const cardWrap = document.createElement('div');
    cardWrap.className = 'wx-rec-card';
    if (!cards.length) {
      cardWrap.innerHTML = '<div class="wx-empty">还没有匹配到现在能做的菜<br>库存多录几样，这里就会出现推荐</div>';
    } else if (mode === 'ai') {
      showRecommendationCards(cardWrap, [cards[idx]], pack, { onRoute });
    } else {
      cardWrap.appendChild(renderSuggestCard(cards[idx], pack, inv));
    }
    bindRecommendationCycling(cardWrap);
    body.appendChild(cardWrap);

    if (cards.length > 1) {
      const hint = document.createElement('div');
      hint.className = 'wx-rec-hint';
      hint.innerHTML = `
        <span>轻点 / 左右滑动换一道</span>
        <span class="wx-rec-dots" aria-hidden="true">
          ${cards.map((_, i) => `<span class="${i === idx ? 'is-active' : ''}"></span>`).join('')}
        </span>
      `;
      body.appendChild(hint);
    }

    if (mode === 'ai' && cards.length) {
      const note = document.createElement('p');
      note.className = 'wx-rec-note';
      note.textContent = 'AI 草稿推荐，确认后再安排。';
      body.appendChild(note);
    }

    const aiStatus = document.createElement('div');
    aiStatus.className = 'small inline-status wx-ai-status';
    aiStatus.hidden = true;
    body.appendChild(aiStatus);

    const foot = document.createElement('div');
    foot.className = 'wx-actions';
    foot.innerHTML = `
      ${mode === 'ai' && cards.length ? '<button type="button" class="wx-mini-btn" id="wxRecLocal">用本地推荐</button>' : ''}
      ${cards.length > 1 ? '<button type="button" class="wx-mini-btn" id="wxRecNext">换一道 ›</button>' : ''}
      <button type="button" class="wx-mini-btn is-ai" id="wxRecAi">✨ AI 换一批</button>
    `;
    body.appendChild(foot);

    const nextBtn = foot.querySelector('#wxRecNext');
    if (nextBtn) nextBtn.onclick = () => stepRecommendation(1);
    const localBtn = foot.querySelector('#wxRecLocal');
    if (localBtn) localBtn.onclick = () => {
      localStorage.removeItem(S.keys.ai_recs);
      recsState = { mode: 'local', cards: getInspirationCards(pack, inv), idx: 0 };
      switchTab('recs');
    };
    foot.querySelector('#wxRecAi').onclick = async (e) => {
      const aiBtn = e.currentTarget;
      if (aiBtn.getAttribute('disabled')) return;
      aiBtn.setAttribute('disabled', 'true');
      const original = aiBtn.textContent;
      aiBtn.innerHTML = '<span class="spinner"></span> 思考中…';
      const safety = setTimeout(() => { aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled'); }, 30000);
      try {
        const aiResult = await callCloudAI(pack, inv);
        clearTimeout(safety);
        const aiCards = processAiData(aiResult, pack);
        if (aiCards.length > 0) {
          S.save(S.keys.ai_recs, aiResult);
          recsState = { mode: 'ai', cards: aiCards, idx: 0 };
          switchTab('recs');
          return;
        }
        setInlineStatus(aiStatus, 'AI 没有返回可用菜谱，已保留本地推荐。', 'info');
      } catch (err) {
        clearTimeout(safety);
        setInlineStatus(aiStatus, formatAiErrorMessage(err), 'bad');
      } finally {
        aiBtn.innerHTML = original; aiBtn.removeAttribute('disabled');
      }
    };
  };

  const TAB_RENDERERS = { plan: renderPlanTab, expiry: renderExpiryTab, shopping: renderShoppingTab, recs: renderRecsTab };
  const switchTab = (name) => {
    const tab = TAB_RENDERERS[name] ? name : 'plan';
    lastWxTab = tab;
    section.querySelectorAll('.wx-tab').forEach(t => {
      const active = t.dataset.tab === tab;
      t.classList.toggle('is-active', active);
      t.setAttribute('aria-selected', String(active));
    });
    body.innerHTML = '';
    TAB_RENDERERS[tab]();
  };
  section.querySelectorAll('.wx-tab').forEach(t => { t.onclick = () => switchTab(t.dataset.tab); });

  // 默认 tab：有今日计划→计划；无计划但有推荐→推荐；否则计划。重渲染时记住上次所在 tab。
  const defaultTab = getTodayPlanCount() > 0 ? 'plan' : (getInspirationCards(pack, inv).length > 0 ? 'recs' : 'plan');
  switchTab(lastWxTab || defaultTab);

  return { el: section, refresh: () => switchTab(lastWxTab || defaultTab) };
}

export function renderHome(pack, { onRoute = () => {} } = {}) {
  const container = document.createElement('div');
  container.className = 'today-view';
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);

  // 空库存 → 友好的可行动空状态（引导录入）。
  if (!hasUsableInventory(inv)) {
    container.appendChild(renderOnboarding(pack, { onRoute }));
    return container;
  }

  // Weather-style 层级：① 顶部固定主状态（不随 tab 变）
  //                    ② 单一 glass 主面板（计划/到期/待买/推荐 tab 切换）
  //                    ③ 两个轻量胶囊快捷入口。
  const summaryStats = getTodaySummaryStats(pack, inv);
  container.appendChild(renderWxStatus(summaryStats));
  const panel = createWeatherPanel(pack, inv, { onRoute });
  container.appendChild(panel.el);
  container.appendChild(renderQuickActions(pack, inv, { onRoute, refreshStatus: panel.refresh }));

  return container;
}
