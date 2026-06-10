import { todayISO } from '../storage.js?v=219';
import {
  buildCatalog,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=219';
import {
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=219';
import {
  addShoppingItem,
  buildCopyableShoppingList,
  clearDoneShoppingItems,
  convertShoppingItemToInventory,
  getVisibleShoppingItems,
  groupShoppingItemsByZone,
  loadShoppingItems,
  markAllShoppingItemsDone,
  mergeShoppingItems,
  saveShoppingItems
} from '../shopping.js?v=219';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=219';
import { restoreStapleByPurchase, restoreStaplesByPurchase } from '../staples.js?v=219';

// 兼容旧入口：完整库存已迁到独立「库存」Tab，本页不再内嵌库存分段；保留空实现避免外部 import 报错。
export function requestInventoryIntent() {}

function getShoppingRowIds(item) {
  if (Array.isArray(item?.ids) && item.ids.length) return item.ids;
  return item?.id ? [item.id] : [];
}

function updateShoppingRowsByIds(ids, updater) {
  const idSet = new Set(ids || []);
  const items = loadShoppingItems().map(item => idSet.has(item.id) ? updater({ ...item }) : item);
  saveShoppingItems(items);
}

function deleteShoppingRowsByIds(ids) {
  const idSet = new Set(ids || []);
  saveShoppingItems(loadShoppingItems().filter(item => !idSet.has(item.id)));
}

// 行内备注默认值：手写 remark 优先；回退系统自动生成的血统备注（菜谱缺货等来源），
// 但跳过「手动 / 其他」这类无意义的通用来源，避免噪音。
function remarkDefault(item) {
  if (item && item.remark) return item.remark;
  const src = String((item && item.source) || '').trim();
  if (src && src !== '手动' && src !== '其他') return src;
  return (item && item.reason) || '';
}

function showShoppingInventoryModal(item, onConfirm, onCancel) {
  const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit);
  const defaultKind = item.kind || (isDryGoodName(normalized.name) ? 'dry' : 'raw');
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="card shopping-inventory-modal">
      <h3>记进厨房</h3>
      <p class="meta">买完后顺手记进厨房。名称、数量不准也可以先改一下。</p>
      <div class="shopping-convert-grid">
        <label><span>食材名</span><input id="stockInName" value="${escapeOptionAttr(normalized.name)}"></label>
        <label><span>数量</span><input id="stockInQty" type="number" min="0" step="0.1" value="${escapeOptionAttr(normalized.qty)}"></label>
        <label><span>单位</span><select id="stockInUnit"><option value="">无单位</option><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="包">包</option><option value="瓶">瓶</option><option value="把">把</option><option value="份">份</option><option value="g">g</option><option value="ml">ml</option></select></label>
        <label><span>购买日期</span><input id="stockInDate" type="date" value="${todayISO()}"></label>
        <label><span>类型</span><select id="stockInKind"><option value="raw">新鲜食材</option><option value="dry">干货/调料</option></select></label>
      </div>
      <div id="stockInStatus" class="inline-status" hidden></div>
      <div class="controls receipt-confirm-actions">
        <button type="button" class="btn" id="cancelStockIn">取消</button>
        <button type="button" class="btn ok" id="saveStockIn">记进厨房</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  setSelectValueWithOption(overlay.querySelector('#stockInUnit'), normalized.unit || guessKitchenUnit(normalized.name) || '份');
  overlay.querySelector('#stockInKind').value = defaultKind;

  const close = () => overlay.remove();
  const cancel = () => {
    close();
    if (typeof onCancel === 'function') onCancel();
  };
  overlay.querySelector('#cancelStockIn').onclick = cancel;
  overlay.onclick = event => { if(event.target === overlay) cancel(); };
  overlay.querySelector('#saveStockIn').onclick = () => {
    const name = overlay.querySelector('#stockInName').value.trim();
    const qty = overlay.querySelector('#stockInQty').value;
    const unit = overlay.querySelector('#stockInUnit').value || guessKitchenUnit(name) || '份';
    const kind = overlay.querySelector('#stockInKind').value;
    if(!name) {
      setInlineStatus(overlay.querySelector('#stockInStatus'), '食材名不能为空。', 'bad');
      return;
    }
    if(Number(qty) < 0) {
      setInlineStatus(overlay.querySelector('#stockInStatus'), '数量不能为负数。', 'bad');
      return;
    }
    const entry = convertShoppingItemToInventory(item, {
      name,
      qty,
      unit,
      kind,
      buyDate: overlay.querySelector('#stockInDate').value || todayISO()
    });
    onConfirm(entry);
    close();
  };
}

export function renderShopping(pack, { onRoute = () => {} } = {}){
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const shoppingItems = loadShoppingItems();
  const mergedItems = mergeShoppingItems(shoppingItems);
  // 默认视图：未完成全部显示；已完成仅显示「最近 24 小时内」，更久的自动隐藏（数据不删）。
  const visibleItems = getVisibleShoppingItems(mergedItems, { includeRecentlyCompleted: true });
  const openItems = visibleItems.filter(item => !item.done);
  const doneItems = visibleItems.filter(item => item.done);
  const unstockedDoneItems = doneItems.filter(item => !item.stockedIn);

  // Weather-style 纵向页面：大标题 → 玻璃主状态卡 → 胶囊快速添加 → 入厨提示卡 →
  // 分区玻璃卡（单列）→ 最近完成 → 底部轻浮动操作（随内容滚动，不遮底部导航）。
  const page = document.createElement('div');
  page.className = 'shopping-weather-page';
  page.innerHTML = `
    <h2 class="shopping-weather-title">买菜清单</h2>
    <div id="shoppingStatus" class="inline-status" hidden></div>
  `;
  const status = page.querySelector('#shoppingStatus');

  const copyOpenItems = () => {
    const text = buildCopyableShoppingList([], loadShoppingItems());
    if(!text.trim()) { setInlineStatus(status, '买菜清单是空的。', 'info'); return; }
    navigator.clipboard.writeText(text)
      .then(() => setInlineStatus(status, '已复制未买内容。', 'ok'))
      .catch(() => setInlineStatus(status, text, 'info'));
  };

  const markEveryOpenItemDone = () => {
    const openNames = loadShoppingItems().filter(it => !it.done).map(it => it.name);
    markAllShoppingItemsDone();
    restoreStaplesByPurchase(openNames);
    onRoute();
  };

  const startBatchStockIn = (itemsList, index) => {
    if (index >= itemsList.length) {
      setInlineStatus(status, '已买的都记进厨房了。', 'ok');
      onRoute();
      return;
    }
    const item = itemsList[index];
    showShoppingInventoryModal(item, entry => {
      mergeInventoryEntry(inv, entry, { mode: 'add' });
      const nowIso = new Date().toISOString();
      updateShoppingRowsByIds(getShoppingRowIds(item), target => ({
        ...target,
        done: true,
        stockedIn: true,
        stockedInAt: nowIso,
        completedAt: target.completedAt || nowIso
      }));
      restoreStapleByPurchase(item.name); // 闭环：常备品入库后恢复充足
      startBatchStockIn(itemsList, index + 1);
    }, () => {
      startBatchStockIn(itemsList, index + 1);
    });
  };

  const stockInOne = (item) => {
    showShoppingInventoryModal(item, entry => {
      mergeInventoryEntry(inv, entry, { mode: 'add' });
      const nowIso = new Date().toISOString();
      updateShoppingRowsByIds(getShoppingRowIds(item), target => ({
        ...target,
        done: true,
        stockedIn: true,
        stockedInAt: nowIso,
        completedAt: target.completedAt || nowIso
      }));
      restoreStapleByPurchase(item.name);
      setInlineStatus(status, `${entry.name} 已记进厨房。`, 'ok');
      onRoute();
    });
  };

  const toggleItemDone = (item) => {
    const checked = !item.done;
    const nowIso = new Date().toISOString();
    updateShoppingRowsByIds(getShoppingRowIds(item), target => checked
      ? ({ ...target, done: true, completedAt: target.completedAt || nowIso })
      : ({ ...target, done: false, stockedIn: false, completedAt: null }));
    if (checked) restoreStapleByPurchase(item.name);
    onRoute();
  };

  // 顶部主状态卡：大数字 + 副文案 + 三个小统计（复制/全部已买/清除已买移到底部轻浮动操作）。
  const hero = document.createElement('section');
  hero.className = 'shopping-weather-hero';
  hero.innerHTML = `
    <div class="sw-hero-main">
      <span class="sw-hero-eyebrow">今天要买</span>
      <span class="sw-hero-num">${openItems.length}<small>样</small></span>
      <p class="sw-hero-sub">买到就点一下，买完顺手记进厨房。</p>
    </div>
    <div class="sw-hero-stats">
      <span class="sw-hero-stat">未买 <strong>${openItems.length}</strong></span>
      <span class="sw-hero-stat">已买 <strong>${doneItems.length}</strong></span>
      <span class="sw-hero-stat">待入厨 <strong>${unstockedDoneItems.length}</strong></span>
    </div>
  `;
  page.appendChild(hero);

  // 快速添加：半透明胶囊输入框，「加入」贴右侧。
  const quickAdd = document.createElement('section');
  quickAdd.className = 'shopping-weather-add';
  quickAdd.innerHTML = `
    <input id="shoppingQuickAddName" type="text" placeholder="临时加点什么">
    <button type="button" class="sw-add-btn" id="shoppingQuickAddBtn">加入</button>
  `;
  const quickInput = quickAdd.querySelector('#shoppingQuickAddName');
  const addQuickItem = () => {
    const name = quickInput.value.trim();
    if (!name) { setInlineStatus(status, '请输入要买的东西。', 'bad'); return; }
    addShoppingItem(name, '', '', '手动', '');
    onRoute();
  };
  quickAdd.querySelector('#shoppingQuickAddBtn').onclick = addQuickItem;
  quickInput.onkeydown = event => {
    if (event.key === 'Enter') addQuickItem();
  };
  page.appendChild(quickAdd);

  // 待入厨提示卡：轻柔玻璃提示（不是警告），放在快速添加下、分区列表上。
  if (unstockedDoneItems.length) {
    const banner = document.createElement('section');
    banner.className = 'shopping-stockin-banner sw-tip-card';
    banner.innerHTML = `
      <span class="sw-tip-text">有 ${unstockedDoneItems.length} 样买完还没记进厨房</span>
      <button type="button" class="sw-tip-btn" id="batchStockIn">全部记进厨房</button>
    `;
    banner.querySelector('#batchStockIn').onclick = () => startBatchStockIn(unstockedDoneItems, 0);
    page.appendChild(banner);
  }

  // iOS 天气式列表行：大圆形勾选 + 名称/备注 + 右侧弱化动作；整行可点切换已买。
  const renderWeatherRow = (item) => {
    const row = document.createElement('div');
    row.className = `shopping-weather-row${item.done ? ' is-done' : ''}${item.stockedIn ? ' is-stocked' : ''}`;
    row.setAttribute('role', 'button');
    row.setAttribute('tabindex', '0');
    row.setAttribute('aria-pressed', item.done ? 'true' : 'false');
    const metaParts = [
      item.amountText || '',
      remarkDefault(item) || item.source || ''
    ].filter(Boolean);
    const actionHtml = item.done
      ? item.stockedIn
        ? '<span class="sw-state-stocked">已记进厨房</span>'
        : '<button type="button" class="shopping-weather-stockin">记进厨房</button>'
      : '<button type="button" class="sw-row-delete" aria-label="删除">✕</button>';
    row.innerHTML = `
      <span class="shopping-weather-check" aria-hidden="true">${item.done ? '✓' : ''}</span>
      <span class="shopping-weather-main">
        <span class="shopping-weather-name">${escapeHtml(item.name)}</span>
        <span class="shopping-weather-meta">${escapeHtml(metaParts.join(' · ') || '按需')}</span>
      </span>
      <span class="shopping-weather-row-actions">${actionHtml}</span>
    `;
    row.onclick = () => toggleItemDone(item);
    row.onkeydown = event => {
      if (!['Enter', ' '].includes(event.key)) return;
      event.preventDefault();
      toggleItemDone(item);
    };
    row.querySelector('.sw-row-delete')?.addEventListener('click', event => {
      event.stopPropagation();
      deleteShoppingRowsByIds(getShoppingRowIds(item));
      onRoute();
    });
    row.querySelector('.shopping-weather-stockin')?.addEventListener('click', event => {
      event.stopPropagation();
      stockInOne(item);
    });
    return row;
  };

  // 分区玻璃卡：标题行（分区名 + N 未买）+ 行列表；最近完成单独一张、整体更弱。
  const renderZoneCard = (title, items, { completed = false } = {}) => {
    const card = document.createElement('section');
    card.className = `shopping-weather-zone${completed ? ' shopping-weather-completed' : ''}`;
    card.innerHTML = `
      <div class="shopping-weather-zone-head">
        <span class="sw-zone-label">${escapeHtml(title)}</span>
        <span class="shopping-weather-zone-count">${items.length}${completed ? '' : ' 未买'}</span>
      </div>
      ${completed ? '<p class="sw-zone-sub">买完后可以在这里记进厨房。</p>' : ''}
    `;
    items.forEach(item => card.appendChild(renderWeatherRow(item)));
    return card;
  };

  if (!visibleItems.length) {
    // 空状态：大玻璃卡。
    const empty = document.createElement('section');
    empty.className = 'shopping-weather-empty';
    empty.innerHTML = `
      <strong>买菜清单是空的</strong>
      <span>可以从推荐菜谱、做完补货，或者首页待买里添加。</span>
      <button type="button" class="sw-action-pill" id="shoppingGoToday">回首页看看</button>
    `;
    empty.querySelector('#shoppingGoToday').onclick = () => { location.hash = '#today'; };
    page.appendChild(empty);
  } else {
    const zones = document.createElement('section');
    zones.className = 'shopping-weather-zones';
    groupShoppingItemsByZone(openItems).forEach(group => {
      if (!group.items.length) return; // 空分区不显示
      zones.appendChild(renderZoneCard(group.label, group.items));
    });
    page.appendChild(zones);
    if (doneItems.length) page.appendChild(renderZoneCard('最近完成', doneItems, { completed: true }));

    // 底部轻浮动操作条：随内容滚动（不 fixed，避免遮底部导航）；清除已买弱化。
    const actions = document.createElement('div');
    actions.className = 'shopping-floating-actions';
    actions.innerHTML = `
      <button type="button" class="sw-action-pill" id="copyOpenShopping">复制未买</button>
      <button type="button" class="sw-action-pill" id="markAllDone">全部已买</button>
      <button type="button" class="sw-action-pill sw-action-weak" id="clearDone">清除已买</button>
    `;
    actions.querySelector('#copyOpenShopping').onclick = copyOpenItems;
    actions.querySelector('#markAllDone').onclick = markEveryOpenItemDone;
    actions.querySelector('#clearDone').onclick = () => { clearDoneShoppingItems(); onRoute(); };
    page.appendChild(actions);
  }

  return page;
}
