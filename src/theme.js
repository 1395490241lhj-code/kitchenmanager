/*
 * src/theme.js —— 外观主题（浅色 / 深色 / 跟随系统）
 *
 * 设计：
 *  - 始终在 <html> 写入具体的 data-theme（light/dark）：'system' 会被解析为当前系统配色，
 *    并监听系统切换实时更新。这样 styles.css 里 html[data-theme="dark"] 的深色组件样式
 *    （玻璃弹窗、卡片、分段控件、空状态文字等）对「系统深色」和「手动深色」都生效，
 *    彻底避免「手动选深色但组件没变暗 / 对比度灾难」的问题。
 *  - html[data-theme="..."] 覆盖核心 CSS 变量（背景、文字、卡片、输入框、状态色等）。
 *  - 偏好保存在 settings.theme（localStorage），随「整个厨房」备份一起迁移。
 */
import { S } from './storage.js?v=198';

const VALID = new Set(['light', 'dark']);

function systemPrefersDark() {
  return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
}

export function getSavedTheme() {
  const s = S.load(S.keys.settings, {});
  return VALID.has(s.theme) ? s.theme : 'system';
}

// 关键：把 'system' 解析成具体的 light / dark，并始终在 <html> 写入 data-theme。
// 这样所有深色样式都统一由 html[data-theme="dark"] 驱动，无论系统设置还是手动选择
// 都能生效，彻底消除「手动深色但组件样式没跟上」的对比度灾难。
export function applyTheme(theme) {
  const t = VALID.has(theme) ? theme : 'system';
  const effective = t === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : t;
  document.documentElement.setAttribute('data-theme', effective);
}

export function saveTheme(theme) {
  const t = VALID.has(theme) ? theme : 'system';
  const current = S.load(S.keys.settings, {});
  S.save(S.keys.settings, { ...current, theme: t });
  applyTheme(t);
  return t;
}

// 启动时尽早调用，避免首屏闪烁；并在「跟随系统」时监听系统主题变化即时更新。
export function initTheme() {
  applyTheme(getSavedTheme());
  if (window.matchMedia) {
    const mql = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => { if (getSavedTheme() === 'system') applyTheme('system'); };
    if (mql.addEventListener) mql.addEventListener('change', onChange);
    else if (mql.addListener) mql.addListener(onChange);
  }
}
