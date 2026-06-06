/*
 * src/utils/recipe-sanitizer.js —— 食材 / 调料结构化分流（Seasoning Classifier）
 *
 * 统一判定「常备调料 / 非追踪物资」与「核心生鲜食材」，用于：
 *   - 菜谱 / 计划详情 UI 的「食材清单 vs 调料清单」双列表分流展示；
 *   - 做菜扣减时把调料彻底排除（调料绝不参与冰箱主库扣减与对账）。
 *
 * 判定优先级：精准正则（油盐酱醋糖 / 水高汤 / 淀粉等常备调味与非追踪物资）
 *            → 兜底复用 ingredients.js 既有的 isSeasoning（含姜葱蒜等香辛料/常备物），更稳健。
 */
import { isSeasoning } from '../ingredients.js?v=210';

// 精准判定常备调料与非追踪物资（盐糖油酱醋 / 水高汤 / 淀粉生粉 等）。
export const SEASONING_REGEX = /^(盐|糖|白糖|冰糖|红糖|酱油|生抽|老抽|料酒|醋|香醋|陈醋|白醋|蚝油|鸡精|味精|胡椒粉|黑胡椒|十三香|五香粉|孜然|孜然粉|咖喱|辣椒面|淀粉|生粉|植物油|花生油|色拉油|菜籽油|橄榄油|香油|芝麻油|猪油|水|清水|高汤|开水)$/;

// 从「字符串 / {item} / {name}」里取出食材名。
function nameOf(x) {
  if (typeof x === 'string') return x.trim();
  return String((x && (x.item || x.name)) || '').trim();
}

// 是否为调料 / 非追踪物资：正则命中 或 命中既有调味料集合。
export function isSeasoningName(name) {
  const n = String(name || '').trim();
  if (!n) return true;
  if (SEASONING_REGEX.test(n)) return true;
  return isSeasoning(n);
}

// 为单个食材对象动态追加布尔标记 isSeasoning（不可变，返回新对象）。
export function tagSeasoning(item) {
  if (typeof item === 'string') return { item, isSeasoning: isSeasoningName(item) };
  return { ...item, isSeasoning: isSeasoningName(nameOf(item)) };
}

// 批量打标。
export function tagSeasonings(list) {
  return (list || []).map(tagSeasoning);
}

/**
 * 把食材列表拆成两组：
 *   foods      —— isSeasoning === false 的核心生鲜食材
 *   seasonings —— isSeasoning === true 的辅助调味品 / 非追踪物资
 */
export function splitIngredients(list) {
  const tagged = tagSeasonings(list);
  return {
    foods: tagged.filter(x => !x.isSeasoning),
    seasonings: tagged.filter(x => x.isSeasoning)
  };
}
