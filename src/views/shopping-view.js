import { todayISO } from '../storage.js?v=203';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=203';
import {
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=203';
import {
  addShoppingItem,
  buildCopyableShoppingList,
  clearDoneShoppingItems,
  convertShoppingItemToInventory,
  groupShoppingItemsBySource,
  loadShoppingItems,
  markAllShoppingItemsDone,
  mergeShoppingItems,
  saveShoppingItems
} from '../shopping.js?v=203';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=203';
import {
  PANTRY_GROUP_OPTIONS,
  STAPLE_STATUS,
  addCustomPantryEntry,
  getManagedStapleGroups,
  getStapleState,
  removePantryEntry,
  restoreStapleByPurchase,
  restoreStaplesByPurchase,
  toggleStaple,
  updatePantryEntry
} from '../staples.js?v=203';
import { renderInventory } from './inventory-view.js?v=203';
import { renderDryGoodsCabinet } from '../components/pantry-shelf.js?v=203';

// 跨页意图：首页「批量入库 / 拍小票 / 临期雷达」跳到本页后要打开的库存区动作。
let pendingInventoryIntent = null;
export function requestInventoryIntent(kind) { pendingInventoryIntent = kind; }

// 库存管理页改用 iOS 风格「分段控件」：记忆当前选中的分段，避免编辑库存触发重渲染后跳回。
// 取值：'shopping' = 购物项｜'staples' = 常备货架｜'inventory' = 完整库存。
let activeInventoryTab = 'shopping';
let isManagingPantry = false;
const INVENTORY_TABS = [
  { key: 'shopping', label: '🛒 购物项' },
  { key: 'staples', label: '🧂 常备货架' },
  { key: 'inventory', label: '📦 完整库存' }
];

function updateShoppingRowsByIds(ids, updater) {
  const idSet = new Set(ids || []);
  const items = loadShoppingItems().map(item => idSet.has(item.id) ? updater({ ...item }) : item);
  saveShoppingItems(items);
}

function deleteShoppingRowsByIds(ids) {
  const idSet = new Set(ids || []);
  saveShoppingItems(loadShoppingItems().filter(item => !idSet.has(item.id)));
}

function showShoppingInventoryModal(item, onConfirm, onCancel) {
  const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit);
  const defaultKind = item.kind || (isDryGoodName(normalized.name) ? 'dry' : 'raw');
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="card shopping-inventory-modal">
      <h3>确认入库</h3>
      <p class="meta">买完后再入库。这里可以先修正名称、数量、单位和类型。</p>
      <div class="shopping-convert-grid">
        <label><span>食材名</span><input id="stockInName" value="${escapeOptionAttr(normalized.name)}"></label>
        <label><span>数量</span><input id="stockInQty" type="number" min="0" step="0.1" value="${escapeOptionAttr(normalized.qty)}"></label>
        <label><span>单位</span><select id="stockInUnit"><option value="">无单位</option><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="包">包</option><option value="瓶">瓶</option><option value="把">把</option><option value="份">份</option><option value="g">g</option><option value="ml">ml</option></select></label>
        <label><span>购买日期</span><input id="stockInDate" type="date" value="${todayISO()}"></label>
        <label><span>类型</span><select id="stockInKind"><option value="raw">普通食材</option><option value="dry">常备干货</option></select></label>
      </div>
      <div id="stockInStatus" class="inline-status" hidden></div>
      <div class="controls receipt-confirm-actions">
        <button type="button" class="btn" id="cancelStockIn">取消</button>
        <button type="button" class="btn ok" id="saveStockIn">确认入库</button>
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

const PANTRY_STOCK_GROUPS = new Set(['蛋奶', '干货']);

function getPantryGroupOptions(entry = null) {
  if (!entry) return PANTRY_GROUP_OPTIONS;
  if (entry.type === 'pantry') return PANTRY_GROUP_OPTIONS.filter(group => PANTRY_STOCK_GROUPS.has(group));
  return PANTRY_GROUP_OPTIONS.filter(group => !PANTRY_STOCK_GROUPS.has(group));
}

function closeLiquidModal(overlay, panel) {
  panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
  panel.style.opacity = '0';
  panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
  overlay.classList.add('closing');
  window.setTimeout(() => overlay.remove(), 220);
}

function renderPantryGroupSelect(options, selected) {
  const chosen = selected && !options.includes(selected) ? [...options, selected] : options;
  return chosen.map(group => `<option value="${escapeOptionAttr(group)}">${escapeHtml(group)}</option>`).join('');
}

function showPantryEntryModal({ entry = null, onRoute = () => {} } = {}) {
  const isEdit = !!entry;
  const options = getPantryGroupOptions(entry);
  const defaultGroup = entry?.group || options[0] || '基础调味';
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content pantry-manage-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">${isEdit ? `编辑「${escapeHtml(entry.name)}」` : '+ 自定义添加'}</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body pantry-manage-body">
      <label class="pantry-manage-field">
        <span>食材名称</span>
        <input class="km-modal-input" id="pantryEntryName" value="${escapeOptionAttr(entry?.name || '')}" placeholder="例如：黑木耳">
      </label>
      <label class="pantry-manage-field">
        <span>所属分类</span>
        <select class="km-modal-input" id="pantryEntryGroup">${renderPantryGroupSelect(options, defaultGroup)}</select>
      </label>
      <div id="pantryManageStatus" class="small inline-status" hidden></div>
      <div class="km-modal-actions pantry-manage-actions">
        <button type="button" class="btn" id="cancelPantryManage">取消</button>
        <button type="button" class="btn ok" id="savePantryManage">${isEdit ? '保存修改' : '添加到货架'}</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add('open'));

  const nameInput = panel.querySelector('#pantryEntryName');
  const groupSelect = panel.querySelector('#pantryEntryGroup');
  const status = panel.querySelector('#pantryManageStatus');
  groupSelect.value = defaultGroup;

  const close = () => closeLiquidModal(overlay, panel);
  panel.querySelector('.km-modal-close').onclick = close;
  panel.querySelector('#cancelPantryManage').onclick = close;
  overlay.onclick = event => { if (event.target === overlay) close(); };
  nameInput.focus();

  const save = () => {
    const name = nameInput.value.trim();
    const group = groupSelect.value;
    if (!name) {
      setInlineStatus(status, '请先输入常备食材名称。', 'bad');
      return;
    }

    const result = isEdit
      ? updatePantryEntry(entry, { name, group })
      : addCustomPantryEntry({
          name,
          group,
          type: PANTRY_STOCK_GROUPS.has(group) ? 'pantry' : 'staple',
          kind: group === '干货' ? 'dry' : (group === '蛋奶' ? 'raw' : 'staple'),
          unit: PANTRY_STOCK_GROUPS.has(group) ? (guessKitchenUnit(name) || '份') : '',
          source: group === '干货' ? '常备干货' : (group === '蛋奶' ? '日常补给' : '常备品')
        });
    if (!result.ok) {
      setInlineStatus(status, result.message || '保存失败，请稍后再试。', 'bad');
      return;
    }
    isManagingPantry = true;
    close();
    onRoute();
  };

  panel.querySelector('#savePantryManage').onclick = save;
  nameInput.onkeydown = event => {
    if (event.key === 'Enter') save();
  };
}

