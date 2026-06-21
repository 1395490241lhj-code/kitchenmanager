import { todayISO } from '../storage.js?v=219';
import {
  UNIT_TYPE,
  buildCatalog,
  getCanonicalName,
  getDryPrepText,
  getUnitType,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName
} from '../ingredients.js?v=219';
import {
  FROZEN_DEFAULT_SHELF_DAYS,
  GEAR_LABELS,
  OUT_OF_STOCK_TTL_MS,
  gearInfo,
  getItemGear,
  loadInventory,
  mergeInventoryEntry,
  remainingDays,
  saveInventory,
  syncOutOfStockTimestamp,
  upsertInventory
} from '../inventory.js?v=219';
import {
  formatAiErrorMessage,
  recognizeReceipt,
  withTimeout
} from '../ai.js?v=219';
import {
  showReceiptConfirmationModal
} from '../components/modal.js?v=219';
import {
  escapeHtml,
  escapeOptionAttr,
  showToast
} from '../components/status.js?v=219';
import { markShoppingItemsStockedIn } from '../shopping.js?v=219';
import { renderStaplesShelf } from '../components/staples-shelf.js?v=219';
import { parseFoodLines } from '../utils/food-input-parser.js?v=219';
import { applyReceiptPantryItems } from '../utils/receipt-import.js?v=219';

// 全局「编辑食材」模式开关（模块级，跨重渲染保持，避免保存后跳回只读态）。
let isEditingInventory = false;

// 库存页内部分段：'normal' = 普通食材｜'staples' = 常备库存（常备货架）。
// 模块级，跨重渲染保持：标记常备品 / 编辑库存会触发整页重渲染，需记住当前分段。
let activeInventoryTab = 'normal';

// 是否真正有货：数量 > 0 且状态不是「没有」，档位型还需未降到「断货」。
function hasRealStock(e){
  if((+e.qty || 0) <= 0) return false;
  if(e.stockStatus === 'empty') return false;
  if(getUnitType(e.name, e.unit) === UNIT_TYPE.GEAR && getItemGear(e) <= 0) return false;
  return true;
}

// 把档位值写回食材，并同步 stockStatus / qty（与做菜扣减逻辑保持一致）。
function applyGearToItem(e, value){
  e.gear = value;
  e.unitType = UNIT_TYPE.GEAR;
  if(value === 0){ e.stockStatus = 'empty'; e.qty = 0; }
  else if(value <= 25){ e.stockStatus = 'low'; if(!(+e.qty > 0)) e.qty = 1; }
  else { e.stockStatus = 'ok'; if(!(+e.qty > 0)) e.qty = 1; }
  syncOutOfStockTimestamp(e); // 降到断货 → 打时间戳；提升复活 → 清空
}

// 双轨制状态徽标：GEAR → 五档液态药丸；PIECE → 优雅件数文本。
function trackHtmlFor(e, unitType){
  if(unitType === UNIT_TYPE.GEAR){
    const gear = gearInfo(getItemGear(e)).value;
    return `<button type="button" class="inv-gear-pill gear-${gear}" title="点击降一档（充足→大半→一半→见底→断货）">${GEAR_LABELS[gear]}</button>`;
  }
  const qty = +e.qty || 0;
  const muted = (qty <= 0 || e.stockStatus === 'empty') ? ' is-muted' : '';
  const countText = qty > 0 ? `${qty} ${escapeHtml(e.unit || '')}`.trim() : '没有';
  return `<span class="inv-piece-count${muted}">${countText}</span>`;
}

// 保质期状态 + 剩余百分比（用于卡片底色与倒计时进度条）。
function lifeStatus(e){
  if((e.kind || 'raw') === 'dry') return { key: 'pantry', pct: 100, rank: 4 };
  const shelf = (e.shelf === undefined || e.shelf === null || e.shelf === '') ? 7 : +e.shelf;
  const r = remainingDays(e);
  const pct = shelf > 0 ? Math.max(0, Math.min(100, Math.round((r / shelf) * 100))) : 0;
  if (r <= 0) return { key: 'expired', pct: 0, rank: 0 };   // 过期：最紧急
  if (r <= 3) return { key: 'near', pct, rank: 1 };          // 临期
  if (e.isFrozen) return { key: 'frozen', pct, rank: 3 };
  return { key: 'fresh', pct, rank: 2 };                     // 新鲜
}

