import { getCanonicalName, guessKitchenUnit } from '../ingredients.js?v=234';
import { addShoppingItem } from '../shopping.js?v=234';
import { escapeHtml, showToast } from './status.js?v=234';

function normalizeName(name) {
  return getCanonicalName(name || '') || String(name || '').trim();
}

function isUsedUpCalibration(row) {
  if (!row) return false;
  if (row.unitType === 'PIECE') return Number(row.finalQty) <= 0;
  return Number(row.finalGear) <= 0;
}

function addCandidate(map, item, reason = 'used-up') {
  const name = normalizeName(item?.name || item?.item);
  if (!name) return;
  const unit = item?.unit || guessKitchenUnit(name) || '';
  const qty = item?.qty ?? '';
  const key = `${name}::${unit}`;
  if (!map.has(key)) {
    map.set(key, {
      name,
      unit,
      qty,
      reason
    });
  }
}

export function getCookShoppingCandidates({ calibrations = [], skipped = [], missing = [] } = {}) {
  const map = new Map();
  (calibrations || [])
    .filter(isUsedUpCalibration)
    .forEach(row => addCandidate(map, row, 'used-up'));

  (skipped || [])
    .filter(row => row && row.reason === 'no-stock')
    .forEach(row => addCandidate(map, row, 'no-stock'));

  (missing || [])
    .filter(row => row && (row.item || row.name))
    .forEach(row => addCandidate(map, row, 'missing'));

  return [...map.values()];
}

function buildCookMessages({ updated = false, skipped = [], candidates = [], missing = [] } = {}) {
  const messages = [];
  if (updated) messages.push('已帮你更新食材余量。');
  else messages.push('已记录最近做过。');

  if (!updated && (missing || []).length) {
    messages.push('这道菜的食材没有自动扣，可以按需加入买菜。');
  }
  if ((skipped || []).length) {
    messages.push('有几样食材没自动扣，之后可以手动调整。');
  }
  if ((candidates || []).length) {
    messages.push((missing || []).length
      ? '有几样可以顺手加入买菜。'
      : '有几样已经用完，可以顺手加入买菜。');
  }
  return messages;
}

function normalizeShoppingCandidates(candidates = []) {
  const map = new Map();
  (candidates || []).forEach(item => addCandidate(map, item, item?.reason || 'used-up'));
  return [...map.values()];
}

function formatCandidateAmount(item) {
  const qty = item?.qty === null || item?.qty === undefined ? '' : String(item.qty).trim();
  const unit = String(item?.unit || '').trim();
  if (qty && unit) return `${qty}${unit}`;
  return qty || unit;
}

function closeModal(overlay, panel, afterClose = () => {}) {
  if (!overlay || !panel) return;
  panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
  panel.style.opacity = '0';
  panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
  overlay.classList.add('closing');
  window.setTimeout(() => {
    overlay.remove();
    afterClose();
  }, 220);
}

export function showCookCompleteFeedback({
  updated = false,
  skipped = [],
  candidates = [],
  missing = [],
  onClose = () => {},
  onShoppingAdded = null
} = {}) {
  const shoppingCandidates = getCookShoppingCandidates({ skipped, missing }).concat(candidates || []);
  const uniqueCandidates = normalizeShoppingCandidates(shoppingCandidates);
  const messages = buildCookMessages({ updated, skipped, candidates: uniqueCandidates, missing });

  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';

  const panel = document.createElement('div');
  panel.className = 'km-modal-content cook-feedback-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">做好啦</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body cook-feedback-body">
      <div class="cook-feedback-icon" aria-hidden="true">🍳</div>
      <div class="cook-feedback-copy">
        ${messages.map(msg => `<p>${escapeHtml(msg)}</p>`).join('')}
      </div>
      ${uniqueCandidates.length ? `
        <div class="cook-feedback-restock">
          ${uniqueCandidates.slice(0, 5).map(item => `
            <span>${escapeHtml(item.name)}${formatCandidateAmount(item) ? ` <small>${escapeHtml(formatCandidateAmount(item))}</small>` : ''}</span>
          `).join('')}
        </div>
      ` : ''}
      <div class="km-modal-actions cook-feedback-actions">
        <button type="button" class="btn km-action-weak" id="cookFeedbackClose">知道了</button>
        ${uniqueCandidates.length ? '<button type="button" class="btn ok km-action-primary" id="cookFeedbackShopping">加入买菜</button>' : ''}
      </div>
    </div>
  `;

  overlay.appendChild(panel);
  document.body.appendChild(overlay);

  let closing = false;
  const close = (after = onClose) => {
    if (closing) return;
    closing = true;
    closeModal(overlay, panel, after);
  };

  panel.querySelector('.km-modal-close')?.addEventListener('click', () => close());
  panel.querySelector('#cookFeedbackClose')?.addEventListener('click', () => close());
  overlay.addEventListener('click', event => {
    if (event.target === overlay) close();
  });

  const shoppingBtn = panel.querySelector('#cookFeedbackShopping');
  if (shoppingBtn) {
    shoppingBtn.addEventListener('click', () => {
      uniqueCandidates.forEach(item => {
        const remark = item.reason === 'missing' ? '做这道菜可能需要' : '做完用完，顺手补上';
        addShoppingItem(item.name, item.qty || '', item.unit || guessKitchenUnit(item.name) || '', '做完补货', remark);
      });
      showToast('已加入买菜清单', { tone: 'success' });
      shoppingBtn.textContent = '已加入买菜';
      shoppingBtn.disabled = true;
      window.setTimeout(() => close(typeof onShoppingAdded === 'function' ? onShoppingAdded : onClose), 450);
    });
  }

  requestAnimationFrame(() => overlay.classList.add('open'));
}
