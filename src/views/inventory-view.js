import { els } from '../dom.js?v=89';
import { todayISO } from '../storage.js?v=98';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  normalizeKitchenAmount
} from '../ingredients.js?v=1';
import {
  inventoryStateInfo,
  loadInventory,
  nextInventoryState,
  remainingDays,
  saveInventory,
  upsertInventory
} from '../inventory.js?v=1';
import {
  formatAiErrorMessage,
  recognizeReceipt,
  withTimeout
} from '../ai.js?v=2';
import {
  showEditInventoryModal,
  showReceiptConfirmationModal
} from '../components/modal.js?v=1';
import {
  escapeHtml,
  escapeOptionAttr,
  setSelectValueWithOption
} from '../components/status.js?v=1';
function badgeFor(e){
  if((e.kind || 'raw') === 'dry') return `<span class="kchip dry" title="${escapeOptionAttr(getDryPrepText(e.name))}">干货 · ${escapeHtml(getDryPrepText(e.name))}</span>`;
  if(e.isFrozen) return `<span class="kchip" style="background:#5f6b78;color:white;cursor:pointer" title="点击切换为冷藏">❄️ 冷冻</span>`;
  const r=remainingDays(e);
  let html = '';
  if(r<=1) html = `<span class="kchip bad" style="cursor:pointer" title="点击切换为冷冻">即将过期 ${r}天</span>`;
  else if(r<=3) html = `<span class="kchip warn" style="cursor:pointer" title="点击切换为冷冻">优先消耗 ${r}天</span>`;
  else html = `<span class="kchip ok" style="cursor:pointer" title="点击切换为冷冻">新鲜 ${r}天</span>`;
  return html;
}

