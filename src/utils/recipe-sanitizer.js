/*
 * src/utils/recipe-sanitizer.js —— 菜谱用料统一分类口径（Recipe Ingredient Classifier）
 *
 * 把菜谱用料分成三类（role）：
 *   core      —— 核心食材：进入库存匹配、推荐可做性、缺货、买菜、做完扣减、明天备菜。
 *   seasoning —— 调料 / 常备小料：详情页「调料清单」展示，不参与主库存扣减 / 缺货 / 买菜。
 *   non-stock —— 非库存烹饪介质或无效项（水/高汤/汤汁/适量…）：不参与任何库存逻辑。
 *
 * 判定优先级（防误杀优先）：
 *   ① 核心食材保护（豆腐/腐竹/木耳/香菇/海带/酸菜/泡菜/汤圆…，含「水发X」归一）
 *   ② 无效量词（适量/少许/若干…，完全匹配）
 *   ③ 水 / 汤 / 汁等烹饪介质（复用 ingredients.isNonStockCookingTerm，单一口径）
 *   ④ 淀粉 / 勾芡类 → seasoning
 *   ⑤ 调料（扩展写法正则 + 兜底 ingredients.isSeasoning）
 *   ⑥ 其余默认 core
 *
 * 菜谱侧逻辑应优先使用本模块（classifyRecipeIngredient / splitRecipeIngredients），
 * 而不是直接调用 ingredients.isSeasoning。
 */
import { isSeasoning, isNonStockCookingTerm } from '../ingredients.js?v=219';

// ① 核心食材保护：这些词命中时强制 core（即便兜底口径误判为调料）。
//    含豆制品、需泡发干货、川菜核心腌渍菜、以及带「汤」字的真实食物名。
// 注：豆腐(?!乳) —— 「豆腐乳/豆腐乳水」是调味腐乳，不能因含「豆腐」被保护成核心食材。
const CORE_PROTECT_REGEX = /(豆腐(?!乳)|豆干|豆皮|千张|腐竹|支竹|木耳|香菇|海带|银耳|黄花菜|酸菜|泡菜|榨菜|盐菜|盐白菜|梅干菜|汤圆|汤面|汤粉|米粉|河粉|凉粉)/;

// 「水发X」归一：水发木耳 → 按「木耳」分类（仍是核心食材）。
const SOAKED_PREFIX_REGEX = /^水发/;

// ② 无效量词（完全匹配；不是物品）。
const QUANTITY_WORDS = new Set(['适量', '少许', '若干', '些许', '适当', '备用', '按需', '适口', '少量', '适量即可']);

// ④ 淀粉 / 勾芡类：可出现在调料清单，但绝不进入 foods / 库存。
const STARCH_REGEX = /^(淀粉|生粉|豆粉|水豆粉|湿淀粉|水淀粉|芡汁|勾芡汁|玉米淀粉|土豆淀粉|红薯淀粉)$/;

// ⑤ 调料扩展写法（ingredients.SEASONINGS 之外的常见变体）。
const SEASONING_EXTRA_REGEX = /^(白胡椒|白胡椒粉|姜片|姜丝|姜末|姜米|蒜末|蒜片|蒜瓣|蒜苗|葱段|葱末|小葱|香葱|食用油|植物油|花生油|色拉油|菜籽油|橄榄油|调和油|郫县豆瓣|郫县豆瓣酱|红油|辣椒油|花椒油|藤椒油|白酒|黄酒|啤酒|绍酒|绍兴酒|甜酒|曲酒|蜂蜜|芝麻|白芝麻|熟芝麻|花椒粒|辣椒粉|干花椒|香料|卤料|椒盐|醪糟|醪糟汁|腐乳|豆腐乳|豆腐乳水|豆瓣乳水|化猪油)$/;

// 历史精准正则：词条已并入 ingredients.SEASONINGS 与上方规则，仅保留作参考，不再是判定路径。
export const SEASONING_REGEX = /^(盐|糖|白糖|冰糖|红糖|酱油|生抽|老抽|料酒|醋|香醋|陈醋|白醋|蚝油|鸡精|味精|胡椒粉|黑胡椒|十三香|五香粉|孜然|孜然粉|咖喱|辣椒面|淀粉|生粉|植物油|花生油|色拉油|菜籽油|橄榄油|香油|芝麻油|猪油|水|清水|高汤|开水)$/;

// 从「字符串 / {item} / {name}」里取出食材名。
function nameOf(x) {
  if (typeof x === 'string') return x.trim();
  return String((x && (x.item || x.name)) || '').trim();
}

/**
 * 统一分类入口。
 * @param {string} rawName 菜谱用料名
 * @returns {{name: string, role: 'core'|'seasoning'|'non-stock', reason: string}}
 */
export function classifyRecipeIngredient(rawName) {
  const name = String(rawName || '').trim();
  if (!name) return { name, role: 'non-stock', reason: 'empty' };
  // 「水发木耳」按「木耳」分类；剥空了则用原名。
  const base = name.replace(SOAKED_PREFIX_REGEX, '') || name;
  if (CORE_PROTECT_REGEX.test(base)) return { name, role: 'core', reason: 'core-protect' };
  if (QUANTITY_WORDS.has(base)) return { name, role: 'non-stock', reason: 'quantity-word' };
  if (isNonStockCookingTerm(base)) return { name, role: 'non-stock', reason: 'cooking-medium' };
  if (STARCH_REGEX.test(base)) return { name, role: 'seasoning', reason: 'starch' };
  if (SEASONING_EXTRA_REGEX.test(base) || isSeasoning(base)) return { name, role: 'seasoning', reason: 'seasoning' };
  return { name, role: 'core', reason: 'default-core' };
}

// 是否「非核心食材」（调料或非库存项）：库存扣减 / 备菜提醒等用它做排除过滤。
// 空名按非核心处理（兜底过滤）。
export function isSeasoningName(name) {
  return classifyRecipeIngredient(name).role !== 'core';
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
 * 三分流：foods（core）/ seasonings（seasoning）/ nonStock（non-stock）。
 * 每项保留原对象字段并追加 role。
 */
export function splitRecipeIngredients(list) {
  const foods = [];
  const seasonings = [];
  const nonStock = [];
  for (const x of (list || [])) {
    const { role } = classifyRecipeIngredient(nameOf(x));
    const tagged = typeof x === 'string'
      ? { item: x, role, isSeasoning: role !== 'core' }
      : { ...x, role, isSeasoning: role !== 'core' };
    if (role === 'core') foods.push(tagged);
    else if (role === 'seasoning') seasonings.push(tagged);
    else nonStock.push(tagged);
  }
  return { foods, seasonings, nonStock };
}

/**
 * 兼容两分流（旧 UI）：foods = core；seasonings = seasoning + non-stock 合并。
 */
export function splitIngredients(list) {
  const { foods, seasonings, nonStock } = splitRecipeIngredients(list);
  return { foods, seasonings: [...seasonings, ...nonStock] };
}
