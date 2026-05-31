import { els } from '../dom.js?v=180';
import { todayISO } from '../storage.js?v=180';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=180';
import {
  inventoryStateInfo,
  loadInventory,
  mergeInventoryEntry,
  nextInventoryState,
  remainingDays,
  saveInventory,
  upsertInventory
} from '../inventory.js?v=180';
import {
  formatAiErrorMessage,
  recognizeReceipt,
  withTimeout
} from '../ai.js?v=180';
import {
  showEditInventoryModal,
  showReceiptConfirmationModal
} from '../components/modal.js?v=180';
import {
  escapeHtml,
  escapeOptionAttr,
  setSelectValueWithOption
} from '../components/status.js?v=180';import { markShoppingItemsStockedIn } from '../shopping.js?v=180';

function badgeFor(e){
  if((e.kind || 'raw') === 'dry') return `<span class="kchip dry" title="${escapeOptionAttr(getDryPrepText(e.name))}">干货 · ${escapeHtml(getDryPrepText(e.name))}</span>`;
  if(e.isFrozen) return `<span class="kchip kchip-frozen" title="点击切换为冷藏">❄️ 冷冻</span>`;
  const r=remainingDays(e);
  let html = '';
  if(r<=1) html = `<span class="kchip bad kchip-clickable" title="点击切换为冷冻">即将过期 ${r}天</span>`;
  else if(r<=3) html = `<span class="kchip warn kchip-clickable" title="点击切换为冷冻">优先消耗 ${r}天</span>`;
  else html = `<span class="kchip ok kchip-clickable" title="点击切换为冷冻">新鲜 ${r}天</span>`;
  return html;
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
  const ingredientOptions = buildIngredientOptions(catalog);
  const header = document.createElement('div');
  header.className = 'main-title-center';
  header.innerHTML = '<span>厨房</span>';
  if (options.showTitle !== false) wrap.appendChild(header);

  const searchDiv = document.createElement('div'); searchDiv.className = 'inventory-toolbar';

  searchDiv.innerHTML = `
    <div class="inventory-toolbar-actions">
      <button type="button" class="btn small inventory-export-btn" id="exportInventoryBtn" title="导出库存">
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        <span>导出库存</span>
      </button>
      <label class="btn ai icon-only inventory-camera-label">
        <input type="file" id="camInput" accept="image/*" class="visually-hidden">
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
      </label>
      <button type="button" class="btn ok icon-only" id="toggleAddBtn">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </button>
    </div>
    <div id="scanStatus" class="small inventory-scan-status"></div>
  `;
  wrap.appendChild(searchDiv);

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

  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container';
  formContainer.innerHTML = `
    <div class="form-grid">
      <div class="full-width">
        <input id="addName" list="catalogList" placeholder="食材名称 (必填)" class="full-width-input">
        <datalist id="catalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      </div>
      <div class="full-width add-state-row">
        <span class="add-state-label">类型</span>
        <div class="add-state-options" id="addItemKind">
          <button type="button" class="add-state-option active" data-kind="raw">普通食材</button>
          <button type="button" class="add-state-option" data-kind="dry">常备干货</button>
        </div>
      </div>
      <div class="full-width add-state-row">
        <span class="add-state-label">状态</span>
        <div class="add-state-options" id="addStockStatus">
          <button type="button" class="add-state-option active" data-status="ok">够用</button>
          <button type="button" class="add-state-option" data-status="low">快没了</button>
          <button type="button" class="add-state-option" data-status="unknown">不确定</button>
        </div>
      </div>
      <div class="qty-group">
        <input id="addQty" type="number" min="0" step="1" placeholder="数量（可选）" class="qty-input-field">
        <select id="addUnit" class="unit-select"><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份" selected>份</option><option value="g">g</option><option value="ml">ml</option></select>
      </div>
      <input id="addDate" type="date" value="${todayISO()}" class="full-width-input">
      <div class="full-width inventory-add-footer">
        <label class="inventory-frozen-label">
          <input type="checkbox" id="addFrozen" class="inventory-frozen-checkbox">冷冻
        </label>
        <button id="addBtn" class="btn ok inventory-add-btn">入库</button>
      </div>
    </div>`;
  wrap.appendChild(formContainer);

  searchDiv.querySelector('#toggleAddBtn').onclick = () => {
    formContainer.classList.toggle('open');
    const btn = searchDiv.querySelector('#toggleAddBtn');
    if (formContainer.classList.contains('open')) {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    } else {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    }
  };
  let selectedKind = 'raw';
  const setAddKind = (kind) => {
    selectedKind = kind === 'dry' ? 'dry' : 'raw';
    els('#addItemKind .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.kind === selectedKind));
    formContainer.querySelector('#addFrozen').closest('label').classList.toggle('hidden', selectedKind === 'dry');
  };
  els('#addItemKind .add-state-option', formContainer).forEach(btn => {
    btn.onclick = () => setAddKind(btn.dataset.kind);
  });
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{
    const val = e.target.value.trim();
    if(val){
      const canonical = getCanonicalName(val);
      setSelectValueWithOption(formContainer.querySelector('#addUnit'), guessKitchenUnit(canonical) || '份');
      if(isDryGoodName(canonical)) setAddKind('dry');
    }
  });
  let selectedStockStatus = 'ok';
  els('#addStockStatus .add-state-option', formContainer).forEach(btn => {
    btn.onclick = () => {
      selectedStockStatus = btn.dataset.status || 'ok';
      els('#addStockStatus .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x === btn));
    };
  });

  formContainer.querySelector('#addBtn').onclick=()=>{
    const rawName=formContainer.querySelector('#addName').value.trim();
    if(!rawName) return alert('请输入食材名称');
    const name=getCanonicalName(rawName);

    const qtyText = formContainer.querySelector('#addQty').value.trim();
    let qty = qtyText === '' ? 1 : Number(qtyText);
    if(!Number.isFinite(qty)) qty = 1;
    if (qty < 0) qty = 0;

    const unit=formContainer.querySelector('#addUnit').value || guessKitchenUnit(name) || '份';
    setSelectValueWithOption(formContainer.querySelector('#addUnit'), unit);
    const date=formContainer.querySelector('#addDate').value||todayISO();
    const itemKind = selectedKind === 'dry' || isDryGoodName(name) ? 'dry' : 'raw';
    const isFrozen = itemKind === 'dry' ? false : formContainer.querySelector('#addFrozen').checked;

    const shelfDays = itemKind === 'dry' ? 365 : (isFrozen ? 180 : guessShelfDays(name, unit));

    mergeInventoryEntry(inv, {name, qty, unit, buyDate:date, kind:itemKind, shelf:shelfDays, isFrozen: isFrozen, stockStatus:selectedStockStatus, ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(name)} : {})}, { mode: 'add' });

    formContainer.querySelector('#addName').value = '';
    formContainer.querySelector('#addQty').value = '';
    formContainer.querySelector('#addFrozen').checked = false;
    setAddKind('raw');
    selectedStockStatus = 'ok';
    els('#addStockStatus .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.status === 'ok'));
    renderTable();
    onInventoryChanged();
  };

  const grid=document.createElement('div'); grid.className='inventory-grid'; wrap.appendChild(grid);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.classList.add('visible'); scanStatus.innerHTML = '<span class="spinner"></span> 识别中...';
    try {
      const rawItems = await withTimeout(recognizeReceipt(file), 30000, 'AI 识别超时');
      const items = (Array.isArray(rawItems) ? rawItems : []).filter(it => it && it.name).map(it => ({
        name: it.name,
        qty: it.qty,
        unit: it.unit,
        originalName: it.originalName || it.name
      }));
      if(items.length === 0) {
        scanStatus.innerHTML = '<span class="text-danger">没有识别到可入库食材</span>';
        return;
      }
      scanStatus.innerHTML = `识别到 ${items.length} 项，请确认后入库`;
      showReceiptConfirmationModal(items, confirmed => {
        const matchedIds = confirmed.map(it => it.matchedShoppingItemId).filter(Boolean);
        if (matchedIds.length > 0) {
          markShoppingItemsStockedIn(matchedIds);
        }
        for(const it of confirmed) {
          const unit = it.unit || guessKitchenUnit(it.name);
          const itemKind = isDryGoodName(it.name) ? 'dry' : 'raw';
          mergeInventoryEntry(inv, { name: it.name, qty: Number(it.qty) || 1, unit, buyDate: todayISO(), kind: itemKind, shelf: itemKind === 'dry' ? 365 : guessShelfDays(it.name, unit), stockStatus:'ok', ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(it.name), isFrozen:false} : {}) }, { mode: 'add' });
        }
        scanStatus.innerHTML = `✅ 已确认入库 ${confirmed.length} 项`;
        setTimeout(() => { scanStatus.classList.remove('visible'); renderTable(); onInventoryChanged(); }, 1200);
      }, () => {
        scanStatus.innerHTML = '已取消入库';
        setTimeout(() => { scanStatus.classList.remove('visible'); }, 1200);
      });
    } catch(err) { scanStatus.innerHTML = `<span class="text-danger">❌ ${formatAiErrorMessage(err)}</span>`; }
    finally { e.target.value = ''; }
  };
  function renderTable(){
    grid.innerHTML='';
    const filteredInv = inv;
    // 按紧急程度降序：过期 → 临期 → 新鲜/冷冻 → 常备干货；同档按剩余天数升序。
    filteredInv.sort((a, b) => {
      const la = lifeStatus(a), lb = lifeStatus(b);
      if (la.rank !== lb.rank) return la.rank - lb.rank;
      return remainingDays(a) - remainingDays(b);
    });
    if(filteredInv.length === 0) {
      grid.innerHTML = `<div class="small inventory-empty-row">${inv.length===0 ? '库存空空如也，快去进货！' : '未找到'}</div>`;
      return;
    }
    for(const e of filteredInv){
      const card=document.createElement('div');
      const stockInfo = inventoryStateInfo(e.stockStatus);
      const life = lifeStatus(e);
      card.className = `inventory-card inventory-row life-${life.key}`;
      const lifeBar = `<div class="inv-life-bar" title="剩余保质期 ${life.pct}%"><span style="width:${life.pct}%"></span></div>`;
      card.innerHTML=`
        <div class="inv-card-head">
          <span class="inventory-item-name">${e.name}</span>
          <button class="btn bad small inventory-delete-btn" type="button" aria-label="删除">删</button>
        </div>
        <div class="status-cell">${badgeFor(e)}</div>
        ${lifeBar}
        <div class="inv-card-foot">
          <button type="button" class="inventory-status-chip ${stockInfo.className}" title="点击切换厨房状态">${stockInfo.label}</button>
          <div class="inventory-amount-control"><span>存量</span><input class="qty-input" type="number" min="0" step="1" value="${+e.qty||0}"><small>${e.unit}</small></div>
        </div>
        <small class="inventory-item-date">${e.buyDate||'未知'}</small>`;

      // 点击菜名打开编辑（其余可交互区域阻止冒泡）
      card.querySelector('.inventory-item-name').onclick = () => {
        showEditInventoryModal(e, () => { saveInventory(inv); renderTable(); onInventoryChanged(); });
      };

      const qtyInput = card.querySelector('.qty-input');
      const stockBtn = card.querySelector('.inventory-status-chip');
      stockBtn.onclick = () => {
        e.stockStatus = nextInventoryState(e.stockStatus);
        saveInventory(inv); renderTable(); onInventoryChanged();
      };

      qtyInput.onchange = () => {
        let newQty = +qtyInput.value || 0;
        if(newQty < 0) newQty = 0;
        e.qty = newQty;
        saveInventory(inv);
        if(+qtyInput.value < 0) qtyInput.value = 0;
        onInventoryChanged();
      };

      const statusCell = card.querySelector('.status-cell');
      if(statusCell) {
        statusCell.onclick = () => {
          if((e.kind || 'raw') === 'dry') return;
          e.isFrozen = !e.isFrozen;
          e.shelf = e.isFrozen ? 180 : guessShelfDays(e.name, e.unit);
          saveInventory(inv); renderTable(); onInventoryChanged();
        };
      }

      card.querySelector('.inventory-delete-btn').onclick = () => {
        const i = inv.indexOf(e);
        if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); onInventoryChanged(); }
      };
      grid.appendChild(card);
    }
  }
  renderTable(); return wrap;
}
