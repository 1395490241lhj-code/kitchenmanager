/*
 * src/views/home/demo-kitchen.js —— 示例厨房（demo mode）状态机 + 引导横幅（从 home-view 抽出）。
 * 进入时快照真实业务数据、退出时原样恢复；步骤状态存 km_demo_step_v1，见 storage.js S.keys。
 */
import { S } from '../../storage.js?v=231';
import { escapeHtml, showToast } from '../../components/status.js?v=231';
import { writeItemsToInventory } from '../../utils/inventory-write.js?v=231';
import { getTodayPlanCount, setHomeTab } from './home-tab-state.js?v=231';

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

const DEMO_BUSINESS_KEY_NAMES = [
  'inventory',
  'plan',
  'shopping_items',
  'staples',
  'pantry_config',
  'prep_done',
  'ai_recs',
  'local_recs',
  'rec_time',
  'rec_signature',
  'recipe_usage',
  'recipe_activity',
  'favorite_recipes'
];

export function isDemoKitchenMode() {
  try { return localStorage.getItem(S.keys.demo_mode) === '1'; } catch (e) { return false; }
}

function getDemoStep() {
  try { return localStorage.getItem(S.keys.demo_step) || 'recs'; } catch (e) { return 'recs'; }
}

export function setDemoStep(step) {
  if (!isDemoKitchenMode()) return;
  try { localStorage.setItem(S.keys.demo_step, step); } catch (e) { /* ignore private mode */ }
}

function advanceDemoStep(step, { onRoute = null } = {}) {
  if (!isDemoKitchenMode()) return;
  setDemoStep(step);
  if (step === 'recs') setHomeTab('recs');
  if (step === 'plan' || step === 'cook') setHomeTab('plan');
  if (typeof onRoute === 'function') onRoute();
}

export function markDemoPlanAdded(added) {
  if (!added || !isDemoKitchenMode()) return;
  setDemoStep('plan');
  refreshDemoKitchenBanner();
}

export function refreshDemoKitchenBanner({ onRoute = null } = {}) {
  const current = document.querySelector('.demo-kitchen-banner');
  if (!current) return;
  const route = onRoute || current.__demoOnRoute || (() => {});
  const next = renderDemoKitchenBanner({ onRoute: route });
  current.replaceWith(next);
}

export function syncDemoStepFromTab(tabName, { onRoute = () => {} } = {}) {
  if (!isDemoKitchenMode()) return;
  if (tabName === 'recs') {
    setDemoStep('recs');
  } else if (tabName === 'plan') {
    setDemoStep(getTodayPlanCount() > 0 ? 'cook' : 'recs');
  } else {
    return;
  }
  refreshDemoKitchenBanner({ onRoute });
}

function saveDemoKitchenSnapshot() {
  if (isDemoKitchenMode() && localStorage.getItem(S.keys.demo_snapshot)) return;
  const keys = {};
  for (const name of DEMO_BUSINESS_KEY_NAMES) {
    const key = S.keys[name];
    if (!key) continue;
    const value = localStorage.getItem(key);
    keys[name] = value === null ? { exists: false } : { exists: true, value };
  }
  S.save(S.keys.demo_snapshot, { version: 1, createdAt: new Date().toISOString(), keys });
}

export function enterDemoKitchen(pack, { onRoute = () => {} } = {}) {
  saveDemoKitchenSnapshot();
  localStorage.setItem(S.keys.demo_mode, '1');
  localStorage.setItem(S.keys.demo_step, 'recs');
  const n = writeItemsToInventory(DEMO_KITCHEN_ITEMS, pack);
  if (n > 0) setHomeTab('recs');
  onRoute();
}

function restoreDemoKitchenSnapshot(snapshot) {
  const keys = snapshot && snapshot.keys && typeof snapshot.keys === 'object' ? snapshot.keys : null;
  for (const name of DEMO_BUSINESS_KEY_NAMES) {
    const key = S.keys[name];
    if (!key) continue;
    const record = keys ? keys[name] : null;
    if (record && record.exists && typeof record.value === 'string') {
      localStorage.setItem(key, record.value);
    } else {
      localStorage.removeItem(key);
    }
  }
}

