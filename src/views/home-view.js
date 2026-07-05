import { S, todayISO } from '../storage.js?v=231';
import { buildCatalog, getCanonicalName, explodeCombinedItems, guessKitchenUnit } from '../ingredients.js?v=231';
import { isInventoryAvailable, loadInventory, remainingDays, saveInventory } from '../inventory.js?v=231';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=231';
import {
  addMissingRecipeIngredientsToShopping,
  findRecipesByName, findRecipesUsingIngredients, hasRecipeMethod, rankRecipesForRecommendation,
  getCleanFridgeRecommendations, getGenericIngredientRecipeRecommendations, getRecipeVariantRecommendations, processAiData,
  isFavoriteRecipe, toggleFavoriteRecipe
} from '../recommendations.js?v=231';
import { addRecipeToPlanWithMissingCheck, getPlanMissingItems } from '../components/plan-missing-check.js?v=231';
import { callAiCreativeRecipeByIngredients, callAiSearchRecipe, callCloudAI, formatAiErrorMessage, getCreativeDishModeLabel, getReceiptAiFailureCopy, pickNextCreativeDishMode, recognizeReceipt, withTimeout } from '../ai.js?v=231';
import { escapeHtml, escapeOptionAttr, brieflyConfirmButton, setActionStatus, setInlineStatus, showToast } from '../components/status.js?v=231';
import { showRecommendationCards } from '../components/recipe-card.js?v=231';
import { parseTargetIngredients } from '../utils/ingredient-intent.js?v=231';
import { perfMeasure } from '../utils/perf.js?v=231';
import { showCleanFridgeModal, showReceiptConfirmationModal, showQuickShoppingModal, showPendingShoppingModal } from '../components/modal.js?v=231';
import { renderMenuPlan, renderCookAllButton } from '../components/menu-plan.js?v=231';
import { parseFoodLines } from '../utils/food-input-parser.js?v=231';
import { classifyRecipeIngredient, splitRecipeIngredients } from '../utils/recipe-sanitizer.js?v=231';
import { splitMethodSteps } from '../utils/method-steps.js?v=231';
import { openRecipeImportModal } from '../components/recipe-import-modal.js?v=231';
import { createUserRecipe } from '../components/recipe-create-modal.js?v=231';
import { getHomeTab, setHomeTab, getTodayPlanCount } from './home/home-tab-state.js?v=231';
import { enterDemoKitchen, isDemoKitchenMode, markDemoPlanAdded, renderDemoKitchenBanner, syncDemoStepFromTab } from './home/demo-kitchen.js?v=231';
import { openCookedMealModal } from './home/cooked-meal-modal.js?v=231';
import { renderBackupNudge, renderPwaInstallNudge } from './home/home-nudges.js?v=231';
import { writeItemsToInventory, writeReceiptPantryItems } from '../utils/inventory-write.js?v=231';
import { loadOverlay, saveOverlay } from '../backup.js?v=231';

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
    onAddPlan: async (id, btn) => {
      const recItem = recs.find(item => item.r.id === id);
      const result = await addRecipeToPlanWithMissingCheck(id, pack, inv, {
        recipe: recItem?.r,
        fallbackItems: recItem?.list,
        missing: recItem?.missing,
        source: isDemoKitchenMode() ? 'demo' : 'clean-fridge',
        onPlanAdded: markDemoPlanAdded
      });
      brieflyConfirmButton(btn, result.added ? '已加入' : '已在今天');
      onRoute();
    },
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
  const variants = getRecipeVariantRecommendations(pack, inv, { limit: Math.max(0, 3 - cards.length) });
  for (const variant of variants) {
    if (cards.length >= 3) break;
    cards.push({
      ...variant,
      id: variant.id,
      name: variant.name,
      matchLabel: variant.matchLabel || '变化菜',
      reason: variant.reason || '',
      tone: 'variant',
      variant,
      isVariant: true
    });
  }
  const genericTemplates = getGenericIngredientRecipeRecommendations(pack, inv, {
    limit: Math.max(0, 3 - cards.length),
    existingNames: cards.map(card => card.name)
  });
  for (const item of genericTemplates) {
    if (cards.length >= 3) break;
    cards.push({
      ...item,
      id: item.id,
      name: item.name,
      matchLabel: item.matchLabel || '简单做法',
      reason: item.reason || '',
      tone: 'generic',
      variant: item,
      isGenericTemplate: true
    });
  }
  return cards;
}

function formatMissingSummary(missing = []) {
  const items = Array.from(new Set((missing || []).map(item => String(item || '').trim()).filter(Boolean)));
  if (!items.length) return '';
  if (items.length === 1) return `只差 1 样：${items[0]}`;
  const shown = items.slice(0, 3).join('、');
  return `还缺 ${items.length} 样：${shown}${items.length > 3 ? '等' : ''}`;
}

function getSuggestTags(card, missing = []) {
  const tags = [];
  const add = value => {
    const text = String(value || '').trim();
    if (text && !tags.includes(text)) tags.push(text);
  };
  if (/^用到\s*\d+\s*\/\s*\d+/.test(String(card.matchLabel || ''))) add(card.matchLabel);
  if (missing.length) add(missing.length === 1 ? '还缺 1 样' : `还缺 ${missing.length} 样`);
  else if (card.tone === 'ready') add('食材齐');
  if (card.tone === 'priority') add('用掉临期');
  if (card.tone === 'variant') add('变化菜');
  if (card.tone === 'generic') add('快手');
  if (!tags.length && card.matchLabel && !/^只差|^还缺/.test(card.matchLabel)) add(card.matchLabel);
  return tags.slice(0, 2);
}

function getSuggestKickerLabel(card) {
  if (card.tone === 'priority') return '优先推荐';
  if (card.tone === 'variant') return '变化菜';
  if (card.tone === 'generic') return '快手灵感';
  return '今日推荐';
}

// ── Section 1: AI 灵感面板（Hero 胶囊） ───────────────────────────────────────
function renderSuggestCard(card, pack, inv, { onPreviewRecipe = null, onPreviewVariant = null, onRoute = null, onMoreRecommendation = null } = {}) {
  const el = document.createElement('article');
  el.className = `home-suggest-card tone-${card.tone || 'idea'}`;
  const variant = card.variant || (card.isVariant ? card : null);
  const previewRecipe = card.row?.r || card.r || card.recipe || null;
  const canPreviewVariant = Boolean(variant && typeof onPreviewVariant === 'function');
  const canPreview = canPreviewVariant || Boolean(card.id && previewRecipe && typeof onPreviewRecipe === 'function' && !String(card.id).startsWith('creative-'));
  const sourceText = variant?.sourceLabel ? `<small class="home-suggest-source">${escapeHtml(variant.sourceLabel)}</small>` : '';
  const missing = Array.from(new Set((card.missing || []).map(item => String(item || '').trim()).filter(Boolean)));
  const targetHits = Array.from(new Set([
    ...(card.targetHits || []),
    ...(card.targetMatchedNames || [])
  ].map(item => String(item || '').trim()).filter(Boolean)));
  const missingSummary = missing.length ? (missing.length === 1 ? '还缺 1 样' : `还缺 ${missing.length} 样`) : '';
  const missingNames = missing.slice(0, 4).join('、');
  const detailLines = [
    targetHits.length ? `用到：${targetHits.slice(0, 4).join('、')}${targetHits.length > 4 ? '等' : ''}` : '',
    missingNames ? `还缺：${missingNames}${missing.length > 4 ? '等' : ''}` : ''
  ].filter(Boolean);
  const tags = getSuggestTags(card, missing);
  const reason = card.reason || missingSummary || (card.tone === 'ready' ? '食材基本齐，可以直接做' : '');
  const kickerLabel = getSuggestKickerLabel(card);
  el.innerHTML = `
    <div class="home-suggest-kicker">
      <span class="home-suggest-match">${escapeHtml(kickerLabel)}</span>
      ${sourceText}
    </div>
    <h3 class="home-suggest-name">${escapeHtml(card.name)}</h3>
    <p class="home-suggest-reason">${escapeHtml(reason)}</p>
    ${detailLines.length ? `<div class="home-suggest-details">${detailLines.map(line => `<span>${escapeHtml(line)}</span>`).join('')}</div>` : ''}
    <div class="home-suggest-tags">
      ${tags.map(tag => `<span>${escapeHtml(tag)}</span>`).join('')}
    </div>
    <div class="home-suggest-actions">
      <button type="button" class="btn ok small home-suggest-cook">加入计划</button>
      ${canPreview ? '<button type="button" class="btn small home-suggest-preview">查看</button>' : ''}
      ${missing.length && card.row ? '<button type="button" class="btn small home-suggest-shopping">补到买菜</button>' : ''}
      ${typeof onMoreRecommendation === 'function' ? '<button type="button" class="btn small home-suggest-more" aria-label="更多操作" title="更多操作">⋯</button>' : ''}
    </div>
    <div class="home-suggest-feedback" hidden></div>
  `;
  const cookBtn = el.querySelector('.home-suggest-cook');
  const shoppingBtn = el.querySelector('.home-suggest-shopping');
  const previewBtn = el.querySelector('.home-suggest-preview');
  const moreBtn = el.querySelector('.home-suggest-more');
  const feedback = el.querySelector('.home-suggest-feedback');
  const openPreview = (event) => {
    event?.preventDefault();
    event?.stopPropagation();
    if (canPreviewVariant) {
      onPreviewVariant(variant);
      return;
    }
    if (canPreview) onPreviewRecipe(previewRecipe);
  };
  const showPlanFeedback = (text) => {
    feedback.hidden = false;
    feedback.innerHTML = `<span>${escapeHtml(text)}</span><button type="button" class="home-suggest-go-plan">去今日看看</button>`;
    feedback.querySelector('.home-suggest-go-plan').onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      setHomeTab('plan');
      if (typeof onRoute === 'function') {
        onRoute();
        return;
      }
      const planTab = document.querySelector('.wx-tab[data-tab="plan"]');
      if ((location.hash === '#today' || !location.hash) && planTab) {
        planTab.click();
      } else {
        location.hash = '#today';
      }
    };
  };
  cookBtn.onclick = async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (variant) {
      onPreviewVariant?.(variant, { confirmPlan: true });
      return;
    }
    if (!card.id) { brieflyConfirmButton(cookBtn, '示例'); return; }
    const result = await addRecipeToPlanWithMissingCheck(card.id, pack, inv, {
      recipe: card.row?.r || previewRecipe,
      fallbackItems: card.row?.list,
      missing: card.row?.missing,
      source: isDemoKitchenMode() ? 'demo' : 'recommendation',
      onPlanAdded: markDemoPlanAdded
    });
    brieflyConfirmButton(cookBtn, result.added ? '已加入今天' : '已在今天');
    const firstPlanGuide = consumeFirstPlanGuideMessage(result.added);
    showFirstPlanGuideToast(firstPlanGuide);
    const successMessage = result.missing.length
      ? (result.shoppingAddedCount ? '已加入计划，缺的食材已加入买菜清单。' : '已加入计划，缺的食材可稍后处理。')
      : '已加入今天，做完后会帮你更新食材。';
    showPlanFeedback(result.added
      ? (result.missing.length ? successMessage : (firstPlanGuide || successMessage))
      : '今天已经安排了这道菜。');
  };
  if (previewBtn) previewBtn.onclick = openPreview;
  if (moreBtn) {
    moreBtn.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      onMoreRecommendation(card);
    };
  }
  if (shoppingBtn) {
    shoppingBtn.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      const count = addMissingRecipeIngredientsToShopping(card.row.r, pack, inv, card.row.list);
      if (count) showToast('已加入买菜清单', { tone: 'success' });
      brieflyConfirmButton(shoppingBtn, count ? '已加入买菜' : '已齐');
    };
  }
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

  const eyebrow = extraNode ? '📅 计划' : '🧠 今日灵感';

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
    showRecommendationCards(scroll, (aiCards || []).slice(0, 4), pack, { onRoute, inv });
    note.hidden = false;
    note.innerHTML = '<button type="button" class="home-note-clear" id="heroAiClear">用本地推荐</button>';
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

