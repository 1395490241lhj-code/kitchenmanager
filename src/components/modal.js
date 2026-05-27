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
  overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:999;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(2px);';

  const dialog = document.createElement('div');
  dialog.className = 'card';
  dialog.style.cssText = 'width:90%;max-width:320px;background:var(--bg-card);padding:24px;border-radius:16px;box-shadow:0 10px 25px rgba(0,0,0,0.2);animation:fadeIn 0.2s ease-out;';

  const style = document.createElement('style');
  style.innerHTML = '@keyframes fadeIn { from { opacity: 0; transform: scale(0.95); } to { opacity: 1; transform: scale(1); } }';
  document.head.appendChild(style);

  dialog.innerHTML = `
    <h3 style="margin-top:0;color:var(--text-main);font-size:18px;">📝 编辑库存: ${item.name}</h3>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">购买日期 (补录用)</label>
      <input type="date" id="editDate" value="${item.buyDate || todayISO()}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">保质期 (天)</label>
      <input type="number" id="editShelf" value="${item.shelf || 7}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:24px;display:flex;align-items:center;padding:10px;background:var(--bg-main);border-radius:8px;">
      <input type="checkbox" id="editFrozen" ${item.isFrozen ? 'checked' : ''} style="width:20px;height:20px;accent-color:var(--accent);cursor:pointer;">
      <label for="editFrozen" style="margin-left:10px;flex:1;cursor:pointer;font-weight:500;">❄️ 冷冻保存 (延长保质)</label>
    </div>
    <div style="display:flex;gap:12px;justify-content:flex-end;">
      <button class="btn" id="cancelBtn" style="background:transparent;border:1px solid var(--separator);color:var(--text-main);">取消</button>
      <button class="btn ok" id="saveBtn" style="flex:1;">保存修改</button>
    </div>
  `;

  overlay.appendChild(dialog);
  document.body.appendChild(overlay);

  const close = () => {
    overlay.style.opacity = '0';
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
