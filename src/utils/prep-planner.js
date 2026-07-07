/*
 * src/utils/prep-planner.js —— 「明天备菜」任务生成（纯本地规则，零 AI / 零 DOM / 零写库）。
 *
 * 根据明天计划的菜谱 + 当前库存，生成三类提前准备任务：
 *   thaw     🧊 冷冻肉类/水产 → 提前从冷冻拿到冷藏
 *   soak     💧 需泡发的干货 → 提前泡发
 *   marinate 🧂 做法里明确出现「腌」的肉类 → 提前腌制
 *
 * 去噪约束：调料不生成任务；普通蔬菜不生成任务；同一 kind+食材全局只提醒一次；
 * 同一道菜最多 3 个任务；没有 method 的菜谱绝不猜腌制。
 * 完成状态由调用方用稳定 id 记录（S.keys.prep_done），任务本体每次动态生成。
 */
import { getMatchingInventoryItems } from '../inventory.js?v=234';
import { isSeasoningName } from './recipe-sanitizer.js?v=234';

// 肉类 / 水产（解冻候选）
const MEAT_REGEX = /(猪肉|牛肉|羊肉|鸡肉|鸡翅|鸡腿|排骨|肉丝|肉片|五花肉|里脊|鱼|虾|海鲜)/;
// 需要泡发的干货
const SOAK_REGEX = /(木耳|香菇|干香菇|腐竹|银耳|海带|黄豆|红豆|绿豆|干贝|粉丝|笋干)/;
// 腌制候选（做法里出现「腌」才触发）
const MARINATE_REGEX = /(猪肉|牛肉|羊肉|鸡肉|鸡翅|鸡腿|排骨|肉丝|肉片|五花肉|里脊|鱼|虾)/;

const KIND_META = {
  thaw: { icon: '🧊', detail: '从冷冻拿到冷藏，明天更好下锅' },
  soak: { icon: '💧', detail: '提前泡发，做菜时更省时间' },
  marinate: { icon: '🧂', detail: '可以先腌一下，明天更入味' }
};

// 明天的 ISO 日期（UTC 截断，与 todayISO 同一口径）。
export function nextDateISO(todayIso) {
  const d = new Date(`${todayIso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

// 统一拿菜谱食材名列表：兼容 recipe_ingredients 映射 / r.ingredients / 缺失。
function ingredientNames(recipe, map) {
  const raw = (map && map[recipe?.id]) ?? recipe?.ingredients;
  if (!Array.isArray(raw)) return [];
  return raw
    .map(it => typeof it === 'string' ? it : (it?.item || it?.name || ''))
    .map(s => String(s).trim())
    .filter(Boolean);
}

/**
 * 通用入口：对一组计划项生成备菜任务（供计划组件等复用）。
 * @param {{pack: object, inv: Array, planItems: Array, targetDate: string}} args
 *   planItems —— 已按日期筛好的 plan 行（内部仍会跳过 isCooked / 库里不存在的菜谱并按 id 去重）
 * @returns {{planCount: number, tasks: Array}}
 *   task: { id, kind, icon, title, detail, recipeId, recipeName, ingredientName, targetDate }
 */
export function getPrepTasksForPlanItems({ pack, inv, planItems, targetDate }) {
  const recipes = Array.isArray(pack?.recipes) ? pack.recipes : [];
  const map = pack?.recipe_ingredients || {};

  // 只看未做完的、库里真实存在的菜谱；按 recipeId 去重。
  const seenRecipe = new Set();
  const tomorrowRecipes = [];
  for (const p of (Array.isArray(planItems) ? planItems : [])) {
    if (!p || p.isCooked) continue;
    if (seenRecipe.has(p.id)) continue;
    const r = recipes.find(x => x?.id === p.id);
    if (!r) continue;
    seenRecipe.add(p.id);
    tomorrowRecipes.push(r);
  }

  const tasks = [];
  const globalSeen = new Set(); // 全局去噪：同一 kind + 食材只提醒一次

  const pushTask = (kind, recipe, name, perRecipeCount) => {
    if (perRecipeCount.count >= 3) return;            // 同一道菜最多 3 个任务
    const globalKey = `${kind}:${name}`;
    if (globalSeen.has(globalKey)) return;
    globalSeen.add(globalKey);
    perRecipeCount.count++;
    const meta = KIND_META[kind];
    tasks.push({
      id: `${targetDate}:${recipe.id}:${kind}:${name}`,
      kind,
      icon: meta.icon,
      title: name,
      detail: meta.detail,
      recipeId: recipe.id,
      recipeName: recipe.name,
      ingredientName: name,
      targetDate
    });
  };

  for (const r of tomorrowRecipes) {
    const names = ingredientNames(r, map).filter(n => !isSeasoningName(n));
    const method = String(r?.method || '');
    const wantsMarinate = /腌/.test(method); // 没有 method 或没出现「腌」→ 绝不猜腌制
    const perRecipeCount = { count: 0 };

    for (const name of names) {
      // 🧊 解冻：肉类/水产 + 当前库存有匹配项且 isFrozen
      if (MEAT_REGEX.test(name)) {
        const frozen = getMatchingInventoryItems(inv, name).some(item => item.isFrozen === true);
        if (frozen) pushTask('thaw', r, name, perRecipeCount);
      }
      // 💧 泡发：食材名命中干货泡发关键词
      if (SOAK_REGEX.test(name)) pushTask('soak', r, name, perRecipeCount);
      // 🧂 腌制：做法明确出现「腌」且食材是肉类/鸡翅/鸡腿/鱼/虾
      if (wantsMarinate && MARINATE_REGEX.test(name)) pushTask('marinate', r, name, perRecipeCount);
    }
  }

  return { planCount: tomorrowRecipes.length, tasks };
}

/**
 * 便捷入口：生成「明天」的备菜任务（targetDate = today + 1）。
 * @param {{pack: object, inv: Array, plan: Array, today: string}} args
 * @returns {{targetDate: string, planCount: number, tasks: Array}}
 */
export function getTomorrowPrepTasks({ pack, inv, plan, today }) {
  const targetDate = nextDateISO(today);
  const planItems = (Array.isArray(plan) ? plan : []).filter(p => p && p.date === targetDate);
  const { planCount, tasks } = getPrepTasksForPlanItems({ pack, inv, planItems, targetDate });
  return { targetDate, planCount, tasks };
}