function formatWeeklySuggestionMeta(item) {
  const used = getWeeklyMatchedNames(item.row);
  const missing = getWeeklyMissingNames(item.row);
  if (used.length) return `用到：${used.join('、')}`;
  if (!missing.length) return '食材基本齐';
  return '适合加入本周菜单';
}

function formatWeeklySuggestionMissing(item) {
  const missing = getWeeklyMissingNames(item.row);
  if (!missing.length) return '食材基本齐';
  return `还缺：${missing.join('、')}${(item.row?.missing || []).length > missing.length ? '等' : ''}`;
}

function renderWeeklyMenuSuggestions(suggestions, addedIds = new Set(), { hasGenerated = false } = {}) {
  if (!hasGenerated) {
    return '';
  }
  if (!suggestions.length) {
    return `
      <div class="weekly-menu-results">
        <h4>建议本周做</h4>
        <p class="weekly-menu-empty">暂时没有合适建议</p>
        <div class="weekly-menu-results-actions">
          <button type="button" class="btn weekly-menu-fill-shopping">补齐待买</button>
        </div>
      </div>
    `;
  }
  return `
    <div class="weekly-menu-results">
      <h4>建议本周做</h4>
      <div class="weekly-menu-suggestion-list">
        ${suggestions.map(({ recipe, row }) => {
          const added = addedIds.has(recipe.id);
          return `
            <article class="weekly-menu-suggestion" data-recipe-id="${escapeOptionAttr(recipe.id)}">
              <div class="weekly-menu-suggestion-main">
                <strong>${escapeHtml(recipe.name)}</strong>
                <span>${escapeHtml(formatWeeklySuggestionMeta({ recipe, row }))}</span>
                <small>${escapeHtml(formatWeeklySuggestionMissing({ recipe, row }))}</small>
              </div>
              <div class="weekly-menu-suggestion-actions">
                <button type="button" class="btn small weekly-menu-add" data-action="add"${added ? ' disabled' : ''}>${added ? '已加入' : '加入计划'}</button>
                <button type="button" class="btn small weekly-menu-view" data-action="view">查看</button>
              </div>
            </article>
          `;
        }).join('')}
      </div>
      <div class="weekly-menu-results-actions">
        <button type="button" class="btn weekly-menu-fill-shopping">补齐待买</button>
      </div>
    </div>
  `;
}

function openWeeklyMenuModal(pack, inv, { onRoute = () => {} } = {}) {
  const content = document.createElement('div');
  content.className = 'km-modal-body weekly-menu-modal';
  let closeWeeklyModal = () => {};
  let mealCount = 4;
  let priorities = {
    expiring: true,
    inventory: true,
    quick: false,
    lunchbox: false
  };
  let suggestions = [];
  let hasGeneratedSuggestions = false;
  const addedIds = new Set(getWeeklyPlanItems(pack).map(item => item.id));
  const render = () => {
    content.innerHTML = `
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">这周打算在家做几顿？</p>
        <div class="weekly-menu-options" role="group" aria-label="选择本周做饭顿数">
          ${[3, 4, 5].map(value => `
            <button type="button" class="weekly-menu-option${mealCount === value ? ' is-active' : ''}" data-meal-count="${value}">${value} 顿</button>
          `).join('')}
        </div>
      </section>
      <section class="weekly-menu-section">
        <p class="weekly-menu-question">优先考虑</p>
        <div class="weekly-menu-checks">
          ${[
            ['expiring', '用掉临期'],
            ['inventory', '利用现有食材'],
            ['quick', '快手菜'],
            ['lunchbox', '适合带饭']
          ].map(([key, label]) => `
            <label class="weekly-menu-check${priorities[key] ? ' is-active' : ''}">
              <input type="checkbox" value="${key}"${priorities[key] ? ' checked' : ''}>
              <span>${priorities[key] ? '✓ ' : ''}${label}</span>
            </label>
          `).join('')}
        </div>
      </section>
      <div class="weekly-menu-generate-row">
        <button type="button" class="btn ok weekly-menu-generate">生成建议</button>
      </div>
      ${renderWeeklyMenuSuggestions(suggestions, addedIds, { hasGenerated: hasGeneratedSuggestions })}
    `;
    content.querySelectorAll('[data-meal-count]').forEach(btn => {
      btn.onclick = () => {
        mealCount = Number(btn.dataset.mealCount) || 4;
        hasGeneratedSuggestions = false;
        suggestions = [];
        render();
      };
    });
    content.querySelectorAll('.weekly-menu-check input').forEach(input => {
      input.onchange = () => {
        priorities = { ...priorities, [input.value]: input.checked };
        input.closest('.weekly-menu-check')?.classList.toggle('is-active', input.checked);
        const label = input.closest('.weekly-menu-check')?.querySelector('span');
        if (label) label.textContent = `${input.checked ? '✓ ' : ''}${label.textContent.replace(/^✓\s*/, '')}`;
      };
    });
    content.querySelector('.weekly-menu-generate').onclick = () => {
      suggestions = buildWeeklyMenuSuggestions(pack, inv, { mealCount, priorities });
      hasGeneratedSuggestions = true;
      render();
    };
    const fillShoppingBtn = content.querySelector('.weekly-menu-fill-shopping');
    if (fillShoppingBtn) {
      fillShoppingBtn.onclick = () => {
        showWeeklyShoppingResult(addWeeklyPlanShortagesToShopping(pack, inv), { onRoute });
      };
    }
    content.querySelectorAll('.weekly-menu-suggestion [data-action]').forEach(btn => {
      btn.onclick = async () => {
        const row = btn.closest('.weekly-menu-suggestion');
        const recipeId = row?.dataset.recipeId || '';
        const item = suggestions.find(entry => entry.recipe.id === recipeId);
        if (!item) return;
        if (btn.dataset.action === 'view') {
          closeWeeklyModal();
          location.hash = `#recipe:${recipeId}`;
          return;
        }
        btn.disabled = true;
        const result = await addRecipeToPlanWithMissingCheck(recipeId, pack, inv, {
          recipe: item.recipe,
          fallbackItems: item.row?.list,
          missing: item.row?.missing,
          source: isDemoKitchenMode() ? 'demo' : 'weekly-menu',
          onPlanAdded: markDemoPlanAdded
        });
        if (result.added) addedIds.add(recipeId);
        brieflyConfirmButton(btn, result.added ? '已加入' : '已在计划');
        onRoute();
        render();
      };
    });
  };
  render();
  const modal = createHomeModal(content, '本周菜单');
  modal.overlay.querySelector('.km-modal-content')?.classList.add('weekly-menu-sheet');
  closeWeeklyModal = modal.close;
}

function renderWeeklyMenuCard(pack, inv, { onRoute = () => {} } = {}) {
  const summary = getWeeklyMenuSummary(pack);
  const card = document.createElement('section');
  card.className = 'weekly-menu-card';
  card.innerHTML = `
    <div class="weekly-menu-card-copy">
      <strong>本周菜单</strong>
      <span>${escapeHtml(summary.label)}</span>
    </div>
    <div class="weekly-menu-card-actions">
      <button type="button" class="wx-mini-btn is-primary weekly-menu-plan-btn">规划本周</button>
      <button type="button" class="wx-mini-btn weekly-menu-shopping-btn">补齐待买</button>
    </div>
  `;
  card.querySelector('.weekly-menu-plan-btn').onclick = () => openWeeklyMenuModal(pack, inv, { onRoute });
  card.querySelector('.weekly-menu-shopping-btn').onclick = () => {
    showWeeklyShoppingResult(addWeeklyPlanShortagesToShopping(pack, inv), { onRoute });
  };
  return card;
}

// ── 弹窗内容构建 ─────────────────────────────────────────────────────────────

/** 「临期食材」弹窗：列出快到期 / 已过期食材，并提供做菜、标记用完入口。 */
function buildExpiryModal(inv, pack, { onClose = () => {}, onUseIngredient = () => {}, onViewInventory = () => {}, onChange = () => {} } = {}) {
  const expiring = (inv || [])
    .filter(it => isExpiryTracked(it) && remainingDays(it) <= 3)
    .sort((a, b) => remainingDays(a) - remainingDays(b));

  const wrap = document.createElement('div');
  wrap.className = 'km-modal-body';

  if (!expiring.length) {
    wrap.innerHTML = '<p class="km-modal-empty">最近没有临期食材</p>';
    const footer = document.createElement('div');
    footer.className = 'km-modal-actions';
    footer.innerHTML = '<button type="button" class="btn" id="expiryCloseBtn">关闭</button><button type="button" class="btn ok" id="expiryViewInventoryBtn">查看全部食材</button>';
    footer.querySelector('#expiryCloseBtn').onclick = onClose;
    footer.querySelector('#expiryViewInventoryBtn').onclick = onViewInventory;
    wrap.appendChild(footer);
    return wrap;
  }

  const list = document.createElement('ul');
  list.className = 'km-expiry-list';
  expiring.forEach(it => {
    const d = remainingDays(it);
    const li = document.createElement('li');
    li.className = `km-expiry-item${d < 0 ? ' is-expired' : d <= 1 ? ' is-urgent' : ''}`;
    const dayText = d < 0 ? `已过期 ${Math.abs(d)} 天` : d === 0 ? '今天到期' : d === 1 ? '明天到期' : `${d} 天后到期`;
    const qty = (+it.qty > 0) ? `${escapeHtml(String(it.qty))}${escapeHtml(it.unit || '')}` : '';
    li.innerHTML = `
      <span class="km-expiry-main">
        <span class="km-expiry-name">${escapeHtml(it.name)}</span>
        ${qty ? `<span class="km-expiry-qty">${qty}</span>` : ''}
      </span>
      <span class="km-expiry-days">${dayText}</span>
      <span class="km-expiry-actions">
        <button type="button" class="btn small km-expiry-use">用它做菜</button>
        <button type="button" class="btn small km-expiry-done">标记用完</button>
      </span>
    `;
    li.querySelector('.km-expiry-use').onclick = () => onUseIngredient(it);
    li.querySelector('.km-expiry-done').onclick = (e) => {
      it.qty = 0;
      it.stockStatus = 'empty';
      saveInventory(inv);
      showToast('已标记用完', { tone: 'success' });
      e.currentTarget.textContent = '已用完';
      e.currentTarget.disabled = true;
      onChange();
    };
    list.appendChild(li);
  });
  wrap.appendChild(list);

  const footer = document.createElement('div');
  footer.className = 'km-modal-actions';
  footer.innerHTML = '<button type="button" class="btn" id="expiryCloseBtn">关闭</button><button type="button" class="btn ok" id="expiryViewInventoryBtn">查看全部食材</button>';
  footer.querySelector('#expiryCloseBtn').onclick = onClose;
  footer.querySelector('#expiryViewInventoryBtn').onclick = onViewInventory;
  wrap.appendChild(footer);

  return wrap;
}

