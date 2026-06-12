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
const CHINESE_NUMBER_DIGITS = {
  一: 1,
  二: 2,
  两: 2,
  三: 3,
  四: 4,
  五: 5,
  六: 6,
  七: 7,
  八: 8,
  九: 9
};

const CHINESE_QUANTITY_UNITS = [
  '个', '颗', '只', '根', '块', '片', '份', '把', '袋', '包',
  '瓶', '盒', '罐', '条', '张', '斤', '两', 'g', 'kg', 'ml', 'L'
];

const CHINESE_QUANTITY_RE = new RegExp(
  `^(.+?)\\s*([一二两三四五六七八九十半]+)\\s*(${CHINESE_QUANTITY_UNITS.join('|')})$`
);

export function parseChineseNumber(text) {
  const raw = String(text || '').trim();
  if (!raw) return NaN;
  if (raw === '半') return 0.5;
  if (raw.includes('半')) return NaN;
  if (!/^[一二两三四五六七八九十]+$/.test(raw)) return NaN;
  if (!raw.includes('十')) return CHINESE_NUMBER_DIGITS[raw] || NaN;

  if (raw.indexOf('十') !== raw.lastIndexOf('十')) return NaN;
  const [left = '', right = ''] = raw.split('十');
  const tens = left ? CHINESE_NUMBER_DIGITS[left] : 1;
  const ones = right ? CHINESE_NUMBER_DIGITS[right] : 0;
  if (!Number.isFinite(tens) || !Number.isFinite(ones)) return NaN;
  const value = tens * 10 + ones;
  return value >= 1 && value <= 99 ? value : NaN;
}

function parseChineseQuantityLine(line) {
  const m = line.match(CHINESE_QUANTITY_RE);
  if (!m) return null;
  const name = m[1].trim();
  const qty = parseChineseNumber(m[2]);
  const unit = (m[3] || '').trim();
  if (!name || !Number.isFinite(qty) || qty <= 0 || !unit) return null;
  return { name, qty, unit };
}

export function parseFoodLines(text) {
  const lines = String(text || '').split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  const out = [];
  for (const line of lines) {
    let m = line.match(/^(.+?)\s+(\d+(?:\.\d+)?)\s*(\S+)?$/);                      // 「西红柿 3 个」/ 「鸡蛋 6」
    if (!m) m = line.match(/^([^\d\s]+?)(\d+(?:\.\d+)?)\s*(\S+)?$/);                // 「西红柿3个」（无空格）
    if (m) {
      out.push({ name: m[1].trim(), qty: Number(m[2]) || 1, unit: (m[3] || '').trim() });
    } else {
      out.push(parseChineseQuantityLine(line) || { name: line, qty: 1, unit: '' });
    }
  }
  return out;
}
