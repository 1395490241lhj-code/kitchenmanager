/*
 * src/views/home/home-data.js —— 首页只读数据派生 helper（临期食材、推荐 UI 上下文）。
 * 抽成共享模块：home-view 与 weekly-menu 都依赖它，若留在 home-view 会造成循环依赖。
 */
import { S, todayISO } from '../../storage.js?v=237';
import { isUseSoonItem, remainingDays } from '../../inventory.js?v=237';

export { isExpiryTracked } from '../../inventory.js?v=237';

// 已过期的食材留给库存页提醒处理，不能再当作「要先用掉」去做菜。
export function getExpiringItems(inv) {
  return [...(inv || [])]
    .filter(isUseSoonItem)
    .sort((a, b) => remainingDays(a) - remainingDays(b))
    .slice(0, 4);
}

export function getRecommendationUiContext() {
  return {
    favoriteIds: S.load(S.keys.favorite_recipes, []),
    recipeUsage: S.load(S.keys.recipe_usage, {}),
    recipeActivity: S.load(S.keys.recipe_activity, {}),
    plan: S.load(S.keys.plan, []),
    today: todayISO()
  };
}
