/*
 * src/views/home/demo-kitchen.js —— 示例厨房（demo mode）状态机 + 引导横幅（从 home-view 抽出）。
 * 进入时快照真实业务数据、退出时原样恢复；步骤状态存 km_demo_step_v1，见 storage.js S.keys。
 */
import { S } from '../../storage.js?v=237';
import { DEMO_COPY } from '../../copy.js?v=237';
import { escapeHtml, showToast } from '../../components/status.js?v=237';
import { writeItemsToInventory } from '../../utils/inventory-write.js?v=237';
import { getTodayPlanCount, setHomeTab } from './home-tab-state.js?v=237';

const DEMO_SNAPSHOT_FAILED_MESSAGE = '无法保存当前厨房数据的备份，已取消进入示例体验。请先清理浏览器存储空间后重试。';
const DEMO_BASELINE_FAILED_MESSAGE = '无法把厨房数据恢复到进入示例前的状态，已保留备份。请先清理浏览器存储空间后重试。';

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

function isValidDemoSnapshot(snapshot) {
  return !!(snapshot && snapshot.keys && typeof snapshot.keys === 'object');
}

/**
 * 保存进入示例前的真实业务数据快照。
 * 快照是「退出时能还原真实数据」的唯一依据，所以这里不再吞掉 S.save 的失败：
 * 存不进去就抛 DEMO_SNAPSHOT_FAILED，调用方必须放弃进入示例（此时业务数据一个字节都没动）。
 * @returns {object|null} 本次使用的快照（已在示例模式时复用既有快照）
 */
function saveDemoKitchenSnapshot() {
  // 已在示例模式且快照仍在 → 复用，绝不能用（已混入示例食材的）当前数据覆盖它。
  if (isDemoKitchenMode() && localStorage.getItem(S.keys.demo_snapshot)) {
    return S.load(S.keys.demo_snapshot, null);
  }
  const keys = {};
  for (const name of DEMO_BUSINESS_KEY_NAMES) {
    const key = S.keys[name];
    if (!key) continue;
    const value = localStorage.getItem(key);
    keys[name] = value === null ? { exists: false } : { exists: true, value };
  }
  if (!S.save(S.keys.demo_snapshot, { version: 1, createdAt: new Date().toISOString(), keys })) {
    const error = new Error(DEMO_SNAPSHOT_FAILED_MESSAGE);
    error.code = 'DEMO_SNAPSHOT_FAILED';
    throw error;
  }
  return S.load(S.keys.demo_snapshot, null);
}

/**
 * 进入示例失败时的回滚。回滚过程自身的异常一律吞掉，不能盖掉原始错误。
 *
 * 只有业务数据「完整」恢复成功，才清掉 demo_mode / demo_step / demo_snapshot。
 * 恢复不完整时（配额仍然满等）刻意停在示例模式里：
 *   - demo_snapshot 原样保留，它是唯一一份干净的恢复锚点；
 *   - demo_mode 保持为 '1'，这样 saveDemoKitchenSnapshot() 的复用分支会命中，
 *     下一次重试不会用已被示例数据污染的当前库存覆盖这份快照；
 *   - 示例横幅仍在，用户随时可以在存储恢复后走「退出示例」把数据还原回去。
 * @returns {'restored'|'partial'|'invalid'}
 */
function rollbackDemoKitchenEntry(snapshot) {
  let outcome;
  try {
    outcome = restoreDemoKitchenSnapshot(snapshot);
  } catch (e) {
    console.error('示例厨房回滚失败', e);
    outcome = 'partial';
  }
  if (outcome === 'partial') return outcome; // 保留快照与示例状态，等待重试 / 退出时再恢复
  for (const key of [S.keys.demo_mode, S.keys.demo_step, S.keys.demo_snapshot]) {
    try { localStorage.removeItem(key); } catch (e) { /* 隐私模式等：忽略 */ }
  }
  try { setHomeTab(null); } catch (e) { /* 纯内存赋值，理论上不会走到 */ }
  return outcome;
}

