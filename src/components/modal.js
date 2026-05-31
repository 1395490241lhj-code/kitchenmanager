import { todayISO } from '../storage.js?v=184';
import { normalizeKitchenAmount, isSeasoning } from '../ingredients.js?v=184';
import { escapeOptionAttr, escapeHtml, setInlineStatus } from './status.js?v=184';
import { findInventoryMatch, formatInventoryAmount, getStockCoverageAnalysis, isIngredientMatch } from '../inventory.js?v=184';
import { loadShoppingItems, matchReceiptItemsToShoppingItems } from '../shopping.js?v=184';

export function showReceiptConfirmationModal(items, onConfirm, onCancel) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const unitOptions = ['个', '盒', '袋', '包', '瓶', '把', '份', 'g', 'ml'];
  const rows = items.map((item, index) => {
    const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit, { source: 'receipt' });
    const name = normalized.name;
    const unit = normalized.unit;
    const qty = normalized.qty;
    const originalName = item.originalName || item.name;
    const showOrig = originalName && originalName !== name;

    return `
      <div class="receipt-confirm-item" data-index="${index}" data-original-name="${escapeOptionAttr(originalName)}">
        <div class="receipt-confirm-row">
          <input class="receipt-name" value="${escapeOptionAttr(name)}" placeholder="食材名">
          <input class="receipt-qty" type="number" min="0" step="0.1" value="${qty}">
          <select class="receipt-unit">
            ${unitOptions.map(u => `<option value="${u}"${u === unit ? ' selected' : ''}>${u}</option>`).join('')}
          </select>
          <button type="button" class="btn bad small receipt-remove">删</button>
        </div>
        ${showOrig ? `<div class="receipt-original-name">原文：${escapeHtml(originalName)}</div>` : ''}
        <div class="receipt-match-container"></div>
      </div>
    `;
  }).join('');

  overlay.innerHTML = `
    <div class="card receipt-confirm-card">
      <h3>确认识别结果</h3>
      <p class="meta">AI 识别只作为草稿，确认后才会入库。</p>
      <div class="receipt-confirm-list">${rows}</div>
      <div class="controls receipt-confirm-actions">
        <button type="button" class="btn" id="cancelReceiptConfirm">取消</button>
        <button type="button" class="btn ok" id="saveReceiptConfirm">确认入库</button>
      </div>
    </div>
  `;

  const shoppingItems = loadShoppingItems();

  const refreshMatches = () => {
    const currentRows = Array.from(overlay.querySelectorAll('.receipt-confirm-item')).map(itemEl => {
      return {
        name: itemEl.querySelector('.receipt-name').value.trim(),
        qty: itemEl.querySelector('.receipt-qty').value,
        unit: itemEl.querySelector('.receipt-unit').value,
        el: itemEl
      };
    });

    const matches = matchReceiptItemsToShoppingItems(currentRows, shoppingItems);

    matches.forEach((res, i) => {
      const itemEl = currentRows[i].el;
      const matchContainer = itemEl.querySelector('.receipt-match-container');
      if (!matchContainer) return;

      const match = res.match;
      if (!match) {
        matchContainer.innerHTML = `<span class="receipt-match-status none">作为新库存项</span>`;
      } else if (match.type === 'exact') {
        const qtyText = match.shoppingItem.qty ? `${match.shoppingItem.qty}${match.shoppingItem.unit}` : '无数量';
        matchContainer.innerHTML = `
          <label class="receipt-match-label">
            <input type="checkbox" class="receipt-match-checkbox" checked data-shopping-id="${match.shoppingItem.id}">
            <span>匹配到购物项：${escapeHtml(match.shoppingItem.name)} ${escapeHtml(qtyText)}${res.match.confidence === 'high' ? ' <span class="match-high-conf">(数量相近)</span>' : ''}</span>
          </label>
        `;
      } else if (match.type === 'needsConfirm') {
        const qtyText = match.shoppingItem.qty ? `${match.shoppingItem.qty}${match.shoppingItem.unit}` : '无数量';
        matchContainer.innerHTML = `
          <label class="receipt-match-label warning">
            <input type="checkbox" class="receipt-match-checkbox" data-shopping-id="${match.shoppingItem.id}">
            <span>⚠️ 单位不同（需确认）：${escapeHtml(match.shoppingItem.name)} ${escapeHtml(qtyText)}</span>
          </label>
        `;
      }
    });
  };

  const close = () => overlay.remove();
  overlay.querySelectorAll('.receipt-remove').forEach(btn => {
    btn.onclick = () => {
      btn.closest('.receipt-confirm-item').remove();
      refreshMatches();
    };
  });
  overlay.querySelector('#cancelReceiptConfirm').onclick = () => {
    close();
    if(onCancel) onCancel();
  };
  overlay.querySelector('#saveReceiptConfirm').onclick = () => {
    const confirmed = Array.from(overlay.querySelectorAll('.receipt-confirm-item')).map(itemEl => {
      const nameEl = itemEl.querySelector('.receipt-name');
      const qtyEl = itemEl.querySelector('.receipt-qty');
      const unitEl = itemEl.querySelector('.receipt-unit');
      if (!nameEl) return null;

      const name = nameEl.value.trim();
      const qty = qtyEl.value;
      const unit = unitEl.value;

      const normalized = normalizeKitchenAmount(name, qty, unit, { source: 'receipt' });
      if (!normalized.name) return null;

      const originalName = itemEl.dataset.originalName || normalized.name;
      normalized.originalName = originalName;

      const matchCheckbox = itemEl.querySelector('.receipt-match-checkbox');
      if (matchCheckbox && matchCheckbox.checked) {
        normalized.matchedShoppingItemId = matchCheckbox.dataset.shoppingId;
      }
      return normalized;
    }).filter(Boolean);

    close();
    onConfirm(confirmed);
  };
  overlay.onclick = e => {
    if(e.target === overlay) {
      close();
      if(onCancel) onCancel();
    }
  };

  const listContainer = overlay.querySelector('.receipt-confirm-list');
  listContainer.addEventListener('input', refreshMatches);
  listContainer.addEventListener('change', refreshMatches);

  refreshMatches();

  document.body.appendChild(overlay);
}