// 打开「到期食材」弹窗。
function openExpiryListModal(inv, pack, { onRoute = () => {}, onChange = () => {} } = {}) {
  let closeFn = () => {};
  const body = buildExpiryModal(inv, pack, {
    onClose: () => closeFn(),
    onUseIngredient: (item) => {
      closeFn();
      targetRecipeQuery = item?.name || '';
      setHomeTab('recs');
      onRoute();
    },
    onViewInventory: () => {
      closeFn();
      location.hash = '#inventory';
    },
    onChange
  });
  const { close } = createHomeModal(body, '临期食材');
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


// ── 空库存引导：先让新用户用生活化的入口完成第一步，而不是跳去别的页面。 ─────
function renderOnboarding(pack, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-hero is-onboarding';
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <span class="home-hero-eyebrow">🍳 先看今天能吃什么</span>
      <h2 class="home-hero-greeting">今天不知道吃什么？</h2>
      <p class="home-hero-note">先用一个示例厨房体验一次：看推荐、安排计划、做完后更新库存。</p>
    </div>
    <div class="home-actions-grid home-onboarding-actions">
      <button type="button" class="home-act-btn home-onboarding-demo is-primary" id="obDemo"><span class="home-act-emoji">🍳</span><span class="home-act-copy"><span>开始示例体验</span><small>先走一遍完整流程</small></span></button>
      <button type="button" class="home-act-btn home-onboarding-manual" id="obManual"><span class="home-act-emoji">✍️</span><span class="home-act-copy"><span>记录我的食材</span><small>先写 3 到 5 样就行</small></span></button>
    </div>
    <div class="home-onboarding-link-row">
      <button type="button" class="home-onboarding-link" id="obRecipes">先逛菜谱</button>
    </div>
  `;
  section.querySelector('#obManual').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
  section.querySelector('#obDemo').onclick = () => enterDemoKitchen(pack, { onRoute });
  section.querySelector('#obRecipes').onclick = () => { location.hash = '#recipes'; };
  return section;
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

    <div class="km-modal-actions batch-input-actions">
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
      const copy = getReceiptAiFailureCopy(err);
      setActionStatus(receiptStatus, {
        title: copy.title,
        message: copy.message,
        primaryText: '改用文本批量记',
        secondaryText: '重新选择图片',
        onPrimary: () => {
          setTab('text');
          overlay.querySelector('#batchTextInput')?.focus();
        },
        onSecondary: () => receiptFileInput.click()
      });
      showToast('小票识别暂时不可用', { tone: 'warning' });
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
      statusEl.textContent = `已记录 ${n} 样食材，看看今天能做什么。`;
      setHomeTab('recs');
      setPostInventoryGuide(n);
      showToast(`已记录 ${n} 样食材，看看今天能做什么。`, { tone: 'success' });
      setTimeout(() => { close(); onRoute(); }, 600);
    } else {
      statusEl.hidden = false;
      statusEl.className = 'small inline-status bad';
      statusEl.textContent = '没能加入厨房：这些内容还没识别成食材。';
    }
  };
}


// ══════════════════════════════════════════════════════════════════════════
//  「今日」决策页：用户打开即知「今天吃什么 / 优先用掉什么 / 计划是什么 / 缺什么」。
//  全部复用既有数据逻辑（getTodayDecisionGroups / getInspirationCards /
//  getExpiringItems / renderSuggestCard / renderMenuPlan / openCleanFridgeHelper…），
//  本段只负责信息层级与 UI 组装，不重写推荐算法。
// ══════════════════════════════════════════════════════════════════════════

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
    showRecommendationCards(grid, list, pack, { onRoute, inv });
    note.hidden = false;
    note.innerHTML = '<button type="button" class="home-note-clear" id="todayAiClear">用本地推荐</button>';
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

  // 头部：今日计划标题 + 轻动作组
  const head = document.createElement('div');
  head.className = 'today-section-head today-main-head';
  head.innerHTML = '<h2 class="today-section-title">📅 计划</h2>';
  const actions = document.createElement('div');
  actions.className = 'menu-plan-head-actions';
  actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
  head.appendChild(actions);
  card.appendChild(head);

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

// ③ 快捷操作区（两个轻量入口）：记食材 + 导入菜谱。临期/待买详情从顶部状态进入。
function renderQuickActions(pack, inv, { onRoute = () => {}, refreshStatus = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'today-section today-quick';
  section.innerHTML = `
    <div class="today-quick-row">
      <button type="button" class="today-quick-btn is-primary" id="qaStock">
        <span class="tq-emoji">📦</span>
        <span class="tq-copy"><strong>记食材</strong><small>记录冰箱食材</small></span>
      </button>
      <button type="button" class="today-quick-btn" id="qaRecipeImport">
        <span class="tq-emoji">📖</span>
        <span class="tq-copy"><strong>导入菜谱</strong><small>粘贴链接识别</small></span>
      </button>
    </div>
  `;
  // 记食材：直接打开现有「记进厨房」弹窗（📸 拍小票识别 + ✍️ 文本批量记）。
  section.querySelector('#qaStock').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
  section.querySelector('#qaRecipeImport').onclick = () => openRecipeImportModal();
  return section;
}


// ══════════════════════════════════════════════════════════════════════════
//  Today 首页：顶部状态负责临期 / 待买提醒；主面板只负责计划 / 推荐。
//  临期和待买详情通过顶部弹窗查看，不再占用主面板 tab。
//  全部复用既有数据与弹窗函数，不新增推荐算法 / 持久化状态 / localStorage key。
// ══════════════════════════════════════════════════════════════════════════


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

function getGreetingLabel() {
  const h = new Date().getHours();
  if (h < 5) return '🌙 夜深了';
  if (h < 11) return '👋 早上好';
  if (h < 14) return '👋 中午好';
  if (h < 18) return '👋 下午好';
  return '🌆 晚上好';
}

function getTodayPlanItems(pack) {
  const today = todayISO();
  const recipes = pack.recipes || [];
  return S.load(S.keys.plan, [])
    .filter(item => item && (item.date || today) === today && !item.isCooked)
    .map(item => ({
      ...item,
      recipe: recipes.find(recipe => recipe.id === item.id) || null
    }))
    .filter(item => item.recipe);
}

function addDaysISO(baseIso, offset = 0) {
  const base = new Date(baseIso);
  base.setDate(base.getDate() + offset);
  return base.toISOString().slice(0, 10);
}

function getWeeklyPlanItems(pack, { days = 7 } = {}) {
  const today = todayISO();
  const end = addDaysISO(today, Math.max(0, days - 1));
  const recipes = pack.recipes || [];
  return S.load(S.keys.plan, [])
    .filter(item => {
      if (!item || item.isCooked) return false;
      const date = item.date || today;
      return date >= today && date <= end;
    })
    .map(item => ({
      ...item,
      date: item.date || today,
      recipe: recipes.find(recipe => recipe.id === item.id) || null
    }))
    .filter(item => item.recipe);
}

function getWeeklyMenuSummary(pack) {
  const plannedCount = getWeeklyPlanItems(pack).length;
  const targetCount = 4;
  return {
    plannedCount,
    targetCount,
    missingCount: Math.max(0, targetCount - plannedCount),
    label: plannedCount >= targetCount
      ? '本周已基本安排好'
      : plannedCount === 0
        ? '买菜前先规划几顿'
        : `已安排 ${plannedCount} 顿 · 还缺 ${Math.max(0, targetCount - plannedCount)} 顿`
  };
}

function getWeeklyMatchedNames(row, limit = 3) {
  return Array.from(new Set((row?.matches || [])
    .map(item => String(item?.inventoryItem || item?.recipeItem || '').trim())
    .filter(Boolean)))
    .slice(0, limit);
}

function getWeeklyMissingNames(row, limit = 3) {
  return Array.from(new Set((row?.missing || [])
    .map(item => String(item?.name || item?.item || '').trim())
    .filter(Boolean)))
    .slice(0, limit);
}

function isQuickWeeklyRecipe(recipe) {
  const text = [
    recipe?.name,
    ...(recipe?.tags || []),
    recipe?.difficulty,
    recipe?.method
  ].join(' ');
  const minutes = Number(recipe?.timeMinutes || recipe?.time_minutes || recipe?.time);
  return (Number.isFinite(minutes) && minutes <= 25) || /快手|简单|easy|quick|15|20|分钟/.test(text);
}

function isLunchboxWeeklyRecipe(recipe) {
  const text = [
    recipe?.name,
    ...(recipe?.tags || []),
    recipe?.method
  ].join(' ');
  return /便当|带饭|饭盒|盖饭|炒饭|焖饭|饭/.test(text);
}

function buildWeeklyMenuSuggestions(pack, inv, {
  mealCount = 4,
  priorities = {}
} = {}) {
  const plannedIds = new Set(getWeeklyPlanItems(pack).map(item => item.id));
  const ranked = rankRecipesForRecommendation(pack, inv, {
    ...getRecommendationUiContext(),
    includeNoMatch: true
  }).filter(row => row?.r && hasRecipeMethod(row.r));
  const pool = ranked.filter(row => !plannedIds.has(row.r.id));
  const rows = pool.length ? pool : ranked;
  return rows
    .map((row, index) => {
      const recipe = row.r;
      let score = row.score - index * 0.2;
      if (priorities.expiring) score += (row.expiringMatches || []).length * 42;
      if (priorities.inventory) score += (row.coverage || 0) * 24 + (row.matchCount || 0) * 4 - (row.missing || []).length * 5;
      if (priorities.quick && isQuickWeeklyRecipe(recipe)) score += 16;
      if (priorities.lunchbox && isLunchboxWeeklyRecipe(recipe)) score += 12;
      if (row.isFavorite) score += 10;
      return { recipe, row, score };
    })
    .sort((a, b) =>
      b.score - a.score ||
      (b.row.matchCount || 0) - (a.row.matchCount || 0) ||
      (a.row.missing || []).length - (b.row.missing || []).length ||
      a.recipe.name.localeCompare(b.recipe.name, 'zh-Hans-CN')
    )
    .slice(0, Math.max(3, Math.min(5, mealCount)));
}

function addWeeklyPlanShortagesToShopping(pack, inv) {
  const existing = new Set(loadShoppingItems()
    .filter(item => item && !item.done)
    .map(item => getCanonicalName(item.name || ''))
    .filter(Boolean));
  const seen = new Set(existing);
  let added = 0;
  let skippedExisting = 0;
  const planItems = getWeeklyPlanItems(pack);
  for (const item of planItems) {
    const recipe = item.recipe;
    const missing = getPlanMissingItems(recipe, pack, inv);
    for (const miss of missing) {
      const name = String(miss.name || miss.item || '').trim();
      const canonical = getCanonicalName(name);
      if (!canonical) continue;
      if (seen.has(canonical)) {
        skippedExisting += 1;
        continue;
      }
      seen.add(canonical);
      addShoppingItem(
        name,
        miss.qty || '',
        miss.unit || guessKitchenUnit(name) || '',
        '本周菜单缺货',
        `菜谱缺货：${recipe.name || '本周菜单'}`
      );
      added += 1;
    }
  }
  return { added, skippedExisting, planCount: planItems.length };
}

function showWeeklyShoppingResult(result, { onRoute = () => {} } = {}) {
  if (result.added > 0) {
    showToast(`已补 ${result.added} 样待买`, { tone: 'success' });
    onRoute();
    return;
  }
  if (!result.planCount) {
    showToast('先规划几顿，再补齐待买', { tone: 'info' });
    return;
  }
  showToast(result.skippedExisting ? '待买清单已包含这些食材' : '本周菜单暂不缺核心食材', { tone: 'info' });
}

function getPrimaryRecommendationCard(cards = []) {
  return (cards || []).find(card =>
    card && card.id && card.row?.r && !card.isVariant && !card.isGenericTemplate && !String(card.id).startsWith('creative-')
  ) || null;
}

function formatExpiryLabel(days) {
  if (days < 0) return `已过期 ${Math.abs(days)} 天`;
  if (days === 0) return '今天到期';
  if (days === 1) return '明天过期';
  return `${days} 天后过期`;
}

function getRecipeItemsPreview(pack, recipeId, limit = 2) {
  return explodeCombinedItems((pack.recipe_ingredients || {})[recipeId] || [])
    .filter(item => item && item.item && classifyRecipeIngredient(item.item).role === 'core')
    .map(item => item.item)
    .slice(0, limit);
}

function normalizeTodayFocusCard(card, pack) {
  if (!card) return null;
  const recipe = card.row?.r || card.r || card.recipe || (card.id ? (pack.recipes || []).find(r => r.id === card.id) : null);
  const id = card.id || recipe?.id || '';
  const list = card.row?.list || card.list || (id ? (pack.recipe_ingredients || {})[id] : []) || [];
  return {
    ...card,
    id,
    name: card.name || recipe?.name || '今日推荐',
    row: card.row || (recipe ? { r: recipe, list, missing: card.missing || [] } : null),
    recipe,
    list
  };
}

function recipeMatchToFocusCard(match, pack) {
  const recipe = match?.r || match?.recipe || match;
  if (!recipe?.id) return null;
  return normalizeTodayFocusCard({
    id: recipe.id,
    name: recipe.name,
    matchLabel: '找到菜谱',
    reason: match.reason || '现有菜谱匹配，可以直接加入今天。',
    tone: 'ready',
    row: {
      r: recipe,
      list: (pack.recipe_ingredients || {})[recipe.id] || [],
      missing: []
    }
  }, pack);
}

function mergeTodayFocusCards(...groups) {
  const merged = [];
  const seen = new Set();
  groups.flat().filter(Boolean).forEach(card => {
    const key = card.id || card.name || JSON.stringify(card);
    if (!key || seen.has(key)) return;
    seen.add(key);
    merged.push(card);
  });
  return merged;
}

function getFocusCardRecipe(card, pack) {
  if (!card) return null;
  return card.row?.r || card.r || card.recipe || (card.id ? (pack.recipes || []).find(r => r.id === card.id) : null);
}

function getFocusCardRecipeItems(card, pack) {
  const recipe = getFocusCardRecipe(card, pack);
  if (!recipe) return [];
  return card.row?.list || card.list || (pack.recipe_ingredients || {})[recipe.id] || [];
}

function getRecipeTimeDifficultyText(recipe) {
  const minutes = recipe?.timeMinutes || recipe?.time_minutes || recipe?.time;
  const difficultyMap = { easy: '简单', medium: '中等', hard: '较难' };
  const difficulty = difficultyMap[recipe?.difficulty] || recipe?.difficulty || '';
  const parts = [];
  if (minutes) parts.push(String(minutes).includes('分钟') ? String(minutes) : `约 ${minutes} 分钟`);
  if (difficulty) parts.push(difficulty);
  return parts.join(' · ');
}

function buildTodayFocusContext(pack, inv, { inspirationCards = [] } = {}) {
  const rawQuery = targetRecipeQuery.trim();
  const targetDescriptors = parseTargetRecipeQuery(rawQuery, inv);
  const targetNames = targetDescriptors.map(item => item.canonical);
  let mode = todayFocusMode === 'ai' ? 'ai' : 'local';
  let cards = [];
  let nameMatches = [];

  if (rawQuery) {
    nameMatches = findRecipesByName(pack, rawQuery, {
      context: getRecommendationUiContext(),
      limit: 4
    });
    if (nameMatches.length) {
      mode = 'search';
      cards = nameMatches.map(item => recipeMatchToFocusCard(item, pack)).filter(Boolean);
    } else if (targetNames.length) {
      mode = 'target';
      cards = findRecipesUsingIngredients(pack, inv, targetNames, {
        context: getRecommendationUiContext(),
        limit: 6,
        targetDescriptors
      }).map(item => normalizeTodayFocusCard(item, pack)).filter(Boolean);
    } else {
      mode = 'search-empty';
      cards = [];
    }
  } else if (mode === 'ai') {
    const savedAi = S.load(S.keys.ai_recs, null);
    cards = savedAi ? processAiData(savedAi, pack).map(item => normalizeTodayFocusCard(item, pack)).filter(Boolean) : [];
    if (!cards.length) mode = 'local';
  }

  if (!rawQuery && mode === 'local') {
    cards = (inspirationCards || []).map(item => normalizeTodayFocusCard(item, pack)).filter(Boolean);
  }

  if (todayFocusCursor >= cards.length) todayFocusCursor = 0;
  const currentCard = cards.length ? cards[todayFocusCursor] : null;
  return {
    rawQuery,
    targetNames,
    targetDescriptors,
    nameMatches,
    mode,
    cards,
    currentCard,
    resultCount: cards.length,
    currentIndex: cards.length ? todayFocusCursor : 0
  };
}

function renderTodayRecipeSearch(context, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'today-recipe-search';
  const hasQuery = Boolean(context.rawQuery);
  const hint = hasQuery
    ? (context.resultCount ? `找到 ${context.resultCount} 道` : '未找到')
    : '';
  section.innerHTML = `
    <div class="today-recipe-search-copy">
      <strong>想做什么？</strong>
      ${hint ? `<span>${escapeHtml(hint)}</span>` : ''}
    </div>
    <div class="today-recipe-search-row">
      <input class="today-recipe-search-input" type="text" value="${escapeOptionAttr(targetRecipeQuery)}" placeholder="比如 番茄炒蛋 / 鸡蛋 番茄">
      <button type="button" class="btn ok today-recipe-search-btn">找菜</button>
      ${hasQuery ? '<button type="button" class="today-recipe-search-clear" aria-label="清空搜索" title="清空搜索">×</button>' : ''}
    </div>
  `;
  const input = section.querySelector('.today-recipe-search-input');
  const apply = () => {
    targetRecipeQuery = input.value.trim();
    todayFocusMode = 'local';
    todayFocusCursor = 0;
    resetTargetCreative();
    resetTargetDishDraft();
    onRoute();
  };
  section.querySelector('.today-recipe-search-btn').onclick = apply;
  input.onkeydown = event => {
    if (event.key === 'Enter') apply();
  };
  section.querySelector('.today-recipe-search-clear')?.addEventListener('click', () => {
    targetRecipeQuery = '';
    todayFocusMode = 'local';
    todayFocusCursor = 0;
    resetTargetCreative();
    resetTargetDishDraft();
    onRoute();
  });
  return section;
}

async function addFocusCardToTodayPlan(card, pack, inv, { button = null, onRoute = () => {} } = {}) {
  const recipe = getFocusCardRecipe(card, pack);
  if (!recipe?.id) {
    showToast('这道推荐需要先查看确认', { tone: 'info' });
    return null;
  }
  const result = await addRecipeToPlanWithMissingCheck(recipe.id, pack, inv, {
    recipe,
    fallbackItems: getFocusCardRecipeItems(card, pack),
    missing: card.row?.missing,
    source: isDemoKitchenMode() ? 'demo' : (card.mode || 'recommendation'),
    onPlanAdded: markDemoPlanAdded
  });
  if (button) brieflyConfirmButton(button, result.added ? '已加入' : '已在今天');
  const firstPlanGuide = consumeFirstPlanGuideMessage(result.added);
  showFirstPlanGuideToast(firstPlanGuide);
  if (!firstPlanGuide) showToast(result.added ? '已加入计划' : '今天已经有这道菜', { tone: 'success' });
  window.setTimeout(onRoute, 650);
  return result;
}

function deleteRecipeFromOverlay(recipeId) {
  if (!recipeId || String(recipeId).startsWith('creative-')) return false;
  const overlay = loadOverlay();
  overlay.deletes = overlay.deletes || {};
  overlay.deletes[recipeId] = true;
  if (overlay.recipes) delete overlay.recipes[recipeId];
  if (overlay.recipe_ingredients) delete overlay.recipe_ingredients[recipeId];
  saveOverlay(overlay);
  window.invalidatePackCache?.();
  return true;
}

function openAllTodayRecommendationsSheet(pack, inv, context, { onRoute = () => {} } = {}) {
  const content = document.createElement('div');
  content.className = 'today-all-recs-sheet';
  const cards = (context.cards || []).slice(0, 8);
  content.innerHTML = `
    <div class="km-modal-body today-all-recs-body">
      <p class="km-modal-subtitle">这里保留完整推荐列表，首页只放当前最重要的一张。</p>
      <div class="today-all-recs-list"></div>
    </div>
    <div class="km-modal-actions">
      <button type="button" class="btn km-action-weak" id="todayAllClose">关闭</button>
    </div>
  `;
  const list = content.querySelector('.today-all-recs-list');
  if (!cards.length) {
    list.innerHTML = '<p class="today-all-recs-empty">暂无可用推荐。</p>';
  } else {
    cards.forEach(card => {
      const recipe = getFocusCardRecipe(card, pack);
      const row = document.createElement('article');
      row.className = 'today-all-rec-row';
      row.innerHTML = `
        <span>
          <strong>${escapeHtml(card.name || recipe?.name || '推荐菜')}</strong>
          <small>${escapeHtml(card.reason || card.matchLabel || '今日推荐')}</small>
        </span>
        <span class="today-all-rec-actions">
          <button type="button" class="btn small today-all-view">查看</button>
          <button type="button" class="btn ok small today-all-plan">加入计划</button>
        </span>
      `;
      row.querySelector('.today-all-view').onclick = () => {
        if (recipe?.id) location.hash = `#recipe:${recipe.id}`;
      };
      row.querySelector('.today-all-plan').onclick = event => addFocusCardToTodayPlan(card, pack, inv, {
        button: event.currentTarget,
        onRoute
      });
      list.appendChild(row);
    });
  }
  const modal = createHomeModal(content, '全部推荐');
  content.querySelector('#todayAllClose').onclick = modal.close;
}

