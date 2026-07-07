/*
 * src/views/home/home-nudges.js —— 首页轻提醒（从 home-view 抽出）：
 * 备份导出提醒 + PWA 安装提示。展示条件分别由 backup.js / pwa-install.js 决定。
 */
import { S, todayISO } from '../../storage.js?v=234';
import { loadShoppingItems } from '../../shopping.js?v=234';
import { escapeHtml, showToast } from '../../components/status.js?v=234';
import { buildKitchenBackup, downloadJsonFile, loadOverlay, markBackupNudgeDismissed, markKitchenBackupExported, shouldShowBackupNudge } from '../../backup.js?v=234';
import { dismissPwaInstallPrompt, getPwaInstallPromptState, promptPwaInstall } from '../../pwa-install.js?v=234';
import { getTodayPendingPlanRows } from '../../plan-selectors.js?v=234';

const KITCHEN_BACKUP_EXPORT_MESSAGE = '已导出厨房备份。请把文件保存到 iCloud、网盘或电脑里。';

function getTodayPlanRowsForBackupNudge() {
  return getTodayPendingPlanRows();
}

export function renderBackupNudge(inv, { isDemoMode = false } = {}) {
  const shouldShow = shouldShowBackupNudge({
    inventory: inv,
    plan: getTodayPlanRowsForBackupNudge(),
    shoppingItems: loadShoppingItems(),
    overlay: loadOverlay(),
    isDemoMode
  });
  if (!shouldShow) return null;

  const section = document.createElement('section');
  section.className = 'home-backup-nudge';
  section.innerHTML = `
    <div class="home-backup-nudge-copy">
      <strong>已经有厨房数据了，建议导出一份备份。</strong>
      <span>换设备或清缓存前，可以用它恢复。</span>
    </div>
    <div class="home-backup-nudge-actions">
      <button type="button" class="btn ok" id="homeBackupExport">导出备份</button>
      <button type="button" class="btn" id="homeBackupLater">稍后提醒</button>
    </div>
  `;
  section.querySelector('#homeBackupExport').onclick = () => {
    downloadJsonFile(buildKitchenBackup(), `kitchenmanager-backup-${todayISO()}.json`);
    markKitchenBackupExported();
    section.remove();
    showToast(KITCHEN_BACKUP_EXPORT_MESSAGE, { tone: 'success' });
  };
  section.querySelector('#homeBackupLater').onclick = () => {
    markBackupNudgeDismissed();
    section.remove();
    showToast('好的，7 天内不再提醒。', { tone: 'info' });
  };
  return section;
}

export function renderPwaInstallNudge(inv, { isDemoMode = false } = {}) {
  const state = getPwaInstallPromptState({
    inventory: inv,
    plan: getTodayPlanRowsForBackupNudge(),
    isDemoMode
  });
  if (!state.show) return null;

  const section = document.createElement('section');
  section.className = `home-pwa-install-nudge is-${state.platform}`;
  const icon = state.platform === 'ios' ? '↗' : '⬇';
  section.innerHTML = `
    <div class="home-pwa-install-icon" aria-hidden="true">${icon}</div>
    <div class="home-pwa-install-copy">
      <strong>${escapeHtml(state.title)}</strong>
      <span>${escapeHtml(state.body)}</span>
    </div>
    <div class="home-pwa-install-actions">
      <button type="button" class="btn ok" id="homePwaInstallPrimary">${escapeHtml(state.primaryLabel)}</button>
      <button type="button" class="btn" id="homePwaInstallLater">${escapeHtml(state.secondaryLabel)}</button>
    </div>
  `;
  const primary = section.querySelector('#homePwaInstallPrimary');
  const later = section.querySelector('#homePwaInstallLater');
  const closeWithDismissal = (message = '稍后再提醒你。') => {
    dismissPwaInstallPrompt();
    section.remove();
    showToast(message, { tone: 'info' });
  };

  if (state.canPrompt) {
    primary.onclick = async () => {
      primary.disabled = true;
      primary.textContent = '正在打开…';
      const choice = await promptPwaInstall();
      section.remove();
      if (choice && choice.outcome === 'accepted') {
        showToast('已开始安装', { tone: 'success' });
      } else {
        showToast('稍后再提醒你。', { tone: 'info' });
      }
    };
  } else {
    primary.onclick = () => closeWithDismissal('可以随时从 Safari 分享菜单添加。');
  }
  later.onclick = () => closeWithDismissal('好的，7 天内不再提醒。');
  return section;
}