function showPantryDeleteConfirm(entry, { onRoute = () => {} } = {}) {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content pantry-manage-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">移除常备项？</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body pantry-manage-body">
      <p class="pantry-confirm-copy">「${escapeHtml(entry.name)}」会从常备货架里隐藏或删除，库存记录本身不会被清空。</p>
      <div class="km-modal-actions pantry-manage-actions">
        <button type="button" class="btn" id="cancelPantryDelete">取消</button>
        <button type="button" class="btn bad" id="confirmPantryDelete">移除</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add('open'));

  const close = () => closeLiquidModal(overlay, panel);
  panel.querySelector('.km-modal-close').onclick = close;
  panel.querySelector('#cancelPantryDelete').onclick = close;
  overlay.onclick = event => { if (event.target === overlay) close(); };
  panel.querySelector('#confirmPantryDelete').onclick = () => {
    removePantryEntry(entry);
    isManagingPantry = true;
    close();
    onRoute();
  };
}

// 【常备货架】统一管理：调料/米面（双态常备品）+ 蛋奶/干货（同样的双态瓦片）。
// 不再使用折叠 <details>，直接返回平铺内容卡片，由分段控件控制显隐。
function renderStaplesShelf(inv, { onRoute = () => {} } = {}) {
  const panel = document.createElement('div');
  panel.className = 'staples-shelf-content';
  panel.innerHTML = `
    <div class="card staples-card">
      <div class="staples-card-head">
        <p class="meta shopping-staple-meta">标记为<strong>不足</strong>会自动加入购物清单；买好后在清单里勾选「已买」，常备调料会自动恢复为<strong>充足</strong>。</p>
        <button type="button" class="pantry-manage-btn" id="togglePantryManage">${isManagingPantry ? '✓ 完成' : '⚙️ 管理货架'}</button>
      </div>
      <div id="stapleShelf"></div>
    </div>
  `;
  panel.querySelector('#togglePantryManage').onclick = () => {
    isManagingPantry = !isManagingPantry;
    activeInventoryTab = 'staples';
    onRoute();
  };
  const shelf = panel.querySelector('#stapleShelf');
  let addTileRendered = false;
  const managedStapleGroups = getManagedStapleGroups();
  if (isManagingPantry && managedStapleGroups.length === 0) managedStapleGroups.push({ group: '自定义', items: [] });
  managedStapleGroups.forEach(group => {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'shopping-staple-group';
    groupDiv.innerHTML = `<div class="shopping-staple-title">${escapeHtml(group.group)}</div>`;
    const grid = document.createElement('div');
    grid.className = 'staple-tile-grid';
    const sortedItems = [...group.items].sort((a, b) => {
      const aLow = getStapleState(a.name).status === STAPLE_STATUS.INSUFFICIENT;
      const bLow = getStapleState(b.name).status === STAPLE_STATUS.INSUFFICIENT;
      if (aLow !== bLow) return aLow ? -1 : 1;
      return a.name.localeCompare(b.name, 'zh-Hans-CN');
    });
    if (isManagingPantry && !addTileRendered) {
      addTileRendered = true;
      const addTile = document.createElement('button');
      addTile.type = 'button';
      addTile.className = 'staple-tile staple-add-tile';
      addTile.innerHTML = '<span class="staple-tile-name">+ 自定义添加</span>';
      addTile.onclick = () => showPantryEntryModal({ onRoute });
      grid.appendChild(addTile);
    }
    sortedItems.forEach(entry => {
      const state = getStapleState(entry.name);
      const low = state.status === STAPLE_STATUS.INSUFFICIENT;
      const tile = document.createElement(isManagingPantry ? 'div' : 'button');
      if (!isManagingPantry) tile.type = 'button';
      tile.className = `staple-tile ${low ? 'is-low' : 'is-ok'}${isManagingPantry ? ' is-managing' : ''}`;
      tile.setAttribute('aria-pressed', low ? 'true' : 'false');
      tile.setAttribute('aria-label', `${entry.name}：${low ? '不足，点击标记为充足' : '充足，点击标记为不足'}`);
      if (isManagingPantry) {
        tile.setAttribute('role', 'button');
        tile.tabIndex = 0;
      }
      tile.innerHTML = `
        <span class="staple-tile-name">${escapeHtml(entry.name)}</span>
        <span class="staple-status-dot" aria-hidden="true"></span>
        ${isManagingPantry ? '<button type="button" class="staple-delete-btn" aria-label="移除">×</button>' : ''}
      `;
      if (isManagingPantry) {
        tile.onclick = () => showPantryEntryModal({ entry, onRoute });
        tile.onkeydown = event => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            showPantryEntryModal({ entry, onRoute });
          }
        };
        tile.querySelector('.staple-delete-btn').onclick = event => {
          event.stopPropagation();
          showPantryDeleteConfirm(entry, { onRoute });
        };
      } else {
        tile.onclick = () => { toggleStaple(entry.name); onRoute(); };
      }
      grid.appendChild(tile);
    });
    groupDiv.appendChild(grid);
    shelf.appendChild(groupDiv);
  });

  // 蛋奶 / 干货：同样的双态瓦片，直接并入同一组网格，视觉与调料一致。
  shelf.appendChild(renderDryGoodsCabinet(inv, {
    onRoute,
    isManagingPantry,
    onEditPantryItem: entry => showPantryEntryModal({ entry, onRoute }),
    onDeletePantryItem: entry => showPantryDeleteConfirm(entry, { onRoute })
  }));

  return panel;
}

