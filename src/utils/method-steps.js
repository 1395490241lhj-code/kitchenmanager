/*
 * src/utils/method-steps.js —— 把菜谱做法字符串解析成分步数组（纯函数，无 DOM/网络/localStorage）。
 *
 * 设计：
 *  - 输入 string/null/undefined → 输出 string[]；空值返回 []。
 *  - 主路径：按换行拆分；每行剥掉行首编号前缀（避免 UI 的 <ol> 再编号变「1. 1.」）。
 *  - 无换行单段：若含多个行内编号（如「1. a 2. b」）按编号边界拆；否则整段为 1 步。
 *  - 只剥「行首/编号边界」的真编号，不误切步骤内容里的数字（如「焖 3 分钟」）。
 *  - 不返回 HTML、不改原始 method（转义由渲染层负责）。
 */

// 行首步骤编号前缀：1. / 1、/ 1）/ 1) / （1）/ (1) / 第一步[:：] / 一、 等。
// 关键约束：数字/中文数字后必须紧跟「. 、 ． 。 ) ） : ：」之一，避免吃掉「3 分钟」这类内容。
const LEADING_MARKER = /^\s*(?:第[一二三四五六七八九十百零\d]+步[：:]?\s*|步骤[一二三四五六七八九十百零\d]+[：:]?\s*|[（(]\s*\d+\s*[)）]\s*|\d+\s*[.、．。)）：:]\s*|[一二三四五六七八九十]+\s*[、.．。)）：:]\s*)/;

// 单段内「行内编号」边界（用于无换行但含「1. … 2. …」的情况）：在「空白 + 数字/中文数字 + 边界标点」前断开。
const INLINE_MARKER = /(?=[\s，。；](?:\d+|[一二三四五六七八九十]+)\s*[.、．。)）：:]\s*)/g;

function stripLeadingMarker(line) {
  return String(line).replace(LEADING_MARKER, '').trim();
}

/**
 * @param {string|null|undefined} method
 * @returns {string[]} 分步文本（不含编号、不含 HTML）
 */
export function splitMethodSteps(method) {
  const s = String(method == null ? '' : method).trim();
  if (!s) return [];

  // 1) 按换行拆分（主路径）。
  let parts = s.split(/\r?\n/).map(x => x.trim()).filter(Boolean);

  // 2) 无换行单段：尝试按行内编号拆；拆不出多段则保持单段。
  if (parts.length <= 1) {
    const inline = s.split(INLINE_MARKER).map(x => x.trim()).filter(Boolean);
    parts = inline.length > 1 ? inline : [s];
  }

  // 3) 逐段剥行首编号前缀，去空段。
  return parts.map(stripLeadingMarker).filter(Boolean);
}
