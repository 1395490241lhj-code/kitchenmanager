export function escapeOptionAttr(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function escapeHtml(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

export function brieflyConfirmButton(button, text = '已加入') {
  if(!button) return;
  const originalText = button.textContent;
  button.textContent = text;
  button.classList.add('is-confirmed');
  button.disabled = true;
  window.setTimeout(() => {
    button.disabled = false;
    button.classList.remove('is-confirmed');
    button.textContent = originalText;
  }, 900);
}

export function setInlineStatus(node, message, type = 'info') {
  if (!node) return;
  if (!message) {
    node.hidden = true;
    node.textContent = '';
    return;
  }
  node.hidden = false;
  node.textContent = message;
  node.className = `small inline-status ${type}`;
}

export function setActionStatus(node, {
  title = '',
  message = '',
  type = 'bad',
  primaryText = '',
  secondaryText = '',
  onPrimary = null,
  onSecondary = null
} = {}) {
  if (!node) return;
  node.hidden = false;
  node.className = `small inline-status ${type} ai-action-status`;
  const actions = [
    primaryText ? `<button type="button" class="btn ok small" data-ai-action="primary">${escapeHtml(primaryText)}</button>` : '',
    secondaryText ? `<button type="button" class="btn small" data-ai-action="secondary">${escapeHtml(secondaryText)}</button>` : ''
  ].filter(Boolean).join('');
  node.innerHTML = `
    <div class="ai-action-status-content">
      ${title ? `<strong>${escapeHtml(title)}</strong>` : ''}
      ${message ? `<span>${escapeHtml(message)}</span>` : ''}
      ${actions ? `<div class="ai-action-status-actions">${actions}</div>` : ''}
    </div>
  `;
  const primary = node.querySelector('[data-ai-action="primary"]');
  const secondary = node.querySelector('[data-ai-action="secondary"]');
  if (primary && typeof onPrimary === 'function') primary.onclick = onPrimary;
  if (secondary && typeof onSecondary === 'function') secondary.onclick = onSecondary;
}

const TOAST_TONES = new Set(['success', 'info', 'warning', 'error']);
let toastRoot = null;
let toastTimer = null;

function getToastRoot() {
  if (typeof document === 'undefined') return null;
  if (toastRoot && toastRoot.isConnected) return toastRoot;
  toastRoot = document.querySelector('.km-toast-root');
  if (!toastRoot) {
    toastRoot = document.createElement('div');
    toastRoot.className = 'km-toast-root';
    toastRoot.setAttribute('aria-live', 'polite');
    toastRoot.setAttribute('aria-atomic', 'true');
    document.body.appendChild(toastRoot);
  }
  return toastRoot;
}

export function showToast(message, options = {}) {
  const text = String(message || '').trim();
  if (!text || typeof document === 'undefined') return null;

  const {
    tone = 'info',
    duration = 2200,
    actionText = '',
    onAction = null
  } = options || {};
  const safeTone = TOAST_TONES.has(tone) ? tone : 'info';
  const root = getToastRoot();
  if (!root) return null;

  if (toastTimer) {
    clearTimeout(toastTimer);
    toastTimer = null;
  }
  root.innerHTML = '';

  const toast = document.createElement('div');
  toast.className = `km-toast is-${safeTone}`;
  toast.setAttribute('role', safeTone === 'error' ? 'alert' : 'status');

  const messageEl = document.createElement('span');
  messageEl.className = 'km-toast-message';
  messageEl.textContent = text;
  toast.appendChild(messageEl);

  if (actionText && typeof onAction === 'function') {
    const actionBtn = document.createElement('button');
    actionBtn.type = 'button';
    actionBtn.className = 'km-toast-action';
    actionBtn.textContent = actionText;
    actionBtn.onclick = () => {
      onAction();
      dismissToast(toast, root);
    };
    toast.appendChild(actionBtn);
  }

  const closeBtn = document.createElement('button');
  closeBtn.type = 'button';
  closeBtn.className = 'km-toast-close';
  closeBtn.setAttribute('aria-label', '关闭提示');
  closeBtn.textContent = '×';
  closeBtn.onclick = () => dismissToast(toast, root);
  toast.appendChild(closeBtn);

  root.appendChild(toast);
  const runSoon = typeof requestAnimationFrame === 'function'
    ? requestAnimationFrame
    : (callback) => setTimeout(callback, 0);
  runSoon(() => toast.classList.add('is-visible'));

  if (Number.isFinite(duration) && duration >= 0) {
    toastTimer = setTimeout(() => dismissToast(toast, root), duration);
  }

  return { root, toast, close: () => dismissToast(toast, root) };
}

function dismissToast(toast, root) {
  if (!toast || !root || !toast.parentNode) return;
  if (toastTimer) {
    clearTimeout(toastTimer);
    toastTimer = null;
  }
  toast.classList.remove('is-visible');
  toast.classList.add('is-hiding');
  setTimeout(() => {
    if (toast.parentNode) toast.remove();
    if (root.children.length === 0) {
      root.remove();
      if (toastRoot === root) toastRoot = null;
    }
  }, 160);
}

export function setSelectValueWithOption(select, value) {
  const v = String(value || '').trim();
  if (!v || !select) return;
  if (!Array.from(select.options).some(option => option.value === v)) {
    select.appendChild(new Option(v, v));
  }
  select.value = v;
}

export function normalizeDifficulty(value) {
  return ['简单', '中等', '复杂'].includes(value) ? value : '';
}

export function getRecipeStatusInfo(recipe, id, baseRecipe = null, overlayRecipe = null) {
  const tags = recipe?.tags || [];
  if (recipe?.isAiDraft || tags.includes('AI草稿')) return { label: 'AI 草稿', className: 'draft' };
  if (!baseRecipe) return { label: '自定义菜谱', className: 'custom' };
  if (overlayRecipe && Object.keys(overlayRecipe).length) return { label: '系统菜谱修改版', className: 'modified' };
  return { label: '系统菜谱', className: 'system' };
}