export function enterDemoKitchen(pack, { onRoute = () => {} } = {}) {
  // 第一步就是快照：它失败就直接抛，后面的写入一个都不执行。
  const snapshot = saveDemoKitchenSnapshot();
  // 重试路径（上一次进入回滚不完整，留下了 demo_mode + 污染数据 + 干净快照）：
  // 必须先退回快照基线再重新应用示例食材，否则同名食材会被二次累加
  // （例如既有「鸡蛋 2 个」被 merge 成 8 个后再加 6 个，变成 14 个）。
  if (isDemoKitchenMode() && isValidDemoSnapshot(snapshot)) {
    if (restoreDemoKitchenSnapshot(snapshot) !== 'restored') {
      // 基线没能完整恢复：保持原样失败，快照原封不动留给下一次重试 / 退出。
      const error = new Error(DEMO_BASELINE_FAILED_MESSAGE);
      error.code = 'DEMO_BASELINE_RESTORE_FAILED';
      throw error;
    }
  }
  try {
    localStorage.setItem(S.keys.demo_mode, '1');
    localStorage.setItem(S.keys.demo_step, 'recs');
    // 示例食材是逐条持久化的（writeItemsToInventory → saveInventory → mustSave），
    // 配额中途耗尽会留下半份示例库存，所以这里必须整体回滚。
    const n = writeItemsToInventory(DEMO_KITCHEN_ITEMS, pack);
    if (n > 0) setHomeTab('recs');
    onRoute();
  } catch (e) {
    rollbackDemoKitchenEntry(snapshot);
    throw e; // 交回 runDemoKitchenEntry：引导保持可见并允许重试
  }
}

/**
 * 按快照还原业务数据。
 * 关键保护：没有有效快照时直接返回 'invalid'，绝不遍历删除业务键——
 * 否则「进入示例时快照写失败」会在退出时变成清空用户真实库存/计划/收藏。
 * 单个键写失败不中断其余键的恢复，但结果必须如实上报为 'partial'：
 * 只要有一个键没还原成功，这份快照就仍是唯一干净的恢复锚点，调用方不能删掉它。
 * @returns {'invalid'|'restored'|'partial'}
 */
function restoreDemoKitchenSnapshot(snapshot) {
  if (!isValidDemoSnapshot(snapshot)) return 'invalid';
  const keys = snapshot.keys;
  let failed = 0;
  for (const name of DEMO_BUSINESS_KEY_NAMES) {
    const key = S.keys[name];
    if (!key) continue;
    const record = keys[name];
    try {
      // record.exists === false 表示进入示例前这个键本来就不存在，删除才是正确的还原。
      if (record && record.exists && typeof record.value === 'string') {
        localStorage.setItem(key, record.value);
      } else {
        localStorage.removeItem(key);
      }
    } catch (e) {
      failed += 1;
      console.error('恢复示例厨房快照失败', key, e);
    }
  }
  return failed === 0 ? 'restored' : 'partial';
}

/**
 * 退出示例厨房。三种结果对应三种处理：
 *   'restored' —— 完整还原，清掉全部示例状态（含快照）。
 *   'invalid'  —— 没有可用快照：业务数据原样保留（宁可留下示例食材让用户手动删，
 *                 也绝不因为「没有快照」去批量删除真实库存 / 计划 / 买菜清单 / 收藏），
 *                 示例状态清掉，因为这份快照本来就没有恢复价值。
 *   'partial'  —— 部分键没还原成功：保留 demo_snapshot 与 demo_mode 作为恢复锚点，
 *                 不退出示例，等用户清理存储空间后再退一次。绝不出现「恢复失败 + 快照已删」。
 * @returns {'invalid'|'restored'|'partial'}
 */
export function exitDemoKitchen({ onRoute = () => {} } = {}) {
  const outcome = restoreDemoKitchenSnapshot(S.load(S.keys.demo_snapshot, null));
  if (outcome !== 'partial') {
    localStorage.removeItem(S.keys.demo_mode);
    localStorage.removeItem(S.keys.demo_snapshot);
    localStorage.removeItem(S.keys.demo_step);
    setHomeTab(null);
  }
  onRoute();
  return outcome;
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
      body: DEMO_COPY.STEP_RECS_BODY,
      primary: '查看推荐',
      primaryStep: 'recs',
      secondary: '退出示例',
      secondaryAction: 'exit'
    },
    plan: {
      title: '第 3 步：做完后更新库存',
      body: DEMO_COPY.STEP_COOK_BODY,
      primary: '去看计划',
      primaryStep: 'cook',
      secondary: '退出示例',
      secondaryAction: 'exit'
    },
    cook: {
      title: '第 3 步：做完后更新库存',
      body: DEMO_COPY.STEP_COOK_BODY,
      primary: '我知道了',
      primaryStep: 'done',
      secondary: '开始我的厨房',
      secondaryAction: 'exit'
    },
    done: {
      title: '示例体验完成',
      body: DEMO_COPY.DONE_BODY,
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
    const outcome = exitDemoKitchen({ onRoute });
    // 如实提示，不谎报「已还原」。
    if (outcome === 'restored') showToast('已退出示例体验', { tone: 'info' });
    else if (outcome === 'invalid') showToast('已退出示例体验，示例食材可能需要你手动删除', { tone: 'warning' });
    else showToast('厨房数据没能完全恢复，已保留备份并停留在示例体验。请清理浏览器存储空间后再退出一次。', { tone: 'error' });
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