function openTodayMoreActionsSheet(pack, inv, context, card, { onRoute = () => {} } = {}) {
  const recipe = getFocusCardRecipe(card, pack);
  const recipeId = recipe?.id || card?.id || '';
  const hasRecipe = Boolean(recipeId && !String(recipeId).startsWith('creative-'));
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay open today-action-sheet-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content today-action-sheet';
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-modal', 'true');
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">更多操作</span>
      <button type="button" class="km-modal-close" aria-label="关闭">×</button>
    </div>
    <div class="km-modal-body today-action-sheet-body">
      <button type="button" class="today-sheet-action" data-action="all">查看全部推荐</button>
      <button type="button" class="today-sheet-action" data-action="favorite"${hasRecipe ? '' : ' disabled'}>${hasRecipe && isFavoriteRecipe(recipeId) ? '取消常做' : '设为常做'}</button>
      <button type="button" class="today-sheet-action" data-action="edit"${hasRecipe ? '' : ' disabled'}>编辑</button>
      <button type="button" class="today-sheet-action is-danger" data-action="delete"${hasRecipe ? '' : ' disabled'}>删除</button>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);
  let deleteArmed = false;
  const close = () => {
    overlay.classList.add('closing');
    window.setTimeout(() => overlay.remove(), 180);
  };
  panel.querySelector('.km-modal-close').onclick = close;
  overlay.addEventListener('click', event => {
    if (event.target === overlay) close();
  });
  panel.querySelectorAll('.today-sheet-action').forEach(btn => {
    btn.onclick = async () => {
      const action = btn.dataset.action;
      if (action === 'all') {
        close();
        openAllTodayRecommendationsSheet(pack, inv, context, { onRoute });
        return;
      }
      if (action === 'favorite' && hasRecipe) {
        toggleFavoriteRecipe(recipeId);
        showToast(isFavoriteRecipe(recipeId) ? '已设为常做' : '已取消常做', { tone: 'success' });
        close();
        onRoute();
        return;
      }
      if (action === 'edit' && hasRecipe) {
        close();
        location.hash = `#recipe-edit:${recipeId}`;
        return;
      }
      if (action === 'delete' && hasRecipe) {
        if (!deleteArmed) {
          deleteArmed = true;
          btn.textContent = '确认删除';
          window.setTimeout(() => {
            deleteArmed = false;
            if (btn.isConnected) btn.textContent = '删除';
          }, 3000);
          return;
        }
        if (deleteRecipeFromOverlay(recipeId)) {
          showToast('已删除菜谱', { tone: 'success' });
          close();
          onRoute();
        }
      }
    };
  });
}

