/*
 * src/views/home/home-data.js —— 首页只读数据派生 helper（临期食材、推荐 UI 上下文）。
 * 抽成共享模块：home-view 与 weekly-menu 都依赖它，若留在 home-view 会造成循环依赖。
 */
import { S, todayISO } from '../../storage.js?v=235';
import { getCanonicalName } from '../../ingredients.js?v=235';
import { isInventoryAvailable, remainingDays } from '../../inventory.js?v=235';

// 到期提醒不统计鸡蛋、牛奶（它们按常备品状态管理，不看保质期）。
const EXPIRY_EXCLUDE_NAMES = new Set(['鸡蛋', '牛奶']);

export function isExpiryTracked(item) {
  return isInventoryAvailable(item) && !EXPIRY_EXCLUDE_NAMES.has(getCanonicalName(item.name || ''));
}

export function getExpiringItems(inv) {
  return [...(inv || [])]
    .filter(item => isExpiryTracked(item) && remainingDays(item) <= 3)
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
