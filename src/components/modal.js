import { todayISO } from '../storage.js?v=98';
import { normalizeKitchenAmount } from '../ingredients.js?v=1';
import { escapeOptionAttr } from './status.js?v=1';

export function showReceiptConfirmationModal(items, onConfirm, onCancel) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const unitOptions = ['个', '盒', '袋', '瓶', '把', '份', 'g', 'ml'];
  const rows = items.map((item, index) => {
    const normalized = normalizeKitchenAmount(item.name, item.qty, item.unit);
    const name = normalized.name;
    const unit = normalized.unit;
    const qty = normalized.qty;
    return `
      <div class="receipt-confirm-row" data-index="${index}">
        <input class="receipt-name" value="${escapeOptionAttr(name)}" placeholder="食材名">
        <input class="receipt-qty" type="number" min="0" step="0.1" value="${qty}">
        <select class="receipt-unit">
          ${unitOptions.map(u => `<option value="${u}"${u === unit ? ' selected' : ''}>${u}</option>`).join('')}
        </select>
        <button type="button" class="btn bad small receipt-remove">删</button>
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
    btn.onclick = () => btn.closest('.receipt-confirm-row').remove();
  });
  overlay.querySelector('#cancelReceiptConfirm').onclick = () => {
    close();
    if(onCancel) onCancel();
  };
  overlay.querySelector('#saveReceiptConfirm').onclick = () => {
    const confirmed = Array.from(overlay.querySelectorAll('.receipt-confirm-row')).map(row => {
      const normalized = normalizeKitchenAmount(row.querySelector('.receipt-name').value.trim(), row.querySelector('.receipt-qty').value, row.querySelector('.receipt-unit').value);
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
    item.buyDate = overlay.querySelector('#editDate').value;
    item.shelf = Number(overlay.querySelector('#editShelf').value) || 7;
    item.isFrozen = overlay.querySelector('#editFrozen').checked;
    onSave();
    close();
  };

  overlay.onclick = e => { if(e.target === overlay) close(); };
}