export function showEditInventoryModal(item, onSave) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';

  const dialog = document.createElement('div');
  dialog.className = 'card modal-card';

  dialog.innerHTML = `
    <h3 class="modal-title">📝 编辑库存: ${item.name}</h3>
    <div class="modal-field-group">
      <label class="small modal-field-label">购买日期 (补录用)</label>
      <input type="date" id="editDate" value="${item.buyDate || todayISO()}" class="modal-field-input">
    </div>
    <div class="modal-field-group">
      <label class="small modal-field-label">保质期 (天)</label>
      <input type="number" id="editShelf" value="${item.shelf || 7}" class="modal-field-input">
    </div>
    <div class="modal-frozen-row">
      <input type="checkbox" id="editFrozen" ${item.isFrozen ? 'checked' : ''} class="modal-frozen-checkbox">
      <label for="editFrozen" class="modal-frozen-label">❄️ 冷冻保存 (延长保质)</label>
    </div>
    <div id="editModalStatus" class="small inline-status" hidden></div>
    <div class="modal-actions">
      <button class="btn modal-cancel-btn" id="cancelBtn">取消</button>
      <button class="btn ok modal-save-btn" id="saveBtn">保存修改</button>
    </div>
  `;

  overlay.appendChild(dialog);
  document.body.appendChild(overlay);

  const close = () => {
    overlay.classList.add('closing');
    setTimeout(() => document.body.removeChild(overlay), 200);
  };

  overlay.querySelector('#cancelBtn').onclick = close;
  overlay.querySelector('#saveBtn').onclick = () => {
    const buyDateVal = overlay.querySelector('#editDate').value;
    const shelfVal = overlay.querySelector('#editShelf').value.trim();
    const shelfNum = Number(shelfVal);
    const statusEl = overlay.querySelector('#editModalStatus');

    if (!buyDateVal) {
      setInlineStatus(statusEl, '购买日期不能为空。', 'bad');
      return;
    }
    if (shelfVal === '' || isNaN(shelfNum) || shelfNum < 0) {
      setInlineStatus(statusEl, '保质期必须是大于或等于 0 的数字。', 'bad');
      return;
    }

    item.buyDate = buyDateVal;
    item.shelf = shelfNum;
    item.isFrozen = overlay.querySelector('#editFrozen').checked;
    onSave();
    close();
  };

  overlay.onclick = e => { if(e.target === overlay) close(); };
}

