import { S, todayISO } from '../storage.js?v=181';
import { buildCatalog, getCanonicalName, buildIngredientOptions, getDryPrepText, guessKitchenUnit, guessShelfDays, isDryGoodName } from '../ingredients.js?v=181';
import { isInventoryAvailable, loadInventory, mergeInventoryEntry, remainingDays } from '../inventory.js?v=181';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=181';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  hasRecipeMethod, rankRecipesForRecommendation,
  getCleanFridgeRecommendations, processAiData
} from '../recommendations.js?v=181';
import { callCloudAI, formatAiErrorMessage, recognizeReceipt, withTimeout } from '../ai.js?v=181';
import { escapeHtml, escapeOptionAttr, brieflyConfirmButton, setInlineStatus } from '../components/status.js?v=181';
import { showRecommendationCards } from '../components/recipe-card.js?v=181';
import { showCleanFridgeModal, showReceiptConfirmationModal } from '../components/modal.js?v=181';
import { renderMenuPlan } from '../components/menu-plan.js?v=181';

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
 *  │  [眉标 + AI 换一批按钮]                     │ ← home-hero-head（仅眉标行）
 *  │  ─── 分隔线 ─────────────────────────────  │
 *  │  📋 菜单计划 (extraNode)                    │ ← 置顶
 *  │  ─── 分隔线 ─────────────────────────────  │
 *  │  🧠 今日灵感 问候语                          │ ← 移至底部
 *  │  [横向滑动推荐卡片流]                        │
 *  │  [注释文字]                                  │
 *  └───────────────────────────────────────────┘
 */