// ★★★ 修复：使用 SVG 图标 + 强制隐藏 Input + 冷冻功能 + 防止负数 + [新增]详情编辑 + [修复]按钮重叠(使用Grid) ★★★
export function renderInventory(pack, options = {}){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div');
  const onInventoryChanged = typeof options.onInventoryChanged === 'function' ? options.onInventoryChanged : () => {};
  const ingredientOptions = buildIngredientOptions(catalog);
  // [修改] 使用新的 main-title-center 样式, 且明确使用 span
  const header = document.createElement('div');
  header.className = 'main-title-center';
  header.innerHTML = '<span>厨房</span>';
  if (options.showTitle !== false) wrap.appendChild(header);

  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px';

  // SVG + visually-hidden input (添加 style="display:none!important" 双重保险)
  searchDiv.innerHTML = `
    <div style="display:flex; gap:8px; width:100%; justify-content:flex-end;">
      <button type="button" class="btn small" id="exportInventoryBtn" title="导出库存" style="gap:6px;">
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        <span>导出库存</span>
      </button>
      <label class="btn ai icon-only" style="cursor:pointer;">
        <input type="file" id="camInput" accept="image/*" capture="environment" class="visually-hidden" style="display:none!important">
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
      </label>
      <button type="button" class="btn ok icon-only" id="toggleAddBtn">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </button>
    </div>
    <div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>
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

  // [修改] 彻底使用 Grid 布局修复对齐问题
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container';
  formContainer.innerHTML = `
    <div class="form-grid">
      <div class="full-width">
        <input id="addName" list="catalogList" placeholder="食材名称 (必填)" style="width:100%;">
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
        <input id="addQty" type="number" min="0" step="1" placeholder="数量（可选）" style="width:60%;">
        <select id="addUnit" style="width:40%;"><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份" selected>份</option><option value="g">g</option><option value="ml">ml</option></select>
      </div>
      <input id="addDate" type="date" value="${todayISO()}" style="width:100%;">
      <div class="full-width" style="margin-top:4px;">
         <label style="display:flex;align-items:center;font-size:14px;cursor:pointer;margin-right:auto;">
           <input type="checkbox" id="addFrozen" style="width:18px;height:18px;margin-right:6px;accent-color:var(--accent);">冷冻
         </label>
         <button id="addBtn" class="btn ok" style="min-width:100px;">入库</button>
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
    formContainer.querySelector('#addFrozen').closest('label').style.display = selectedKind === 'dry' ? 'none' : 'flex';
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

  // [修改] 强制数量非负 + 冷冻逻辑
  formContainer.querySelector('#addBtn').onclick=()=>{
    const rawName=formContainer.querySelector('#addName').value.trim();
    if(!rawName) return alert('请输入食材名称');
    const name=getCanonicalName(rawName);

    // 空数量按 1 处理；明确填写 0 时保留 0，方便记录“已用完但想保留条目”的食材。
    const qtyText = formContainer.querySelector('#addQty').value.trim();
    let qty = qtyText === '' ? 1 : Number(qtyText);
    if(!Number.isFinite(qty)) qty = 1;
    if (qty < 0) qty = 0;

    const unit=formContainer.querySelector('#addUnit').value || guessKitchenUnit(name) || '份';
    setSelectValueWithOption(formContainer.querySelector('#addUnit'), unit);
    const date=formContainer.querySelector('#addDate').value||todayISO();
    const itemKind = selectedKind === 'dry' || isDryGoodName(name) ? 'dry' : 'raw';
    const isFrozen = itemKind === 'dry' ? false : formContainer.querySelector('#addFrozen').checked; // 获取冷冻状态

    // 如果冷冻，保质期设为180天，否则自动推算
    const shelfDays = itemKind === 'dry' ? 365 : (isFrozen ? 180 : guessShelfDays(name, unit));

    upsertInventory(inv,{name, qty, unit, buyDate:date, kind:itemKind, shelf:shelfDays, isFrozen: isFrozen, stockStatus:selectedStockStatus, ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(name)} : {})});

    formContainer.querySelector('#addName').value = '';
    formContainer.querySelector('#addQty').value = '';
    formContainer.querySelector('#addFrozen').checked = false; // 重置
    setAddKind('raw');
    selectedStockStatus = 'ok';
    els('#addStockStatus .add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.status === 'ok'));
    renderTable();
    onInventoryChanged();
  };

  const tbl=document.createElement('table'); tbl.className='table inventory-table'; tbl.innerHTML=`<thead><tr><th style="width:35%">食材</th><th style="width:25%">厨房状态</th><th style="width:25%">保质</th><th class="right">操作</th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 识别中...';
    try {
      const rawItems = await withTimeout(recognizeReceipt(file), 30000, 'AI 识别超时');
      const items = (Array.isArray(rawItems) ? rawItems : []).filter(it => it && it.name).map(it => normalizeKitchenAmount(it.name, it.qty, it.unit));
      if(items.length === 0) {
        scanStatus.innerHTML = '<span style="color:var(--danger)">没有识别到可入库食材</span>';
        return;
      }
      scanStatus.innerHTML = `识别到 ${items.length} 项，请确认后入库`;
      showReceiptConfirmationModal(items, confirmed => {
        for(const it of confirmed) {
          const unit = it.unit || guessKitchenUnit(it.name);
          const itemKind = isDryGoodName(it.name) ? 'dry' : 'raw';
          upsertInventory(inv, { name: it.name, qty: Number(it.qty) || 1, unit, buyDate: todayISO(), kind: itemKind, shelf: itemKind === 'dry' ? 365 : guessShelfDays(it.name, unit), stockStatus:'ok', ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(it.name), isFrozen:false} : {}) });
        }
        scanStatus.innerHTML = `✅ 已确认入库 ${confirmed.length} 项`;
        setTimeout(() => { scanStatus.style.display = 'none'; renderTable(); onInventoryChanged(); }, 1200);
      }, () => {
        scanStatus.innerHTML = '已取消入库';
        setTimeout(() => { scanStatus.style.display = 'none'; }, 1200);
      });
    } catch(err) { scanStatus.innerHTML = `<span style="color:var(--danger)">❌ ${formatAiErrorMessage(err)}</span>`; }
    finally { e.target.value = ''; }
  };
  function renderTable(){
    const tb=tbl.querySelector('tbody'); tb.innerHTML='';
    const filteredInv = inv;
    filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b));
    if(filteredInv.length === 0) { tb.innerHTML = `<tr><td colspan="4" class="small" style="text-align:center;padding:20px;">${inv.length===0 ? '库存空空如也，快去进货！' : '未找到'}</td></tr>`; return; }
    for(const e of filteredInv){
      const tr=document.createElement('tr');
      const stockInfo = inventoryStateInfo(e.stockStatus);
      // [修改] 增加点击名字编辑功能 + 显示购买日期
      tr.innerHTML=`
        <td class="name-cell" style="cursor:pointer;position:relative;">
          <span style="font-weight:600;color:var(--text-main)">${e.name}</span>
          <br><small style="color:var(--text-secondary);font-size:10px;">${e.buyDate||'未知'}</small>
        </td>
        <td class="kitchen-status-cell"><button type="button" class="inventory-status-chip ${stockInfo.className}" title="点击切换厨房状态">${stockInfo.label}</button><div class="inventory-amount-control"><span>存量</span><input class="qty-input" type="number" min="0" step="1" value="${+e.qty||0}"><small>${e.unit}</small></div></td>
        <td class="status-cell">${badgeFor(e)}</td>
        <td class="right"><button class="btn bad small" style="padding:4px 8px;" type="button">删</button></td>`;

      // 绑定编辑弹窗事件
      tr.querySelector('.name-cell').onclick = () => {
        showEditInventoryModal(e, () => {
          saveInventory(inv);
          renderTable();
          onInventoryChanged();
        });
      };

      const qtyInput = tr.querySelector('input');
      const stockBtn = tr.querySelector('.inventory-status-chip');
      stockBtn.onclick = () => {
        e.stockStatus = nextInventoryState(e.stockStatus);
        saveInventory(inv);
        renderTable();
        onInventoryChanged();
      };

      // [修改] 强制列表输入框非负
      qtyInput.onchange = () => {
        let newQty = +qtyInput.value || 0;
        if(newQty < 0) newQty = 0;
        e.qty = newQty;
        saveInventory(inv);
        // 如果用户输入了负数，重置输入框显示为0
        if(+qtyInput.value < 0) qtyInput.value = 0;
        onInventoryChanged();
      };

      // [新增] 点击状态标签切换冷冻/冷藏
      const statusCell = tr.querySelector('.status-cell');
      if(statusCell) {
        statusCell.onclick = () => {
          if((e.kind || 'raw') === 'dry') return;
          e.isFrozen = !e.isFrozen; // 切换状态
          // 重新计算保质期：冷冻=180天，冷藏=按规则计算
          e.shelf = e.isFrozen ? 180 : guessShelfDays(e.name, e.unit);
          saveInventory(inv);
          renderTable(); // 刷新显示
          onInventoryChanged();
        };
      }

      els('.btn',tr)[0].onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); onInventoryChanged(); }}; tb.appendChild(tr);
    }
  }
  renderTable(); return wrap;
}