function renderTodayStatusHeader({ planCount, expiringCount, shoppingCount, recommendationCount, hasInventory }) {
  const section = document.createElement('section');
  section.className = 'today-focus-header';
  const title = hasInventory
    ? `今天可以做 ${recommendationCount} 道菜`
    : '先记录几样食材';
  const subtitle = hasInventory
    ? (recommendationCount > 0 ? '先选一道加入计划' : '记下更多食材后，我会帮你找灵感')
    : '添加冰箱食材后，我可以帮你推荐今天吃什么';
  section.innerHTML = `
    <p class="today-focus-greeting">${escapeHtml(getGreetingLabel())}</p>
    <h2 class="today-focus-title">${escapeHtml(title)}</h2>
    <p class="today-focus-subtitle">${escapeHtml(subtitle)}</p>
    <div class="today-focus-stats" aria-label="今日厨房状态">
      <span>计划 <b>${escapeHtml(String(planCount || 0))}</b></span>
      <span>临期 <b>${escapeHtml(String(expiringCount || 0))}</b></span>
      <span>待买 <b>${escapeHtml(String(shoppingCount || 0))}</b></span>
    </div>
  `;
  return section;
}

function chooseTodayMainCard(pack, inv, { focusContext = null } = {}) {
  const expiring = getExpiringItems(inv);
  const planItems = getTodayPlanItems(pack);
  const activeShopping = loadShoppingItems().filter(item => item && !item.done);
  const recommendation = focusContext?.currentCard || null;

  if (focusContext?.rawQuery && recommendation) return { type: 'recommendation', card: recommendation, focusContext };
  if (planItems.length) return { type: 'plan', item: planItems[0] };
  if (recommendation) return { type: 'recommendation', card: recommendation, focusContext };
  if (activeShopping.length && !recommendation) return { type: 'shopping', item: activeShopping[0] };
  if (expiring.length) return { type: 'expiry', item: expiring[0] };
  return { type: 'empty' };
}

function renderTodayInlineNudge(pack, inv, state, { onRoute = () => {} } = {}) {
  const item = getExpiringItems(inv)[0];
  if (!item || state?.type === 'expiry') return null;
  const node = document.createElement('button');
  node.type = 'button';
  node.className = 'today-inline-nudge';
  const days = remainingDays(item);
  node.innerHTML = `
    <span>⏳ ${escapeHtml(item.name)} ${escapeHtml(formatExpiryLabel(days))}，建议优先使用</span>
    <strong>用它做菜</strong>
  `;
  node.onclick = () => openCleanFridgeHelper(pack, inv, onRoute);
  return node;
}

function createTodayMainCard(pack, inv, state, { onRoute = () => {} } = {}) {
  const card = document.createElement('section');
  card.className = `today-focus-card is-${state.type || 'empty'}`;

  const renderShell = ({ icon, label, badge, title, meta = '', desc, actions = '', more = false }) => {
    card.innerHTML = `
      <div class="today-focus-card-head">
        <span class="today-focus-card-label">${escapeHtml(icon)} ${escapeHtml(label)}</span>
        ${more
          ? `<span class="today-focus-head-actions">${badge ? `<span class="today-focus-card-badge">${escapeHtml(badge)}</span>` : ''}<button type="button" class="today-focus-more" id="todayMoreActions" aria-label="更多操作">⋯</button></span>`
          : (badge ? `<span class="today-focus-card-badge">${escapeHtml(badge)}</span>` : '')}
      </div>
      <div class="today-focus-card-body">
        <h3>${escapeHtml(title)}</h3>
        ${meta ? `<p class="today-focus-card-meta">${escapeHtml(meta)}</p>` : ''}
        <p class="today-focus-card-desc">${escapeHtml(desc)}</p>
      </div>
      <div class="today-focus-card-actions">${actions}</div>
    `;
  };

  if (state.type === 'expiry') {
    const item = state.item || {};
    const days = remainingDays(item);
    renderShell({
      icon: '⏳',
      label: '优先用掉',
      badge: days <= 2 ? '2 天内到期' : formatExpiryLabel(days),
      title: item.name || '快过期食材',
      meta: formatExpiryLabel(days),
      desc: `建议今天优先用掉，减少浪费。`,
      actions: '<button type="button" class="btn ok today-focus-primary" id="todayUseIngredient">用它做菜</button><button type="button" class="btn today-focus-secondary" id="todayLater">稍后</button>'
    });
    card.querySelector('#todayUseIngredient').onclick = () => openCleanFridgeHelper(pack, inv, onRoute);
    card.querySelector('#todayLater').onclick = () => showToast('稍后再看临期食材', { tone: 'info' });
    return card;
  }

  if (state.type === 'plan') {
    const recipe = state.item?.recipe || {};
    renderShell({
      icon: '🍽️',
      label: '今晚计划',
      badge: '已计划',
      title: recipe.name || '计划中的菜',
      meta: getRecipeTimeDifficultyText(recipe) || (recipe.tags || []).slice(0, 2).join(' · ') || '今天准备做',
      desc: '做完后记录消耗，库存会自动更新。',
      actions: '<button type="button" class="btn ok today-focus-primary" id="todayRecordCooked">记录消耗</button><button type="button" class="btn today-focus-secondary" id="todayStartCook">查看</button>'
    });
    card.querySelector('#todayRecordCooked').onclick = () => openCookedMealModal(pack, inv, { onRoute });
    card.querySelector('#todayStartCook').onclick = () => {
      if (recipe.id) location.hash = `#recipe:${recipe.id}`;
    };
    return card;
  }

  if (state.type === 'shopping') {
    const item = state.item || {};
    const source = item.source ? `用于「${item.source.replace(/^菜谱缺货：/, '')}」` : '买完后可以回到食材页入库。';
    renderShell({
      icon: '🛒',
      label: '待买提醒',
      badge: `待购买 ${loadShoppingItems().filter(row => row && !row.done).length} 项`,
      title: item.name || '待买食材',
      meta: item.qty ? `${item.qty}${item.unit || ''}` : '',
      desc: source,
      actions: '<button type="button" class="btn ok today-focus-primary" id="todayGoShopping">去买菜</button><button type="button" class="btn today-focus-secondary" id="todayViewShopping">查看清单</button>'
    });
    card.querySelector('#todayGoShopping').onclick = () => { location.hash = '#shopping'; };
    card.querySelector('#todayViewShopping').onclick = () => showPendingShoppingModal({ onChange: onRoute });
    return card;
  }

  if (state.type === 'recommendation') {
    const rec = normalizeTodayFocusCard(state.card, pack);
    const recipe = getFocusCardRecipe(rec, pack);
    const rawMissing = rec.missing || rec.row?.missing || [];
    const missing = Array.from(new Set(rawMissing
      .map(item => String(item?.name || item?.item || item || '').trim())
      .filter(Boolean)));
    const items = getRecipeItemsPreview(pack, rec.id || recipe?.id, 3);
    const badge = missing.length ? (missing.length === 1 ? '缺 1 样' : `缺 ${missing.length} 样`) : '可直接做';
    renderShell({
      icon: '✨',
      label: '今日推荐',
      badge,
      title: rec.name || recipe?.name || '今日推荐',
      meta: [
        items.length ? items.join(' · ') : (rec.matchLabel || ''),
        getRecipeTimeDifficultyText(recipe)
      ].filter(Boolean).join(' · ') || '今日推荐',
      desc: rec.reason || (missing.length ? formatMissingSummary(missing) : '食材匹配度不错，可以先加入计划。'),
      more: true,
      actions: '<button type="button" class="btn ok today-focus-primary" id="todayAddPlan">加入计划</button><button type="button" class="btn today-focus-secondary" id="todayViewRecipe">查看</button>'
    });
    card.querySelector('#todayAddPlan').onclick = event => addFocusCardToTodayPlan(rec, pack, inv, {
      button: event.currentTarget,
      onRoute
    });
    card.querySelector('#todayViewRecipe').onclick = () => {
      if (recipe?.id) location.hash = `#recipe:${recipe.id}`;
    };
    card.querySelector('#todayMoreActions').onclick = () => openTodayMoreActionsSheet(pack, inv, state.focusContext || { cards: [rec] }, rec, { onRoute });
    return card;
  }

  renderShell({
    icon: '📦',
    label: '先记录食材',
    badge: '',
    title: '还没有食材',
    desc: '添加冰箱食材后，我可以帮你推荐今天吃什么。',
    actions: '<button type="button" class="btn ok today-focus-primary" id="todayRecordFood">记食材</button>'
  });
  card.querySelector('#todayRecordFood').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
  return card;
}

// 顶部固定主状态区：问候 + 决策主文案 + 一行副文案。
// 不是卡片：直接铺在页面背景上；下方面板 tab 切换不影响这里。
function renderWxStatus({ planCount, expiringCount, shoppingCount, recommendationCount }) {
  const section = document.createElement('section');
  section.className = 'wx-status';
  const greeting = buildGreeting(expiringCount).split('！')[0]; // 「🌆 晚上好」——复用现有问候逻辑
  let title = '今天还没决定吃什么';
  let subtitle = '先记录几样食材，或者去菜谱里找灵感。';
  if (planCount > 0) {
    title = '今天已经安排好了';
    subtitle = `准备做 ${planCount} 道菜。记录消耗后，库存会自动更新。`;
  } else if (recommendationCount > 0) {
    title = `今天可以做 ${recommendationCount} 道菜`;
    subtitle = '先选一道加入计划';
  }
  // 顶部角标只保留「临期 / 待买」两个提醒位：计划入口在下方主面板的「📅 计划」Tab，
  // 不在顶部重复（适配一周买一次菜的节奏，顶部聚焦"该处理什么"而非"今天排了什么"）。
  const stats = [
    ['expiry', '临期', expiringCount],
    ['shopping', '待买', shoppingCount]
  ];
  section.innerHTML = `
    <p class="wx-greeting">${escapeHtml(greeting)}</p>
    <h2 class="wx-title">${escapeHtml(title)}</h2>
    <p class="wx-sub">${escapeHtml(subtitle)}</p>
    <div class="wx-summary-stats" aria-label="今日厨房状态">
      ${stats.map(([tone, label, value]) => `
        <button type="button" class="wx-stat-pill is-${tone}${value ? '' : ' is-empty'}" data-status="${escapeHtml(tone)}" aria-label="查看${escapeHtml(label)}">
          <span>${escapeHtml(label)}</span><b>${escapeHtml(String(value || 0))}</b>
          <span class="wx-stat-chevron" aria-hidden="true">›</span>
        </button>
      `).join('')}
    </div>
  `;
  return section;
}

function bindWxStatusActions(statusEl, panel, pack, inv, { onRoute = () => {} } = {}) {
  statusEl.querySelector('[data-status="expiry"]')?.addEventListener('click', () => {
    openExpiryListModal(inv, pack, {
      onRoute,
      onChange: () => {
        panel.refresh?.();
      }
    });
  });
  statusEl.querySelector('[data-status="shopping"]')?.addEventListener('click', () => {
    showPendingShoppingModal({
      onChange: () => {
        panel.refresh?.();
      },
      onGoShopping: () => {
        location.hash = '#shopping';
      }
    });
  });
}

