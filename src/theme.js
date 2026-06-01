/*
 * src/theme.js —— 外观主题（浅色 / 深色 / 跟随系统）
 *
 * 设计：
 *  - 默认 'system'：不写 data-theme 属性，完全沿用 @media (prefers-color-scheme) 的系统主题，
 *    行为与历史版本 100% 一致。
 *  - 'light' / 'dark'：在 <html> 上写 data-theme 属性，由 styles.css 中
 *    html[data-theme="..."] 规则覆盖核心 CSS 变量（背景、文字、卡片、输入框、状态色等），
 *    实现脱离系统设置的手动主题。
 *  - 偏好保存在 settings.theme（localStorage），随「整个厨房」备份一起迁移。
 */
import { S } from './storage.js?v=197';

const VALID = new Set(['light', 'dark']);

export function getSavedTheme() {
  const s = S.load(S.keys.settings, {});
  return VALID.has(s.theme) ? s.theme : 'system';
}

export function applyTheme(theme) {
  const t = VALID.has(theme) ? theme : 'system';
  const root = document.documentElement;
  if (t === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', t);
}

export function saveTheme(theme) {
  const t = VALID.has(theme) ? theme : 'system';
  const current = S.load(S.keys.settings, {});
  S.save(S.keys.settings, { ...current, theme: t });
  applyTheme(t);
  return t;
}

// 启动时尽早调用，避免首屏闪烁。
export function initTheme() {
  applyTheme(getSavedTheme());
}
