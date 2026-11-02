// test/expired-food-priority.test.mjs
// 已过期的食材不能被当成「临期、优先用」：首页临期名单、推荐加分与理由、清冰箱、
// 周菜单 AI 请求都只把今天到期和快到期的食材当作要先用掉的。
// 过期食材仍然在库存里，由库存页提醒处理；这里只管它不能驱动做菜。
import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { addDaysISO, todayISO } from '../src/storage.js';
import { normalizeAiInventoryNames } from '../src/ai.js';
import { analyzeRecipeInventory, getCleanFridgeRecommendations, scoreRecipe } from '../src/recommendations.js';
import { getGenericIngredientRecipeRecommendations } from '../src/utils/recipe-variants.js';
import { getExpiringItems } from '../src/views/home/home-data.js';
import { buildAiWeeklyMenuPlanPayload } from '../src/views/home/weekly-menu.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// remainingDays = shelf - (today - buyDate)
const stock = (name, remaining, qty = 300, unit = '克') => ({
  name, qty, unit, kind: 'raw', stockStatus: 'ok',
  buyDate: addDaysISO(todayISO(), -10), shelf: 10 + remaining
});

const inventory = () => [
  stock('菠菜', -5),
  stock('豆腐', 0, 1, '块'),
  stock('鲈鱼', 2, 1, '条'),
  stock('番茄', 8, 3, '个')
];

const spinachRecipe = { id: 'spinach', name: '蒜蓉菠菜', method: '炒熟即可' };
const tofuRecipe = { id: 'tofu', name: '家常豆腐', method: '煎香后焖煮' };
const pack = {
  recipes: [spinachRecipe, tofuRecipe],
  recipe_ingredients: {
    spinach: [{ item: '菠菜', qty: 200, unit: '克' }],
    tofu: [{ item: '豆腐', qty: 1, unit: '块' }]
  }
};
const context = { plan: [], favoriteIds: [], recipeActivity: {}, today: todayISO() };

test('首页临期名单只含今天到期和快到期的，不含已过期的', () => {
  assert.deepEqual(getExpiringItems(inventory()).map(item => item.name), ['豆腐', '鲈鱼']);
});

test('用过期食材的菜不拿临期加分，也不算「优先用」', () => {
  const spinach = scoreRecipe(spinachRecipe, pack, inventory(), context);
  assert.deepEqual(spinach.expiringMatches, []);
  assert.equal(spinach.scoreParts.expiringBonus, 0);

  const tofu = scoreRecipe(tofuRecipe, pack, inventory(), context);
  assert.deepEqual(tofu.expiringMatches.map(item => item.name), ['豆腐']);
  assert.equal(tofu.expiringMatches[0].label, '今天到期');
});

test('清冰箱不推荐围绕过期食材的菜，也不把过期说成「今天到期」', () => {
  const recs = getCleanFridgeRecommendations(pack, inventory(), context);
  assert.deepEqual(recs.map(row => row.recipeId), ['tofu']);
  assert.match(recs[0].reason, /^豆腐今天到期/);
});

test('周菜单 AI 请求不把过期食材当作已有或临期食材', () => {
  const payload = buildAiWeeklyMenuPlanPayload(pack, inventory(), {
    mealCount: 2,
    dishesPerMeal: 1,
    peopleCount: 2,
    priorities: { expiring: true, inventory: true }
  });
  assert.deepEqual(payload.inventory.map(item => item.name), ['豆腐', '鲈鱼', '番茄']);
  assert.deepEqual(payload.expiringItems.map(item => item.name), ['豆腐', '鲈鱼']);
});

test('只剩过期食材时，菜谱不算「食材已齐」，而是缺这样食材', () => {
  const analysis = analyzeRecipeInventory(spinachRecipe, pack, [stock('菠菜', -5)]);
  assert.equal(analysis.matchCount, 0);
  assert.deepEqual(analysis.missing.map(item => item.name), ['菠菜']);
});

test('同一食材另有过期批次时，今天到期的那批仍然算临期、优先用', () => {
  const analysis = analyzeRecipeInventory(spinachRecipe, pack, [stock('菠菜', -5, 500), stock('菠菜', 0, 300)]);
  assert.equal(analysis.matchCount, 1);
  assert.deepEqual(analysis.expiringMatches.map(item => [item.name, item.label]), [['菠菜', '今天到期']]);
});

test('干货没有填保质期也不会因为放久了被当成过期', () => {
  const noodles = { name: '挂面', qty: 2, unit: '把', kind: 'dry', stockStatus: 'ok', buyDate: addDaysISO(todayISO(), -60) };
  const noodleRecipe = { id: 'noodle', name: '清汤挂面', method: '煮熟即可' };
  const analysis = analyzeRecipeInventory(noodleRecipe, { recipe_ingredients: { noodle: [{ item: '挂面', qty: 1, unit: '把' }] } }, [noodles]);
  assert.equal(analysis.matchCount, 1);
});

test('清冰箱不会因为「已开封」把过期食材推出来', () => {
  const opened = { ...stock('菠菜', -5), opened: true };
  assert.deepEqual(getCleanFridgeRecommendations(pack, [opened], context), []);
});

test('周菜单 AI 请求的本地候选菜不把过期食材写成「用到、不缺」', () => {
  const payload = buildAiWeeklyMenuPlanPayload(pack, inventory(), {
    mealCount: 2,
    dishesPerMeal: 1,
    peopleCount: 2,
    priorities: { expiring: true, inventory: true }
  });
  const spinach = payload.localCandidateRecipes.find(row => row.recipeId === 'spinach');
  assert.ok(spinach, '候选里仍有这道菜，只是不能算食材齐');
  assert.ok(!spinach.uses.includes('菠菜'), '过期菠菜不能算「用到」');
  assert.ok(spinach.missing.includes('菠菜'), '过期菠菜要算作缺');
});

test('发给 AI 的冰箱库存名不含过期食材', () => {
  const names = normalizeAiInventoryNames(inventory());
  assert.equal(names.length, 3);
  assert.ok(!names.includes('菠菜'));
});

test('通用做法不会围绕过期的绿叶菜生成', () => {
  assert.deepEqual(getGenericIngredientRecipeRecommendations({ recipes: [] }, [stock('菠菜', -5)]), []);
  assert.ok(getGenericIngredientRecipeRecommendations({ recipes: [] }, [stock('菠菜', 3)]).length > 0);
});
