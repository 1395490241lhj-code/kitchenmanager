import { todayISO } from '../storage.js?v=208';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=208';
import {
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=208';
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
} from '../shopping.js?v=208';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=208';
import { restoreStapleByPurchase, restoreStaplesByPurchase } from '../staples.js?v=208';

// 兼容旧入口：完整库存已迁到独立「库存」Tab，本页不再内嵌库存分段；保留空实现避免外部 import 报错。
export function requestInventoryIntent() {}

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
    <h2 class="section-title">清单</h2>
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
      <input id="shoppingAddRemark" type="text" class="shopping-add-remark" placeholder="备注 (选填)...">
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
    const remark = manualCard.querySelector('#shoppingAddRemark').value.trim();
    addShoppingItem(name, manualCard.querySelector('#shoppingAddQty').value || '', manualCard.querySelector('#shoppingAddUnit').value || '', '手动', remark);
    manualCard.querySelector('#shoppingAddRemark').value = ''; // 加入后清空备注（onRoute 重渲染亦会重置，此处双保险）
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
      <input type="text" class="shopping-remark-input" placeholder="点击添加备注..." value="${escapeOptionAttr(remarkDefault(item))}" aria-label="备注" title="${escapeOptionAttr(item.source || '')}">
      <div class="shopping-row-actions">
        ${stockInHtml}
        <button type="button" class="btn small bad delete-shopping-btn">删</button>
      </div>
    `;
    // 行内备注：原地直接修改，失焦 / 变更即写回底层数据并持久化（不触发整页重渲染，保持焦点）。
    // 默认值多字段兼容：手写 remark 优先，回退系统自动生成的来源（菜谱缺货等血统备注）。
    const remarkBaseline = remarkDefault(item);
    const remarkInput = row.querySelector('.shopping-remark-input');
    if (remarkInput) {
      remarkInput.onclick = event => event.stopPropagation();
      const commitRemark = () => {
        const val = remarkInput.value.trim();
        if (val === remarkBaseline) return; // 与当前显示值一致（未改动）→ 不写库
        item.remark = val;
        updateShoppingRowsByIds(item.ids, target => ({ ...target, remark: val }));
      };
      remarkInput.onchange = commitRemark;
      remarkInput.onblur = commitRemark;
    }
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
  // 清单页只负责「购物项」；常备货架已迁到独立「库存」Tab，这里只挂购物项卡片。
  page.appendChild(itemCard);

  // 轻量指引：常备货架（调料/蛋奶/干货）现在统一在「库存」页管理。
  const shelfHint = document.createElement('p');
  shelfHint.className = 'shopping-shelf-hint small';
  shelfHint.innerHTML = '🧂 常备货架（调料 / 蛋奶 / 干货）已移到 <a href="#inventory">库存页</a> 统一管理。';
  page.appendChild(shelfHint);

  return page;
}
