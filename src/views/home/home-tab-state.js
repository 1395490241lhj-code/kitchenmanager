/*
 * src/views/home/home-tab-state.js —— 首页主面板 tab 的页内记忆（仅内存，不持久化）。
 * 抽成独立模块：home-view 与 demo-kitchen 共享同一份 tab 状态，避免循环依赖。
 * 注意：import 时的 ?v= 版本参数必须与其他引用方一致，否则会产生两份模块实例。
 */
import { S, todayISO } from '../../storage.js?v=222';

let lastWxTab = null;

export function getHomeTab() {
  return lastWxTab;
}

export function setHomeTab(tab) {
  lastWxTab = tab;
}

// 今日计划项数（只读 plan key，按 date===今天计数，不改任何计划逻辑）。
export function getTodayPlanCount() {
  const today = todayISO();
  return S.load(S.keys.plan, []).filter(p => p && p.date === today).length;
}