function renderInspirationPanel(pack, inv, expiringCount, { onRoute = () => {}, extraNode = null } = {}) {
  const section = document.createElement('section');
  section.className = `home-hero${extraNode ? ' is-combo' : ''}`;

  const eyebrow = extraNode ? '📅 今日饮食与灵感' : '🧠 今日灵感';

  // 眉标行（仅眉标文字，不再放「换一批」按钮——已移入折叠面板内部）
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

  if (extraNode) {
    // ── 菜单计划区（置顶） ──
    // ⚠️ 不再添加 home-combo-plan-label：menu-plan.js 已自带「📅 菜单计划」h3 标题
    const topDivider = document.createElement('div');
    topDivider.className = 'home-combo-divider';
    topDivider.setAttribute('aria-hidden', 'true');
    section.appendChild(topDivider);

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

  const close = () => {
    overlay.classList.add('closing');
    overlay.addEventListener('transitionend', () => overlay.remove(), { once: true });
    setTimeout(() => overlay.remove(), 250);
  };

  header.querySelector('.km-modal-close').onclick = close;
  overlay.onclick = (e) => { if (e.target === overlay) close(); };

  document.body.appendChild(overlay);
  // 触发入场动画
  requestAnimationFrame(() => overlay.classList.add('open'));

  return { overlay, close };
}

// ── 弹窗内容构建 ─────────────────────────────────────────────────────────────

/** 「48 小时内到期」弹窗 */
function buildExpiryModal(inv) {
  const expiring = (inv || [])
    .filter(it => isExpiryTracked(it) && remainingDays(it) <= 2)
    .sort((a, b) => remainingDays(a) - remainingDays(b));

  const wrap = document.createElement('div');
  wrap.className = 'km-modal-body';

  if (!expiring.length) {
    wrap.innerHTML = '<p class="km-modal-empty">✅ 48 小时内没有即将到期的食材。</p>';
    return wrap;
  }

  const list = document.createElement('ul');
  list.className = 'km-expiry-list';
  expiring.forEach(it => {
    const d = remainingDays(it);
    const li = document.createElement('li');
    li.className = `km-expiry-item${d <= 0 ? ' is-expired' : d <= 1 ? ' is-urgent' : ''}`;
    const dayText = d < 0 ? `已过期 ${Math.abs(d)} 天` : d === 0 ? '今天到期' : `还剩 ${d} 天`;
    li.innerHTML = `
      <span class="km-expiry-name">${escapeHtml(it.name)}</span>
      <span class="km-expiry-days">${dayText}</span>
    `;
    list.appendChild(li);
  });
  wrap.appendChild(list);

  const hint = document.createElement('p');
  hint.className = 'km-modal-hint';
  hint.textContent = '建议优先安排到菜单计划中，避免浪费。';
  wrap.appendChild(hint);

  return wrap;
}

/** 「购物清单待买」弹窗 */
function buildShoppingModal(onClose) {
  const wrap = document.createElement('div');
  wrap.className = 'km-modal-body';

  const items = loadShoppingItems().filter(i => !i.done);

  // 快速添加行
  const addRow = document.createElement('div');
  addRow.className = 'km-modal-add-row';
  addRow.innerHTML = `
    <input class="km-modal-input" id="shoppingModalInput" placeholder="快速记录，回车加入…">
    <button type="button" class="btn ok small" id="shoppingModalAdd">加入</button>
  `;
  wrap.appendChild(addRow);

  const listEl = document.createElement('ul');
  listEl.className = 'km-shopping-list';
  wrap.appendChild(listEl);

  const renderList = () => {
    const current = loadShoppingItems().filter(i => !i.done);
    listEl.innerHTML = '';
    if (!current.length) {
      listEl.innerHTML = '<li class="km-modal-empty">购物清单为空 🎉</li>';
      return;
    }
    current.slice(0, 12).forEach(it => {
      const li = document.createElement('li');
      li.className = 'km-shopping-item';
      const qty = it.qty ? ` · ${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}` : '';
      li.innerHTML = `<span>${escapeHtml(it.name)}${qty}</span><small>${escapeHtml(it.source || '')}</small>`;
      listEl.appendChild(li);
    });
    if (current.length > 12) {
      const more = document.createElement('li');
      more.className = 'km-modal-empty';
      more.textContent = `还有 ${current.length - 12} 项，前往购物清单查看全部`;
      listEl.appendChild(more);
    }
  };
  renderList();

  const input = addRow.querySelector('#shoppingModalInput');
  const addBtn = addRow.querySelector('#shoppingModalAdd');
  const doAdd = () => {
    const name = input.value.trim();
    if (!name) return;
    addShoppingItem(name, '', '', '速记');
    input.value = '';
    input.focus();
    renderList();
    // 更新首页 metric 数字
    const numEl = document.querySelector('#metricShopping .home-metric-num');
    if (numEl) numEl.textContent = String(loadShoppingItems().filter(i => !i.done).length);
  };
  input.onkeydown = (e) => { if (e.key === 'Enter') doAdd(); };
  addBtn.onclick = doAdd;

  // 跳转按钮组
  const footer = document.createElement('div');
  footer.className = 'km-modal-actions';
  footer.innerHTML = `<button type="button" class="btn ok" id="gotoShoppingBtn">前往购物清单 →</button>`;
  footer.querySelector('#gotoShoppingBtn').onclick = () => { onClose(); location.hash = '#shopping'; };
  wrap.appendChild(footer);

  return wrap;
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
function renderUrgentMetrics(inv, activeShoppingCount) {
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
        <span class="home-metric-label">48小时内到期</span>
      </span>
      <span class="home-metric-num">${expiring48.length}</span>
      <span class="home-metric-sub">种食材</span>
    </button>
    <button type="button" class="home-metric is-info" id="metricShopping">
      <span class="home-metric-header">
        <span class="home-metric-icon">🛒</span>
        <span class="home-metric-label">购物清单待买</span>
      </span>
      <span class="home-metric-num">${activeShoppingCount}</span>
      <span class="home-metric-sub">项未完成</span>
    </button>
  `;

  // ── 原地弹窗（不再硬跳转到 #shopping 页面）──
  section.querySelector('#metricExpiring').onclick = () => {
    const { overlay, close } = createHomeModal(buildExpiryModal(inv), '🚨 48 小时内到期食材');
    setTimeout(() => overlay.querySelector('#memoModalInput, input')?.focus?.(), 80);
  };
  section.querySelector('#metricShopping').onclick = () => {
    const { overlay, close } = createHomeModal(buildShoppingModal(() => close()), '🛒 购物清单待买');
    setTimeout(() => overlay.querySelector('#shoppingModalInput')?.focus?.(), 80);
  };

  return section;
}

// ── Section 3: 极速操作组（批量入库 / 随手记 / 微型清冰箱） ──────────────────
function renderActionHub(pack, inv, { onQuickInput = () => {}, onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-actions-hub';
  section.innerHTML = `
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="actQuickInput"><span class="home-act-emoji">📦</span><span>批量入库</span></button>
      <button type="button" class="home-act-btn" id="actQuickMemo"><span class="home-act-emoji">📝</span><span>随手记</span></button>
    </div>
    <div class="home-hub-extra">
      <button type="button" class="home-mini-btn" id="actCleanFridge" title="帮我清冰箱">🔁 帮我清冰箱</button>
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
    const { overlay, close } = createHomeModal(buildMemoModal(() => close()), '📝 随手记');
    setTimeout(() => {
      overlay.querySelector('#memoModalInput')?.focus?.();
      renderActivity(); // 关闭后刷新动态列
    }, 80);
  };

  // 微型「清冰箱」按钮：保留原有弹窗推荐逻辑，仅缩小为快捷入口。
  section.querySelector('#actCleanFridge').onclick = () => {
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
  const { overlay, close } = createHomeModal(body, '📦 批量入库');

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

export function renderHome(pack, { onRoute = () => {} } = {}) {
  const container = document.createElement('div');
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const expiringSoonCount = (inv || []).filter(it => isExpiryTracked(it) && remainingDays(it) <= 3).length;
  const activeShopping = loadShoppingItems().filter(item => !item.done);

  const title = document.createElement('div'); title.className = 'main-title-center'; title.innerHTML = '<span>厨房</span>';
  container.appendChild(title);

  // 空库存 → 引导到「清单」页录入
  if (!hasUsableInventory(inv)) {
    container.appendChild(renderOnboarding(pack, { onRoute }));
    return container;
  }

  // 自上而下视觉层级：① 紧急指标 ②「📅 今日饮食与灵感」合并卡（菜单计划置顶 + AI 灵感居底） ③ 极速操作
  container.appendChild(renderUrgentMetrics(inv, activeShopping.length));
  const menuPlanNode = renderMenuPlan(pack, { onRoute });
  container.appendChild(renderInspirationPanel(pack, inv, expiringSoonCount, { onRoute, extraNode: menuPlanNode }));
  container.appendChild(renderActionHub(pack, inv, {
    // 「📦 批量入库」打开统一弹窗（📸 拍小票识别 + ✍️ 文本批量记），不再跳走。
    onQuickInput: () => openBatchInputModal(pack, { onRoute, initialTab: 'receipt' }),
    onRoute
  }));

  return container;
}
