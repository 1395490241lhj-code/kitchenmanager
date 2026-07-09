/*
 * src/views/home/home-modal.js —— 首页统一模态外壳（毛玻璃遮罩 + 圆角面板 + X 关闭 + 入场动画）。
 * 从 home-view 抽出为共享 helper：home-view 各弹窗与 weekly-menu 都从这里取，避免循环依赖。
 */
import { escapeHtml } from '../../components/status.js?v=235';

export function createHomeModal(contentEl, title = '') {
  // 统一模态外壳骨架（背景毛玻璃 + 圆角面板 + 右上角 X + 入场动画）。
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';

  const panel = document.createElement('div');
  panel.className = 'km-modal-content';
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-modal', 'true');

  // 标题行 + X 关闭按钮
  const header = document.createElement('div');
  header.className = 'km-modal-header';
  header.innerHTML = `
    <span class="km-modal-title">${escapeHtml(title)}</span>
    <button type="button" class="km-modal-close" aria-label="关闭">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
      </svg>
    </button>
  `;
  panel.appendChild(header);
  panel.appendChild(contentEl);
  overlay.appendChild(panel);

  let isClosing = false;
  const close = () => {
    if (isClosing) return;
    isClosing = true;
    panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
    panel.style.opacity = '0';
    panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
    overlay.classList.add('closing');
    setTimeout(() => overlay.remove(), 220);
  };

  header.querySelector('.km-modal-close').onclick = close;
  overlay.onclick = (e) => { if (e.target === overlay) close(); };

  document.body.appendChild(overlay);
  // 触发入场动画
  requestAnimationFrame(() => {
    overlay.classList.add('open');
    const focusTarget = panel.querySelector('input:not([type="hidden"]), textarea, select, button:not(.km-modal-close)') || header.querySelector('.km-modal-close');
    focusTarget?.focus?.({ preventScroll: true });
  });

  return { overlay, close };
}