export function renderInventory(pack, options = {}){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div');
  const onInventoryChanged = typeof options.onInventoryChanged === 'function' ? options.onInventoryChanged : () => {};
  const header = document.createElement('div');
  header.className = 'main-title-center';
  header.innerHTML = '<span>我的食材</span>';
  if (options.showTitle !== false) wrap.appendChild(header);

  // 「普通食材」分段面板：承载轻量录入 + 工具栏 + 添加表单 + 库存网格（常备库存另起一个面板）。
  const normalPanel = document.createElement('div');
  normalPanel.className = 'inv-panel';
  normalPanel.dataset.panel = 'normal';

  // ── 轻量录入区：随手记几样食材（每行一个，自动猜单位走 parseFoodLines + 现有写库链路）──
  //    新用户第一眼看到的是这块；更完整的添加入口收进工具栏「+」里的“记进厨房”窗口。
  const QUICK_CHIPS = ['鸡蛋', '番茄', '土豆', '青菜', '豆腐', '牛肉', '面条', '胡萝卜'];
  const quickAdd = document.createElement('div');
  quickAdd.className = 'inventory-quick-add glass-panel';
  quickAdd.innerHTML = `
    <div class="inventory-quick-title">随手记几样食材</div>
    <p class="inventory-quick-hint">每行一个食材。数量不确定也可以只写名字。</p>
    <textarea class="batch-text-area inventory-quick-textarea" id="quickAddInput" rows="4" placeholder="鸡蛋 6个&#10;番茄 3个&#10;土豆&#10;豆腐 1盒"></textarea>
    <div class="inventory-chip-row">${QUICK_CHIPS.map(n => `<button type="button" class="inventory-chip" data-name="${escapeOptionAttr(n)}">${escapeHtml(n)}</button>`).join('')}</div>
    <div id="quickAddStatus" class="small inline-status" hidden></div>
    <div class="inventory-quick-actions">
      <button type="button" class="btn small" id="quickAddSample">试试常见食材</button>
      <button type="button" class="btn ok" id="quickAddBtn">加入厨房</button>
    </div>
  `;
  normalPanel.appendChild(quickAdd);

  const quickInput = quickAdd.querySelector('#quickAddInput');
  const quickStatus = quickAdd.querySelector('#quickAddStatus');
  const inlineStatusTimers = new WeakMap();
  const showInlineStatus = (statusEl, text, tone = 'info') => {
    if (!statusEl) return;
    statusEl.hidden = false;
    statusEl.className = `small inline-status ${tone}`;
    statusEl.textContent = text;
    clearTimeout(inlineStatusTimers.get(statusEl));
    inlineStatusTimers.set(statusEl, setTimeout(() => { statusEl.hidden = true; }, 2200));
  };
  const addTextInventoryItems = (text, { textarea = null, statusEl = quickStatus, frozen = false } = {}) => {
    const parsed = parseFoodLines(text);
    let count = 0;
    for (const it of parsed) {
      const name = getCanonicalName(it.name || '');
      if (!name) continue;
      const qty = Number(it.qty);
      const safeQty = Number.isFinite(qty) && qty > 0 ? qty : 1;
      const unit = (it.unit && String(it.unit).trim()) || guessKitchenUnit(name) || '份';
      const kind = isDryGoodName(name) ? 'dry' : 'raw';
      const isFrozen = kind === 'raw' && frozen;
      const shelf = kind === 'dry' ? 365 : (isFrozen ? FROZEN_DEFAULT_SHELF_DAYS : guessShelfDays(name, unit));
      const entry = { name, qty: safeQty, unit, buyDate: todayISO(), kind, shelf, stockStatus: 'ok' };
      if (kind === 'dry') {
        entry.dryPrep = getDryPrepText(name);
        entry.isFrozen = false;
      } else if (isFrozen) {
        entry.isFrozen = true;
      }
      mergeInventoryEntry(inv, entry, { mode: 'add' });
      count++;
    }
    if (!count) {
      showInlineStatus(statusEl, '先写一两样食材吧。', 'info');
      return 0;
    }
    if (textarea) textarea.value = '';
    showInlineStatus(statusEl, `已加入 ${count} 样食材`, 'ok');
    showToast(`已加入 ${count} 样食材`, { tone: 'success' });
    renderTable();
    setTimeout(() => onInventoryChanged(), 1500);
    return count;
  };

  // chips：只帮用户填输入框（追加一行），不直接写库；已有同名行则不重复追加。
  quickAdd.querySelectorAll('.inventory-chip').forEach(chip => {
    chip.onclick = () => {
      const name = chip.dataset.name;
      const lines = quickInput.value.split(/\r?\n/).map(l => l.trim());
      if (lines.some(l => l === name || l.startsWith(name + ' '))) return;
      quickInput.value = (quickInput.value.trim() ? quickInput.value.replace(/\s+$/, '') + '\n' : '') + name;
    };
  });

  // 「试试常见食材」：只填进输入框示例，等用户确认后再点「加入厨房」。
  quickAdd.querySelector('#quickAddSample').onclick = () => {
    quickInput.value = '鸡蛋 6个\n番茄 3个\n土豆 2个\n青菜 1把';
    quickInput.focus();
  };

  // 「加入厨房」：parseFoodLines 解析 → 规范名/猜单位/猜保质期 → mergeInventoryEntry 写库
  // （与“记进厨房”弹窗、小票识别同一条链路；单位相同累加、不同作新批次，行为不变）。
  quickAdd.querySelector('#quickAddBtn').onclick = () => {
    addTextInventoryItems(quickInput.value, { textarea: quickInput, statusEl: quickStatus });
  };

  const searchDiv = document.createElement('div'); searchDiv.className = 'inventory-toolbar';

  searchDiv.innerHTML = `
    <div class="inventory-tool-row">
      <button type="button" class="inventory-tool-btn inventory-add-trigger is-primary" id="inventoryAddBtn" aria-label="记进厨房" title="记进厨房">
        <span class="inventory-tool-icon">+</span>
        <span>添加</span>
      </button>
      <button type="button" class="inventory-tool-btn inventory-edit-toggle" id="toggleEditBtn" title="进入/退出编辑模式">
        <span class="inv-edit-toggle-label">编辑</span>
      </button>
      <button type="button" class="inventory-tool-btn inventory-export-btn" id="exportInventoryBtn" title="导出食材">
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        <span>导出</span>
      </button>
    </div>
  `;
  normalPanel.appendChild(searchDiv);

  searchDiv.querySelector('#exportInventoryBtn').onclick = () => {
    const payload = {
      type: 'kitchen-inventory',
      version: 1,
      exportedAt: new Date().toISOString(),
      inventory: inv.map(item => ({...item}))
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], {type: 'application/json'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `kitchen-inventory-${todayISO()}.json`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  };

  // 全局「编辑食材」切换：默认 ✏️ 编辑食材；激活后变 ✓ 完成，并让所有卡片进入编辑态。
  const editBtn = searchDiv.querySelector('#toggleEditBtn');
  const syncEditBtn = () => {
    editBtn.classList.toggle('is-active', isEditingInventory);
    editBtn.querySelector('.inv-edit-toggle-label').textContent = isEditingInventory ? '完成' : '编辑';
  };
  editBtn.onclick = () => {
    isEditingInventory = !isEditingInventory;
    syncEditBtn();
    // 「✓ 完成」时把行内就地编辑的最新数组一次性持久化并通知外部刷新。
    if (!isEditingInventory) {
      saveInventory(inv);
      renderTable();
      onInventoryChanged();
    } else {
      renderTable();
    }
  };
  syncEditBtn();

  const handleReceiptFile = async (file, inputEl, statusEl) => {
    if(!file) return;
    if (statusEl) {
      statusEl.classList.add('visible');
      statusEl.hidden = false;
      statusEl.innerHTML = '<span class="spinner"></span> 识别中...';
    }
    try {
      const result = await withTimeout(recognizeReceipt(file), 30000, '识别超时');
      const total = ['inventory', 'pantry', 'review', 'ignored'].reduce((sum, key) => sum + (result?.[key]?.length || 0), 0);
      if(total === 0) {
        if (statusEl) statusEl.innerHTML = '<span class="text-danger">没有识别到可处理的内容</span>';
        showToast('没有识别到可入库食材', { tone: 'warning' });
        return;
      }
      if (statusEl) statusEl.innerHTML = `识别到 ${total} 项，请确认后加入厨房`;
      showReceiptConfirmationModal(result, ({ inventory = [], pantry = [] } = {}) => {
        const matchedIds = inventory.map(it => it.matchedShoppingItemId).filter(Boolean);
        if (matchedIds.length > 0) {
          markShoppingItemsStockedIn(matchedIds);
        }
        for(const it of inventory) {
          const unit = it.unit || guessKitchenUnit(it.name);
          const itemKind = isDryGoodName(it.name) ? 'dry' : 'raw';
          mergeInventoryEntry(inv, { name: it.name, qty: Number(it.qty) || 1, unit, buyDate: todayISO(), kind: itemKind, shelf: itemKind === 'dry' ? 365 : guessShelfDays(it.name, unit), stockStatus:'ok', ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(it.name), isFrozen:false} : {}) }, { mode: 'add' });
        }
        const pantryCount = applyReceiptPantryItems(pantry, inv);
        if (statusEl) statusEl.innerHTML = `✅ 已加入厨房 ${inventory.length + pantryCount} 项`;
        setTimeout(() => {
          statusEl?.classList.remove('visible');
          if (statusEl) statusEl.hidden = true;
          renderTable();
          onInventoryChanged();
        }, 1200);
      }, () => {
        if (statusEl) statusEl.innerHTML = '已取消';
        setTimeout(() => {
          statusEl?.classList.remove('visible');
          if (statusEl) statusEl.hidden = true;
        }, 1200);
      });
    } catch(err) {
      if (statusEl) statusEl.innerHTML = `<span class="text-danger">❌ ${formatAiErrorMessage(err)}</span>`;
    }
    finally { if (inputEl) inputEl.value = ''; }
  };

  const openInventoryAddModal = (initialTab = 'manual') => {
    const overlay = document.createElement('div');
    overlay.className = 'km-modal-overlay';
    overlay.innerHTML = `
      <div class="km-modal-content inventory-add-modal" role="dialog" aria-modal="true" aria-labelledby="inventoryAddTitle">
        <div class="km-modal-header">
          <span class="km-modal-title" id="inventoryAddTitle">记进厨房</span>
          <button type="button" class="km-modal-close" aria-label="关闭">
            <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>
          </button>
        </div>
        <div class="km-modal-body inventory-add-modal-body">
          <div class="inventory-add-tabs" role="tablist" aria-label="记进厨房方式">
            <button type="button" class="inventory-add-tab" data-tab="manual" role="tab">手动记食材</button>
            <button type="button" class="inventory-add-tab" data-tab="receipt" role="tab">拍小票识别</button>
          </div>
          <section class="inventory-add-pane" data-pane="manual">
            <div class="inventory-modal-card">
              <div class="inventory-quick-title">随手记几样食材</div>
              <p class="inventory-quick-hint">每行一个食材，数量不确定也可以只写名字。</p>
              <textarea class="batch-text-area inventory-modal-textarea" id="inventoryModalText" rows="5" placeholder="鸡蛋 6个&#10;番茄 3个&#10;土豆&#10;豆腐 1盒"></textarea>
              <div class="inventory-chip-row">${QUICK_CHIPS.map(n => `<button type="button" class="inventory-chip" data-name="${escapeOptionAttr(n)}">${escapeHtml(n)}</button>`).join('')}</div>
              <div class="inventory-modal-options">
                <button type="button" class="btn small" id="inventoryModalSample">试试常见食材</button>
                <label class="inventory-modal-freeze">
                  <input type="checkbox" id="inventoryModalFrozen"> 按冷冻保存
                </label>
              </div>
              <div id="inventoryModalManualStatus" class="small inline-status" hidden></div>
            </div>
          </section>
          <section class="inventory-add-pane" data-pane="receipt" hidden>
            <div class="inventory-modal-card inventory-receipt-card">
              <div class="inventory-quick-title">拍小票识别</div>
              <p class="inventory-quick-hint">选择小票图片，识别后你再确认入库。</p>
              <div class="inventory-receipt-pick-card" aria-hidden="true">
                <span class="inventory-receipt-icon">📷</span>
                <span>
                  <strong>选择图片后再确认</strong>
                  <small>支持相册、拍照或文件</small>
                </span>
              </div>
              <input type="file" id="inventoryModalReceiptInput" accept="image/*" class="visually-hidden">
              <div id="inventoryModalReceiptStatus" class="small inventory-scan-status" hidden></div>
            </div>
          </section>
        </div>
        <div class="km-modal-actions inventory-add-modal-actions">
          <button type="button" class="btn" id="inventoryAddCancel">取消</button>
          <button type="button" class="btn ok" id="inventoryAddPrimary">加入厨房</button>
        </div>
      </div>
    `;
    document.body.appendChild(overlay);
    requestAnimationFrame(() => overlay.classList.add('open'));

    const close = () => {
      overlay.classList.add('closing');
      setTimeout(() => overlay.remove(), 180);
    };
    const modalText = overlay.querySelector('#inventoryModalText');
    const manualStatus = overlay.querySelector('#inventoryModalManualStatus');
    const receiptInput = overlay.querySelector('#inventoryModalReceiptInput');
    const receiptStatus = overlay.querySelector('#inventoryModalReceiptStatus');
    const primaryBtn = overlay.querySelector('#inventoryAddPrimary');
    let activeTab = initialTab === 'receipt' ? 'receipt' : 'manual';

    const setTab = (tab) => {
      activeTab = tab === 'receipt' ? 'receipt' : 'manual';
      overlay.querySelectorAll('.inventory-add-tab').forEach(btn => {
        const isActive = btn.dataset.tab === activeTab;
        btn.classList.toggle('is-active', isActive);
        btn.setAttribute('aria-selected', String(isActive));
      });
      overlay.querySelectorAll('.inventory-add-pane').forEach(pane => {
        const isActive = pane.dataset.pane === activeTab;
        pane.hidden = !isActive;
        pane.classList.toggle('is-active', isActive);
      });
      primaryBtn.textContent = activeTab === 'receipt' ? '选取小票图片' : '加入厨房';
      if (activeTab === 'manual') modalText?.focus();
    };

    overlay.querySelector('.km-modal-close').onclick = close;
    overlay.querySelector('#inventoryAddCancel').onclick = close;
    overlay.querySelectorAll('.inventory-add-tab').forEach(btn => {
      btn.onclick = () => setTab(btn.dataset.tab);
    });
    overlay.querySelectorAll('.inventory-chip').forEach(chip => {
      chip.onclick = () => {
        const name = chip.dataset.name;
        const lines = modalText.value.split(/\r?\n/).map(l => l.trim());
        if (lines.some(l => l === name || l.startsWith(name + ' '))) return;
        modalText.value = (modalText.value.trim() ? modalText.value.replace(/\s+$/, '') + '\n' : '') + name;
        modalText.focus();
      };
    });
    overlay.querySelector('#inventoryModalSample').onclick = () => {
      modalText.value = '鸡蛋 6个\n番茄 3个\n土豆 2个\n青菜 1把';
      modalText.focus();
    };
    receiptInput.onchange = (event) => handleReceiptFile(event.target.files?.[0], event.target, receiptStatus);
    primaryBtn.onclick = () => {
      if (activeTab === 'receipt') {
        receiptInput.click();
        return;
      }
      const frozen = overlay.querySelector('#inventoryModalFrozen')?.checked;
      addTextInventoryItems(modalText.value, { textarea: modalText, statusEl: manualStatus, frozen });
    };

    setTab(activeTab);
  };

  searchDiv.querySelector('#inventoryAddBtn').onclick = () => openInventoryAddModal('manual');

  const grid=document.createElement('div'); grid.className='inventory-grid'; normalPanel.appendChild(grid);
  function renderTable(){
    grid.innerHTML='';

    // ① 自蒸发（Auto-Evaporation）：断货时间戳存在且已超过 7 天 TTL 的食材，
    //    直接从源数组物理剔除并持久化，让其在界面上无感自然消失。
    const now = Date.now();
    let evaporated = false;
    for(let i = inv.length - 1; i >= 0; i--){
      const it = inv[i];
      if(it.outOfStockAt && (now - it.outOfStockAt) > OUT_OF_STOCK_TTL_MS){
        inv.splice(i, 1);
        evaporated = true;
      }
    }
    if(evaporated) saveInventory(inv);

    const filteredInv = inv;
    // ② 排序：最高优先级——未满 7 天的断货「幽灵卡片」(outOfStockAt 非空) 强行沉底；
    //    其余按紧急程度：过期 → 临期 → 新鲜/冷冻 → 常备干货；同档按剩余天数升序。
    filteredInv.sort((a, b) => {
      const aGhost = a.outOfStockAt ? 1 : 0;
      const bGhost = b.outOfStockAt ? 1 : 0;
      if (aGhost !== bGhost) return aGhost - bGhost; // 幽灵(1) 永远排在有货(0) 之后
      const la = lifeStatus(a), lb = lifeStatus(b);
      if (la.rank !== lb.rank) return la.rank - lb.rank;
      return remainingDays(a) - remainingDays(b);
    });
    if(filteredInv.length === 0) {
      grid.innerHTML = `<div class="small inventory-empty-row">${inv.length===0 ? '厨房里还没记食材，先加几样常吃的吧。记完就能看今天推荐。' : '未找到'}</div>`;
      return;
    }
    for(const e of filteredInv){
      const card=document.createElement('div');
      const life = lifeStatus(e);
      const unitType = e.unitType || getUnitType(e.name, e.unit);
      const inStock = hasRealStock(e);

      // 删除当前食材（编辑模式行内小叉）：仅改本地数组并重渲染，持久化留到「✓ 完成」。
      const deleteItem = () => {
        const i = inv.indexOf(e);
        if(i >= 0){ inv.splice(i,1); renderTable(); }
      };

      if(isEditingInventory){
        // ── 行内就地编辑：双行紧凑型微型表单卡片（无弹窗）──
        card.className = `inventory-card inv-card-v2 inv-ie-card is-editing inventory-row life-${life.key}`;

        // 存量微调控件：PIECE → 步进器；GEAR → 5 个微型档位圆圈。
        const gearCur = gearInfo(getItemGear(e)).value;
        const stockControl = unitType === UNIT_TYPE.PIECE
          ? `<div class="inv-ie-stepper">
               <button type="button" class="inv-ie-step" data-step="-1" aria-label="减少">−</button>
               <span class="inv-ie-qty">${+e.qty || 0}</span>
               <button type="button" class="inv-ie-step" data-step="1" aria-label="增加">+</button>
             </div>`
          : `<div class="inv-ie-gears" role="group" aria-label="油表档位">${
               [100, 75, 50, 25, 0].map(g => `<button type="button" class="inv-ie-gear gear-${g}${g === gearCur ? ' is-active' : ''}" data-gear="${g}" title="${GEAR_LABELS[g]}" aria-label="${GEAR_LABELS[g]}"></button>`).join('')
             }</div>`;
        const remainingInputValue = Math.max(0, Math.round(remainingDays(e)));

        card.innerHTML = `
          <div class="inv-ie-top">
            <input type="text" class="inv-ie-name" value="${escapeOptionAttr(e.name)}" aria-label="食材名称">
            <button type="button" class="inv-ie-freeze${e.isFrozen ? ' is-on' : ''}" title="冷冻切换" aria-label="冷冻切换" aria-pressed="${e.isFrozen ? 'true' : 'false'}">🧊</button>
          </div>
          <div class="inv-ie-bottom">
            <label class="inv-ie-shelf">
              <span class="inv-ie-shelf-label">剩余</span>
              <input type="number" min="0" step="1" class="inv-ie-shelf-input" value="${remainingInputValue}" aria-label="剩余有效期天数"> 天
            </label>
            <div class="inv-ie-stock">${stockControl}</div>
          </div>
          <span class="inv-del-x" role="button" tabindex="0" aria-label="删除" title="删除">✕</span>`;

        // 名称：失焦 / 变更时写回本地 State（空值则回退原名）。
        // 人工修改名称视为「主动管理」→ 强制清空断货时间戳，重置自蒸发倒计时。
        const nameInput = card.querySelector('.inv-ie-name');
        const commitName = () => { const v = nameInput.value.trim(); if(v) e.name = v; else nameInput.value = e.name; e.outOfStockAt = null; };
        nameInput.onchange = commitName;
        nameInput.onblur = commitName;

        // 剩余有效期：输入 X 天表示从今天起还剩 X 天，不再理解成总保质期。
        const shelfInput = card.querySelector('.inv-ie-shelf-input');
        const commitShelf = () => {
          let n = Math.max(0, Math.round(+shelfInput.value || 0));
          e.buyDate = todayISO();
          e.shelf = n;
          shelfInput.value = n;
          e.outOfStockAt = null;
        };
        shelfInput.onchange = commitShelf;
        shelfInput.onblur = commitShelf;

        // 冷冻：原地取反，仅切换高亮，不重渲染。
        const freezeBtn = card.querySelector('.inv-ie-freeze');
        freezeBtn.onclick = () => {
          const inputRemaining = Math.max(0, Math.round(+shelfInput.value || 0));
          const userEditedRemaining = inputRemaining !== remainingInputValue;
          commitShelf();
          e.isFrozen = !e.isFrozen;
          if (e.isFrozen && !userEditedRemaining) {
            const currentRemaining = remainingDays(e);
            if (!(currentRemaining >= FROZEN_DEFAULT_SHELF_DAYS)) {
              e.buyDate = todayISO();
              e.shelf = FROZEN_DEFAULT_SHELF_DAYS;
              shelfInput.value = FROZEN_DEFAULT_SHELF_DAYS;
            }
          }
          freezeBtn.classList.toggle('is-on', e.isFrozen);
          freezeBtn.setAttribute('aria-pressed', e.isFrozen ? 'true' : 'false');
        };

        // 存量微调：原地加减 / 切档，仅更新局部 DOM，不重渲染。
        if(unitType === UNIT_TYPE.PIECE){
          const qtyEl = card.querySelector('.inv-ie-qty');
          card.querySelectorAll('.inv-ie-step').forEach(btn => {
            btn.onclick = () => {
              const next = Math.max(0, (+e.qty || 0) + (+btn.dataset.step));
              e.qty = next;
              e.unitType = UNIT_TYPE.PIECE;
              e.stockStatus = next <= 0 ? 'empty' : 'ok';
              syncOutOfStockTimestamp(e); // 减到 0 → 打时间戳；加回 → 清空
              qtyEl.textContent = next;
            };
          });
        } else {
          const circles = card.querySelectorAll('.inv-ie-gear');
          circles.forEach(circle => {
            circle.onclick = () => {
              applyGearToItem(e, +circle.dataset.gear);
              circles.forEach(c => c.classList.toggle('is-active', c === circle));
            };
          });
        }

        // 删除小叉。
        const delX = card.querySelector('.inv-del-x');
        delX.onclick = deleteItem;
        delX.onkeydown = (ev) => { if(ev.key === 'Enter' || ev.key === ' '){ ev.preventDefault(); deleteItem(); } };

        grid.appendChild(card);
        continue;
      }

      // ── 只读模式：双层卡片（核心信息轴 + 生命周期轴）──
      // 未满 7 天的断货幽灵卡片：灰度去色 + 半透明，沉底且不抢视线。
      const ghostClass = e.outOfStockAt ? ' is-ghost' : '';
      card.className = `inventory-card inv-card-v2 inventory-row life-${life.key}${ghostClass}`;
      const frozenTag = e.isFrozen
        ? `<span class="inv-frozen-tag" title="冷冻保存中">🧊 冷冻</span>`
        : '';
      const trackHtml = trackHtmlFor(e, unitType);

      // 生命周期轴：非干货时贴一条「内嵌于卡片最底部的全宽流光轨道」。
      // 进度比例 = 剩余寿命 / 总保质期；断货或数量为 0 → 0%，保持干净。
      // 「剩余 X 天」文字仅在有货时显示，避免空货卡片出现误导性倒计时。
      let lifeAxisHtml = '';
      if((e.kind || 'raw') !== 'dry'){
        const r = remainingDays(e);
        const progressPercent = inStock ? life.pct : 0;
        const remainHtml = inStock
          ? `<div class="inv-row-bottom">
            <span class="inv-life-remain life-${life.key}">${r > 0 ? `剩余 ${r} 天` : '已过期'}</span>
          </div>`
          : '';
        lifeAxisHtml = `${remainHtml}
          <!-- 临期寿命全宽轨道 -->
          <div class="inv-progress-track">
            <span class="inv-progress-fill" style="width: ${progressPercent}%;"></span>
          </div>`;
      }

      card.innerHTML = `
        <div class="inv-row-top">
          <div class="inv-top-left">
            <span class="inventory-item-name">${escapeHtml(e.name)}</span>
            ${frozenTag}
          </div>
          <div class="inv-top-right">${trackHtml}</div>
        </div>
        ${lifeAxisHtml}`;

      // GEAR 药丸：只读模式仍支持「点击降一档」快捷消耗（非弹窗，立即持久化）。
      if(unitType === UNIT_TYPE.GEAR){
        card.querySelector('.inv-gear-pill').onclick = () => {
          const order = [100, 75, 50, 25, 0];
          const cur = gearInfo(getItemGear(e)).value;
          applyGearToItem(e, order[(order.indexOf(cur) + 1) % order.length]);
          saveInventory(inv); renderTable(); onInventoryChanged();
        };
      }

      grid.appendChild(card);
    }
  }
  renderTable();

  // ── 「常备库存」分段面板：复用常备货架组件（调料 / 蛋奶 / 干货），不再做成普通折叠卡片 ──
  const staplesPanel = document.createElement('div');
  staplesPanel.className = 'inv-panel';
  staplesPanel.dataset.panel = 'staples';
  staplesPanel.appendChild(renderStaplesShelf(inv, { onRoute: onInventoryChanged }));

  // ── 顶部 iOS 分段控件：普通食材 / 常备库存（仅库存页内部状态切换，不改 hash、不跳转）──
  const segmented = document.createElement('div');
  segmented.className = 'inv-segmented';
  segmented.setAttribute('role', 'tablist');
  segmented.setAttribute('aria-label', '食材分段');
  const TABS = [
    { key: 'normal', label: '🥬 新鲜食材' },
    { key: 'staples', label: '🧂 家里常备' }
  ];
  TABS.forEach(tab => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'inv-seg-btn';
    btn.dataset.tab = tab.key;
    btn.textContent = tab.label;
    btn.setAttribute('role', 'tab');
    segmented.appendChild(btn);
  });

  const panelWrap = document.createElement('div');
  panelWrap.className = 'inv-panel-wrap';
  panelWrap.appendChild(normalPanel);
  panelWrap.appendChild(staplesPanel);

  const setTab = (key) => {
    activeInventoryTab = key === 'staples' ? 'staples' : 'normal';
    segmented.querySelectorAll('.inv-seg-btn').forEach(b => {
      const on = b.dataset.tab === activeInventoryTab;
      b.classList.toggle('is-active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    normalPanel.classList.toggle('is-hidden', activeInventoryTab !== 'normal');
    staplesPanel.classList.toggle('is-hidden', activeInventoryTab !== 'staples');
  };
  segmented.querySelectorAll('.inv-seg-btn').forEach(b => { b.onclick = () => setTab(b.dataset.tab); });

  wrap.appendChild(segmented);
  wrap.appendChild(panelWrap);

  // 恢复上次所在分段（标记常备品 / 编辑库存触发整页重渲染后保持当前 Tab）。
  setTab(activeInventoryTab);

  return wrap;
}
