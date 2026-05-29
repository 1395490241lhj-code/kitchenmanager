import { S, todayISO } from '../storage.js?v=176';
import {
  buildCatalog,
  buildIngredientOptions,
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount,
  isSeasoning
} from '../ingredients.js?v=176';
import {
  getStockCoverageAnalysis,
  getStockCoverageForNeed,
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=176';
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
} from '../shopping.js?v=176';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=176';
import {
  STAPLE_CATALOG,
  STAPLE_STATUS,
  getStapleState,
  restoreStapleByPurchase,
  restoreStaplesByPurchase,
  toggleStaple
} from '../staples.js?v=176';
import { renderInventory } from './inventory-view.js?v=176';
import { renderDryGoodsCabinet } from '../components/pantry-shelf.js?v=176';
import { getPlanRange } from '../components/menu-plan.js?v=176';

// 跨页意图：首页「批量入库 / 拍小票 / 临期雷达」跳到本页后要打开的库存区动作。
let pendingInventoryIntent = null;
export function requestInventoryIntent(kind) { pendingInventoryIntent = kind; }

// 记忆折叠块展开状态，避免编辑库存触发重渲染后被重置收起。
let staplesShelfOpen = false;
let invDetailsOpen = false;

// 折叠块封装：summary 作为标题，nodes 作为内容；open 控制默认展开/收起。
function makeDetails(title, subtitle, nodes, open = false) {
  const details = document.createElement('details');
  details.className = 'home-secondary-details';
  if (open) details.open = true;
  details.innerHTML = `<summary><span>${escapeHtml(title)}</span><small>${escapeHtml(subtitle)}</small></summary>`;
  nodes.forEach(node => details.appendChild(node));
  return details;
}

function buildPlanMissingItems(pack, inv, plan, includeSeasonings = false, dateRange = 'today') {
  const map = pack.recipe_ingredients || {};
  const need = {};
  const addNeed = (name, qty, unit, source = '菜谱') => {
    const canonicalName = getCanonicalName(name || '');
    if(!canonicalName) return;
    const key = canonicalName + '|' + (unit || guessKitchenUnit(canonicalName) || '份');
    if(!need[key]) need[key] = { name: canonicalName, unit: unit || guessKitchenUnit(canonicalName) || '份', qty: 0, sources: [] };
    need[key].qty += (+qty || 0);
    if(source && !need[key].sources.includes(source)) need[key].sources.push(source);
  };

  const today = todayISO();
  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate);
  tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate);
  dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const filteredPlan = (plan || []).filter(p => {
    const d = p.date || today;
    if (dateRange === 'today') {
      return d === today;
    } else if (dateRange === '3days') {
      return d === today || d === tomorrowISO || d === dayAfterISO;
    }
    return true;
  });

  for(const p of filteredPlan){
    const recipe = (pack.recipes || []).find(r => r.id === p.id);
    const ingList = explodeCombinedItems(map[p.id] || []);
    if(!ingList.length) {
      if(recipe) addNeed(recipe.name + ' 原料', p.servings || 1, '份', recipe.name);
      continue;
    }
    for(const it of ingList) {
      if(!includeSeasonings && isSeasoning(it.item)) continue;
      const qty = typeof it.qty === 'number' && isFinite(it.qty) ? it.qty : 1;
      addNeed(it.item, qty * (p.servings || 1), it.unit, recipe ? recipe.name : '菜谱');
    }
  }

  return Object.values(need).map(req => {
    const analysis = getStockCoverageAnalysis(inv, req.name, req.qty, req.unit);

    if (analysis.confidence === 'exact') {
      const missingQty = Math.max(0, Math.round((req.qty - analysis.coveredQty) * 100) / 100);
      return missingQty > 0
        ? { name: req.name, unit: req.unit, qty: missingQty, source: req.sources.join('、'), needsConfirm: false }
        : null;
    }

    if (analysis.confidence === 'unit-mismatch') {
      const stockDesc = analysis.matchedItems.map(i => `${i.qty}${i.unit}`).join('/');
      return {
        name: req.name, unit: req.unit, qty: req.qty,
        source: req.sources.join('、'),
        needsConfirm: true,
        confirmReason: `库存有 ${stockDesc}，单位不同，数量需确认`
      };
    }

    if (analysis.confidence === 'status-only') {
      return {
        name: req.name, unit: req.unit, qty: req.qty,
        source: req.sources.join('、'),
        needsConfirm: true,
        confirmReason: '库存需确认'
      };
    }

    // confidence === 'none' → 真正缺货
    return { name: req.name, unit: req.unit, qty: req.qty, source: req.sources.join('、'), needsConfirm: false };
  }).filter(Boolean);
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

function formatStapleTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const today = todayISO();
  const dISO = d.toISOString().slice(0, 10);
  if (dISO === today) return '今天补';
  const diff = Math.round((new Date(today) - new Date(dISO)) / 86400000);
  if (diff === 1) return '昨天补';
  if (diff > 1 && diff <= 30) return `${diff} 天前补`;
  return `补于 ${dISO.slice(5)}`;
}

// 【常备货架】统一管理：调料/米面（双态常备品）+ 蛋奶/干货（同样的双态瓦片）。
// 折叠组件，open 状态由模块变量 staplesShelfOpen 记忆，避免重渲染后被重置收起。
function renderStaplesShelf(inv, { onRoute = () => {} } = {}) {
  const panel = document.createElement('details');
  panel.className = 'home-secondary-details staples-details';
  if (staplesShelfOpen) panel.open = true;
  // 记忆展开/收起状态：编辑库存触发 onRoute 重渲染时保持原样。
  panel.addEventListener('toggle', () => { staplesShelfOpen = panel.open; });
  panel.innerHTML = `
    <summary><span>🧂 常备货架</span><small>点一下切换「充足 / 不足」，不足自动进购物清单</small></summary>
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
    group.items.forEach(name => {
      const state = getStapleState(name);
      const low = state.status === STAPLE_STATUS.INSUFFICIENT;
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = `staple-tile ${low ? 'is-low' : 'is-ok'}`;
      tile.setAttribute('aria-pressed', low ? 'true' : 'false');
      const stateText = low ? '不足 · 已加清单' : '充足';
      const timeText = (!low && state.updatedAt) ? formatStapleTime(state.updatedAt) : '';
      tile.innerHTML = `
        <span class="staple-tile-name">${escapeHtml(name)}</span>
        <span class="staple-tile-state">${escapeHtml(stateText)}</span>
        ${timeText ? `<span class="staple-tile-time">${escapeHtml(timeText)}</span>` : ''}
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
  const plan = S.load(S.keys.plan, []);
  const ingredientOptions = buildIngredientOptions(catalog);
  const shoppingItems = loadShoppingItems();
  const settings = S.load(S.keys.settings, {});
  if (settings.includeSeasoningsInShopping === undefined) {
    const oldVal = localStorage.getItem('km_include_seasoning');
    if (oldVal === 'true') {
      settings.includeSeasoningsInShopping = true;
      S.save(S.keys.settings, settings);
    }
    if (oldVal !== null) {
      localStorage.removeItem('km_include_seasoning');
    }
  }
  const includeSeasonings = settings.includeSeasoningsInShopping === true;
  const missing = buildPlanMissingItems(pack, inv, plan, includeSeasonings, getPlanRange());
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

  const missingCard = document.createElement('div');
  missingCard.className = 'card shopping-missing-card';
  missingCard.innerHTML = `
    <div class="shopping-card-head">
      <div>
        <h3>菜谱缺货</h3>
      </div>
      <div class="shopping-bulk-actions">
        <label class="shopping-check shopping-seasoning-toggle">
          <input type="checkbox" id="toggleSeasonings" ${includeSeasonings ? 'checked' : ''}>
          <span>包含调味料</span>
        </label>
      </div>
    </div>
  `;

  const toggleCheckbox = missingCard.querySelector('#toggleSeasonings');
  toggleCheckbox.onchange = (e) => {
    const s = S.load(S.keys.settings, {});
    s.includeSeasoningsInShopping = e.target.checked;
    S.save(S.keys.settings, s);
    onRoute();
  };
  const missingTable = document.createElement('table');
  missingTable.className = 'table shopping-table';
  missingTable.innerHTML = `<thead><tr><th>食材</th><th>缺少数量</th><th>来源</th><th class="right">操作</th></tr></thead><tbody></tbody>`;
  const missingBody = missingTable.querySelector('tbody');
  if(!missing.length) {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td colspan="4" class="small">库存已满足，不需要购买。</td>';
    missingBody.appendChild(tr);
  } else {
    missing.forEach(item => {
      const tr = document.createElement('tr');
      const qtyCell = item.needsConfirm
        ? `<span class="confirm-badge">${escapeHtml(item.confirmReason || '需确认')}</span>`
        : escapeHtml([item.qty, item.unit].filter(Boolean).join(' '));
      tr.innerHTML = `<td>${escapeHtml(item.name)}</td><td>${qtyCell}</td><td class="small">${escapeHtml(item.source || '菜谱')}</td><td class="right"><button type="button" class="btn small">已买入库</button></td>`;
      tr.querySelector('button').onclick = () => {
        showShoppingInventoryModal(item, entry => {
          mergeInventoryEntry(inv, entry, { mode: 'add' });
          setInlineStatus(status, `${entry.name} 已入库。`, 'ok');
          onRoute();
        });
      };
      missingBody.appendChild(tr);
    });
  }
  missingCard.appendChild(missingTable);

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
    const text = buildCopyableShoppingList(missing, loadShoppingItems());
    if(!text.trim()) { setInlineStatus(status, '清单是空的。', 'info'); return; }
    navigator.clipboard.writeText(text)
      .then(() => setInlineStatus(status, '已复制未买清单。', 'ok'))
      .catch(() => setInlineStatus(status, text, 'info'));
  };
  // 合并后的【常备货架】：调料/米面 + 蛋奶/干货，统一双态瓦片，默认收起、展开状态记忆。
  const staplesShelf = renderStaplesShelf(inv, { onRoute });

  // 【完整库存】默认收起（跨页意图跳转或上次展开过时才展开），展开状态记忆。
  const inventoryNode = renderInventory(pack, { showTitle: false, onInventoryChanged: onRoute });
  const invDetails = makeDetails(
    '完整库存',
    '手动录入、拍小票及完整库存明细',
    [inventoryNode],
    invDetailsOpen || pendingInventoryIntent != null
  );
  invDetails.id = 'shoppingInventoryDetails';
  invDetails.addEventListener('toggle', () => { invDetailsOpen = invDetails.open; });

  // ── 页面顺序：① 我的购物项（含内联添加项）② 菜谱缺货 ③ 常备货架 ④ 完整库存 ──
  page.appendChild(makeDetails('🛒 我的购物项', '勾选「已买」即可；常备品会自动恢复充足', [itemCard], true));
  page.appendChild(missingCard);
  page.appendChild(staplesShelf);
  page.appendChild(invDetails);

  // 消费跨页意图：首页跳转过来时自动展开库存并触发对应动作。
  if (pendingInventoryIntent) {
    const intent = pendingInventoryIntent;
    pendingInventoryIntent = null;
    setTimeout(() => {
      invDetails.open = true;
      if (intent === 'add') {
        const form = invDetails.querySelector('.add-form-container');
        const toggle = invDetails.querySelector('#toggleAddBtn');
        if (form && toggle && !form.classList.contains('open')) toggle.click();
      } else if (intent === 'receipt') {
        const cam = invDetails.querySelector('#camInput');
        if (cam) cam.click();
      }
      invDetails.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }, 60);
  }

  return page;
}
