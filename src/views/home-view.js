import { S, todayISO } from '../storage.js?v=219';
import { buildCatalog, getCanonicalName, buildIngredientOptions, getDryPrepText, guessKitchenUnit, guessShelfDays, isDryGoodName, UNIT_TYPE, explodeCombinedItems } from '../ingredients.js?v=219';
import { applyCookCalibration, computeCookDeductions, isInventoryAvailable, loadInventory, mergeInventoryEntry, remainingDays, gearInfo, GEAR_LABELS } from '../inventory.js?v=219';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=219';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  findRecipesByName, findRecipesUsingIngredients, hasRecipeMethod, rankRecipesForRecommendation,
  getCleanFridgeRecommendations, markRecipeCookedKeepPlan, processAiData
} from '../recommendations.js?v=219';
import { callAiCreativeRecipeByIngredients, callAiForCookedMeal, callAiSearchRecipe, callCloudAI, formatAiErrorMessage, getCreativeDishModeLabel, pickNextCreativeDishMode, recognizeReceipt, withTimeout } from '../ai.js?v=219';
import { escapeHtml, escapeOptionAttr, brieflyConfirmButton, setInlineStatus, showToast } from '../components/status.js?v=219';
import { renderAiRecipeDraftCard, showRecommendationCards } from '../components/recipe-card.js?v=219';
import { parseTargetIngredients } from '../utils/ingredient-intent.js?v=219';
import { perfMeasure } from '../utils/perf.js?v=219';
import { showCleanFridgeModal, showReceiptConfirmationModal, showQuickShoppingModal, showQuickShoppingNoteModal, showPendingShoppingModal } from '../components/modal.js?v=219';
import { renderMenuPlan, renderPlanRangeSelect, renderCookAllButton } from '../components/menu-plan.js?v=219';
import { parseFoodLines } from '../utils/food-input-parser.js?v=219';
import { splitRecipeIngredients } from '../utils/recipe-sanitizer.js?v=219';
import { splitMethodSteps } from '../utils/method-steps.js?v=219';
import { applyReceiptPantryItems } from '../utils/receipt-import.js?v=219';
import { openRecipeImportModal } from '../components/recipe-import-modal.js?v=219';
import { getCookShoppingCandidates, showCookCompleteFeedback } from '../components/cook-feedback.js?v=219';
import {
  buildLocalCookedMealCandidates,
  getRecipeCoreItems,
  matchCookedMealRecipe,
  mergeCookedMealCandidates,
  normalizeAiCookedMealResult
} from '../utils/cooked-meal.js?v=219';

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
    { id: null, name: '番茄炒蛋', matchLabel: '食材已齐', missing: [], reason: '鸡蛋和番茄都在，十分钟上桌', tone: 'ready' },
    { id: null, name: '青椒肉丝', matchLabel: '只差 1 样', missing: ['青椒'], reason: '补个青椒就能下锅', tone: 'almost' },
    { id: null, name: '麻婆豆腐', matchLabel: '灵感菜', missing: [], reason: '今天想吃点麻辣的？', tone: 'idea' }
  ]
};

