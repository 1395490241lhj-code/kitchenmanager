import { S } from './storage.js?v=235';

export const PWA_INSTALL_DISMISS_DAYS = 7;

const DAY_MS = 24 * 60 * 60 * 1000;

let deferredInstallPrompt = null;
const listeners = new Set();

function safeLocalStorageGet(key) {
  try { return localStorage.getItem(key); } catch (e) { return null; }
}

function safeLocalStorageSet(key, value) {
  try {
    localStorage.setItem(key, String(value));
    return true;
  } catch (e) {
    return false;
  }
}

function readTimestamp(key) {
  const raw = safeLocalStorageGet(key);
  if (!raw) return 0;
  const numeric = Number(raw);
  if (Number.isFinite(numeric) && numeric > 0) return numeric;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function wasWithinDays(key, now = Date.now(), days = 0) {
  const timestamp = readTimestamp(key);
  if (!timestamp) return false;
  const age = Number(now) - timestamp;
  return age >= 0 && age < days * DAY_MS;
}

function notifyInstallListeners() {
  listeners.forEach(listener => {
    try { listener(); } catch (e) { /* keep install state updates best-effort */ }
  });
}

function isTruthyStandalone(value) {
  return value === true || value === 'true' || value === '1';
}

export function isPwaInstallDismissedRecently(now = Date.now()) {
  return wasWithinDays(S.keys.pwa_install_dismissed_at, now, PWA_INSTALL_DISMISS_DAYS);
}

export function dismissPwaInstallPrompt(now = Date.now()) {
  const ok = safeLocalStorageSet(S.keys.pwa_install_dismissed_at, now);
  notifyInstallListeners();
  return ok;
}

export function markPwaInstallDone() {
  if (isPwaInstallDone()) return true;
  const ok = safeLocalStorageSet(S.keys.pwa_install_done, '1');
  notifyInstallListeners();
  return ok;
}

export function isPwaInstallDone() {
  return safeLocalStorageGet(S.keys.pwa_install_done) === '1';
}

export function getPwaInstallEnvironment(input = {}) {
  const nav = input.navigator || (typeof navigator !== 'undefined' ? navigator : {});
  const win = input.window || (typeof window !== 'undefined' ? window : {});
  const userAgent = String(input.userAgent ?? nav.userAgent ?? '').toLowerCase();
  const platform = String(input.platform ?? nav.platform ?? '').toLowerCase();
  const maxTouchPoints = Number(input.maxTouchPoints ?? nav.maxTouchPoints ?? 0);
  const viewportWidth = Number(input.viewportWidth ?? win.innerWidth ?? 1024);
  const standalone = input.standalone ?? (
    (typeof win.matchMedia === 'function' && win.matchMedia('(display-mode: standalone)').matches)
    || isTruthyStandalone(nav.standalone)
  );
  const isIOS = /iphone|ipad|ipod/.test(userAgent)
    || (platform === 'macintel' && maxTouchPoints > 1);
  const isAndroid = /android/.test(userAgent);
  const isIOSBrowserShell = /(crios|fxios|edgios|opios|duckduckgo)/.test(userAgent);
  const isIOSSafari = isIOS && /safari/.test(userAgent) && !isIOSBrowserShell;
  const isAndroidChrome = isAndroid
    && /chrome|chromium/.test(userAgent)
    && !/(edg|opr|opera|samsungbrowser|firefox)/.test(userAgent);
  const isMobile = viewportWidth <= 768
    || /mobile|android|iphone|ipad|ipod/.test(userAgent)
    || (isIOS && maxTouchPoints > 1);

  return {
    isMobile,
    isStandalone: Boolean(standalone),
    isIOS,
    isIOSSafari,
    isAndroid,
    isAndroidChrome,
    hasDeferredPrompt: Boolean(input.hasDeferredPrompt ?? deferredInstallPrompt)
  };
}

function hasRealUsageIntent({ inventory = [], plan = [] } = {}) {
  const hasInventory = (inventory || []).some(item => {
    if (!item || !String(item.name || '').trim()) return false;
    const qty = Number(item.qty ?? 1);
    return !Number.isFinite(qty) || qty > 0;
  });
  const hasPlan = (plan || []).some(item => item && item.id && !item.isCooked);
  return hasInventory || hasPlan;
}

export function shouldShowPwaInstallPrompt({
  inventory = [],
  plan = [],
  isDemoMode = false,
  environment = getPwaInstallEnvironment(),
  now = Date.now()
} = {}) {
  if (isDemoMode) return false;
  if (!environment.isMobile) return false;
  if (environment.isStandalone) return false;
  if (isPwaInstallDone()) return false;
  if (isPwaInstallDismissedRecently(now)) return false;
  if (!hasRealUsageIntent({ inventory, plan })) return false;
  if (environment.isIOSSafari) return true;
  if (environment.isAndroidChrome && environment.hasDeferredPrompt) return true;
  return false;
}

export function getPwaInstallPromptState(options = {}) {
  const environment = options.environment || getPwaInstallEnvironment();
  if (environment.isStandalone) {
    markPwaInstallDone();
    return { show: false, reason: 'standalone', environment };
  }
  const show = shouldShowPwaInstallPrompt({ ...options, environment });
  if (!show) return { show: false, environment };

  if (environment.isIOSSafari) {
    return {
      show: true,
      platform: 'ios',
      canPrompt: false,
      title: '可以把 Kitchen Manager 添加到主屏幕，像 App 一样打开。',
      body: '在 Safari 底部点“分享”，再选择“添加到主屏幕”。',
      primaryLabel: '我知道了',
      secondaryLabel: '稍后提醒',
      environment
    };
  }

  return {
    show: true,
    platform: 'android',
    canPrompt: true,
    title: '把 Kitchen Manager 安装到手机桌面。',
    body: '打开更快，也更像 App，库存和计划仍保存在本机浏览器。',
    primaryLabel: '安装',
    secondaryLabel: '稍后',
    environment
  };
}

export async function promptPwaInstall() {
  const promptEvent = deferredInstallPrompt;
  if (!promptEvent || typeof promptEvent.prompt !== 'function') {
    dismissPwaInstallPrompt();
    return { outcome: 'unavailable' };
  }
  try {
    await promptEvent.prompt();
    const choice = await (promptEvent.userChoice || Promise.resolve({ outcome: 'dismissed' }));
    deferredInstallPrompt = null;
    if (choice && choice.outcome === 'accepted') markPwaInstallDone();
    else dismissPwaInstallPrompt();
    notifyInstallListeners();
    return choice || { outcome: 'dismissed' };
  } catch (e) {
    deferredInstallPrompt = null;
    dismissPwaInstallPrompt();
    return { outcome: 'failed' };
  }
}

export function initPwaInstallPrompt({ onChange = () => {} } = {}) {
  if (typeof window === 'undefined') return () => {};
  listeners.add(onChange);
  if (getPwaInstallEnvironment().isStandalone) markPwaInstallDone();

  const handleBeforeInstallPrompt = event => {
    if (event && typeof event.preventDefault === 'function') event.preventDefault();
    deferredInstallPrompt = event;
    notifyInstallListeners();
  };
  const handleAppInstalled = () => {
    deferredInstallPrompt = null;
    markPwaInstallDone();
    notifyInstallListeners();
  };

  window.addEventListener('beforeinstallprompt', handleBeforeInstallPrompt);
  window.addEventListener('appinstalled', handleAppInstalled);

  return () => {
    listeners.delete(onChange);
    window.removeEventListener('beforeinstallprompt', handleBeforeInstallPrompt);
    window.removeEventListener('appinstalled', handleAppInstalled);
  };
}