// 页内记忆（仅内存，不持久化）；当前 tab 状态抽到 home/home-tab-state.js 与 demo 模块共享。
let postInventoryGuide = null;
let postInventoryPlanGuidePending = false;
let targetRecipeQuery = '';
let todayFocusMode = 'local';
let todayFocusCursor = 0;
// AI 创意做法状态（仅页面内存，不持久化）：idle / loading / error / success。
let targetCreativeDraft = null;
let targetCreativeStatus = 'idle';
let targetCreativeError = '';
let targetCreativeHistory = { names: [], modes: [] };
let targetCreativeSavedRecipeId = '';
let targetCreativeRequestId = 0;
let targetDishDraft = null;
let targetDishStatus = 'idle';
let targetDishError = '';
let targetDishQuery = '';
let targetDishSavedRecipeId = '';
let targetDishRequestId = 0;

function setPostInventoryGuide(count) {
  postInventoryGuide = { count, createdAt: Date.now() };
  postInventoryPlanGuidePending = true;
}

function consumeFirstPlanGuideMessage(added) {
  if (!added || !postInventoryPlanGuidePending) return '';
  postInventoryPlanGuidePending = false;
  return '已加入计划。做完后点“记录消耗”，我会帮你更新剩余食材和待买清单。';
}

function showFirstPlanGuideToast(message) {
  if (!message) return;
  showToast(message, { tone: 'success', duration: 4200 });
}

function resetTargetCreative() {
  targetCreativeDraft = null;
  targetCreativeStatus = 'idle';
  targetCreativeError = '';
  targetCreativeHistory = { names: [], modes: [] };
  targetCreativeSavedRecipeId = '';
  targetCreativeRequestId += 1;
}

