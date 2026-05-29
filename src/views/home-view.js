import { S, todayISO } from '../storage.js?v=173';
import { buildCatalog, getCanonicalName } from '../ingredients.js?v=173';
import { isInventoryAvailable, loadInventory, remainingDays } from '../inventory.js?v=173';
import { addShoppingItem, loadShoppingItems } from '../shopping.js?v=173';
import {
  addMissingRecipeIngredientsToShopping, addRecipeToPlan,
  hasRecipeMethod, rankRecipesForRecommendation,
  getCleanFridgeRecommendations, processAiData
} from '../recommendations.js?v=173';
import { callCloudAI, formatAiErrorMessage } from '../ai.js?v=173';
import { escapeHtml, brieflyConfirmButton, setInlineStatus } from '../components/status.js?v=173';
import { showRecommendationCards } from '../components/recipe-card.js?v=173';
import { showCleanFridgeModal } from '../components/modal.js?v=173';
import { renderMenuPlan } from '../components/menu-plan.js?v=173';
import { requestInventoryIntent } from './shopping-view.js?v=173';

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

function renderInspirationPanel(pack, inv, expiringCount, { onRoute = () => {} } = {}) {
  const section = document.createElement('section');
  section.className = 'home-hero';

  const greeting = mockAiRecommendations.greeting || buildGreeting(expiringCount);
  section.innerHTML = `
    <div class="home-hero-glow" aria-hidden="true"></div>
    <div class="home-hero-head">
      <div class="home-hero-top">
        <span class="home-hero-eyebrow">🧠 今日灵感</span>
        <button type="button" class="home-mini-btn home-ai-btn" id="heroAiBtn">✨ AI 换一批</button>
      </div>
      <h2 class="home-hero-greeting">${escapeHtml(greeting)}</h2>
    </div>
    <div id="heroAiStatus" class="small inline-status" hidden></div>
    <div class="home-suggest-scroll"></div>
    <p class="home-hero-note" id="heroNote"></p>
  `;
  const scroll = section.querySelector('.home-suggest-scroll');
  const note = section.querySelector('#heroNote');
  const aiStatus = section.querySelector('#heroAiStatus');
  const aiBtn = section.querySelector('#heroAiBtn');

  // 默认：本地/示例推荐
  const showLocal = () => {
    let cards = getInspirationCards(pack, inv);
    const usingMock = cards.length === 0;
    if (usingMock) cards = mockAiRecommendations.cards;
    scroll.innerHTML = '';
    cards.forEach(card => scroll.appendChild(renderSuggestCard(card, pack, inv)));
    note.textContent = usingMock ? '示例推荐 · 录入更多库存后会自动匹配你的食材' : '';
    note.hidden = !usingMock;
  };

  // AI 推荐：复用原有 AI 推荐卡片渲染与草稿逻辑；最多展示 4 张，避免拥挤。
  const showAi = (aiCards) => {
    showRecommendationCards(scroll, (aiCards || []).slice(0, 4), pack, { onRoute });
    note.hidden = false;
    note.innerHTML = 'AI 草稿推荐，请确认后再安排。<button type="button" class="home-note-clear" id="heroAiClear">用本地推荐</button>';
    const clearBtn = note.querySelector('#heroAiClear');
    if (clearBtn) clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); showLocal(); setInlineStatus(aiStatus, '', 'info'); };
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

// ── Section 2: 紧急指标 / 雷达（2 列） ─────────────────────────────────────
function renderUrgentMetrics(inv, activeShoppingCount) {
  const expiring48 = (inv || []).filter(it => isExpiryTracked(it) && remainingDays(it) <= 2);
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
  // 库存与采购已迁至「清单」页：临期雷达跳转到该页的库存区。
  section.querySelector('#metricExpiring').onclick = () => { requestInventoryIntent('inventory'); location.hash = '#shopping'; };
  section.querySelector('#metricShopping').onclick = () => { location.hash = '#shopping'; };
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
    <div class="home-memo is-hidden" id="memoRow">
      <input id="memoInput" placeholder="输入要买的东西，回车加入清单">
      <button type="button" class="btn ok small" id="memoAdd">加入</button>
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
    const numEl = document.querySelector('#metricShopping .home-metric-num');
    if (numEl) numEl.textContent = String(loadShoppingItems().filter(i => !i.done).length);
  };
  memoInput.onkeydown = (e) => { if (e.key === 'Enter') commitMemo(); };
  section.querySelector('#memoAdd').onclick = commitMemo;

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
function renderOnboarding() {
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
  section.querySelector('#obManual').onclick = () => { requestInventoryIntent('add'); location.hash = '#shopping'; };
  section.querySelector('#obReceipt').onclick = () => { requestInventoryIntent('receipt'); location.hash = '#shopping'; };
  section.querySelector('#obBackup').onclick = () => { location.hash = '#settings'; };
  return section;
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
    container.appendChild(renderOnboarding());
    return container;
  }

  // 自上而下视觉层级：① 紧急指标 ② 今日灵感 ③ 菜单计划 ④ 极速操作（含微型「清冰箱」）
  container.appendChild(renderUrgentMetrics(inv, activeShopping.length));
  container.appendChild(renderInspirationPanel(pack, inv, expiringSoonCount, { onRoute }));
  container.appendChild(renderMenuPlan(pack, { onRoute }));
  container.appendChild(renderActionHub(pack, inv, {
    onQuickInput: () => { requestInventoryIntent('add'); location.hash = '#shopping'; },
    onRoute
  }));

  return container;
}
