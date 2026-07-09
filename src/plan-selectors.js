/*
 * src/plan-selectors.js —— 计划（plan）读取口径的唯一事实源（S5 语义收敛）。
 *
 * 背景：随着「一周买一次菜」方向演进，plan 行带 date、可跨多天；但「哪些菜算
 * 今天要做的」这个判断曾以 `(row.date || today) === today && !row.isCooked`
 * 的形态散落在 9 个文件 17 处，口径漂移已真实发生过（getTodayPlanCount 曾
 * 独家不排除 isCooked）。此后一律从这里取口径：
 *   - 无 date 的旧数据按今天算（历史兼容，唯一定义处）；
 *   - 「待做」= 属于该日期 且 未标记 isCooked。
 * 写入/变更计划仍由各业务模块负责，这里只做读取与判定。
 */
import { S, todayISO } from './storage.js?v=235';

// row 是否归属某个日期（默认今天）。无 date 的旧数据视为今天。
export function isPlanRowOnDate(row, date = todayISO(), today = todayISO()) {
  return !!row && (row.date || today) === date;
}

// row 是否为该日期的「待做」项（未记录消耗）。
export function isPendingPlanRow(row, date = todayISO(), today = todayISO()) {
  return isPlanRowOnDate(row, date, today) && !row.isCooked;
}

export function loadPlanRows() {
  return S.load(S.keys.plan, []);
}

// 今天的全部计划行（含已做完，用于展示成就/历史）。
export function getTodayPlanRows(today = todayISO()) {
  return loadPlanRows().filter(row => isPlanRowOnDate(row, today, today));
}

// 今天的待做计划行（首页计数、备份提醒、记录消耗列表等统一用它）。
export function getTodayPendingPlanRows(today = todayISO()) {
  return loadPlanRows().filter(row => isPendingPlanRow(row, today, today));
}

export function getTodayPendingPlanCount(today = todayISO()) {
  return getTodayPendingPlanRows(today).length;
}

// 日期区间内的待做计划行（周菜单视图用；start/end 均为含端点的 ISO 日期）。
export function getPendingPlanRowsInRange(startIso, endIso, today = todayISO()) {
  return loadPlanRows().filter(row => {
    if (!row || row.isCooked) return false;
    const date = row.date || today;
    return date >= startIso && date <= endIso;
  });
}
