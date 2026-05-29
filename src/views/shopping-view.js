import { S, todayISO } from '../storage.js?v=161';
import {
  buildCatalog,
  buildIngredientOptions,
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isDryGoodName,
  normalizeKitchenAmount,
  isSeasoning
} from '../ingredients.js?v=161';
import {
  getStockCoverageAnalysis,
  getStockCoverageForNeed,
  loadInventory,
  mergeInventoryEntry
} from '../inventory.js?v=161';
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
} from '../shopping.js?v=161';
import {
  escapeHtml,
  escapeOptionAttr,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=161';

let currentPlanRange = 'today';
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
  const missing = buildPlanMissingItems(pack, inv, plan, includeSeasonings, currentPlanRange);
  const mergedItems = mergeShoppingItems(shoppingItems);
  const openItems = mergedItems.filter(item => !item.done);
  const doneItems = mergedItems.filter(item => item.done);

  const page = document.createElement('div');
  page.className = 'shopping-page';
  page.innerHTML = `
    <h2 class="section-title">购物清单</h2>
    <div id="shoppingStatus" class="inline-status" hidden></div>
  `;
  const status = page.querySelector('#shoppingStatus');

  const manualCard = document.createElement('div');
  manualCard.className = 'card shopping-manual-card';
  manualCard.innerHTML = `
    <h3>手动添加</h3>
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
  page.appendChild(manualCard);

  const planCard = document.createElement('div');
  planCard.className = 'card shopping-plan-card';
  planCard.innerHTML = `
    <div class="shopping-card-head" style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
      <h3 style="margin:0;">菜单计划</h3>
      <select id="planRangeSelect" style="padding:4px 8px; border-radius:var(--radius-s); border:1px solid var(--separator); background:var(--bg-input); font-size:13px; color:var(--text-main); font-weight:700;">
        <option value="today">只看今天</option>
        <option value="3days">未来 3 天</option>
      </select>
    </div>
  `;
  const rangeSelect = planCard.querySelector('#planRangeSelect');
  if (rangeSelect) {
    rangeSelect.value = currentPlanRange;
    rangeSelect.onchange = (e) => {
      currentPlanRange = e.target.value;
      onRoute();
    };
  }

  const today = todayISO();
  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate);
  tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate);
  dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const getDayLabel = (dateStr) => {
    const d = dateStr || today;
    if (d === today) return '今天';
    if (d === tomorrowISO) return '明天';
    if (d === dayAfterISO) return '后天';
    return d;
  };

  const filteredPlans = plan.filter(item => {
    const d = item.date || today;
    if (currentPlanRange === 'today') {
      return d === today;
    } else if (currentPlanRange === '3days') {
      return d === today || d === tomorrowISO || d === dayAfterISO;
    }
    return true;
  });

  const planList = document.createElement('div');
  planList.className = 'shopping-plan-list';
  if(!filteredPlans.length) {
    const empty = document.createElement('p');
    empty.className = 'small';
    empty.textContent = '该时间段暂未添加菜谱。';
    planList.appendChild(empty);
  } else {
    for(const item of filteredPlans) {
      const recipe = (pack.recipes || []).find(r => r.id === item.id);
      if(!recipe) continue;
      const row = document.createElement('div');
      row.className = 'shopping-plan-row';
      const label = getDayLabel(item.date);
      row.innerHTML = `<span class="shopping-plan-name">${escapeHtml(recipe.name)} <small style="color:var(--text-secondary);">(${label})</small></span><label class="shopping-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${item.servings||1}"></label><a class="btn small" href="javascript:void(0)">移除</a>`;
      row.querySelector('input').onchange = event => {
        const plans = S.load(S.keys.plan, []);
        const target = plans.find(x => x.id === item.id && (x.date || today) === (item.date || today));
        if(target) {
          target.servings = +event.target.value || 1;
          S.save(S.keys.plan, plans);
          onRoute();
        }
      };
      row.querySelector('.btn').onclick = () => {
        const plans = S.load(S.keys.plan, []);
        const index = plans.findIndex(x => x.id === item.id && (x.date || today) === (item.date || today));
        if(index >= 0) {
          plans.splice(index, 1);
          S.save(S.keys.plan, plans);
          onRoute();
        }
      };
      planList.appendChild(row);
    }
  }
  planCard.appendChild(planList);
  page.appendChild(planCard);

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
  page.appendChild(missingCard);

  const itemCard = document.createElement('div');
  itemCard.className = 'card shopping-items-card';
  itemCard.innerHTML = `
    <div class="shopping-card-head">
      <div>
        <h3>我的购物项</h3>
        <p class="meta">同名同单位会自动合并，来源会保留下来。</p>
      </div>
      <div class="shopping-bulk-actions">
        <button type="button" class="btn small" id="copyOpenShopping">复制未买清单</button>
        <button type="button" class="btn small" id="markAllDone">全部标记已买</button>
        <button type="button" class="btn ok small is-hidden" id="batchStockIn">逐项确认入库</button>
        <button type="button" class="btn bad small" id="clearDone">清除已买</button>
      </div>
    </div>
  `;
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

  itemCard.querySelector('#markAllDone').onclick = () => { markAllShoppingItemsDone(); onRoute(); };
  itemCard.querySelector('#clearDone').onclick = () => { clearDoneShoppingItems(); onRoute(); };
  itemCard.querySelector('#copyOpenShopping').onclick = () => {
    const text = buildCopyableShoppingList(missing, loadShoppingItems());
    if(!text.trim()) { setInlineStatus(status, '清单是空的。', 'info'); return; }
    navigator.clipboard.writeText(text)
      .then(() => setInlineStatus(status, '已复制未买清单。', 'ok'))
      .catch(() => setInlineStatus(status, text, 'info'));
  };
  page.appendChild(itemCard);

  const staplesPanel = document.createElement('div');
  staplesPanel.className = 'card staples-card';
  staplesPanel.innerHTML = `
    <h3 class="shopping-staple-heading">
      <span>🧂</span> 家中常备品检查
    </h3>
    <p class="meta shopping-staple-meta">点击缺少的常备品，它们会加入"我的购物项"。</p>
    <div id="stapleContainer"></div>
  `;
  const categories = [
    { name: '生鲜/蛋', items: ['葱', '姜', '蒜', '大葱', '香菜', '小米辣', '鸡蛋'] },
    { name: '基础调味', items: ['盐', '糖', '醋', '生抽', '老抽', '料酒', '米酒', '蚝油', '香油', '味精', '鸡精'] },
    { name: '酱料/腌菜', items: ['豆瓣酱', '甜面酱', '豆豉', '酸菜', '酸豆角', '泡椒'] },
    { name: '香料/干粉', items: ['淀粉', '花椒', '干辣椒', '胡椒粉', '八角', '桂皮', '香叶', '五香粉', '孜然', '茴香'] },
    { name: '食用油', items: ['菜油', '猪油'] }
  ];
  const stapleContainer = staplesPanel.querySelector('#stapleContainer');
  categories.forEach(category => {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'shopping-staple-group';
    const title = document.createElement('div');
    title.textContent = category.name;
    title.className = 'shopping-staple-title';
    groupDiv.appendChild(title);
    const pillContainer = document.createElement('div');
    pillContainer.className = 'ing-compact-container';
    category.items.forEach(name => {
      const span = document.createElement('span');
      span.className = 'ing-tag-pill staple-item';
      span.textContent = name;
      const canonical = getCanonicalName(name);
      const alreadyAdded = loadShoppingItems().some(item => item.name === canonical && item.source === '常备品' && !item.done);
      if(alreadyAdded) span.classList.add('active');
      span.onclick = () => {
        const items = loadShoppingItems();
        const existing = items.find(item => item.name === canonical && item.source === '常备品' && !item.done);
        if(existing) saveShoppingItems(items.filter(item => item.id !== existing.id));
        else addShoppingItem(canonical, '', '', '常备品');
        onRoute();
      };
      pillContainer.appendChild(span);
    });
    groupDiv.appendChild(pillContainer);
    stapleContainer.appendChild(groupDiv);
  });
  page.appendChild(staplesPanel);

  return page;
}
