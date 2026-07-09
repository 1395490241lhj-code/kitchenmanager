/*
 * src/views/home/home-tab-state.js —— 首页主面板 tab 的页内记忆（仅内存，不持久化）。
 * 抽成独立模块：home-view 与 demo-kitchen 共享同一份 tab 状态，避免循环依赖。
 * 注意：import 时的 ?v= 版本参数必须与其他引用方一致，否则会产生两份模块实例。
 */
import { getTodayPendingPlanCount } from '../../plan-selectors.js?v=235';

let lastWxTab = null;

export function getHomeTab() {
  return lastWxTab;
}

export function setHomeTab(tab) {
  lastWxTab = tab;
}

// 今日待完成计划项数：口径统一走 plan-selectors（S5 语义收敛）。
export function getTodayPlanCount() {
  return getTodayPendingPlanCount();
}