/**
 * 做完菜后弹出"是否扣减库存？"确认弹窗。
 * @param {string}   recipeName   - 菜谱名
 * @param {Array}    coreItems    - 核心食材列表，来自 recipe_ingredients（已 explode）
 * @param {Array}    inv          - 当前库存
 * @param {Function} onConfirm   - (deductions: [{name,qty,unit}]) => void  — 确认扣减
 * @param {Function} onSkip      - () => void  — 仅记录做完，不扣库存
 * @param {Function} [onCancel]  - () => void  — 取消
 */
export function showDeductStockModal(recipeName, coreItems, inv, onConfirm, onSkip, onCancel) {
  // 过滤掉调味料，只保留核心食材
  const rows = (coreItems || [])
    .filter(it => it && it.item && !isSeasoning(it.item))
    .map(it => {
      const analysis = getStockCoverageAnalysis(inv, it.item, it.qty, it.unit);
      
      let match = null;
      let stockText = '';
      let defaultVal = '0';
      let unitMismatch = false;

      if (analysis.confidence === 'exact') {
        match = analysis.matchedItems[0];
        const totalQty = analysis.matchedItems.reduce((sum, x) => sum + (+x.qty || 0), 0);
        stockText = `${totalQty}${it.unit || ''}`;
        defaultVal = it.qty !== '' ? String(it.qty) : '0';
        unitMismatch = false;
      } else if (analysis.confidence === 'unit-mismatch') {
        match = analysis.matchedItems[0];
        const totalQty = analysis.matchedItems.reduce((sum, x) => sum + (+x.qty || 0), 0);
        stockText = `${totalQty}${match.unit || ''}`;
        defaultVal = '0';
        unitMismatch = true;
      } else if (analysis.confidence === 'status-only') {
        match = analysis.matchedItems[0];
        stockText = '充足 (数量未填)';
        defaultVal = '0';
        unitMismatch = (match.unit || '') !== (it.unit || '');
      } else {
        match = null;
        stockText = '无匹配库存';
        defaultVal = '0';
        unitMismatch = false;
      }

      return {
        name: it.item,
        recipeQty: it.qty || '',
        unit: it.unit || '',
        match,
        stockText,
        defaultVal,
        unitMismatch,
        matchedUnit: match ? (match.unit || '') : ''
      };
    });

  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';

  const rowsHtml = rows.length
    ? rows.map((row, i) => `
        <div class="deduct-row" data-index="${i}">
          <span class="deduct-name">${escapeHtml(row.name)}</span>
          <span class="deduct-recipe-qty">${row.recipeQty ? `用量 ${escapeHtml(String(row.recipeQty))}${escapeHtml(row.unit)}` : '用量不详'}</span>
          <span class="deduct-stock-info ${row.match ? 'has-match' : 'no-match'}">
            ${row.match ? `库存 ${escapeHtml(row.stockText)}` : '无匹配库存'}
            ${row.unitMismatch ? `<br><small class="deduct-unit-warning">⚠️ 库存单位（${escapeHtml(row.matchedUnit)}）与菜谱单位（${escapeHtml(row.unit)}）不同</small>` : ''}
          </span>
          <label class="deduct-qty-label">
            <span>扣减</span>
            <input
              class="deduct-qty-input"
              type="number"
              min="0"
              step="0.1"
              value="${escapeOptionAttr(row.defaultVal)}"
              ${!row.match ? 'disabled title="无库存匹配，无法扣减"' : ''}
            >
            <span>${escapeHtml(row.unit) || ''}</span>
          </label>
          ${row.unitMismatch ? `<label class="deduct-mismatch-warn is-hidden" id="deduct-mismatch-confirm-${i}"><input type="checkbox" class="deduct-mismatch-checkbox"> 我确认要从不同单位库存中扣减（可能不精确）</label>` : ''}
        </div>
      `).join('')
    : '<p class="meta">本菜谱没有核心食材信息，无需扣减。</p>';

  overlay.innerHTML = `
    <div class="card deduct-stock-card">
      <h3 class="modal-title">📦 是否扣减库存？</h3>
      <p class="meta">做完 <strong>${escapeHtml(recipeName)}</strong> 后，可以按实际用量扣减对应食材。</p>
      <div class="deduct-stock-list">${rowsHtml}</div>
      <div id="deductModalStatus" class="inline-status" hidden></div>
      <div class="modal-actions deduct-stock-actions">
        <button type="button" class="btn modal-cancel-btn" id="deductCancelBtn">取消</button>
        <button type="button" class="btn" id="deductSkipBtn">仅记录做完</button>
        <button type="button" class="btn ok" id="deductConfirmBtn">确认扣减并完成</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  const statusEl = overlay.querySelector('#deductModalStatus');

  // 绑定单位不一致时，输入数量后显示确认复选框
  overlay.querySelectorAll('.deduct-row').forEach((rowEl, i) => {
    const row = rows[i];
    if (!row || !row.unitMismatch) return;
    const input = rowEl.querySelector('.deduct-qty-input');
    const confirmLabel = overlay.querySelector(`#deduct-mismatch-confirm-${i}`);
    if (!input || !confirmLabel) return;
    const toggleConfirm = () => {
      const val = parseFloat(input.value);
      if (val > 0) {
        confirmLabel.classList.remove('is-hidden');
      } else {
        confirmLabel.classList.add('is-hidden');
        confirmLabel.querySelector('.deduct-mismatch-checkbox').checked = false;
      }
    };
    input.addEventListener('input', toggleConfirm);
    toggleConfirm();
  });

  const close = () => {
    overlay.classList.add('closing');
    setTimeout(() => overlay.remove(), 200);
  };

  overlay.querySelector('#deductCancelBtn').onclick = () => {
    close();
    if (typeof onCancel === 'function') onCancel();
  };

  overlay.querySelector('#deductSkipBtn').onclick = () => {
    close();
    onSkip();
  };

  // 二次确认状态：当第一次检测到超量时置 true，再次点击时才放行
  let overLimitConfirmed = false;

  // 任何输入变化都重置二次确认状态
  overlay.querySelectorAll('.deduct-qty-input').forEach(input => {
    input.addEventListener('input', () => {
      overLimitConfirmed = false;
      setInlineStatus(statusEl, '', '');
    });
  });

  overlay.querySelector('#deductConfirmBtn').onclick = () => {
    const deductions = [];
    let needsMismatchConfirm = false;

    overlay.querySelectorAll('.deduct-row').forEach((rowEl, i) => {
      const row = rows[i];
      if (!row || !row.match) return; // 无库存匹配，跳过
      const input = rowEl.querySelector('.deduct-qty-input');
      const qty = parseFloat(input.value);
      if (!isFinite(qty) || qty <= 0) return; // 0 或空 → 不扣

      // 跨单位：必须勾选确认复选框才允许
      if (row.unitMismatch) {
        const confirmLabel = overlay.querySelector(`#deduct-mismatch-confirm-${i}`);
        const checkbox = confirmLabel ? confirmLabel.querySelector('.deduct-mismatch-checkbox') : null;
        if (!checkbox || !checkbox.checked) {
          needsMismatchConfirm = true;
          return; // 此行跳过，继续检查其他行
        }
      }

      deductions.push({
        name: row.name,
        qty,
        unit: row.unit,
        allowMismatch: row.unitMismatch ? true : false
      });
    });

    // 如果有跨单位行填了数量但没勾选确认，阻止关闭并提示（优先于超量检查）
    if (needsMismatchConfirm) {
      setInlineStatus(statusEl, '请先勾选"我确认要从不同单位库存中扣减"后再继续。', 'bad');
      overLimitConfirmed = false;
      return;
    }

    // 检测超量：收集所有超量食材名
    const overLimitNames = [];
    for (const d of deductions) {
      const matched = (inv || []).filter(x => isIngredientMatch(d.name, x.name) && (+x.qty || 0) > 0 && x.stockStatus !== 'empty');
      const sameUnit = matched.filter(x => (x.unit || '') === (d.unit || ''));
      const diffUnit = matched.filter(x => (x.unit || '') !== (d.unit || ''));

      let totalAvail = sameUnit.reduce((s, b) => s + (+b.qty || 0), 0);
      if (d.allowMismatch) {
        totalAvail += diffUnit.reduce((s, b) => s + (+b.qty || 0), 0);
      }

      if (d.qty > totalAvail + 0.001) {
        overLimitNames.push(`${d.name}（输入 ${d.qty}${d.unit}，库存 ${totalAvail}${d.unit}）`);
      }
    }

    // 第一次检测到超量：仅展示警告，不关闭
    if (overLimitNames.length > 0 && !overLimitConfirmed) {
      const nameList = overLimitNames.join('；');
      setInlineStatus(
        statusEl,
        `以下食材扣减量超过当前库存，将扣至 0：${nameList}。请再次点击"确认扣减并完成"继续，或修改数量。`,
        'bad'
      );
      overLimitConfirmed = true; // 下次点击放行
      return;
    }

    // 正常（或已二次确认）→ 执行扣减
    close();
    onConfirm(deductions);
  };

  overlay.onclick = e => { if (e.target === overlay) close(); };
}

