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

  const page = document.createElement('div');
  page.className = 'shopping-page shopping-unified';
  page.innerHTML = `
    <h2 class="section-title">买菜清单</h2>
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

  const summary = document.createElement('section');
  summary.className = 'shopping-summary-card';
  summary.innerHTML = `
    <div class="shopping-summary-copy">
      <h3>今天要买 ${openItems.length} 样</h3>
      <p>买到就点一下，买完可以顺手记进厨房。</p>
    </div>
    <div class="shopping-summary-actions">
      <button type="button" class="shopping-tool-btn" id="copyOpenShopping">复制未买</button>
      <button type="button" class="shopping-tool-btn" id="markAllDone">全部标记已买</button>
      <button type="button" class="shopping-tool-btn shopping-clear-btn" id="clearDone">清除已买</button>
    </div>
  `;
  summary.querySelector('#copyOpenShopping').onclick = copyOpenItems;
  summary.querySelector('#markAllDone').onclick = markEveryOpenItemDone;
  summary.querySelector('#clearDone').onclick = () => { clearDoneShoppingItems(); onRoute(); };
  page.appendChild(summary);

  const quickAdd = document.createElement('div');
  quickAdd.className = 'shopping-quick-add';
  quickAdd.innerHTML = `
    <input id="shoppingQuickAddName" type="text" placeholder="临时加点什么">
    <button type="button" class="btn ok small" id="shoppingQuickAddBtn">加入</button>
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

  if (unstockedDoneItems.length) {
    const banner = document.createElement('div');
    banner.className = 'shopping-stockin-banner';
    banner.innerHTML = `
      <span>有 ${unstockedDoneItems.length} 样买完还没记进厨房</span>
      <button type="button" class="shopping-tool-btn shopping-tool-ok" id="batchStockIn">全部记进厨房</button>
    `;
    banner.querySelector('#batchStockIn').onclick = () => startBatchStockIn(unstockedDoneItems, 0);
    page.appendChild(banner);
  }

  const list = document.createElement('div');
  list.className = 'shopping-unified-list';

  const renderUnifiedRow = (item) => {
    const row = document.createElement('div');
    row.className = `shopping-unified-row${item.done ? ' is-done' : ''}${item.stockedIn ? ' is-stocked' : ''}`;
    row.setAttribute('role', 'button');
    row.setAttribute('tabindex', '0');
    row.setAttribute('aria-pressed', item.done ? 'true' : 'false');
    const metaParts = [
      item.amountText || '',
      remarkDefault(item) || item.source || ''
    ].filter(Boolean);
    const actionHtml = item.done
      ? item.stockedIn
        ? '<span class="shopping-unified-state">已记进厨房</span>'
        : '<span class="shopping-unified-state is-bought">已买</span><button type="button" class="shopping-unified-stock">记进厨房</button>'
      : '<button type="button" class="shopping-unified-delete" aria-label="删除">删</button>';
    row.innerHTML = `
      <span class="shopping-unified-check" aria-hidden="true">${item.done ? '✓' : ''}</span>
      <span class="shopping-unified-main">
        <span class="shopping-unified-name">${escapeHtml(item.name)}</span>
        <span class="shopping-unified-meta">${escapeHtml(metaParts.join(' · ') || '按需')}</span>
      </span>
      <span class="shopping-unified-actions">${actionHtml}</span>
    `;
    row.onclick = () => toggleItemDone(item);
    row.onkeydown = event => {
      if (!['Enter', ' '].includes(event.key)) return;
      event.preventDefault();
      toggleItemDone(item);
    };
    row.querySelector('.shopping-unified-delete')?.addEventListener('click', event => {
      event.stopPropagation();
      deleteShoppingRowsByIds(getShoppingRowIds(item));
      onRoute();
    });
    row.querySelector('.shopping-unified-stock')?.addEventListener('click', event => {
      event.stopPropagation();
      stockInOne(item);
    });
    return row;
  };

  const renderZone = (title, items, isDoneSection = false) => {
    const section = document.createElement('section');
    section.className = `shopping-zone-section${isDoneSection ? ' is-completed' : ''}`;
    section.innerHTML = `
      <div class="shopping-zone-title">
        <span>${escapeHtml(title)}</span>
        <small>${items.length}</small>
      </div>
    `;
    items.forEach(item => section.appendChild(renderUnifiedRow(item)));
    return section;
  };

  if (!visibleItems.length) {
    const empty = document.createElement('div');
    empty.className = 'shopping-unified-empty';
    empty.innerHTML = `
      <strong>买菜清单是空的</strong>
      <span>可以从推荐菜谱、做完补货，或者首页待买里添加。</span>
      <button type="button" class="btn" id="shoppingGoToday">回首页看看</button>
    `;
    empty.querySelector('#shoppingGoToday').onclick = () => { location.hash = '#today'; };
    list.appendChild(empty);
  } else {
    groupShoppingItemsByZone(openItems).forEach(group => {
      list.appendChild(renderZone(group.label, group.items));
    });
    if (doneItems.length) list.appendChild(renderZone('最近完成', doneItems, true));
  }

  page.appendChild(list);

  return page;
}
