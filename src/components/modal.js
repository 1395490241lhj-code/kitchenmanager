import { todayISO } from '../storage.js?v=98';
import { normalizeKitchenAmount, isSeasoning } from '../ingredients.js?v=1';
import { escapeOptionAttr, escapeHtml, setInlineStatus } from './status.js?v=1';
import { findInventoryMatch, formatInventoryAmount } from '../inventory.js?v=1';

export function showReceiptConfirmationModal(items, onConfirm, onCancel) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const unitOptions = ['个', '盒', '袋', '瓶', '把', '份', 'g', 'ml'];
  const rows = items.map((item, index) => {
    const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit, { source: 'receipt' });
    const name = normalized.name;
    const unit = normalized.unit;
    const qty = normalized.qty;
    const originalName = item.originalName || item.name;
    const showOrig = originalName && originalName !== name;

    return `
      <div class="receipt-confirm-item" data-index="${index}">
        <div class="receipt-confirm-row">
          <input class="receipt-name" value="${escapeOptionAttr(name)}" placeholder="食材名">
          <input class="receipt-qty" type="number" min="0" step="0.1" value="${qty}">
          <select class="receipt-unit">
            ${unitOptions.map(u => `<option value="${u}"${u === unit ? ' selected' : ''}>${u}</option>`).join('')}
          </select>
          <button type="button" class="btn bad small receipt-remove">删</button>
        </div>
        ${showOrig ? `<div class="receipt-original-name" style="font-size: 11px; color: var(--text-muted); margin-top: -2px; margin-bottom: 6px; padding-left: 8px;">原文：${escapeHtml(originalName)}</div>` : ''}
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

  const close = () => overlay.remove();
  overlay.querySelectorAll('.receipt-remove').forEach(btn => {
    btn.onclick = () => btn.closest('.receipt-confirm-item').remove();
  });
  overlay.querySelector('#cancelReceiptConfirm').onclick = () => {
    close();
    if(onCancel) onCancel();
  };
  overlay.querySelector('#saveReceiptConfirm').onclick = () => {
    const confirmed = Array.from(overlay.querySelectorAll('.receipt-confirm-row')).map(row => {
      const normalized = normalizeKitchenAmount(row.querySelector('.receipt-name').value.trim(), row.querySelector('.receipt-qty').value, row.querySelector('.receipt-unit').value, { source: 'receipt' });
      return normalized.name ? normalized : null;
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
      const match = findInventoryMatch(inv, it.item);
      const stockText = match ? formatInventoryAmount(match) : null;
      return { name: it.item, recipeQty: it.qty || '', unit: it.unit || '', match, stockText };
    });

  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';

  const rowsHtml = rows.length
    ? rows.map((row, i) => `
        <div class="deduct-row" data-index="${i}">
          <span class="deduct-name">${escapeHtml(row.name)}</span>
          <span class="deduct-recipe-qty">${row.recipeQty ? `用量 ${escapeHtml(String(row.recipeQty))}${escapeHtml(row.unit)}` : '用量不详'}</span>
          <span class="deduct-stock-info ${row.match ? 'has-match' : 'no-match'}">${row.match ? `库存 ${escapeHtml(row.stockText)}` : '无匹配库存'}</span>
          <label class="deduct-qty-label">
            <span>扣减</span>
            <input
              class="deduct-qty-input"
              type="number"
              min="0"
              step="0.1"
              value="${row.recipeQty !== '' && row.match ? escapeOptionAttr(String(row.recipeQty)) : '0'}"
              ${!row.match ? 'disabled title="无库存匹配，无法扣减"' : ''}
            >
            <span>${escapeHtml(row.unit) || ''}</span>
          </label>
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

  overlay.querySelector('#deductConfirmBtn').onclick = () => {
    const deductions = [];
    overlay.querySelectorAll('.deduct-row').forEach((rowEl, i) => {
      const row = rows[i];
      if (!row || !row.match) return; // 无库存匹配，跳过
      const input = rowEl.querySelector('.deduct-qty-input');
      const qty = parseFloat(input.value);
      if (!isFinite(qty) || qty <= 0) return; // 0 或空 → 不扣
      deductions.push({ name: row.name, qty, unit: row.unit });
    });

    // 校验：不会扣成负数（deductInventoryForRecipe 自行 clamp，这里只做提示）
    for (const d of deductions) {
      const batches = (inv || []).filter(x => {
        // 与 deductInventoryForRecipe 中的 isIngredientMatch 逻辑一致
        return String(x.name || '').trim() !== '' &&
          (x.name === d.name || x.name.includes(d.name) || d.name.includes(x.name));
      });
      const totalAvail = batches.reduce((s, b) => s + (+b.qty || 0), 0);
      if (d.qty > totalAvail + 0.001) {
        setInlineStatus(statusEl, `${d.name} 的扣减量（${d.qty}）超过当前库存（${totalAvail}），将扣至 0。`, 'info');
      }
    }

    close();
    onConfirm(deductions);
  };

  overlay.onclick = e => { if (e.target === overlay) close(); };
}