function exitDemoKitchen({ onRoute = () => {} } = {}) {
  const snapshot = S.load(S.keys.demo_snapshot, null);
  restoreDemoKitchenSnapshot(snapshot);
  localStorage.removeItem(S.keys.demo_mode);
  localStorage.removeItem(S.keys.demo_snapshot);
  localStorage.removeItem(S.keys.demo_step);
  setHomeTab(null);
  onRoute();
}

export function renderDemoKitchenBanner({ onRoute = () => {} } = {}) {
  const step = getDemoStep();
  const state = {
    intro: {
      title: '示例体验：食材已经准备好',
      body: '我先放了几样常见食材。你可以像真实厨房一样试用，不会影响你的设置。',
      primary: '看看今天能做什么',
      primaryStep: 'recs',
      secondary: '退出示例',
      secondaryAction: 'exit'
    },
    recs: {
      title: '第 2 步：选一道今天想吃的菜',
      body: '在下面的推荐里，点“加入计划”。缺的食材可以顺手放进买菜清单。',
      primary: '查看推荐',
      primaryStep: 'recs',
      secondary: '退出示例',
      secondaryAction: 'exit'
    },
    plan: {
      title: '第 3 步：做完后更新库存',
      body: '计划里已经有菜了。做完后点“记录消耗”，我会帮你确认用掉了哪些食材。',
      primary: '去看计划',
      primaryStep: 'cook',
      secondary: '退出示例',
      secondaryAction: 'exit'
    },
    cook: {
      title: '第 3 步：做完后更新库存',
      body: '计划里已经有菜了。做完后点“记录消耗”，我会帮你确认用掉了哪些食材。',
      primary: '我知道了',
      primaryStep: 'done',
      secondary: '开始我的厨房',
      secondaryAction: 'exit'
    },
    done: {
      title: '示例体验完成',
      body: '你已经体验了推荐、计划和饭后更新。现在可以开始记录自己的厨房。',
      primary: '开始我的厨房',
      primaryAction: 'exit',
      secondary: '继续试用',
      secondaryStep: 'recs'
    }
  }[step] || {
    title: '当前是示例体验',
    body: '你可以随便试用推荐、计划和买菜清单。准备记录自己的厨房时，可以退出示例。',
    primary: '查看推荐',
    primaryStep: 'recs',
    secondary: '退出示例',
    secondaryAction: 'exit'
  };
  const banner = document.createElement('section');
  banner.className = 'demo-kitchen-banner';
  banner.__demoOnRoute = onRoute;
  banner.innerHTML = `
    <div class="demo-kitchen-copy">
      <small>当前是示例体验</small>
      <strong>${escapeHtml(state.title)}</strong>
      <span>${escapeHtml(state.body)}</span>
    </div>
    <div class="demo-kitchen-actions">
      <button type="button" class="demo-kitchen-primary">${escapeHtml(state.primary)}</button>
      <button type="button" class="demo-kitchen-exit">${escapeHtml(state.secondary)}</button>
    </div>
  `;
  const confirmExit = () => {
    const ok = window.confirm('退出后会清除示例食材和示例计划，回到空厨房。你的设置不会被删除。');
    if (!ok) return;
    exitDemoKitchen({ onRoute });
    showToast('已退出示例体验', { tone: 'info' });
  };
  banner.querySelector('.demo-kitchen-primary').onclick = () => {
    if (state.primaryAction === 'exit') {
      confirmExit();
      return;
    }
    advanceDemoStep(state.primaryStep || 'recs', { onRoute });
  };
  banner.querySelector('.demo-kitchen-exit').onclick = () => {
    if (state.secondaryAction === 'exit') {
      confirmExit();
      return;
    }
    advanceDemoStep(state.secondaryStep || 'recs', { onRoute });
  };
  return banner;
}