export function renderShopping(pack, { onRoute = () => {} } = {}){
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const ingredientOptions = buildIngredientOptions(catalog);
  const shoppingItems = loadShoppingItems();
  const mergedItems = mergeShoppingItems(shoppingItems);
  const openItems = mergedItems.filter(item => !item.done);
  const doneItems = mergedItems.filter(item => item.done);

  const page = document.createElement('div');
  page.className = 'shopping-page';
  page.innerHTML = `
    <h2 class="section-title">库存管理</h2>
    <div id="shoppingStatus" class="inline-status" hidden></div>
  `;
  const status = page.querySelector('#shoppingStatus');

  // 「添加项」内联快捷输入：默认隐藏，由「我的购物项」右上角的 ＋ 按钮唤出。
  const manualCard = document.createElement('div');
  manualCard.className = 'shopping-manual-inline is-hidden';
  manualCard.innerHTML = `
    <div class="shopping-add-row">
      <input id="shoppingAddName" list="shoppingCatalogList" placeholder="想买什么">
      <datalist id="shoppingCatalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      <input id="shoppingAddQty" type="number" min="0" step="1" placeholder="数量">
      <select id="shoppingAddUnit"><option value="">无单位</option><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="包">包</option><option value="瓶">瓶</option><option value="把">把</option><option value="份">份</option><option value="g">g</option><option value="ml">ml</option></select>
      <button type="button" class="btn ok" id="shoppingAddBtn">加入</button>
    </div>
  `;
  manualCard.querySelector('#shoppingAddName').addEventListener('input', event => {
    const val = event.target.value.trim();
    if(val) setSelectValueWithOption(manualCard.querySelector('#shoppingAddUnit'), guessKitchenUnit(getCanonicalName(val)) || '');
  });
  manualCard.querySelector('#shoppingAddBtn').onclick = () => {
    const name = manualCard.querySelector('#shoppingAddName').value.trim();
    if(!name) { setInlineStatus(status, '请输入要买的东西。', 'bad'); return; }
    addShoppingItem(name, manualCard.querySelector('#shoppingAddQty').value || '', manualCard.querySelector('#shoppingAddUnit').value || '', '手动');
    onRoute();
  };

  const itemCard = document.createElement('div');
  itemCard.className = 'card shopping-items-card';
  itemCard.innerHTML = `
    <div class="shopping-card-head shopping-toolbar">
      <button type="button" class="btn ok small shopping-add-primary" id="miniAddItem">＋ 添加项</button>
      <div class="shopping-tool-group">
        <button type="button" class="shopping-tool-btn" id="copyOpenShopping">复制未买清单</button>
        <button type="button" class="shopping-tool-btn" id="markAllDone">全部标记已买</button>
        <button type="button" class="shopping-tool-btn shopping-tool-ok is-hidden" id="batchStockIn">逐项确认入库</button>
        <button type="button" class="shopping-tool-btn shopping-clear-btn" id="clearDone">清除已买</button>
      </div>
    </div>
  `;
  // 内联「添加项」快捷输入，嵌入在购物项区块顶部，默认隐藏。
  itemCard.appendChild(manualCard);
  itemCard.querySelector('#miniAddItem').onclick = () => {
    manualCard.classList.toggle('is-hidden');
    if (!manualCard.classList.contains('is-hidden')) manualCard.querySelector('#shoppingAddName').focus();
  };

  const itemList = document.createElement('div');
  itemList.className = 'shopping-item-list grouped';

  const renderItemRow = (item) => {
    const row = document.createElement('div');
    row.className = `shopping-item-row${item.done ? ' done' : ''}`;
    const stockInHtml = item.done
      ? item.stockedIn
        ? '<span class="btn small stocked-in-badge" aria-label="已入库">✓ 已入库</span>'
        : '<button type="button" class="btn ok small stock-in-btn">入库</button>'
      : '';
    row.innerHTML = `
      <label class="shopping-check"><input type="checkbox" ${item.done ? 'checked' : ''}><span>${escapeHtml(item.name)}</span></label>
      <span class="shopping-item-amount">${escapeHtml(item.amountText || '按需')}</span>
      <span class="shopping-source">${escapeHtml(item.source || '手动')}</span>
      <div class="shopping-row-actions">
        ${stockInHtml}
        <button type="button" class="btn small bad delete-shopping-btn">删</button>
      </div>
    `;
    row.querySelector('input').onchange = event => {
      updateShoppingRowsByIds(item.ids, target => ({ ...target, done: event.target.checked }));
      // 闭环：勾选「已买」时，若是常备品则恢复为充足并更新库存时间。
      if (event.target.checked) restoreStapleByPurchase(item.name);
      onRoute();
    };
    const stockBtn = row.querySelector('.stock-in-btn');
    if(stockBtn) {
      stockBtn.onclick = () => {
        showShoppingInventoryModal(item, entry => {
          mergeInventoryEntry(inv, entry, { mode: 'add' });
          updateShoppingRowsByIds(item.ids, target => ({
            ...target,
            done: true,
            stockedIn: true,
            stockedInAt: new Date().toISOString()
          }));
          restoreStapleByPurchase(item.name); // 闭环：常备品入库后恢复充足
          setInlineStatus(status, `${entry.name} 已入库。`, 'ok');
          onRoute();
        });
      };
    }
    row.querySelector('.delete-shopping-btn').onclick = () => {
      deleteShoppingRowsByIds(item.ids);
      onRoute();
    };
    return row;
  };

  const renderGroups = (title, items, emptyText) => {
    const section = document.createElement('div');
    section.className = 'shopping-source-section';
    section.innerHTML = `<div class="shopping-source-title">${escapeHtml(title)}<span>${items.length}</span></div>`;
    if(!items.length) {
      const empty = document.createElement('p');
      empty.className = 'small';
      empty.textContent = emptyText;
      section.appendChild(empty);
      return section;
    }
    groupShoppingItemsBySource(items).forEach(group => {
      const groupDiv = document.createElement('div');
      groupDiv.className = 'shopping-source-group';
      groupDiv.innerHTML = `<div class="shopping-source-label">${escapeHtml(group.label)}</div>`;
      group.items.forEach(item => groupDiv.appendChild(renderItemRow(item)));
      section.appendChild(groupDiv);
    });
    return section;
  };

  itemList.appendChild(renderGroups('未买', openItems, '还没有未买的购物项。'));
  itemList.appendChild(renderGroups('已买 / 可入库', doneItems, '勾选"已买"后，可以在这里确认入库。'));
  itemCard.appendChild(itemList);

  const startBatchStockIn = (itemsList, index) => {
    if (index >= itemsList.length) {
      setInlineStatus(status, '已买项目逐项确认入库完成。', 'ok');
      onRoute();
      return;
    }
    const item = itemsList[index];
    showShoppingInventoryModal(item, entry => {
      mergeInventoryEntry(inv, entry, { mode: 'add' });
      updateShoppingRowsByIds(item.ids, target => ({
        ...target,
        done: true,
        stockedIn: true,
        stockedInAt: new Date().toISOString()
      }));
      restoreStapleByPurchase(item.name); // 闭环：常备品入库后恢复充足
      startBatchStockIn(itemsList, index + 1);
    }, () => {
      startBatchStockIn(itemsList, index + 1);
    });
  };

  const unstockedDoneItems = doneItems.filter(item => !item.stockedIn);
  const batchBtn = itemCard.querySelector('#batchStockIn');
  if (unstockedDoneItems.length > 0) {
    batchBtn.classList.remove('is-hidden');
    batchBtn.onclick = () => {
      startBatchStockIn(unstockedDoneItems, 0);
    };
  } else {
    batchBtn.classList.add('is-hidden');
  }

  itemCard.querySelector('#markAllDone').onclick = () => {
    // 闭环：标记全部已买时，把其中的常备品都恢复为充足。
    const openNames = loadShoppingItems().filter(it => !it.done).map(it => it.name);
    markAllShoppingItemsDone();
    restoreStaplesByPurchase(openNames);
    onRoute();
  };
  itemCard.querySelector('#clearDone').onclick = () => { clearDoneShoppingItems(); onRoute(); };
  itemCard.querySelector('#copyOpenShopping').onclick = () => {
    const text = buildCopyableShoppingList([], loadShoppingItems());
    if(!text.trim()) { setInlineStatus(status, '清单是空的。', 'info'); return; }
    navigator.clipboard.writeText(text)
      .then(() => setInlineStatus(status, '已复制未买清单。', 'ok'))
      .catch(() => setInlineStatus(status, text, 'info'));
  };
  // 【常备货架】内容：调料/米面 + 蛋奶/干货，统一双态瓦片（平铺，无折叠）。
  const staplesShelf = renderStaplesShelf(inv, { onRoute });

  // 【完整库存】内容：保留已优化的高密度双列网格，仅去掉折叠外壳，直接平铺。
  const inventoryNode = renderInventory(pack, { showTitle: false, onInventoryChanged: onRoute });

  // ── iOS 风格「分段控件」：顶部吸顶三选项，下方平铺渲染对应内容，无折叠动画 ──
  const segmented = document.createElement('div');
  segmented.className = 'inv-segmented';
  segmented.setAttribute('role', 'tablist');
  segmented.setAttribute('aria-label', '库存管理分段');
  INVENTORY_TABS.forEach(tab => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'inv-seg-btn';
    btn.dataset.tab = tab.key;
    btn.textContent = tab.label;
    btn.setAttribute('role', 'tab');
    segmented.appendChild(btn);
  });

  // 三个内容面板，包进同一容器，靠分段控件切换显隐（display 切换，无重渲染、无动画）。
  const panelWrap = document.createElement('div');
  panelWrap.className = 'inv-panel-wrap';
  const panelNodes = {};
  const panelSource = { shopping: itemCard, staples: staplesShelf, inventory: inventoryNode };
  INVENTORY_TABS.forEach(tab => {
    const p = document.createElement('div');
    p.className = 'inv-panel';
    p.dataset.panel = tab.key;
    p.appendChild(panelSource[tab.key]);
    panelWrap.appendChild(p);
    panelNodes[tab.key] = p;
  });

  const setTab = (key) => {
    if (!panelNodes[key]) key = 'shopping';
    activeInventoryTab = key;
    segmented.querySelectorAll('.inv-seg-btn').forEach(b => {
      const on = b.dataset.tab === key;
      b.classList.toggle('is-active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    Object.entries(panelNodes).forEach(([k, p]) => p.classList.toggle('is-hidden', k !== key));
  };
  segmented.querySelectorAll('.inv-seg-btn').forEach(b => { b.onclick = () => setTab(b.dataset.tab); });

  page.appendChild(segmented);
  page.appendChild(panelWrap);

  // 消费跨页意图：首页「批量入库 / 拍小票」跳转过来时，自动切到「完整库存」分段并触发动作。
  if (pendingInventoryIntent) {
    const intent = pendingInventoryIntent;
    pendingInventoryIntent = null;
    activeInventoryTab = 'inventory';
    setTab('inventory');
    setTimeout(() => {
      if (intent === 'add') {
        const form = panelNodes.inventory.querySelector('.add-form-container');
        const toggle = panelNodes.inventory.querySelector('#toggleAddBtn');
        if (form && toggle && !form.classList.contains('open')) toggle.click();
      } else if (intent === 'receipt') {
        const cam = panelNodes.inventory.querySelector('#camInput');
        if (cam) cam.click();
      }
      panelNodes.inventory.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }, 60);
  } else {
    setTab(activeInventoryTab);
  }

  return page;
}