function resetTargetDishDraft() {
  targetDishDraft = null;
  targetDishStatus = 'idle';
  targetDishError = '';
  targetDishQuery = '';
  targetDishSavedRecipeId = '';
  targetDishRequestId += 1;
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

// 单一主信息面板：顶部 segmented tabs（📅计划 / ✨推荐），
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
  section.className = 'wx-panel glass-panel is-two-tab';
  section.innerHTML = `
    <div class="wx-tabs" role="tablist">
      <button type="button" class="wx-tab" data-tab="plan" role="tab">📅 计划</button>
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
  const renderWxSectionIntro = (title, subtitle = '') => {
    const head = document.createElement('div');
    head.className = 'wx-section-intro';
    head.innerHTML = `<h3>${escapeHtml(title)}</h3>${subtitle ? `<p>${escapeHtml(subtitle)}</p>` : ''}`;
    return head;
  };

  // ── 📅 计划：轻动作组 + 计划列表，全部复用现有组件 ──
  const renderPlanTab = () => {
    const todayPlanCount = getTodayPlanCount();
    body.appendChild(renderWxSectionIntro(
      '计划',
      todayPlanCount > 0
        ? `已经安排 ${todayPlanCount} 道菜。`
        : ''
    ));
    body.appendChild(renderWeeklyMenuCard(pack, inv, { onRoute }));
    const actions = document.createElement('div');
    actions.className = 'menu-plan-head-actions wx-plan-actions';
    actions.appendChild(renderCookAllButton(pack, { onRoute, inventory: inv }));
    body.appendChild(actions);

    const planNode = renderMenuPlan(pack, { onRoute, hideHeader: true, inventory: inv });
    // 空态瘦身：一行轻提示 + 「看推荐」切 tab（原空态是纯静态节点、无事件绑定，见 menu-plan.js）。
    const empty = planNode.querySelector('.menu-plan-empty');
    if (empty) {
      empty.innerHTML = `
        <span class="plan-empty-line">还没有安排今天吃什么</span>
        <button type="button" class="wx-mini-btn" id="wxGoRecs">看看推荐</button>
      `;
      empty.querySelector('#wxGoRecs').onclick = () => switchTab('recs');
    }
    body.appendChild(planNode);
  };

  // ── ✨ 推荐：一次只展示 1 个主推荐（不摊开三张卡）。
  //    「换一道」在已有推荐里轮换；「AI 换一批」沿用原 callCloudAI → processAiData 流程。──
  const renderTargetRecipeSearch = (targetNames, resultCount, nameCount = 0) => {
    const hasQuery = !!targetRecipeQuery.trim();
    const search = document.createElement('div');
    search.className = 'target-recipe-search';
    const hint = hasQuery
      ? ([
          Number.isFinite(resultCount) ? `找到 ${resultCount} 道` : '',
          !Number.isFinite(resultCount) && nameCount ? `找到 ${nameCount} 道` : ''
        ].filter(Boolean)[0] || '未找到')
      : '';
    search.innerHTML = `
      <div class="target-recipe-head">
        <span>想做什么？</span>
        ${hint ? `<small class="target-recipe-hint">${escapeHtml(hint)}</small>` : ''}
      </div>
      <div class="target-recipe-input-row">
        <input class="target-recipe-input" type="text" value="${escapeOptionAttr(targetRecipeQuery)}" placeholder="比如 番茄炒蛋 / 鸡蛋 番茄">
        <button type="button" class="target-recipe-btn">找菜</button>
        ${hasQuery ? '<button type="button" class="target-recipe-clear" aria-label="清空搜索" title="清空搜索">×</button>' : ''}
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

  const openRecipePreviewModal = (recipe, { sourceLabel = '本地菜谱' } = {}) => {
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
        <button type="button" class="btn ok" id="recipePreviewPlan">加入计划</button>
        <button type="button" class="btn recipe-preview-go-plan" id="recipePreviewGoPlan" hidden>查看计划</button>
      </div>
    `;
    const modal = createHomeModal(content, recipe.name || '菜谱预览');
    const addBtn = content.querySelector('#recipePreviewPlan');
    const goPlanBtn = content.querySelector('#recipePreviewGoPlan');
    addBtn.onclick = async event => {
      event.preventDefault();
      const result = await addRecipeToPlanWithMissingCheck(recipe.id, pack, inv, {
        recipe,
        fallbackItems: items,
        source: isDemoKitchenMode() ? 'demo' : 'recipe-preview',
        onPlanAdded: markDemoPlanAdded
      });
      brieflyConfirmButton(addBtn, result.added ? '已加入今天' : '已在今天');
      const firstPlanGuide = consumeFirstPlanGuideMessage(result.added);
      showFirstPlanGuideToast(firstPlanGuide);
      goPlanBtn.hidden = false;
    };
    goPlanBtn.onclick = event => {
      event.preventDefault();
      setHomeTab('plan');
      modal.close();
      window.setTimeout(() => onRoute(), 220);
    };
    content.querySelector('#recipePreviewClose').onclick = modal.close;
  };

  const formatVariantReplacements = (variant) => {
    if (variant?.isGenericTemplate) return `用 ${variant.ingredientName || variant.name} 生成本地通用做法`;
    return (variant.replacements || [])
      .map(item => `${item.from} → ${item.to}`)
      .join('、');
  };

  const saveVariantAndAddPlan = async (variant, button, goPlanBtn) => {
    try {
      const isGeneric = Boolean(variant?.isGenericTemplate);
      const ingredients = variant.recipeIngredients || variant.ingredients || [];
      const recipeDraft = {
        name: variant.name,
        tags: variant.tags || [isGeneric ? '简单做法' : '变化菜'],
        method: variant.methodDraft || '',
        ingredients
      };
      const newId = createUserRecipe(pack, recipeDraft);
      const result = await addRecipeToPlanWithMissingCheck(newId, pack, inv, {
        recipe: { id: newId, name: recipeDraft.name, tags: recipeDraft.tags, method: recipeDraft.method },
        fallbackItems: ingredients,
        source: isGeneric ? 'generic-template' : 'variant',
        onPlanAdded: markDemoPlanAdded,
        toast: false
      });
      brieflyConfirmButton(button, result.added ? '已加入今天' : '已保存');
      if (result.missing.length) {
        showToast(result.shoppingAddedCount
          ? '已保存并加入计划，缺的食材已加入买菜清单'
          : '已保存并加入计划，缺的食材可稍后处理', { tone: 'success' });
      } else {
        showToast(isGeneric ? '已保存简单做法并加入计划' : '已保存变化菜并加入计划', { tone: 'success' });
      }
      if (goPlanBtn) goPlanBtn.hidden = false;
      return newId;
    } catch (err) {
      showToast(err?.message || '保存失败', { tone: 'error' });
      return null;
    }
  };

  const openRecipeVariantPreviewModal = (variant, { confirmPlan = false } = {}) => {
    if (!variant) return;
    const content = document.createElement('div');
    content.className = 'recipe-preview-shell recipe-variant-preview-shell';
    const isGeneric = Boolean(variant.isGenericTemplate);
    const replacementsText = formatVariantReplacements(variant);
    content.innerHTML = `
      <div class="km-modal-body recipe-preview-body">
        <p class="recipe-preview-source">${escapeHtml(variant.sourceLabel || (isGeneric ? '通用做法 · 适合现有食材' : `变化菜 · 由 ${variant.baseRecipeName || '现有菜谱'} 改`))}</p>
        <section class="recipe-preview-section recipe-variant-note">
          <h4>${isGeneric ? '做法来源' : '变化关系'}</h4>
          <p>${escapeHtml(replacementsText || '根据现有食材微调。')}</p>
          <small>${isGeneric ? '这是一份本地生成的简单做法，加入计划前会先保存为你的菜谱。' : '这还不是正式菜谱，加入计划前会先保存为你的菜谱。'}</small>
        </section>
        <section class="recipe-preview-section">
          <h4>核心食材</h4>
          <div class="recipe-preview-chip-list">${renderPreviewIngredientChips(variant.ingredients || [], '还没有生成核心食材。')}</div>
        </section>
        <section class="recipe-preview-section">
          <h4>做法提示</h4>
          ${renderPreviewMethod(variant.methodDraft || '')}
        </section>
      </div>
      <div class="km-modal-actions recipe-preview-actions recipe-variant-actions">
        <button type="button" class="btn" id="variantPreviewClose">${confirmPlan ? '取消' : '关闭'}</button>
        <button type="button" class="btn" id="variantPreviewOnly">仅查看做法</button>
        <button type="button" class="btn ok" id="variantPreviewSave">保存为菜谱并加入计划</button>
        <button type="button" class="btn recipe-preview-go-plan" id="variantPreviewGoPlan" hidden>查看计划</button>
      </div>
    `;
    const modal = createHomeModal(content, confirmPlan ? (isGeneric ? '加入简单做法' : '加入变化菜') : variant.name || (isGeneric ? '简单做法预览' : '变化菜预览'));
    const saveBtn = content.querySelector('#variantPreviewSave');
    const goPlanBtn = content.querySelector('#variantPreviewGoPlan');
    content.querySelector('#variantPreviewClose').onclick = modal.close;
    content.querySelector('#variantPreviewOnly').onclick = event => {
      event.preventDefault();
      content.querySelector('.recipe-preview-body')?.scrollTo?.({ top: 0, behavior: 'smooth' });
    };
    saveBtn.onclick = async event => {
      event.preventDefault();
      const newId = await saveVariantAndAddPlan(variant, saveBtn, goPlanBtn);
      if (newId) {
        saveBtn.disabled = true;
        window.invalidatePackCache?.();
      }
    };
    goPlanBtn.onclick = event => {
      event.preventDefault();
      setHomeTab('plan');
      modal.close();
      window.setTimeout(() => onRoute(), 220);
    };
  };

  const getAiDraftIngredients = (draft) => Array.isArray(draft?.ingredients) ? draft.ingredients : [];
  const getAiDraftMethodText = (draft) => Array.isArray(draft?.method)
    ? draft.method.join('\n')
    : String(draft?.method || '').trim();
  const getInlineAiLabel = (targetNames, query) => targetNames.length
    ? targetNames.join('、')
    : String(query || '').trim();

  const saveInlineAiDraft = (draft, kind, { goEdit = false } = {}) => {
    const id = 'ai-search-' + Date.now();
    const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {};
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    overlay.recipes[id] = {
      name: draft.name,
      tags: Array.from(new Set(['AI草稿', 'AI搜索', ...(draft.tags || [])])),
      method: getAiDraftMethodText(draft),
      isAiDraft: true
    };
    overlay.recipe_ingredients[id] = getAiDraftIngredients(draft).map(item => ({
      item: item.item || item.name || item,
      qty: item.qty || null,
      unit: item.unit || null
    }));
    saveOverlay(overlay);
    window.invalidatePackCache?.();
    if (kind === 'creative') targetCreativeSavedRecipeId = id;
    else targetDishSavedRecipeId = id;
    showToast('AI 草稿已保存', { tone: 'success' });
    if (goEdit) {
      location.hash = `#recipe-edit:${id}`;
      return id;
    }
    switchTab('recs');
    return id;
  };

  const generateInlineAiDraft = async ({ kind, targetNames = [], localCards = [], query = '', regenerate = false } = {}) => {
    if (kind === 'creative') {
      if (targetCreativeStatus === 'loading') return;
      const nextMode = pickNextCreativeDishMode(targetCreativeHistory.modes, targetCreativeDraft?.dishMode || '');
      const requestId = ++targetCreativeRequestId;
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
      targetCreativeSavedRecipeId = '';
      if (regenerate) targetCreativeDraft = null;
      switchTab('recs');
      try {
        const draft = await withTimeout(callAiCreativeRecipeByIngredients({
          targets: targetNames,
          inventoryNames: (inv || []).map(x => x && x.name).filter(Boolean),
          localRecipeNames: localCards.map(c => c.name).filter(Boolean),
          preferredDishMode: nextMode.key,
          avoidedRecipeNames,
          avoidedDishModes
        }), 30000, 'AI 响应超时');
        if (requestId !== targetCreativeRequestId) return;
        targetCreativeDraft = draft;
        rememberTargetCreativeDraft(draft);
        targetCreativeStatus = 'success';
      } catch (err) {
        if (requestId !== targetCreativeRequestId) return;
        targetCreativeStatus = targetCreativeDraft ? 'success' : 'error';
        targetCreativeError = formatAiErrorMessage(err);
        showToast('AI 暂不可用', { tone: 'error' });
      }
      switchTab('recs');
      return;
    }

    if (targetDishStatus === 'loading') return;
    const requestId = ++targetDishRequestId;
    targetDishStatus = 'loading';
    targetDishError = '';
    targetDishQuery = query;
    targetDishSavedRecipeId = '';
    if (regenerate) targetDishDraft = null;
    switchTab('recs');
    try {
      const invNames = (inv || []).map(x => x && x.name).filter(Boolean).join('、');
      const draft = await withTimeout(callAiSearchRecipe(query, invNames), 30000, 'AI 响应超时');
      if (requestId !== targetDishRequestId) return;
      targetDishDraft = draft;
      targetDishQuery = query;
      targetDishStatus = 'success';
    } catch (err) {
      if (requestId !== targetDishRequestId) return;
      targetDishStatus = 'error';
      targetDishError = `${formatAiErrorMessage(err)} 可以换个菜名或先按食材推荐。`;
      showToast('AI 暂不可用', { tone: 'error' });
    }
    switchTab('recs');
  };

  const cancelInlineAiDraft = (kind) => {
    if (kind === 'creative') resetTargetCreative();
    else resetTargetDishDraft();
    switchTab('recs');
  };

  const renderInlineAiEntry = ({ kind, targetNames = [], localCards = [], query = '', hasLocalCards = false } = {}) => {
    const label = getInlineAiLabel(targetNames, query);
    const status = kind === 'creative' ? targetCreativeStatus : targetDishStatus;
    const error = kind === 'creative' ? targetCreativeError : targetDishError;
    const section = document.createElement(hasLocalCards ? 'section' : 'article');
    section.className = hasLocalCards ? 'target-recipe-ai-inline' : 'home-suggest-card target-ai-entry-card';
    section.innerHTML = hasLocalCards
      ? `
        <span class="target-recipe-ai-inline-copy">
          <strong>没有合适的？</strong>
          <small>用这些食材生成新菜</small>
        </span>
        <button type="button" class="wx-mini-btn is-ai target-recipe-ai-btn" id="targetInlineAiBtn"${status === 'loading' ? ' disabled' : ''}>
          ${status === 'loading' ? '正在生成...' : 'AI 生成'}
        </button>
        ${error ? `<p class="target-recipe-ai-inline-error">${escapeHtml(error)}</p>` : ''}
      `
      : `
        <div class="home-suggest-kicker">
          <span class="home-suggest-match">没有找到本地菜谱</span>
        </div>
        <h3 class="home-suggest-name">AI 生成新菜</h3>
        <p class="home-suggest-reason">可以用这些食材生成可编辑草稿。</p>
        <div class="home-suggest-actions">
          <button type="button" class="btn ok small target-recipe-ai-btn" id="targetInlineAiBtn"${status === 'loading' ? ' disabled' : ''}>
            ${status === 'loading' ? '正在生成...' : 'AI 生成'}
          </button>
        </div>
        ${error ? `<p class="target-recipe-ai-inline-error">${escapeHtml(error)}</p>` : ''}
      `;
    section.querySelector('#targetInlineAiBtn').onclick = () => generateInlineAiDraft({
      kind,
      targetNames,
      localCards,
      query
    });
    return section;
  };

  const renderInlineAiSavedCard = ({ kind, draft, savedRecipeId }) => {
    const card = document.createElement('article');
    card.className = 'home-suggest-card target-ai-draft-card is-saved';
    card.innerHTML = `
      <div class="home-suggest-kicker">
        <span class="home-suggest-match">已保存为菜谱</span>
      </div>
      <h3 class="home-suggest-name">${escapeHtml(draft?.name || 'AI 新菜')}</h3>
      <p class="home-suggest-reason">已保存，可加入计划或查看。</p>
      <div class="home-suggest-actions">
        <button type="button" class="btn ok small" id="targetAiAddSaved">加入计划</button>
        <button type="button" class="btn small" id="targetAiViewSaved">查看菜谱</button>
      </div>
    `;
    card.querySelector('#targetAiAddSaved').onclick = async event => {
      const recipe = {
        id: savedRecipeId,
        name: draft?.name || 'AI 新菜',
        tags: Array.from(new Set(['AI草稿', 'AI搜索', ...(draft?.tags || [])])),
        method: getAiDraftMethodText(draft)
      };
      const result = await addRecipeToPlanWithMissingCheck(savedRecipeId, pack, inv, {
        recipe,
        fallbackItems: getAiDraftIngredients(draft),
        source: isDemoKitchenMode() ? 'demo' : 'ai-draft',
        onPlanAdded: markDemoPlanAdded
      });
      brieflyConfirmButton(event.currentTarget, result.added ? '已加入今天' : '已在今天');
      const firstPlanGuide = consumeFirstPlanGuideMessage(result.added);
      showFirstPlanGuideToast(firstPlanGuide);
    };
    card.querySelector('#targetAiViewSaved').onclick = () => {
      location.hash = `#recipe:${savedRecipeId}`;
    };
    return card;
  };

  const renderInlineAiDraftCard = ({ kind, draft, status, error, targetNames = [], localCards = [], query = '' } = {}) => {
    const savedRecipeId = kind === 'creative' ? targetCreativeSavedRecipeId : targetDishSavedRecipeId;
    if (savedRecipeId && draft) return renderInlineAiSavedCard({ kind, draft, savedRecipeId });

    const label = getInlineAiLabel(targetNames, query);
    const ingredients = getAiDraftIngredients(draft).slice(0, 8);
    const methodSteps = splitMethodSteps(getAiDraftMethodText(draft)).slice(0, 4);
    const modeLabel = kind === 'creative' && draft?.dishMode ? ` · ${getCreativeDishModeLabel(draft.dishMode)}` : '';
    const card = document.createElement('article');
    card.className = `home-suggest-card target-ai-draft-card${status === 'loading' ? ' is-loading' : ''}`;
    if (status === 'loading' && !draft) {
      card.innerHTML = `
        <div class="home-suggest-kicker">
          <span class="home-suggest-match">AI 新菜草稿</span>
          <small class="home-suggest-source">生成中</small>
        </div>
        <h3 class="home-suggest-name">正在生成新菜...</h3>
        <p class="home-suggest-reason">我正在根据“${escapeHtml(label || '这些食材')}”整理一份可编辑草稿。</p>
        <div class="home-suggest-actions">
          <button type="button" class="btn small" id="targetAiCancel">取消</button>
        </div>
      `;
      card.querySelector('#targetAiCancel').onclick = () => cancelInlineAiDraft(kind);
      return card;
    }

    card.innerHTML = `
      <div class="home-suggest-kicker">
        <span class="home-suggest-match">AI 新菜草稿${escapeHtml(modeLabel)}</span>
          <small class="home-suggest-source">未保存草稿</small>
      </div>
      <h3 class="home-suggest-name">${escapeHtml(draft?.name || 'AI 新菜草稿')}</h3>
      <p class="home-suggest-reason">确认后保存</p>
      ${ingredients.length ? `<div class="target-ai-draft-tags">${ingredients.map(item => `<span>${escapeHtml(item.item || item.name || item)}</span>`).join('')}</div>` : ''}
      ${methodSteps.length ? `
        <div class="target-ai-draft-method">
          ${methodSteps.map(step => `<p>${escapeHtml(step)}</p>`).join('')}
        </div>
      ` : '<p class="target-ai-draft-muted">还没有生成做法预览，可以重新生成或取消。</p>'}
      ${error ? `<p class="target-recipe-ai-inline-error">${escapeHtml(error)}</p>` : ''}
      <div class="home-suggest-actions target-ai-draft-actions">
        <button type="button" class="btn ok small" id="targetAiSave">保存草稿</button>
        <button type="button" class="btn small" id="targetAiEdit">保存并编辑</button>
        <button type="button" class="btn small" id="targetAiAgain"${status === 'loading' ? ' disabled' : ''}>${status === 'loading' ? '正在生成...' : '重新生成'}</button>
        <button type="button" class="btn small" id="targetAiCancel">取消</button>
      </div>
    `;
    card.querySelector('#targetAiSave').onclick = () => saveInlineAiDraft(draft, kind, { goEdit: false });
    card.querySelector('#targetAiEdit').onclick = () => saveInlineAiDraft(draft, kind, { goEdit: true });
    card.querySelector('#targetAiAgain').onclick = () => generateInlineAiDraft({
      kind,
      targetNames,
      localCards,
      query,
      regenerate: true
    });
    card.querySelector('#targetAiCancel').onclick = () => cancelInlineAiDraft(kind);
    return card;
  };

  const renderPostInventoryGuide = () => {
    if (!postInventoryGuide) return null;
    const guide = document.createElement('div');
    guide.className = 'post-inventory-guide';
    guide.innerHTML = `
      <div class="post-inventory-guide-copy">
        <strong>已经记下食材了</strong>
        <span>下一步，选一道今天想吃的菜加入计划。</span>
      </div>
      <div class="post-inventory-guide-actions">
        <button type="button" class="wx-mini-btn is-primary" id="postInventoryGuideRecs">看推荐</button>
        <button type="button" class="wx-mini-btn" id="postInventoryGuideAdd">继续记食材</button>
      </div>
    `;
    guide.querySelector('#postInventoryGuideRecs').onclick = () => {
      postInventoryGuide = null;
      setHomeTab('recs');
      switchTab('recs');
    };
    guide.querySelector('#postInventoryGuideAdd').onclick = () => {
      openBatchInputModal(pack, { onRoute, initialTab: 'text' });
    };
    return guide;
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
    const nameCards = nameMatches.map(item => recipeMatchToFocusCard(item, pack)).filter(Boolean);
    const targetKey = targetNames.join('|');
    if (targetNames.length) {
      // 同一面板内目标没变（如点 AI 按钮 / 来回切 tab 触发的重绘）→ 复用上次结果，
      // 不重扫全库；pack/inv 变化必经 onRoute 重建面板，缓存自然失效。
      const sameTarget = recsState && recsState.mode === 'target' && recsState.key === targetKey;
      const directCards = sameTarget
        ? recsState.cards
        : perfMeasure(`findRecipesUsingIngredients(${targetKey})`, () => findRecipesUsingIngredients(pack, inv, targetNames, {
            context: getRecommendationUiContext(),
            limit: 6,
            targetDescriptors
          }));
      const targetCards = sameTarget
        ? directCards
        : (() => {
            const variants = getRecipeVariantRecommendations(pack, inv, {
              limit: 4,
              targetNames
            });
            const genericTemplates = getGenericIngredientRecipeRecommendations(pack, inv, {
              limit: 3,
              targetNames,
              existingNames: [
                ...directCards.map(item => item.name),
                ...variants.map(item => item.name)
              ]
            });
            const seen = new Set(directCards.map(item => item.id || item.name));
            return mergeTodayFocusCards(
              nameCards,
              directCards,
              ...variants.filter(item => {
                const key = item.id || item.name;
                if (!key || seen.has(key)) return false;
                seen.add(key);
                return true;
              }),
              ...genericTemplates.filter(item => {
                const key = item.id || item.name;
                if (!key || seen.has(key)) return false;
                seen.add(key);
                return true;
              })
            ).slice(0, 6);
          })();
      const prevIdx = sameTarget ? recsState.idx : 0;
      recsState = {
        mode: 'target',
        cards: targetCards,
        idx: Math.min(prevIdx, Math.max(0, targetCards.length - 1)),
        key: targetKey,
        targets: targetNames
      };
    } else if (hasSearchQuery) {
      recsState = { mode: nameCards.length ? 'search' : 'search-empty', cards: nameCards, idx: 0, key: rawQuery };
    } else if (!recsState || recsState.mode === 'target') {
      recsState = initRecsState();
    }
    const { mode, cards, idx } = recsState;
    const aiKind = targetNames.length ? 'creative' : 'dish';
    const hasInlineAiState = hasSearchQuery && (
      aiKind === 'creative'
        ? Boolean(targetCreativeSavedRecipeId || targetCreativeDraft || targetCreativeStatus === 'loading')
        : Boolean(targetDishQuery === rawQuery && (targetDishSavedRecipeId || targetDishDraft || targetDishStatus === 'loading'))
    );
    body.appendChild(renderTargetRecipeSearch(targetNames, cards.length, nameMatches.length));
    const postGuide = renderPostInventoryGuide();
    if (postGuide) body.appendChild(postGuide);

    const cardWrap = document.createElement('div');
    cardWrap.className = 'wx-rec-card';
    if (hasInlineAiState) {
      const draft = aiKind === 'creative' ? targetCreativeDraft : targetDishDraft;
      const status = aiKind === 'creative' ? targetCreativeStatus : targetDishStatus;
      const error = aiKind === 'creative' ? targetCreativeError : targetDishError;
      cardWrap.appendChild(renderInlineAiDraftCard({
        kind: aiKind,
        draft,
        status,
        error,
        targetNames,
        localCards: cards,
        query: rawQuery
      }));
    } else if (hasSearchQuery && !cards.length) {
      cardWrap.appendChild(renderInlineAiEntry({
        kind: aiKind,
        targetNames,
        localCards: cards,
        query: rawQuery,
        hasLocalCards: false
      }));
    } else if (!cards.length && mode === 'target' && targetNames.length) {
      cardWrap.innerHTML = `
        <div class="wx-empty wx-rec-empty">
          <strong>还没有匹配到能直接做的菜</strong>
          <span>可以再记几样食材，或者先去菜谱里挑一道。</span>
          <small class="wx-help-text">也可以让 AI 先想一个草稿，确认后再保存。</small>
          <div class="wx-actions wx-empty-actions">
            <button type="button" class="wx-mini-btn" id="wxRecAddFood">继续记食材</button>
            <button type="button" class="wx-mini-btn" id="wxRecGoRecipes">去菜谱看看</button>
          </div>
        </div>
      `;
      cardWrap.querySelector('#wxRecAddFood').onclick = () => openBatchInputModal(pack, { onRoute, initialTab: 'text' });
      cardWrap.querySelector('#wxRecGoRecipes').onclick = () => { location.hash = '#recipes'; };
    } else if (!cards.length) {
      cardWrap.innerHTML = `
        <div class="wx-empty wx-rec-empty">
          <strong>还没有匹配到能直接做的菜</strong>
          <span>可以再记几样食材，或者先去菜谱里挑一道。</span>
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
      const item = cards[idx];
      const aiCard = {
        id: item?.r?.id,
        name: item?.r?.name || 'AI 推荐',
        matchLabel: 'AI 推荐',
        reason: item?.reason || (Array.isArray(item?.explain) ? item.explain.join('；') : ''),
        tone: 'idea',
        row: item?.r ? {
          r: item.r,
          list: item.list || (pack.recipe_ingredients || {})[item.r.id] || [],
          missing: item.missing || []
        } : null
      };
      cardWrap.appendChild(renderSuggestCard(aiCard, pack, inv, {
        onPreviewRecipe: openRecipePreviewModal,
        onMoreRecommendation: focused => openTodayMoreActionsSheet(pack, inv, recsState, focused, { onRoute }),
        onRoute
      }));
    } else {
      const suggestCard = renderSuggestCard(cards[idx], pack, inv, {
        onPreviewRecipe: openRecipePreviewModal,
        onPreviewVariant: openRecipeVariantPreviewModal,
        onMoreRecommendation: focused => openTodayMoreActionsSheet(pack, inv, recsState, focused, { onRoute }),
        onRoute
      });
      if (hasSearchQuery) {
        suggestCard.appendChild(renderInlineAiEntry({
          kind: aiKind,
          targetNames,
          localCards: cards,
          query: rawQuery,
          hasLocalCards: true
        }));
      }
      cardWrap.appendChild(suggestCard);
    }
    bindRecommendationCycling(cardWrap);
    if (hasSearchQuery) {
      const countText = `第 ${idx + 1} / ${cards.length} 道`;
      if (hasInlineAiState) {
        body.appendChild(renderTargetSectionTitle('AI 新菜草稿', `根据“${getInlineAiLabel(targetNames, rawQuery)}”生成`));
      } else if (cards.length && mode === 'target' && targetNames.length) {
        body.appendChild(renderTargetSectionTitle('按这些食材推荐', countText));
      } else if (cards.length) {
        body.appendChild(renderTargetSectionTitle('找到的推荐', countText));
      } else {
        body.appendChild(renderTargetSectionTitle('没有找到本地菜谱', `可以用“${getInlineAiLabel(targetNames, rawQuery)}”生成一道新菜`));
      }
    } else if (cards.length) {
      body.appendChild(renderWxSectionIntro('推荐', ''));
    } else {
      body.appendChild(renderWxSectionIntro('暂无合适推荐', '再记录几样食材，推荐会更准。'));
    }
    body.appendChild(cardWrap);

    if (cards.length > 1) {
      const dots = document.createElement('div');
      dots.className = 'wx-rec-dots-only';
      dots.innerHTML = `
        <span class="wx-rec-dots" aria-hidden="true">
          ${cards.map((_, i) => `<span class="${i === idx ? 'is-active' : ''}"></span>`).join('')}
        </span>
      `;
      body.appendChild(dots);
    }
    // AI 创意做法入口：指定食材模式专属，本地结果（或空提示）之下，分层清楚。
    const aiStatus = document.createElement('div');
    aiStatus.className = 'small inline-status wx-ai-status';
    aiStatus.hidden = true;
    body.appendChild(aiStatus);

    if (hasInlineAiState || (hasSearchQuery && !cards.length)) return;

    const foot = document.createElement('div');
    foot.className = 'wx-actions';
    foot.innerHTML = `
      ${mode === 'ai' && cards.length ? '<button type="button" class="wx-mini-btn" id="wxRecLocal">用本地推荐</button>' : ''}
      ${cards.length > 1 ? '<button type="button" class="wx-mini-btn" id="wxRecNext">换一道 ›</button>' : ''}
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

  const TAB_RENDERERS = { plan: renderPlanTab, recs: renderRecsTab };
  const switchTab = (name) => {
    const tab = TAB_RENDERERS[name] ? name : 'plan';
    setHomeTab(tab);
    syncDemoStepFromTab(tab, { onRoute });
    section.querySelectorAll('.wx-tab').forEach(t => {
      const active = t.dataset.tab === tab;
      t.classList.toggle('is-active', active);
      t.setAttribute('aria-selected', String(active));
    });
    body.innerHTML = '';
    perfMeasure(`wx-switchTab:${tab}`, () => TAB_RENDERERS[tab]());
  };
  section.querySelectorAll('.wx-tab').forEach(t => { t.onclick = () => switchTab(t.dataset.tab); });

  // 默认 tab：优先回答“今天能做什么”；手动切过 tab 时仍尊重记忆的 tab（home-tab-state）。
  const defaultRecCount = getInspirationCached().length;
  const defaultPlanCount = getTodayPlanCount();
  const defaultTab = defaultRecCount > 0 ? 'recs' : (defaultPlanCount > 0 ? 'plan' : 'plan');
  switchTab(getHomeTab() || defaultTab);

  return {
    el: section,
    refresh: () => switchTab(getHomeTab() || defaultTab),
    switchTab
  };
}

// 「明天备菜」提醒已融入计划组件（menu-plan.js：顶部 menu-prep-alert + 行内 menu-prep-tags），
// 首页不再渲染独立大卡片；prep-planner 工具与 S.keys.prep_done 保留（后续可做「已解冻」状态）。

export function renderHome(pack, { onRoute = () => {} } = {}) {
  const container = document.createElement('div');
  container.className = 'today-view';
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const isDemoMode = isDemoKitchenMode();

  if (isDemoMode) {
    container.appendChild(renderDemoKitchenBanner({ onRoute }));
  }

  // 轻量 Today：主面板保留「计划 / 推荐」，临期和待买由顶部状态弹窗承接，
  // 只压轻视觉和按钮层级；不改推荐算法、不接新 API。
  const inspirationCards = perfMeasure('getInspirationCards(home)', () => getInspirationCards(pack, inv));
  const summaryStats = getTodaySummaryStats(pack, inv, { inspirationCards });
  const statusHeader = renderWxStatus(summaryStats);
  const panel = perfMeasure('createWeatherPanel', () => createWeatherPanel(pack, inv, { onRoute, inspirationCards }));
  bindWxStatusActions(statusHeader, panel, pack, inv, { onRoute });
  container.appendChild(statusHeader);
  const backupNudge = renderBackupNudge(inv, { isDemoMode });
  if (backupNudge) container.appendChild(backupNudge);
  else {
    const pwaNudge = renderPwaInstallNudge(inv, { isDemoMode });
    if (pwaNudge) container.appendChild(pwaNudge);
  }
  container.appendChild(panel.el);
  container.appendChild(renderQuickActions(pack, inv, { onRoute, refreshStatus: panel.refresh }));

  return container;
}