function buildGreeting(expiringCount) {
  const h = new Date().getHours();
  const part = h < 5 ? '夜深了' : h < 11 ? '早上好' : h < 14 ? '中午好' : h < 18 ? '下午好' : '晚上好';
  const emoji = h < 5 ? '🌙' : h < 18 ? '👋' : '🌆';
  if (expiringCount > 0) {
    return `${emoji} ${part}！有 ${expiringCount} 样食材快到期了，今天可以这样做：`;
  }
  return `${emoji} ${part}！根据你现在的食材，今天推荐这几道：`;
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
        if (count) showToast('已加入买菜清单', { tone: 'success' });
        brieflyConfirmButton(btn, count ? '已加入买菜' : '已齐');
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
      else if (tone === 'ready') matchLabel = '食材已齐';
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
function renderSuggestCard(card, pack, inv, { onPreviewRecipe = null } = {}) {
  const el = document.createElement('article');
  el.className = `home-suggest-card tone-${card.tone || 'idea'}`;
  const previewRecipe = card.row?.r || card.r || card.recipe || null;
  const canPreview = Boolean(card.id && previewRecipe && typeof onPreviewRecipe === 'function' && !String(card.id).startsWith('creative-'));
  const missingTag = (card.missing && card.missing.length)
    ? `<span class="home-suggest-missing">缺 ${escapeHtml(card.missing.join('、'))}</span>`
    : '';
  el.innerHTML = `
    <span class="home-suggest-match">${escapeHtml(card.matchLabel || '')}</span>
    <h3 class="home-suggest-name">${escapeHtml(card.name)}</h3>
    <p class="home-suggest-reason">${escapeHtml(card.reason || '')}</p>
    ${missingTag}
    <div class="home-suggest-actions">
      ${canPreview ? '<button type="button" class="btn small home-suggest-preview">查看做法</button>' : ''}
      <button type="button" class="btn ok small home-suggest-cook">${card.tone === 'almost' ? '加入买菜' : '做这道'}</button>
    </div>
    <div class="home-suggest-feedback" hidden></div>
  `;
  const cookBtn = el.querySelector('.home-suggest-cook');
  const previewBtn = el.querySelector('.home-suggest-preview');
  const feedback = el.querySelector('.home-suggest-feedback');
  const openPreview = (event) => {
    event?.preventDefault();
    event?.stopPropagation();
    if (canPreview) onPreviewRecipe(previewRecipe);
  };
  const showPlanFeedback = (text) => {
    feedback.hidden = false;
    feedback.innerHTML = `<span>${escapeHtml(text)}</span><button type="button" class="home-suggest-go-plan">去今日看看</button>`;
    feedback.querySelector('.home-suggest-go-plan').onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      lastWxTab = 'plan';
      const planTab = document.querySelector('.wx-tab[data-tab="plan"]');
      if ((location.hash === '#today' || !location.hash) && planTab) {
        planTab.click();
      } else {
        location.hash = '#today';
      }
    };
  };
  cookBtn.onclick = (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (!card.id) { brieflyConfirmButton(cookBtn, '示例'); return; }
    if (card.tone === 'almost' && card.row) {
      const count = addMissingRecipeIngredientsToShopping(card.row.r, pack, inv, card.row.list);
      if (count) showToast('已加入买菜清单', { tone: 'success' });
      brieflyConfirmButton(cookBtn, count ? '已加入买菜' : '已齐');
    } else {
      const added = addRecipeToPlan(card.id);
      brieflyConfirmButton(cookBtn, added ? '已加入今天' : '已在今天');
      showToast(added ? '已加入今日计划' : '已在今天', { tone: added ? 'success' : 'info' });
      showPlanFeedback(added ? '已加入今天，做完后会帮你更新食材。' : '今天已经安排了这道菜。');
    }
  };
  if (previewBtn) previewBtn.onclick = openPreview;
  if (card.id) {
    const name = el.querySelector('.home-suggest-name');
    if (canPreview) {
      el.classList.add('has-preview-action');
    } else {
      name.classList.add('is-link');
      name.onclick = () => { location.hash = `#recipe:${card.id}`; };
    }
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
  toggleBtn.innerHTML = `<span class="home-inspi-toggle-icon">✨</span><span class="home-inspi-toggle-text">查看今日推荐</span><span class="home-inspi-toggle-arrow">›</span>`;
  section.appendChild(toggleBtn);

  // 2. 折叠内容容器（默认隐藏）
  const inspiWrap = document.createElement('div');
  inspiWrap.className = 'home-inspi-bottom is-collapsed';
  inspiWrap.setAttribute('aria-hidden', 'true');

  // 面板内部：问候语行（含「换一批」按钮） + 状态行 + 滚动卡片 + 注释
  inspiWrap.innerHTML = `
    <div class="home-inspi-panel-head">
      <p class="home-hero-greeting">🔮 结合当前厨房食材，为你定制的今日烹饪灵感：</p>
      <button type="button" class="home-mini-btn home-ai-btn" id="heroAiBtn">✨ 换几道</button>
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
      : `查看今日推荐${count ? ` (${count})` : ''}`;
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
    note.textContent = usingMock ? '示例推荐 · 多记几样食材后会自动匹配' : '';
    note.hidden = !usingMock;
    updateToggleLabel(cards.length);
  };

  // AI 推荐：最多展示 4 张
  const showAi = (aiCards) => {
    showRecommendationCards(scroll, (aiCards || []).slice(0, 4), pack, { onRoute });
    note.hidden = false;
    note.innerHTML = '推荐仅供参考，安排前可以再看一眼。<button type="button" class="home-note-clear" id="heroAiClear">用本地推荐</button>';
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
        setInlineStatus(aiStatus, '已生成几道推荐。', 'ok');
        // 自动展开（刷新后）
        if (!inspiExpanded) toggleBtn.click();
      } else {
        setInlineStatus(aiStatus, '暂时没有返回可用菜谱，已保留本地推荐。', 'info');
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
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-modal', 'true');

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
  requestAnimationFrame(() => {
    overlay.classList.add('open');
    const focusTarget = panel.querySelector('input:not([type="hidden"]), textarea, select, button:not(.km-modal-close)') || header.querySelector('.km-modal-close');
    focusTarget?.focus?.({ preventScroll: true });
  });

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
      <button type="button" class="btn small km-expiry-add">加入买菜</button>
    `;
    li.querySelector('.km-expiry-add').onclick = (e) => {
      addShoppingItem(it.name, (+it.qty > 0 ? it.qty : ''), it.unit || '', '临期补货');
      showToast('已加入买菜清单', { tone: 'success' });
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
    <p class="km-modal-hint" style="margin-top:0">输入名字后回车，快速加入买菜清单。</p>
    <div class="km-modal-add-row">
      <input class="km-modal-input" id="memoModalInput" placeholder="要买什么？">
      <button type="button" class="btn ok small" id="memoModalAdd">加入</button>
    </div>
    <ul class="km-memo-log" id="memoLog"></ul>
    <div class="km-modal-actions">
      <button type="button" class="btn ok" id="gotoShoppingFromMemo">去买菜清单 →</button>
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
    showToast('已加入买菜清单', { tone: 'success' });
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
        <span class="home-metric-label">待买</span>
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
      <button type="button" class="home-act-btn" id="actQuickInput"><span class="home-act-emoji">📦</span><span>记食材</span></button>
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
    activity.innerHTML = '<div class="home-activity-title">最近记下要买</div>' + recent.map(it => {
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

const DEMO_KITCHEN_ITEMS = [
  { name: '鸡蛋', qty: 6, unit: '个' },
  { name: '番茄', qty: 3, unit: '个' },
  { name: '土豆', qty: 2, unit: '个' },
  { name: '豆腐', qty: 1, unit: '盒' },
  { name: '青椒', qty: 2, unit: '个' },
  { name: '牛肉', qty: 1, unit: '份' },
  { name: '面条', qty: 1, unit: '袋' },
  { name: '青菜', qty: 1, unit: '把' }
];

// ── 空库存引导：先让新用户用生活化的入口完成第一步，而不是跳去别的页面。 ─────
function renderOnboarding(pack, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-hero is-onboarding';
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <span class="home-hero-eyebrow">🍳 从几样食材开始</span>
      <h2 class="home-hero-greeting">先告诉我厨房里有什么</h2>
      <p class="home-hero-note">记几样食材后，我会帮你看今天能做什么、缺什么、该买什么。</p>
    </div>
    <div class="home-actions-grid">
      <button type="button" class="home-act-btn" id="obManual"><span class="home-act-emoji">✍️</span><span class="home-act-copy"><span>手动记食材</span><small>先输入几样</small></span></button>
      <button type="button" class="home-act-btn" id="obReceipt"><span class="home-act-emoji">🧾</span><span class="home-act-copy"><span>拍小票识别</span><small>刚买完菜</small></span></button>
      <button type="button" class="home-act-btn" id="obDemo"><span class="home-act-emoji">🍳</span><span class="home-act-copy"><span>试用示例厨房</span><small>先看完整流程</small></span></button>
      <button type="button" class="home-act-btn" id="obRecipes"><span class="home-act-emoji">📖</span><span class="home-act-copy"><span>先逛菜谱</span><small>不想录入也可以</small></span></button>
    </div>
  `;
  section.querySelector('#obManual').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
  section.querySelector('#obReceipt').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'receipt' });
  section.querySelector('#obDemo').onclick = () => {
    const n = writeItemsToInventory(DEMO_KITCHEN_ITEMS, pack);
    if (n > 0) lastWxTab = 'recs';
    onRoute();
  };
  section.querySelector('#obRecipes').onclick = () => { location.hash = '#recipes'; };
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

function writeReceiptPantryItems(items, pack) {
  if (!Array.isArray(items) || !items.length) return 0;
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  return applyReceiptPantryItems(items, inv);
}

// 文本批量录入解析已抽成共享纯函数 parseFoodLines（src/utils/food-input-parser.js），
// 与食材页「随手记几样食材」轻量录入区共用同一套「每行一个食材」解析规则。

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
      <div class="receipt-drop-zone">
        <input type="file" id="batchReceiptFile" accept="image/*" class="visually-hidden">
        <span class="receipt-camera-icon" aria-hidden="true">📷</span>
        <strong>拍小票识别</strong>
        <small>自动识别食材并让你确认</small>
      </div>
      <div id="batchReceiptStatus" class="small inline-status" hidden></div>
    </div>

    <div class="batch-tab-panel is-hidden" id="batch-panel-text" role="tabpanel">
      <p class="meta">每行一个食材。数量不确定也可以只写名字。</p>
      <textarea id="batchTextInput" rows="6" class="batch-text-area" placeholder="鸡蛋 6个&#10;番茄 3个&#10;土豆 2个&#10;豆腐 1盒"></textarea>
      <div id="batchTextStatus" class="small inline-status" hidden></div>
    </div>

    <div class="km-modal-actions">
      <button type="button" class="btn" id="batchCancel">取消</button>
      <button type="button" class="btn ok" id="batchConfirm">加入厨房</button>
    </div>
  `;
  const { overlay, close } = createHomeModal(body, '记进厨房');

  let currentTab = (initialTab === 'text' ? 'text' : 'receipt');
  const setTab = (name) => {
    currentTab = name;
    overlay.querySelectorAll('.batch-tab').forEach(t => t.classList.toggle('is-active', t.dataset.tab === name));
    overlay.querySelectorAll('.batch-tab-panel').forEach(p => p.classList.toggle('is-hidden', p.id !== `batch-panel-${name}`));
    // 拍小票模式：主按钮文案改为「打开相机」式提示；文本模式：恢复「确认入库」。
    const confirmBtn = overlay.querySelector('#batchConfirm');
    confirmBtn.textContent = name === 'receipt' ? '选取小票图片' : '加入厨房';
  };
  setTab(currentTab);
  overlay.querySelectorAll('.batch-tab').forEach(t => { t.onclick = () => setTab(t.dataset.tab); });

  overlay.querySelector('#batchCancel').onclick = close;

  // ── 模式 A：拍小票识别 ──
  const receiptFileInput = overlay.querySelector('#batchReceiptFile');
  const receiptStatus = overlay.querySelector('#batchReceiptStatus');
  const handleReceiptFile = async (file, inputEl) => {
    if (!file) return;
    receiptStatus.hidden = false;
    receiptStatus.className = 'small inline-status info';
    receiptStatus.innerHTML = '<span class="spinner"></span> 正在识别…';
    try {
      const result = await withTimeout(recognizeReceipt(file), 30000, '识别超时');
      const total = ['inventory', 'pantry', 'review', 'ignored'].reduce((sum, key) => sum + (result?.[key]?.length || 0), 0);
      if (!total) {
        receiptStatus.className = 'small inline-status bad';
        receiptStatus.textContent = '没有识别到可处理的内容';
        showToast('没有识别到可入库食材', { tone: 'warning' });
        return;
      }
      // 借用既有的确认弹窗渲染可编辑预览列表，确认后再写库 → 统一走 writeItemsToInventory。
      close();
      showReceiptConfirmationModal(
        result,
        ({ inventory = [], pantry = [] } = {}) => {
          const n = writeItemsToInventory(inventory, pack);
          const p = writeReceiptPantryItems(pantry, pack);
          if (n + p > 0) onRoute();
        },
        () => { /* 用户取消：不写库 */ }
      );
    } catch (err) {
      receiptStatus.className = 'small inline-status bad';
      receiptStatus.textContent = '❌ ' + formatAiErrorMessage(err);
    } finally {
      if (inputEl) inputEl.value = '';
    }
  };
  receiptFileInput.onchange = (e) => handleReceiptFile(e.target.files?.[0], e.target);

  // ── 模式 B：文本批量记 ──
  overlay.querySelector('#batchConfirm').onclick = () => {
    if (currentTab === 'receipt') {
      receiptFileInput.click(); // iPhone 会弹出相册 / 拍照 / 文件选择
      return;
    }
    const text = overlay.querySelector('#batchTextInput').value;
    const parsed = parseFoodLines(text);
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
      statusEl.textContent = `✓ 已加入厨房 ${n} 项`;
      setTimeout(() => { close(); onRoute(); }, 600);
    } else {
      statusEl.hidden = false;
      statusEl.className = 'small inline-status bad';
      statusEl.textContent = '没能加入厨房：这些内容还没识别成食材。';
    }
  };
}

// “直接选食材”里的推荐排序：适合下面 / 煮螺蛳粉 / 麻辣烫等场景的快熟百搭配料优先出现。
const IMPROMPTU_ALLOWED_REGEX = /(菜|茼蒿|菠菜|韭菜|肠|午餐肉|培根|香肠|火腿|丸|棒|饺|千层肚|菇|豆腐|豆皮|腐竹|木耳|蛋|面条|粉|年糕|水饺)/;

function isImpromptuCandidate(e) {
  return isInventoryAvailable(e) && IMPROMPTU_ALLOWED_REGEX.test(String(e.name || ''));
}

// ══════════════════════════════════════════════════════════════════════════
//  「今日」决策页：用户打开即知「今天吃什么 / 优先用掉什么 / 计划是什么 / 缺什么」。
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
    const shopSub = shopCount === 0 ? '还没记要买' : '项待买';

    section.innerHTML = `
      <button type="button" class="home-metric ${expTone}" id="statExpiring">
        <span class="home-metric-header"><span class="home-metric-icon">⏳</span><span class="home-metric-label">到期食材</span></span>
        <span class="home-metric-num">${expCount}</span>
        <span class="home-metric-sub">${escapeHtml(expSub)}</span>
      </button>
      <button type="button" class="home-metric is-info" id="statShopping">
        <span class="home-metric-header"><span class="home-metric-icon">🛒</span><span class="home-metric-label">待买</span></span>
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
      <span class="today-ai-toggle-title">今日推荐</span>
      <span class="today-ai-toggle-sub" id="aiSummary">根据食材生成晚餐灵感</span>
    </span>
    <span class="today-ai-toggle-arrow" aria-hidden="true">›</span>
  `;
  wrap.appendChild(toggle);

  const body = document.createElement('div');
  body.className = 'today-ai-body is-collapsed';
  body.setAttribute('aria-hidden', 'true');
  body.innerHTML = `
    <div class="today-ai-head">
      <button type="button" class="home-mini-btn today-ai-btn" id="todayAiBtn">✨ 换几道</button>
    </div>
    <div class="today-picks-grid" id="todayPicksGrid"></div>
    <p class="today-picks-note" id="todayPicksNote" hidden></p>
  `;
  wrap.appendChild(body);

  const grid = body.querySelector('#todayPicksGrid');
  const note = body.querySelector('#todayPicksNote');
  const aiBtn = body.querySelector('#todayAiBtn');
  const summary = toggle.querySelector('#aiSummary');
  const setSummary = (n) => { summary.textContent = n > 0 ? `有 ${n} 个推荐` : '根据食材生成晚餐灵感'; };

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
    note.innerHTML = '推荐仅供参考，安排前可以再看一眼。<button type="button" class="home-note-clear" id="todayAiClear">用本地推荐</button>';
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

  // 头部：今日计划标题 + 动作组（✓全部做完 / 范围筛选）
  const head = document.createElement('div');
  head.className = 'today-section-head today-main-head';
  head.innerHTML = '<h2 class="today-section-title">📅 今日计划</h2>';
  const actions = document.createElement('div');
  actions.className = 'menu-plan-head-actions';
  actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
  actions.appendChild(renderPlanRangeSelect({ onRoute, id: 'homePlanRangeSelect' }));
  head.appendChild(actions);
  card.appendChild(head);

  card.appendChild(createRecordCookedCta(pack, inv, { onRoute }));

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

// ③ 快捷操作区（两个轻量入口）：记食材 + 导入菜谱。待买速记入口放进「待买」Tab。
function renderQuickActions(pack, inv, { onRoute = () => {}, refreshStatus = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'today-section today-quick';
  section.innerHTML = `
    <div class="today-quick-row">
      <button type="button" class="today-quick-btn is-primary" id="qaStock"><span class="tq-emoji">📦</span><span>记食材</span></button>
      <button type="button" class="today-quick-btn" id="qaRecipeImport"><span class="tq-emoji">📸</span><span>导入菜谱</span></button>
    </div>
  `;
  // 记食材：直接打开现有「记进厨房」弹窗（📸 拍小票识别 + ✍️ 文本批量记）。
  section.querySelector('#qaStock').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'receipt' });
  section.querySelector('#qaRecipeImport').onclick = () => openRecipeImportModal();
  return section;
}

function decorateCookedPredictions(predictions, candidates) {
  return (predictions || []).map(prediction => {
    const matchName = prediction.match?.name || prediction.name;
    const candidate = (candidates || []).find(item =>
      item && (item.matchName === matchName || item.item === matchName || getCanonicalName(item.item) === getCanonicalName(prediction.name))
    );
    return {
      ...prediction,
      reason: candidate?.reason || '需确认',
      suggestedQty: Number.isFinite(Number(candidate?.qty)) && Number(candidate.qty) > 0
        ? Number(candidate.qty)
        : (prediction.recipeQty || 1)
    };
  });
}

function getTodayPlanRecipeRows(pack) {
  const today = todayISO();
  const recipes = pack.recipes || [];
  return S.load(S.keys.plan, [])
    .filter(row => row && (row.date || today) === today && !row.isCooked)
    .map(row => {
      const recipe = recipes.find(r => r.id === row.id);
      return recipe ? { row, recipe } : null;
    })
    .filter(Boolean);
}

function markTodayPlanCooked(recipeId) {
  if (!recipeId) return;
  const today = todayISO();
  const plans = S.load(S.keys.plan, []);
  let changed = false;
  for (const row of plans) {
    if (row && row.id === recipeId && (row.date || today) === today && !row.isCooked) {
      row.isCooked = true;
      row.cookedAt = Date.now();
      changed = true;
    }
  }
  if (changed) S.save(S.keys.plan, plans);
  markRecipeCookedKeepPlan(recipeId);
}

function createRecordCookedButton(pack, inv, { onRoute = () => {} } = {}) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'record-cooked-btn';
  button.innerHTML = '<span class="record-cooked-icon">🍽️</span><span>饭后记一下</span>';
  button.onclick = () => {
    const original = button.innerHTML;
    button.disabled = true;
    button.classList.add('is-opening');
    button.innerHTML = '<span class="record-cooked-icon">🍽️</span><span>打开中...</span>';
    requestAnimationFrame(() => {
      openCookedMealModal(pack, inv, { onRoute });
      window.setTimeout(() => {
        button.innerHTML = original;
        button.disabled = false;
        button.classList.remove('is-opening');
      }, 180);
    });
  };
  return button;
}

function createRecordCookedCta(pack, inv, { onRoute = () => {} } = {}) {
  const cta = document.createElement('div');
  cta.className = 'record-cooked-cta';
  cta.innerHTML = `
    <span class="record-cooked-cta-text">
      <strong>做完饭了？</strong>
      <small>顺手把用掉的食材记一下</small>
    </span>
  `;
  cta.appendChild(createRecordCookedButton(pack, inv, { onRoute }));
  return cta;
}

function openCookedMealModal(pack, inv, { onRoute = () => {} } = {}) {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content cooked-meal-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">饭后记一下</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body cooked-meal-body">
      <div class="cooked-meal-start" id="cookedMealStart"></div>
      <textarea class="cooked-meal-textarea" id="cookedMealText" rows="4" placeholder="比如：番茄炒蛋，或者我炒了鸡腿和豆芽"></textarea>
      <div class="small inline-status cooked-meal-status" id="cookedMealStatus" hidden></div>
      <div class="cooked-meal-result" id="cookedMealResult"></div>
      <div class="km-modal-actions cooked-meal-actions">
        <button type="button" class="btn" id="cookedMealCancel">取消</button>
        <button type="button" class="btn" id="cookedMealAddAction" hidden>添加食材</button>
        <button type="button" class="btn ok" id="cookedMealAnalyze">生成建议</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);

  const textInput = panel.querySelector('#cookedMealText');
  const startHost = panel.querySelector('#cookedMealStart');
  const status = panel.querySelector('#cookedMealStatus');
  const resultHost = panel.querySelector('#cookedMealResult');
  const analyzeBtn = panel.querySelector('#cookedMealAnalyze');
  const addActionBtn = panel.querySelector('#cookedMealAddAction');
  const recipes = pack.recipes || [];
  let currentRecipe = null;
  let currentCandidates = [];
  let currentPredictions = [];
  let currentSourceLabel = '';
  let currentMarkPlanId = '';

  let closing = false;
  const close = (after = () => {}) => {
    if (closing) return;
    closing = true;
    panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
    panel.style.opacity = '0';
    panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
    overlay.classList.add('closing');
    window.setTimeout(() => {
      overlay.remove();
      after();
    }, 220);
  };
  const showStatus = (message, tone = '') => {
    status.hidden = false;
    status.className = `small inline-status cooked-meal-status ${tone}`.trim();
    status.textContent = message;
  };
  const clearStatus = () => {
    status.hidden = true;
    status.textContent = '';
  };
  const resetAnalyzeButton = () => {
    analyzeBtn.textContent = '生成建议';
    analyzeBtn.disabled = false;
    analyzeBtn.onclick = analyze;
    addActionBtn.hidden = true;
  };

  function renderStart() {
    const planRows = getTodayPlanRecipeRows(pack);
    startHost.innerHTML = `
      <section class="cooked-meal-start-block">
        <div class="cooked-meal-start-title">从今日计划记录</div>
        <div class="cooked-meal-plan-list">
          ${planRows.length
            ? planRows.slice(0, 5).map(({ recipe }) => `
              <button type="button" class="cooked-meal-plan-chip" data-recipe-id="${escapeOptionAttr(recipe.id)}">${escapeHtml(recipe.name)}</button>
            `).join('')
            : '<span class="cooked-meal-muted">今天还没有待完成的计划。</span>'}
        </div>
      </section>
      <section class="cooked-meal-start-block">
        <div class="cooked-meal-start-title">直接选食材</div>
        <button type="button" class="wx-mini-btn cooked-meal-select-btn" id="cookedMealPickStock">直接选库存食材</button>
      </section>
    `;
    startHost.querySelectorAll('.cooked-meal-plan-chip').forEach(btn => {
      btn.onclick = () => {
        const recipe = recipes.find(r => r.id === btn.dataset.recipeId);
        if (recipe) useRecipeForCookedMeal(recipe, { source: '来自今日计划', markPlan: true });
      };
    });
    startHost.querySelector('#cookedMealPickStock')?.addEventListener('click', () => {
      clearStatus();
      currentRecipe = null;
      currentCandidates = [];
      currentPredictions = [];
      currentSourceLabel = '你手动选择库存食材。';
      currentMarkPlanId = '';
      renderInventoryPicker({ title: '直接选库存食材' });
    });
  }

  function recomputeAndRenderConfirm({ recipe = currentRecipe, candidates = currentCandidates, sourceLabel = currentSourceLabel, markPlanId = currentMarkPlanId } = {}) {
    const merged = mergeCookedMealCandidates(candidates);
    const predictions = decorateCookedPredictions(computeCookDeductions(merged, inv), merged);
    if (!predictions.length) {
      showStatus('没判断出用到哪些食材，可以直接从库存里选。', 'bad');
      renderInventoryPicker({ title: '直接选库存食材' });
      resetAnalyzeButton();
      return;
    }
    currentRecipe = recipe || null;
    currentCandidates = merged;
    currentPredictions = predictions;
    currentSourceLabel = sourceLabel || '确认后才会更新食材。';
    currentMarkPlanId = markPlanId || '';
    renderConfirm();
  }

  function renderConfirm() {
    const title = '可能用掉了这些';
    const subtitle = currentRecipe
      ? `按「${currentRecipe.name}」整理，你可以增删改，确认后才会更新库存。`
      : '你可以增删改，确认后才会更新库存。';
    const predictions = currentPredictions;
    resultHost.innerHTML = `
      <div class="cooked-meal-suggestion-head">
        <strong>${escapeHtml(title)}</strong>
        <span>${escapeHtml(subtitle)}</span>
      </div>
      <div class="cooked-meal-list">
        ${predictions.map((prediction, index) => {
          const isPiece = prediction.unitType === UNIT_TYPE.PIECE;
          const unit = prediction.unit || prediction.match?.unit || '';
          const current = isPiece
            ? `当前 ${prediction.currentQty}${unit}`
            : `当前 ${GEAR_LABELS[gearInfo(prediction.currentGear).value] || '有'}`;
          const control = isPiece
            ? `<input class="cooked-meal-use" type="number" min="0" step="1" value="${escapeOptionAttr(String(prediction.suggestedQty || prediction.recipeQty || 1))}"><input class="cooked-meal-unit" value="${escapeOptionAttr(unit || '份')}" aria-label="单位">`
            : `<select class="cooked-meal-final-gear" aria-label="剩余档位">${[100, 75, 50, 25, 0].map(g => `<option value="${g}"${g === prediction.predictedGear ? ' selected' : ''}>剩余${GEAR_LABELS[g]}</option>`).join('')}</select>`;
          return `
            <div class="cooked-meal-row" data-index="${index}">
              <input type="checkbox" class="cooked-meal-check" checked>
              <span class="cooked-meal-main">
                <strong>${escapeHtml(prediction.match?.name || prediction.name)}</strong>
                <small>${escapeHtml(prediction.reason || '需确认')} · ${escapeHtml(current)}</small>
              </span>
              <span class="cooked-meal-control">${control}</span>
              <button type="button" class="cooked-meal-remove" aria-label="移除">×</button>
            </div>
          `;
        }).join('')}
      </div>
    `;
    resultHost.querySelectorAll('.cooked-meal-remove').forEach(btn => {
      btn.onclick = event => {
        event.preventDefault();
        event.stopPropagation();
        const row = btn.closest('.cooked-meal-row');
        const prediction = predictions[Number(row?.dataset.index)];
        const key = getCanonicalName(prediction?.match?.name || prediction?.name || '');
        currentCandidates = currentCandidates.filter(item => (getCanonicalName(item?.item || item?.name || '') !== key));
        if (!currentCandidates.length) {
          resultHost.innerHTML = '';
          showStatus('确认单已清空，可以直接选择食材。', '');
          renderInventoryPicker({ title: '直接选库存食材' });
        } else {
          recomputeAndRenderConfirm();
        }
      };
    });
    startHost.hidden = true;
    analyzeBtn.textContent = '确认更新库存';
    analyzeBtn.disabled = false;
    addActionBtn.hidden = false;
    addActionBtn.onclick = () => renderInventoryPicker({ title: '添加库存食材', append: true });
    analyzeBtn.onclick = () => {
      const rows = Array.from(resultHost.querySelectorAll('.cooked-meal-row'));
      const calibrations = rows.map(row => {
        if (!row.querySelector('.cooked-meal-check')?.checked) return null;
        const prediction = predictions[Number(row.dataset.index)];
        if (!prediction) return null;
        if (prediction.unitType === UNIT_TYPE.PIECE) {
          const useQty = Math.max(0, Math.round(Number(row.querySelector('.cooked-meal-use')?.value) || 0));
          const unit = String(row.querySelector('.cooked-meal-unit')?.value || prediction.unit || prediction.match?.unit || '').trim();
          if (useQty <= 0) return null;
          if (unit && prediction.match) prediction.match.unit = unit;
          return {
            match: prediction.match,
            name: prediction.name,
            unitType: UNIT_TYPE.PIECE,
            finalQty: Math.max(0, (Number(prediction.currentQty) || 0) - useQty)
          };
        }
        return {
          match: prediction.match,
          name: prediction.name,
          unitType: UNIT_TYPE.GEAR,
          finalGear: Number(row.querySelector('.cooked-meal-final-gear')?.value ?? prediction.predictedGear)
        };
      }).filter(Boolean);
      if (!calibrations.length) {
        showToast('没有选择要更新的食材', { tone: 'warning' });
        showStatus('至少勾选一样食材。', 'bad');
        return;
      }
      const shoppingCandidates = getCookShoppingCandidates({ calibrations });
      applyCookCalibration(inv, calibrations);
      showToast('已更新库存', { tone: 'success' });
      if (currentMarkPlanId) markTodayPlanCooked(currentMarkPlanId);
      else if (currentRecipe?.id) markRecipeCookedKeepPlan(currentRecipe.id);
      close(() => showCookCompleteFeedback({
        updated: true,
        candidates: shoppingCandidates,
        onClose: onRoute,
        onShoppingAdded: onRoute
      }));
    };
  }

  function renderInventoryPicker({ title = '选择库存食材', append = false } = {}) {
    const available = (inv || [])
      .filter(item => item && isInventoryAvailable(item))
      .filter(item => mergeCookedMealCandidates([{ item: item.name }]).length)
      .sort((a, b) => Number(isImpromptuCandidate(b)) - Number(isImpromptuCandidate(a)) || String(a.name).localeCompare(String(b.name), 'zh-Hans-CN'));
    const picker = document.createElement('div');
    picker.className = 'cooked-meal-picker';
    picker.innerHTML = `
      <div class="cooked-meal-picker-head">
        <strong>${escapeHtml(title)}</strong>
        <input class="cooked-meal-picker-filter" type="search" placeholder="搜索库存食材">
      </div>
      <div class="cooked-meal-picker-list">
        ${available.length
          ? available.map(item => `
            <button type="button" class="cooked-meal-stock-option${isImpromptuCandidate(item) ? ' is-suggested' : ''}" data-name="${escapeOptionAttr(item.name)}">
              <span>${escapeHtml(item.name)}</span>
              <small>${escapeHtml(item.qty ? `${item.qty}${item.unit || ''}` : item.unit || '')}</small>
            </button>
          `).join('')
          : '<span class="cooked-meal-muted">当前没有可扣减的库存食材。</span>'}
      </div>
    `;
    const host = append && currentPredictions.length ? resultHost : resultHost;
    if (append && currentPredictions.length) {
      host.querySelector('.cooked-meal-picker')?.remove();
      host.appendChild(picker);
    } else {
      startHost.hidden = true;
      addActionBtn.hidden = true;
      resultHost.innerHTML = '';
      resultHost.appendChild(picker);
    }
    const filter = picker.querySelector('.cooked-meal-picker-filter');
    const refreshFilter = () => {
      const q = getCanonicalName(filter.value.trim()) || filter.value.trim();
      picker.querySelectorAll('.cooked-meal-stock-option').forEach(btn => {
        const name = btn.dataset.name || '';
        const canonical = getCanonicalName(name) || '';
        btn.hidden = q && !name.includes(q) && !canonical.includes(q);
      });
    };
    filter.oninput = refreshFilter;
    picker.querySelectorAll('.cooked-meal-stock-option').forEach(btn => {
      btn.onclick = () => {
        const item = available.find(x => x.name === btn.dataset.name);
        if (!item) return;
        const next = {
          item: item.name,
          qty: 1,
          unit: item.unit || guessKitchenUnit(item.name) || '份',
          reason: '你手动添加',
          matchName: item.name
        };
        currentCandidates = mergeCookedMealCandidates(currentCandidates, [next]);
        recomputeAndRenderConfirm({
          recipe: currentRecipe,
          candidates: currentCandidates,
          sourceLabel: currentSourceLabel || '你手动选择库存食材。',
          markPlanId: currentMarkPlanId
        });
      };
    });
    filter.focus();
  }

  function useRecipeForCookedMeal(recipe, { source = '来自菜谱', markPlan = false } = {}) {
    clearStatus();
    const candidates = getRecipeCoreItems(recipe, pack).map(item => ({ ...item, reason: source }));
    recomputeAndRenderConfirm({
      recipe,
      candidates,
      sourceLabel: `${source}，确认后才会更新食材。`,
      markPlanId: markPlan ? recipe.id : ''
    });
  }

  async function analyze() {
    const text = textInput.value.trim();
    resultHost.innerHTML = '';
    if (!text) {
      showStatus('先写一下刚吃了什么。', 'bad');
      textInput.focus();
      return;
    }
    clearStatus();
    analyzeBtn.disabled = true;
    analyzeBtn.textContent = '正在分析...';
    const recipe = matchCookedMealRecipe(text, recipes);
    let sourceLabel = '';
    let candidates = [];

    if (recipe) {
      candidates = getRecipeCoreItems(recipe, pack).map(item => ({ ...item, reason: '来自菜谱' }));
      sourceLabel = '来自菜谱，确认后才会更新食材。';
    }

    let predictions = computeCookDeductions(candidates, inv);
    if (!predictions.length) {
      const localCandidates = buildLocalCookedMealCandidates(text, inv);
      predictions = computeCookDeductions(localCandidates, inv);
      if (predictions.length) {
        candidates = localCandidates;
        sourceLabel = '根据你刚刚提到的食材匹配库存。';
      }
    }

    if (!predictions.length) {
      try {
        const aiResult = await withTimeout(callAiForCookedMeal(text, inv, recipes), 22000, 'AI 响应超时');
        const normalized = normalizeAiCookedMealResult(aiResult, inv);
        const aiCandidates = mergeCookedMealCandidates(normalized.candidates);
        predictions = computeCookDeductions(aiCandidates, inv);
        if (predictions.length) {
          candidates = aiCandidates;
          sourceLabel = 'AI 辅助整理，仍需你确认。';
        }
      } catch (err) {
        showStatus(`${formatAiErrorMessage(err)} 已尝试用本地规则匹配。`, 'bad');
      }
    }

    if (!predictions.length) {
      analyzeBtn.disabled = false;
      analyzeBtn.textContent = '生成建议';
      if (status.hidden) showStatus('没判断出用到哪些食材，可以直接从库存里选。', 'bad');
      renderInventoryPicker({ title: '直接选库存食材' });
      return;
    }

    const decorated = decorateCookedPredictions(predictions, candidates);
    clearStatus();
    currentRecipe = recipe || null;
    currentCandidates = mergeCookedMealCandidates(candidates);
    currentPredictions = decorated;
    currentSourceLabel = sourceLabel || '确认后才会更新食材。';
    currentMarkPlanId = '';
    renderConfirm();
  }

  analyzeBtn.onclick = analyze;
  panel.querySelector('.km-modal-close').onclick = () => close();
  panel.querySelector('#cookedMealCancel').onclick = () => close();
  overlay.onclick = event => { if (event.target === overlay) close(); };
  textInput.onkeydown = event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') analyze();
  };
  renderStart();
  requestAnimationFrame(() => overlay.classList.add('open'));
  setTimeout(() => textInput.focus(), 80);
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

function getTodaySummaryStats(pack, inv, { inspirationCards = null } = {}) {
  // inspirationCards 可由调用方传入（renderHome 一次渲染内复用，避免全库推荐重算多次）。
  const cards = inspirationCards || getInspirationCards(pack, inv);
  return {
    planCount: getTodayPlanCount(),
    expiringCount: getExpiringItemCount(inv),
    shoppingCount: loadShoppingItems().filter(item => item && !item.done).length,
    recommendationCount: cards.length
  };
}

// 顶部固定主状态区：问候 + 决策主文案 + 一行副文案。
// 不是卡片：直接铺在页面背景上；下方面板 tab 切换不影响这里。
function renderWxStatus({ planCount, expiringCount, shoppingCount, recommendationCount }) {
  const section = document.createElement('section');
  section.className = 'wx-status';
  const greeting = buildGreeting(expiringCount).split('！')[0]; // 「🌆 晚上好」——复用现有问候逻辑
  const title = recommendationCount > 0
    ? `今天可以做 ${recommendationCount} 道菜`
    : (planCount > 0 ? `今天计划了 ${planCount} 道菜` : '今天还没决定吃什么');
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
let targetRecipeQuery = '';
// AI 创意做法状态（仅页面内存，不持久化）：idle / loading / error / success。
let targetCreativeDraft = null;
let targetCreativeStatus = 'idle';
let targetCreativeError = '';
let targetCreativeHistory = { names: [], modes: [] };
let targetDishDraft = null;
let targetDishStatus = 'idle';
let targetDishError = '';
let targetDishQuery = '';

function resetTargetCreative() {
  targetCreativeDraft = null;
  targetCreativeStatus = 'idle';
  targetCreativeError = '';
  targetCreativeHistory = { names: [], modes: [] };
}

function resetTargetDishDraft() {
  targetDishDraft = null;
  targetDishStatus = 'idle';
  targetDishError = '';
  targetDishQuery = '';
}

function rememberTargetCreativeDraft(draft) {
  const name = String(draft?.name || '').trim();
  const mode = String(draft?.dishMode || '').trim();
  if (name && !targetCreativeHistory.names.includes(name)) {
    targetCreativeHistory.names = [...targetCreativeHistory.names, name].slice(-8);
  }
  if (mode && !targetCreativeHistory.modes.includes(mode)) {
    targetCreativeHistory.modes = [...targetCreativeHistory.modes, mode].slice(-10);
  }
}

// 解析目标食材：类别展开（菌菇/绿叶菜/肉片…）+ 库存辅助 + 调料过滤，详见 ingredient-intent。
function parseTargetRecipeQuery(query, inv) {
  const raw = String(query || '').trim();
  const inventoryNames = (inv || []).map(x => x && x.name).filter(Boolean);
  const parsed = parseTargetIngredients(raw, { inventoryNames, limit: 5 }).targets;
  const hasSeparator = /[\s,，、/;；]+/.test(raw);
  if (!hasSeparator && parsed.length === 1 && raw.length >= 3) {
    const target = parsed[0];
    const stockSet = new Set(inventoryNames.map(name => getCanonicalName(name)).filter(Boolean));
    if (target.canonical === getCanonicalName(raw) && !target.category && !stockSet.has(target.canonical)) {
      return [];
    }
  }
  return parsed;
}

// 单一主信息面板：顶部 segmented tabs（📅计划 / ⏳到期 / 🛒待买 / ✨推荐），
// 下方同一块 .wx-body 区域按 tab 重渲染内容——巧妙复用同一块屏幕空间。
function createWeatherPanel(pack, inv, { onRoute = () => {}, inspirationCards = null } = {}) {
  // 本面板生命周期内的本地推荐缓存：pack/inv 在一次渲染内不变（任何写库操作都会
  // onRoute 整页重建面板），同一面板内多处需要本地推荐时只算一次全库排序。
  let inspirationCache = Array.isArray(inspirationCards) ? inspirationCards : null;
  const getInspirationCached = () => {
    if (!inspirationCache) inspirationCache = getInspirationCards(pack, inv);
    return inspirationCache;
  };
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
    return { mode: 'local', cards: getInspirationCached(), idx: 0 };
  };
  const stepRecommendation = (delta = 1) => {
    if (!recsState || !recsState.cards || recsState.cards.length <= 1) return;
    const total = recsState.cards.length;
    recsState.idx = (recsState.idx + delta + total) % total;
    switchTab('recs');
  };
  const isCardControlTarget = (target) => Boolean(target && target.closest('button, a, input, select, textarea, [data-no-card-swipe]'));
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

  // ── 📅 计划：动作组（全部做完/范围）+ 饭后轻 CTA + 计划列表，全部复用现有组件 ──
  const renderPlanTab = () => {
    const actions = document.createElement('div');
    actions.className = 'menu-plan-head-actions wx-plan-actions';
    actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
    actions.appendChild(renderPlanRangeSelect({ onRoute, id: 'homePlanRangeSelect' }));
    body.appendChild(actions);

    body.appendChild(createRecordCookedCta(pack, inv, { onRoute }));

    const planNode = renderMenuPlan(pack, { onRoute, hideHeader: true, inventory: inv });
    // 空态瘦身：一行轻提示 + 「看推荐」切 tab（原空态是纯静态节点、无事件绑定，见 menu-plan.js）。
    const empty = planNode.querySelector('.menu-plan-empty');
    if (empty) {
      empty.innerHTML = `
        <span class="plan-empty-line">还没有安排今天吃什么</span>
        <span class="wx-help-text">计划就是今天/明天准备吃什么。</span>
        <button type="button" class="wx-mini-btn" id="wxGoRecs">✨ 看看推荐</button>
      `;
      empty.querySelector('#wxGoRecs').onclick = () => switchTab('recs');
    }
    body.appendChild(planNode);
  };

  // ── ⏳ 到期：最多 3 行（名称+剩余天数），「查看全部」沿用原到期弹窗 ──
  const renderExpiryTab = () => {
    const items = getExpiringItems(inv).slice(0, 3);
    if (!items.length) {
      body.innerHTML = '<div class="wx-empty"><strong>✅ 最近没有快到期的食材</strong><span class="wx-help-text">这里会提醒你优先吃掉快过期的食材。</span></div>';
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
    const openShoppingNote = () => {
      showQuickShoppingNoteModal({
        onAdd: () => {
          lastWxTab = 'shopping';
          onRoute();
        }
      });
    };
    if (!items.length) {
      body.innerHTML = `
        <div class="wx-empty wx-shopping-empty">
          <span>🧺 还没有要买的东西</span>
          <small class="wx-help-text">缺的食材、做完要补的东西会放在这里。</small>
          <button type="button" class="wx-mini-btn" id="wxShoppingAddEmpty">记要买</button>
        </div>
      `;
      body.querySelector('#wxShoppingAddEmpty').onclick = openShoppingNote;
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
    foot.innerHTML = `
      <span class="wx-count-note">共 ${items.length} 项待买</span>
      <button type="button" class="wx-mini-btn" id="wxShoppingAdd">记要买</button>
      <button type="button" class="wx-mini-btn" id="wxShoppingAll">查看全部 ›</button>
    `;
    foot.querySelector('#wxShoppingAdd').onclick = openShoppingNote;
    foot.querySelector('#wxShoppingAll').onclick = () => showPendingShoppingModal({ onChange: () => switchTab('shopping') });
    body.appendChild(foot);
  };

  // ── ✨ 推荐：一次只展示 1 个主推荐（不摊开三张卡）。
  //    「换一道」在已有推荐里轮换；「AI 换一批」沿用原 callCloudAI → processAiData 流程。──
  const renderTargetRecipeSearch = (targetNames, resultCount, nameCount = 0) => {
    const hasQuery = !!targetRecipeQuery.trim();
    const search = document.createElement('div');
    search.className = 'target-recipe-search';
    const hint = hasQuery
      ? ([
          nameCount ? `找到 ${nameCount} 道现有菜谱` : '',
          targetNames.length && Number.isFinite(resultCount) ? `按食材推荐 ${resultCount} 道` : ''
        ].filter(Boolean).join(' · ') || '没找到现有菜谱，可以让 AI 生成草稿。')
      : '输入菜名或食材，找到后可以直接加入今天。';
    search.innerHTML = `
      <div class="target-recipe-head">
        <span>想做什么？</span>
        <small class="target-recipe-hint">${hint}</small>
      </div>
      <div class="target-recipe-input-row">
        <input class="target-recipe-input" type="text" value="${escapeOptionAttr(targetRecipeQuery)}" placeholder="比如 番茄炒蛋 / 鸡蛋 番茄">
        <button type="button" class="target-recipe-btn">找菜</button>
        ${hasQuery ? '<button type="button" class="target-recipe-clear" aria-label="清空搜索" title="清空搜索">❌</button>' : ''}
      </div>
    `;
    const input = search.querySelector('.target-recipe-input');
    const applyQuery = () => {
      targetRecipeQuery = input.value.trim();
      recsState = null;
      resetTargetCreative(); // 换了目标食材，旧的 AI 草稿不再适用
      resetTargetDishDraft();
      switchTab('recs');
    };
    search.querySelector('.target-recipe-btn').onclick = applyQuery;
    input.onkeydown = event => {
      if (event.key === 'Enter') applyQuery();
    };
    search.querySelector('.target-recipe-clear')?.addEventListener('click', () => {
      targetRecipeQuery = '';
      recsState = null;
      resetTargetCreative();
      resetTargetDishDraft();
      switchTab('recs');
      requestAnimationFrame(() => document.querySelector('.today-view .target-recipe-input')?.focus());
    });
    return search;
  };

  const renderRecipeNameResults = (matches) => {
    const refreshAfterAdd = (added) => {
      if (!added) return;
      window.setTimeout(() => {
        onRoute();
      }, 650);
    };
    const section = document.createElement('div');
    section.className = 'target-recipe-results';
    section.innerHTML = `
      <div class="target-recipe-section-title">
        <strong>找到这些菜</strong>
        <span>可以直接加入今天</span>
      </div>
      <div class="target-recipe-result-list"></div>
    `;
    const list = section.querySelector('.target-recipe-result-list');
    matches.forEach(item => {
      const card = document.createElement('article');
      card.className = 'target-recipe-result-card';
      card.setAttribute('role', 'button');
      card.tabIndex = 0;
      card.innerHTML = `
        <span class="target-recipe-result-main">
          <strong>${escapeHtml(item.name)}</strong>
          <small>${escapeHtml(item.reason || '本地菜谱匹配')}</small>
        </span>
        <span class="target-recipe-result-actions">
          <button type="button" class="wx-mini-btn target-recipe-view-btn">查看做法</button>
          <button type="button" class="wx-mini-btn target-recipe-plan-btn">加入今日计划</button>
        </span>
      `;
      const openPreview = () => openRecipePreviewModal(item.r || item.recipe);
      const addBtn = card.querySelector('.target-recipe-plan-btn');
      addBtn.onclick = event => {
        event.preventDefault();
        event.stopPropagation();
        const added = addRecipeToPlan(item.id);
        brieflyConfirmButton(addBtn, added ? '已加入今天' : '已在今天');
        showToast(added ? '已加入今日计划' : '已在今天', { tone: added ? 'success' : 'info' });
        refreshAfterAdd(added);
      };
      card.querySelector('.target-recipe-view-btn').onclick = event => {
        event.preventDefault();
        event.stopPropagation();
        openPreview();
      };
      card.onclick = openPreview;
      card.onkeydown = event => {
        if (event.target.closest('button, a, input, select, textarea')) return;
        if (event.key !== 'Enter' && event.key !== ' ') return;
        event.preventDefault();
        openPreview();
      };
      list.appendChild(card);
    });
    return section;
  };

  const renderTargetSectionTitle = (title, subtitle = '') => {
    const head = document.createElement('div');
    head.className = 'target-recipe-section-title';
    head.innerHTML = `<strong>${escapeHtml(title)}</strong>${subtitle ? `<span>${escapeHtml(subtitle)}</span>` : ''}`;
    return head;
  };

  const renderPreviewIngredientChips = (items, emptyText) => {
    if (!items.length) return `<span class="recipe-preview-muted">${escapeHtml(emptyText)}</span>`;
    return items.map(item => {
      const name = item.item || item.name || '';
      const amount = [item.qty, item.unit].filter(v => v !== null && v !== undefined && String(v).trim()).join('');
      return `<span class="recipe-preview-chip"><strong>${escapeHtml(name)}</strong>${amount ? `<small>${escapeHtml(amount)}</small>` : ''}</span>`;
    }).join('');
  };

  const renderPreviewMethod = (method) => {
    const steps = splitMethodSteps(method);
    if (!steps.length) {
      return '<p class="recipe-preview-muted">这个菜谱还没有做法，可以先加入计划或稍后补做法。</p>';
    }
    return `<ol class="recipe-preview-steps">${steps.map((step, index) => `
      <li><span>${index + 1}</span><p>${escapeHtml(step)}</p></li>
    `).join('')}</ol>`;
  };

  const openRecipePreviewModal = (recipe, { sourceLabel = '本地菜谱 · 可以直接加入今日计划' } = {}) => {
    if (!recipe) return;
    const items = explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
    const { foods, seasonings, nonStock } = splitRecipeIngredients(items);
    const referenceItems = [...seasonings, ...nonStock];
    const content = document.createElement('div');
    content.className = 'recipe-preview-shell';
    content.innerHTML = `
      <div class="km-modal-body recipe-preview-body">
      <p class="recipe-preview-source">${escapeHtml(sourceLabel)}</p>
      <section class="recipe-preview-section">
        <h4>核心食材</h4>
        <div class="recipe-preview-chip-list">${renderPreviewIngredientChips(foods, '还没有录入核心食材。')}</div>
      </section>
      <section class="recipe-preview-section">
        <h4>调味 / 参考配料</h4>
        <div class="recipe-preview-chip-list">${renderPreviewIngredientChips(referenceItems, '暂无调味或参考配料。')}</div>
      </section>
      <section class="recipe-preview-section">
        <h4>做法</h4>
        ${renderPreviewMethod(recipe.method || '')}
      </section>
      </div>
      <div class="km-modal-actions recipe-preview-actions">
        <button type="button" class="btn" id="recipePreviewClose">关闭</button>
        <button type="button" class="btn ok" id="recipePreviewPlan">加入今日计划</button>
        <button type="button" class="btn recipe-preview-go-plan" id="recipePreviewGoPlan" hidden>查看今日计划</button>
      </div>
    `;
    const modal = createHomeModal(content, recipe.name || '菜谱预览');
    const addBtn = content.querySelector('#recipePreviewPlan');
    const goPlanBtn = content.querySelector('#recipePreviewGoPlan');
    addBtn.onclick = event => {
      event.preventDefault();
      const added = addRecipeToPlan(recipe.id);
      brieflyConfirmButton(addBtn, added ? '已加入今天' : '已在今天');
      showToast(added ? '已加入今日计划' : '已在今天', { tone: added ? 'success' : 'info' });
      goPlanBtn.hidden = false;
    };
    goPlanBtn.onclick = event => {
      event.preventDefault();
      lastWxTab = 'plan';
      modal.close();
      window.setTimeout(() => onRoute(), 220);
    };
    content.querySelector('#recipePreviewClose').onclick = modal.close;
  };

  // ── AI 创意做法（指定食材模式专属）：本地结果之下、明确分层；只有点按钮才调 AI ──
  const renderTargetCreativeBox = (targetNames, localCards) => {
    const box = document.createElement('div');
    box.className = 'target-recipe-ai-box';

    if ((targetCreativeStatus === 'success' || targetCreativeStatus === 'loading') && targetCreativeDraft) {
      const modeLabel = getCreativeDishModeLabel(targetCreativeDraft.dishMode);
      const note = document.createElement('p');
      note.className = 'target-recipe-ai-note';
      note.innerHTML = `
        <span class="target-recipe-ai-mode">AI 草稿 · ${escapeHtml(modeLabel)}</span>
        <span>用到${escapeHtml(targetNames.join('、'))} · 草稿确认后才会保存</span>
      `;
      box.appendChild(note);
      const cardHost = document.createElement('div');
      cardHost.className = 'target-recipe-ai-card';
      // 复用现有草稿卡：查看做法（卡内直接展示）+ 保存草稿/保存并编辑/取消，绝不自动保存。
      cardHost.appendChild(renderAiRecipeDraftCard(targetCreativeDraft));
      box.appendChild(cardHost);
      const again = document.createElement('div');
      again.className = 'target-recipe-ai-actions';
      again.innerHTML = `
        <button type="button" class="wx-mini-btn target-recipe-ai-btn" id="targetAiAgain"${targetCreativeStatus === 'loading' ? ' disabled' : ''}>
          ${targetCreativeStatus === 'loading' ? '正在换个方向...' : '换一种做法'}
        </button>
      `;
      box.appendChild(again);
      if (targetCreativeError) {
        const err = document.createElement('div');
        err.className = 'small inline-status bad';
        err.textContent = targetCreativeError;
        box.appendChild(err);
      }
    } else {
      const actions = document.createElement('div');
      actions.className = 'target-recipe-ai-actions';
      actions.innerHTML = `
        <button type="button" class="wx-mini-btn is-ai target-recipe-ai-btn" id="targetAiBtn"${targetCreativeStatus === 'loading' ? ' disabled' : ''}>
          ${targetCreativeStatus === 'loading' ? '正在换个方向...' : '让 AI 想一个做法'}
        </button>
      `;
      box.appendChild(actions);
      const hint = document.createElement('p');
      hint.className = 'target-recipe-ai-hint';
      hint.textContent = 'AI 草稿，确认后才会保存。';
      box.appendChild(hint);
      if (targetCreativeStatus === 'error' && targetCreativeError) {
        const err = document.createElement('div');
        err.className = 'small inline-status bad';
        err.textContent = targetCreativeError;
        box.appendChild(err);
      }
    }

    const trigger = box.querySelector('#targetAiBtn, #targetAiAgain');
    if (trigger) trigger.onclick = async () => {
      if (targetCreativeStatus === 'loading') return;
      const nextMode = pickNextCreativeDishMode(targetCreativeHistory.modes, targetCreativeDraft?.dishMode || '');
      const avoidedRecipeNames = [
        ...targetCreativeHistory.names,
        targetCreativeDraft?.name
      ].filter(Boolean);
      const avoidedDishModes = [
        ...targetCreativeHistory.modes,
        targetCreativeDraft?.dishMode
      ].filter(Boolean);
      targetCreativeStatus = 'loading';
      targetCreativeError = '';
      switchTab('recs'); // 立即反馈「正在想...」
      try {
        const draft = await withTimeout(callAiCreativeRecipeByIngredients({
          targets: targetNames,
          inventoryNames: (inv || []).map(x => x && x.name).filter(Boolean),
          localRecipeNames: localCards.map(c => c.name).filter(Boolean),
          preferredDishMode: nextMode.key,
          avoidedRecipeNames,
          avoidedDishModes
        }), 30000, 'AI 响应超时');
        targetCreativeDraft = draft;
        rememberTargetCreativeDraft(draft);
        targetCreativeStatus = 'success';
      } catch (err) {
        targetCreativeStatus = targetCreativeDraft ? 'success' : 'error';
        targetCreativeError = formatAiErrorMessage(err);
        showToast('AI 暂不可用', { tone: 'error' });
      }
      switchTab('recs');
    };
    return box;
  };

  const renderDishDraftBox = (query) => {
    const box = document.createElement('div');
    box.className = 'target-recipe-ai-box target-recipe-dish-ai';
    if (targetDishDraft && targetDishQuery === query) {
      const note = document.createElement('p');
      note.className = 'target-recipe-ai-note';
      note.innerHTML = '<span class="target-recipe-ai-mode">AI 草稿</span><span>确认后才会保存，不会自动加入今天。</span>';
      box.appendChild(note);
      const cardHost = document.createElement('div');
      cardHost.className = 'target-recipe-ai-card';
      cardHost.appendChild(renderAiRecipeDraftCard(targetDishDraft));
      box.appendChild(cardHost);
    } else {
      const empty = document.createElement('div');
      empty.className = 'target-recipe-fallback-head';
      empty.innerHTML = `
        <strong>没找到现有菜谱</strong>
        <span>可以先让 AI 生成一份可编辑草稿。</span>
      `;
      box.appendChild(empty);
    }

    const options = document.createElement('div');
    options.className = 'target-recipe-fallback-grid';
    options.innerHTML = `
      <article class="target-recipe-fallback-card">
        <span>
          <strong>AI 生成草稿</strong>
          <small>根据你的厨房和菜名生成一份可编辑草稿。</small>
        </span>
        <button type="button" class="wx-mini-btn is-ai target-recipe-ai-btn" id="targetDishAiBtn"${targetDishStatus === 'loading' ? ' disabled' : ''}>
          ${targetDishStatus === 'loading' ? '正在整理草稿...' : (targetDishDraft && targetDishQuery === query ? '重新生成 AI 草稿' : '生成 AI 草稿')}
        </button>
      </article>
    `;
    box.appendChild(options);
    if (targetDishError) {
      const err = document.createElement('div');
      err.className = 'small inline-status bad';
      err.textContent = targetDishError;
      box.appendChild(err);
    }

    const trigger = box.querySelector('#targetDishAiBtn');
    if (trigger) trigger.onclick = async () => {
      if (targetDishStatus === 'loading') return;
      targetDishStatus = 'loading';
      targetDishError = '';
      targetDishQuery = query;
      switchTab('recs');
      try {
        const invNames = (inv || []).map(x => x && x.name).filter(Boolean).join('、');
        targetDishDraft = await withTimeout(callAiSearchRecipe(query, invNames), 30000, 'AI 响应超时');
        targetDishQuery = query;
        targetDishStatus = 'success';
      } catch (err) {
        targetDishStatus = 'error';
        targetDishError = `${formatAiErrorMessage(err)} 可以换个菜名或先按食材推荐。`;
        showToast('AI 暂不可用', { tone: 'error' });
      }
      switchTab('recs');
    };
    return box;
  };

  const renderRecsTab = () => {
    const rawQuery = targetRecipeQuery.trim();
    const hasSearchQuery = !!rawQuery;
    const targetDescriptors = parseTargetRecipeQuery(targetRecipeQuery, inv);
    const targetNames = targetDescriptors.map(t => t.canonical);
    const nameMatches = hasSearchQuery
      ? perfMeasure(`findRecipesByName(${rawQuery})`, () => findRecipesByName(pack, rawQuery, {
          context: getRecommendationUiContext(),
          limit: 4
        }))
      : [];
    const targetKey = targetNames.join('|');
    if (targetNames.length) {
      // 同一面板内目标没变（如点 AI 按钮 / 来回切 tab 触发的重绘）→ 复用上次结果，
      // 不重扫全库；pack/inv 变化必经 onRoute 重建面板，缓存自然失效。
      const sameTarget = recsState && recsState.mode === 'target' && recsState.key === targetKey;
      const targetCards = sameTarget
        ? recsState.cards
        : perfMeasure(`findRecipesUsingIngredients(${targetKey})`, () => findRecipesUsingIngredients(pack, inv, targetNames, {
            context: getRecommendationUiContext(),
            limit: 6,
            targetDescriptors
          }));
      const prevIdx = sameTarget ? recsState.idx : 0;
      recsState = {
        mode: 'target',
        cards: targetCards,
        idx: Math.min(prevIdx, Math.max(0, targetCards.length - 1)),
        key: targetKey,
        targets: targetNames
      };
    } else if (hasSearchQuery) {
      recsState = { mode: 'search', cards: [], idx: 0, key: rawQuery };
    } else if (!recsState || recsState.mode === 'target') {
      recsState = initRecsState();
    }
    const { mode, cards, idx } = recsState;
    body.appendChild(renderTargetRecipeSearch(targetNames, cards.length, nameMatches.length));
    if (nameMatches.length) {
      body.appendChild(renderRecipeNameResults(nameMatches));
    }

    if (hasSearchQuery && !targetNames.length) {
      if (!nameMatches.length) body.appendChild(renderDishDraftBox(rawQuery));
      return;
    }

    const cardWrap = document.createElement('div');
    cardWrap.className = 'wx-rec-card';
    if (!cards.length && mode === 'target' && targetNames.length) {
      cardWrap.innerHTML = `
        <div class="wx-empty wx-rec-empty">
          <strong>还没找到同时用到这些食材的菜</strong>
          <span>可以少填一个食材试试，或者去菜谱库看看。</span>
          <small class="wx-help-text">也可以让 AI 先想一个草稿，确认后再保存。</small>
          <div class="wx-actions wx-empty-actions">
            <button type="button" class="wx-mini-btn" id="wxRecGoRecipes">去菜谱看看</button>
          </div>
        </div>
      `;
      cardWrap.querySelector('#wxRecGoRecipes').onclick = () => { location.hash = '#recipes'; };
    } else if (!cards.length) {
      cardWrap.innerHTML = `
        <div class="wx-empty wx-rec-empty">
          <strong>还没匹配到能直接做的菜</strong>
          <span>再记几样常见食材，比如鸡蛋、番茄、土豆、豆腐，就能开始推荐。</span>
          <small class="wx-help-text">推荐会优先看现有食材，缺的可以加入买菜。</small>
          <div class="wx-actions wx-empty-actions">
            <button type="button" class="wx-mini-btn" id="wxRecAddFood">继续记食材</button>
            <button type="button" class="wx-mini-btn" id="wxRecGoRecipes">去菜谱看看</button>
          </div>
        </div>
      `;
      cardWrap.querySelector('#wxRecAddFood').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
      cardWrap.querySelector('#wxRecGoRecipes').onclick = () => { location.hash = '#recipes'; };
    } else if (mode === 'ai') {
      showRecommendationCards(cardWrap, [cards[idx]], pack, { onRoute, onPreviewRecipe: openRecipePreviewModal });
    } else {
      cardWrap.appendChild(renderSuggestCard(cards[idx], pack, inv, { onPreviewRecipe: openRecipePreviewModal }));
    }
    bindRecommendationCycling(cardWrap);
    if (mode === 'target' && targetNames.length) {
      body.appendChild(renderTargetSectionTitle('按这些食材推荐', '继续从本地菜谱里找'));
    }
    body.appendChild(cardWrap);

    if (cards.length) {
      const guide = document.createElement('p');
      guide.className = 'wx-rec-guide';
      guide.textContent = '点“做这道”会加入今日计划，做完后可以顺手更新食材。';
      body.appendChild(guide);
    }

    if (cards.length > 1) {
      const hint = document.createElement('div');
      hint.className = 'wx-rec-hint';
      hint.innerHTML = `
        <span>${mode === 'target' ? '轻点 / 左右滑动看下一个本地菜' : '轻点 / 左右滑动换一道'}</span>
        <span class="wx-rec-dots" aria-hidden="true">
          ${cards.map((_, i) => `<span class="${i === idx ? 'is-active' : ''}"></span>`).join('')}
        </span>
      `;
      body.appendChild(hint);
    }

    if (mode === 'target' && cards.length) {
      const note = document.createElement('p');
      note.className = 'wx-rec-note target-recipe-summary';
      note.textContent = '本地菜谱匹配结果，不调用 AI。';
      body.appendChild(note);
    }
    // AI 创意做法入口：指定食材模式专属，本地结果（或空提示）之下，分层清楚。
    if (mode === 'target' && targetNames.length) {
      body.appendChild(renderTargetCreativeBox(targetNames, cards));
    }
    if (mode === 'ai' && cards.length) {
      const note = document.createElement('p');
      note.className = 'wx-rec-note';
      note.textContent = '推荐仅供参考，安排前可以再看一眼。';
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
      ${mode !== 'target' && cards.length > 1 ? '<button type="button" class="wx-mini-btn" id="wxRecNext">换一道 ›</button>' : ''}
      <button type="button" class="wx-mini-btn is-ai" id="wxRecAi">✨ 换几道</button>
    `;
    body.appendChild(foot);
    if (mode === 'target') foot.querySelector('#wxRecAi')?.remove();
    if (!foot.querySelector('button')) {
      foot.remove();
      return;
    }

    const nextBtn = foot.querySelector('#wxRecNext');
    if (nextBtn) nextBtn.onclick = () => stepRecommendation(1);
    const localBtn = foot.querySelector('#wxRecLocal');
    if (localBtn) localBtn.onclick = () => {
      localStorage.removeItem(S.keys.ai_recs);
      recsState = { mode: 'local', cards: getInspirationCached(), idx: 0 };
      switchTab('recs');
    };
    const aiTrigger = foot.querySelector('#wxRecAi');
    if (!aiTrigger) return;
    aiTrigger.onclick = async (e) => {
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
        setInlineStatus(aiStatus, '暂时没有返回可用菜谱，已保留本地推荐。', 'info');
      } catch (err) {
        clearTimeout(safety);
        setInlineStatus(aiStatus, formatAiErrorMessage(err), 'bad');
        showToast('AI 暂不可用', { tone: 'error' });
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
    perfMeasure(`wx-switchTab:${tab}`, () => TAB_RENDERERS[tab]());
  };
  section.querySelectorAll('.wx-tab').forEach(t => { t.onclick = () => switchTab(t.dataset.tab); });

  // 默认 tab：优先回答“今天能做什么”；手动切过 tab 时仍尊重 lastWxTab。
  const defaultRecCount = getInspirationCached().length;
  const defaultPlanCount = getTodayPlanCount();
  const defaultTab = defaultRecCount > 0 ? 'recs' : (defaultPlanCount > 0 ? 'plan' : 'plan');
  switchTab(lastWxTab || defaultTab);

  return { el: section, refresh: () => switchTab(lastWxTab || defaultTab) };
}

// 「明天备菜」提醒已融入计划组件（menu-plan.js：顶部 menu-prep-alert + 行内 menu-prep-tags），
// 首页不再渲染独立大卡片；prep-planner 工具与 S.keys.prep_done 保留（后续可做「已解冻」状态）。

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
  //                    ② 单一 glass 主面板（计划/到期/待买/推荐 tab 切换；
  //                       计划 tab 内含「今晚提前准备」提醒与行内标签）
  //                    ③ 两个轻量胶囊快捷入口。
  // 一次渲染只跑一遍全库本地推荐：状态区计数与主面板（默认 tab / 推荐 tab）共用同一份结果。
  const inspirationCards = perfMeasure('getInspirationCards(home)', () => getInspirationCards(pack, inv));
  const summaryStats = getTodaySummaryStats(pack, inv, { inspirationCards });
  container.appendChild(renderWxStatus(summaryStats));
  const panel = perfMeasure('createWeatherPanel', () => createWeatherPanel(pack, inv, { onRoute, inspirationCards }));
  container.appendChild(panel.el);
  container.appendChild(renderQuickActions(pack, inv, { onRoute, refreshStatus: panel.refresh }));

  return container;
}
