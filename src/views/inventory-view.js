import { els } from '../dom.js?v=205';
import { todayISO } from '../storage.js?v=205';
import {
  UNIT_TYPE,
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  getDryPrepText,
  getUnitType,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=205';
import {
  GEAR_LABELS,
  gearInfo,
  getItemGear,
  loadInventory,
  mergeInventoryEntry,
  remainingDays,
  saveInventory,
  upsertInventory
} from '../inventory.js?v=205';
import {
  formatAiErrorMessage,
  recognizeReceipt,
  withTimeout
} from '../ai.js?v=205';
import {
  showEditInventoryModal,
  showReceiptConfirmationModal
} from '../components/modal.js?v=205';
import {
  escapeHtml,
  escapeOptionAttr,
  setSelectValueWithOption
} from '../components/status.js?v=205';import { markShoppingItemsStockedIn } from '../shopping.js?v=205';

// 是否真正有货：数量 > 0 且状态不是「没有」，档位型还需未降到「断货」。
function hasRealStock(e){
  if((+e.qty || 0) <= 0) return false;
  if(e.stockStatus === 'empty') return false;
  if(getUnitType(e.name, e.unit) === UNIT_TYPE.GEAR && getItemGear(e) <= 0) return false;
  return true;
}

// 临期提示条：仅在「真正有货」且非干货时渲染，断货/没有的食材强制不渲染。
function expiryChipHtml(e){
  if((e.kind || 'raw') === 'dry') return '';
  if(!hasRealStock(e)) return ''; // 【前置判断】数量为 0 / 断货 → 不渲染临期标签
  if(e.isFrozen) return `<button type="button" class="inv-expiry-chip is-frozen" title="点击切换为冷藏">❄️ 冷冻</button>`;
  const r = remainingDays(e);
  if(r <= 1) return `<button type="button" class="inv-expiry-chip is-danger" title="点击切换为冷冻">即将过期 ${r}天</button>`;
  if(r <= 3) return `<button type="button" class="inv-expiry-chip is-warn" title="点击切换为冷冻">优先消耗 ${r}天</button>`;
  return ''; // 新鲜食材无需提示，保持卡片清爽
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
      const life = lifeStatus(e);
      const unitType = e.unitType || getUnitType(e.name, e.unit);
      card.className = `inventory-card inv-card-v2 inventory-row life-${life.key}`;

      // ── 双轨制状态徽标 ──────────────────────────────────────────────
      // GEAR（散装蔬菜/调料）：纯液态状态药丸，按五档位自适应色彩，无输入框、无进度条。
      // PIECE（计件物资）：菜名旁的优雅件数文本（如「1 盒」「2 个」），无输入框边框。
      let trackHtml;
      if(unitType === UNIT_TYPE.GEAR){
        const gear = gearInfo(getItemGear(e)).value;
        trackHtml = `<button type="button" class="inv-gear-pill gear-${gear}" title="点击降一档（充足→大半→一半→见底→断货）">${GEAR_LABELS[gear]}</button>`;
      } else {
        const qty = +e.qty || 0;
        const muted = (qty <= 0 || e.stockStatus === 'empty') ? ' is-muted' : '';
        const countText = qty > 0 ? `${qty} ${escapeHtml(e.unit || '')}`.trim() : '没有';
        trackHtml = `<span class="inv-piece-count${muted}">${countText}</span>`;
      }

      const expiryHtml = expiryChipHtml(e);

      // ── 紧凑两层横向流 ─────────────────────────────────────────────
      // Top Row：左 [食材名][状态药丸/件数]，右 [✕]；Bottom Row：临期提示条（仅有货且临期）。
      card.innerHTML=`
        <div class="inv-row-top">
          <div class="inv-top-left">
            <span class="inventory-item-name">${escapeHtml(e.name)}</span>
            ${trackHtml}
          </div>
          <span class="inv-del-x" role="button" tabindex="0" aria-label="删除" title="删除">✕</span>
        </div>
        ${expiryHtml ? `<div class="inv-row-bottom">${expiryHtml}</div>` : ''}`;

      // 点击菜名打开编辑
      card.querySelector('.inventory-item-name').onclick = () => {
        showEditInventoryModal(e, () => { saveInventory(inv); renderTable(); onInventoryChanged(); });
      };

      // GEAR 药丸：点击降一档（到断货后循环回充足）；PIECE 件数：点击打开编辑修改数量/单位。
      if(unitType === UNIT_TYPE.GEAR){
        card.querySelector('.inv-gear-pill').onclick = () => {
          const order = [100, 75, 50, 25, 0];
          const cur = gearInfo(getItemGear(e)).value;
          const next = order[(order.indexOf(cur) + 1) % order.length];
          e.gear = next;
          e.unitType = UNIT_TYPE.GEAR;
          if(next === 0){ e.stockStatus = 'empty'; e.qty = 0; }
          else if(next <= 25){ e.stockStatus = 'low'; if(!(+e.qty > 0)) e.qty = 1; }
          else { e.stockStatus = 'ok'; if(!(+e.qty > 0)) e.qty = 1; }
          saveInventory(inv); renderTable(); onInventoryChanged();
        };
      } else {
        card.querySelector('.inv-piece-count').onclick = () => {
          showEditInventoryModal(e, () => { saveInventory(inv); renderTable(); onInventoryChanged(); });
        };
      }

      // 临期提示条：点击切换冷冻 / 冷藏（保留原有交互）。
      const expiryChip = card.querySelector('.inv-expiry-chip');
      if(expiryChip){
        expiryChip.onclick = () => {
          if((e.kind || 'raw') === 'dry') return;
          e.isFrozen = !e.isFrozen;
          e.shelf = e.isFrozen ? 180 : guessShelfDays(e.name, e.unit);
          saveInventory(inv); renderTable(); onInventoryChanged();
        };
      }

      // 删除：右上角轻量化小叉。
      const delX = card.querySelector('.inv-del-x');
      const doDelete = () => {
        const i = inv.indexOf(e);
        if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); onInventoryChanged(); }
      };
      delX.onclick = doDelete;
      delX.onkeydown = (ev) => { if(ev.key === 'Enter' || ev.key === ' '){ ev.preventDefault(); doDelete(); } };

      grid.appendChild(card);
    }
  }
  renderTable(); return wrap;
}