export function showCleanFridgeModal(recs, options = {}) {
  const { onAddPlan, onAddShopping } = options;
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  
  let contentHtml = '';
  if (!recs || recs.length === 0) {
    contentHtml = `
      <div class="clean-fridge-empty" style="text-align: center; padding: 24px; color: var(--text-secondary);">
        <strong style="display: block; font-size: 16px; margin-bottom: 8px; color: var(--text-main);">当前没有特别需要优先消耗的食材</strong>
        <span>您的食材都还很新鲜，或者存量充足！</span>
      </div>
    `;
  } else {
    const rows = recs.map((item, index) => {
      const isAlmost = item.missing && item.missing.length > 0 && item.missing.length <= 2;
      return `
        <div class="clean-fridge-item" data-index="${index}" style="display: flex; align-items: center; justify-content: space-between; padding: 12px; border-bottom: 1px solid var(--separator); gap: 12px;">
          <div class="clean-fridge-item-main" style="display: flex; flex-direction: column; gap: 4px; flex: 1; min-width: 0;">
            <span class="clean-fridge-item-name" style="font-weight: 600; color: var(--text-main); font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${escapeHtml(item.r.name)}</span>
            <span class="clean-fridge-item-reason" style="font-size: 12px; color: var(--status-warn-text, #a55e00); font-weight: 500;">${escapeHtml(item.reason)}</span>
          </div>
          <div class="clean-fridge-item-actions" style="display: flex; gap: 8px; flex-shrink: 0;">
            <a class="btn small clean-fridge-view-btn" href="#recipe:${item.r.id}" style="text-decoration: none;">详情</a>
            <button type="button" class="btn ${isAlmost ? '' : 'ok'} small clean-fridge-action-btn" data-id="${item.r.id}" data-mode="${isAlmost ? 'almost' : 'ready'}">
              ${isAlmost ? '补清单' : '加入计划'}
            </button>
          </div>
        </div>
      `;
    }).join('');
    contentHtml = `<div class="clean-fridge-list" style="display: flex; flex-direction: column; max-height: 400px; overflow-y: auto;">${rows}</div>`;
  }

  overlay.innerHTML = `
    <div class="card clean-fridge-modal-card" style="width: min(540px, 95vw); max-height: min(600px, 90vh); overflow-y: auto;">
      <h3 class="modal-title">❄️ 帮我清冰箱</h3>
      <p class="meta" style="margin-bottom: 16px;">系统已为您智能筛选出快到期、低存量或已开封的食材搭配做法：</p>
      <div class="clean-fridge-modal-body">${contentHtml}</div>
      <div class="modal-actions" style="margin-top: 20px;">
        <button type="button" class="btn ok" id="closeCleanFridgeBtn">知道了</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector('#closeCleanFridgeBtn').onclick = close;
  overlay.onclick = e => { if (e.target === overlay) close(); };

  overlay.querySelectorAll('.clean-fridge-view-btn').forEach(btn => {
    btn.onclick = () => close();
  });

  overlay.querySelectorAll('.clean-fridge-action-btn').forEach(btn => {
    btn.onclick = () => {
      const id = btn.dataset.id;
      const mode = btn.dataset.mode;
      if (mode === 'almost') {
        if (onAddShopping) onAddShopping(id, btn);
      } else {
        if (onAddPlan) onAddPlan(id, btn);
      }
    };
  });
}

