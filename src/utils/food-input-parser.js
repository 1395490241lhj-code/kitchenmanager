/*
 * src/utils/food-input-parser.js —— 「每行一个食材」轻量文本解析（纯函数，无 DOM/存储）。
 *
 * 共享给首页「记食材」弹窗（home-view）与食材页「随手记几样食材」轻量录入区（inventory-view）。
 * 支持：「西红柿 3 个」「西红柿 3个」「西红柿3个」「鸡蛋 6」「土豆」；空行忽略。
 * 只负责拆 name / qty / unit，不做规范名、单位推断、写库——
 * 由调用方走现有 getCanonicalName / guessKitchenUnit / mergeInventoryEntry。
 */

/**
 * @param {string|null|undefined} text - 多行输入，每行一个食材
 * @returns {{name: string, qty: number, unit: string}[]}
 */
export function parseFoodLines(text) {
  const lines = String(text || '').split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  const out = [];
  for (const line of lines) {
    let m = line.match(/^(.+?)\s+(\d+(?:\.\d+)?)\s*(\S+)?$/);                      // 「西红柿 3 个」/ 「鸡蛋 6」
    if (!m) m = line.match(/^([^\d\s]+?)(\d+(?:\.\d+)?)\s*(\S+)?$/);                // 「西红柿3个」（无空格）
    if (m) {
      out.push({ name: m[1].trim(), qty: Number(m[2]) || 1, unit: (m[3] || '').trim() });
    } else {
      out.push({ name: line, qty: 1, unit: '' });
    }
  }
  return out;
}
