import { todayISO } from '../storage.js?v=199';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=199';
import {
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=199';
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
} from '../shopping.js?v=199';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=199';
import {
  STAPLE_CATALOG,
  STAPLE_STATUS,
  getStapleState,
  restoreStapleByPurchase,
  restoreStaplesByPurchase,
  toggleStaple
} from '../staples.js?v=199';
import { renderInventory } from './inventory-view.js?v=199';
import { renderDryGoodsCabinet } from '../components/pantry-shelf.js?v=200';

// 跨页意图：首页「批量入库 / 拍小票 / 临期雷达」跳到本页后要打开的库存区动作。
let pendingInventoryIntent = null;
export function requestInventoryIntent(kind) { pendingInventoryIntent = kind; }

// 库存管理页改用 iOS 风格「分段控件」：记忆当前选中的分段，避免编辑库存触发重渲染后跳回。
// 取值：'shopping' = 购物项｜'staples' = 常备货架｜'inventory' = 完整库存。
let activeInventoryTab = 'shopping';
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

// 【常备货架】统一管理：调料/米面（双态常备品）+ 蛋奶/干货（同样的双态瓦片）。
// 不再使用折叠 <details>，直接返回平铺内容卡片，由分段控件控制显隐。
function renderStaplesShelf(inv, { onRoute = () => {} } = {}) {
  const panel = document.createElement('div');
  panel.className = 'staples-shelf-content';
  panel.innerHTML = `
    <div class="card staples-card">
      <p class="meta shopping-staple-meta">标记为<strong>不足</strong>会自动加入购物清单；买好后在清单里勾选「已买」，常备调料会自动恢复为<strong>充足</strong>。</p>
      <div id="stapleShelf"></div>
    </div>
  `;
  const shelf = panel.querySelector('#stapleShelf');
  STAPLE_CATALOG.forEach(group => {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'shopping-staple-group';
    groupDiv.innerHTML = `<div class="shopping-staple-title">${escapeHtml(group.group)}</div>`;
    const grid = document.createElement('div');
    grid.className = 'staple-tile-grid';
    const sortedItems = [...group.items].sort((a, b) => {
      const aLow = getStapleState(a).status === STAPLE_STATUS.INSUFFICIENT;
      const bLow = getStapleState(b).status === STAPLE_STATUS.INSUFFICIENT;
      if (aLow !== bLow) return aLow ? -1 : 1;
      return a.localeCompare(b, 'zh-Hans-CN');
    });
    sortedItems.forEach(name => {
      const state = getStapleState(name);
      const low = state.status === STAPLE_STATUS.INSUFFICIENT;
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = `staple-tile ${low ? 'is-low' : 'is-ok'}`;
      tile.setAttribute('aria-pressed', low ? 'true' : 'false');
      tile.setAttribute('aria-label', `${name}：${low ? '不足，点击标记为充足' : '充足，点击标记为不足'}`);
      tile.innerHTML = `
        <span class="staple-tile-name">${escapeHtml(name)}</span>
        <span class="staple-status-dot" aria-hidden="true"></span>
      `;
      tile.onclick = () => { toggleStaple(name); onRoute(); };
      grid.appendChild(tile);
    });
    groupDiv.appendChild(grid);
    shelf.appendChild(groupDiv);
  });

  // 蛋奶 / 干货：同样的双态瓦片，直接并入同一组网格，视觉与调料一致。
  shelf.appendChild(renderDryGoodsCabinet(inv, { onRoute }));

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
    <div class="shopping-card-head">
      <div>
        <p class="meta">同名同单位会自动合并，来源会保留下来。</p>
      </div>
      <div class="shopping-bulk-actions">
        <button type="button" class="btn ok small" id="miniAddItem">＋ 添加项</button>
        <button type="button" class="btn small" id="copyOpenShopping">复制未买清单</button>
        <button type="button" class="btn small" id="markAllDone">全部标记已买</button>
        <button type="button" class="btn ok small is-hidden" id="batchStockIn">逐项确认入库</button>
        <button type="button" class="btn bad small" id="clearDone">清除已买</button>
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
