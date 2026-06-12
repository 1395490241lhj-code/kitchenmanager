/*
 * src/utils/ingredient-intent.js —— 「想用这些食材」输入解析（纯函数，零 DOM/网络/存储）。
 *
 * 把用户随手输入（牛肉 土豆 / 番茄，鸡蛋 / 肉片、青椒 / 菌菇/豆腐）解析成
 * 规范化目标数组，并做三件聪明事：
 *   ① 通用类别展开：菌菇→香菇/蘑菇/平菇…，绿叶菜→青菜/菠菜…，肉片/肉丝→猪肉类…
 *   ② 库存辅助：输入「肉」时库存里有牛肉就优先牛肉，都有则保留多个候选
 *   ③ 调料/非库存过滤：盐、生抽、高汤、水、适量等绝不进入目标（role==='core' 才算）
 *
 * 返回形状：
 *   { raw, targets: [{ raw, canonical, candidates: string[], category: string|null }] }
 * candidates 含 canonical 本身 + 类别展开词，供 recommendations 做「任一命中即算」匹配。
 */
import { getCanonicalName } from '../ingredients.js?v=219';
import { classifyRecipeIngredient } from './recipe-sanitizer.js?v=219';

// 通用食材类别 → 具体候选（顺序即偏好顺序；库存辅助会把有货的提到前面）。
const CATEGORY_MAP = {
  '菌菇': ['香菇', '蘑菇', '平菇', '金针菇', '口蘑', '杏鲍菇'],
  '蘑菇': ['蘑菇', '香菇', '平菇', '金针菇', '口蘑', '杏鲍菇'],
  '绿叶菜': ['青菜', '小白菜', '菠菜', '油菜', '生菜'],
  '青菜': ['青菜', '小白菜', '油菜', '菠菜'],
  '辣椒': ['青椒', '红椒', '尖椒', '二荆条'],
  '豆制品': ['豆腐', '豆干', '豆皮', '腐竹'],
  '海鲜': ['鱼', '虾', '鱿鱼'],
  '蛋': ['鸡蛋', '鸭蛋'],
  '肉': ['猪肉', '牛肉', '鸡肉', '羊肉'],
  '肉片': ['猪肉', '肉片', '肉丝', '瘦肉'],
  '肉丝': ['猪肉', '肉丝', '肉片', '瘦肉'],
  '肉末': ['猪肉', '肉末', '瘦肉'],
  '瘦肉': ['猪肉', '瘦肉', '肉片', '肉丝']
};

// 类别词对应的 category 标签（输出用，方便上层显示/调试）。
const CATEGORY_LABEL = {
  '菌菇': 'mushroom', '蘑菇': 'mushroom',
  '绿叶菜': 'leafy', '青菜': 'leafy',
  '辣椒': 'pepper',
  '豆制品': 'tofu',
  '海鲜': 'seafood',
  '蛋': 'egg',
  '肉': 'meat', '肉片': 'meat', '肉丝': 'meat', '肉末': 'meat', '瘦肉': 'meat'
};

// 拆词：空格 / 中英文逗号 / 顿号 / 斜杠 / 分号。
function splitQuery(input) {
  return String(input || '')
    .split(/[\s,，、/;；]+/)
    .map(s => s.trim())
    .filter(Boolean);
}

/**
 * @param {string} input 用户输入
 * @param {{inventoryNames?: string[], limit?: number}} opts
 * @returns {{raw: string, targets: Array<{raw:string, canonical:string, candidates:string[], category:string|null}>}}
 */
export function parseTargetIngredients(input, { inventoryNames = [], limit = 5 } = {}) {
  const raw = String(input || '').trim();
  const stockSet = new Set((inventoryNames || []).map(n => getCanonicalName(String(n || '').trim())).filter(Boolean));
  const seen = new Set();
  const targets = [];

  for (const token of splitQuery(raw)) {
    const canonical = getCanonicalName(token);
    if (!canonical || seen.has(canonical)) continue;
    // 调料 / 非库存项（盐、生抽、高汤、水、适量…）不参与目标匹配。
    if (classifyRecipeIngredient(canonical).role !== 'core') continue;
    seen.add(canonical);

    // 类别展开：先查 canonical，再查原词（番茄→西红柿后类别词可能在原词上）。
    const expansion = CATEGORY_MAP[canonical] || CATEGORY_MAP[token] || null;
    let candidates = expansion ? [...new Set([canonical, ...expansion])] : [canonical];

    // 库存辅助：候选里有「库存现有」的，把它们排到最前（都有则都保留，匹配不受影响、
    // 仅影响展示顺序与「肉→牛肉」这类歧义的解释优先级）。
    if (candidates.length > 1 && stockSet.size) {
      const stocked = candidates.filter(c => stockSet.has(c));
      if (stocked.length) candidates = [...stocked, ...candidates.filter(c => !stockSet.has(c))];
    }

    targets.push({
      raw: token,
      canonical,
      candidates,
      category: CATEGORY_LABEL[canonical] || CATEGORY_LABEL[token] || null
    });
    if (targets.length >= limit) break;
  }

  return { raw, targets };
}
