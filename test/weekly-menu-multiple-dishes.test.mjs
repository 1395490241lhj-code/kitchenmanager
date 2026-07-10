import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

import {
  buildAiWeeklyMenuPlanPrompt,
  validateWeeklyMenuPlanResult
} from '../src/ai.js';
import {
  WEEKLY_MENU_MAX_DISHES,
  buildAiWeeklyMenuPlanPayload,
  createLocalWeeklyMenuEntries,
  getWeeklyPlanEntries,
  getWeeklyTargetDishCount,
  groupWeeklyMenuEntries,
  normalizeAiWeeklyMenuEntries,
  syncWeeklyMealPlannedDate
} from '../src/views/home/weekly-menu.js';

const TODAY = '2026-07-10';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

function meal({ name, mealIndex, daySuggestion = '', recipeId = '', servings = 2 } = {}) {
  return {
    name,
    ...(mealIndex === undefined ? {} : { mealIndex }),
    ...(daySuggestion ? { daySuggestion } : {}),
    ...(recipeId ? { recipeId } : {}),
    servings,
    uses: [],
    missing: []
  };
}

function sixMeals() {
  return [
    meal({ name: '青椒肉丝', mealIndex: 1, daySuggestion: '周一', recipeId: 'r1' }),
    meal({ name: '蒜蓉西兰花', mealIndex: 1, daySuggestion: '周一', recipeId: 'r2' }),
    meal({ name: '土豆烧鸡', mealIndex: 2, daySuggestion: '周三', recipeId: 'r3' }),
    meal({ name: '番茄炒蛋', mealIndex: 2, daySuggestion: '周三', recipeId: 'r4' }),
    meal({ name: '鱼香肉丝', mealIndex: 3, daySuggestion: '周五', recipeId: 'r5' }),
    meal({ name: '清炒油麦菜', mealIndex: 3, daySuggestion: '周五', recipeId: 'r6' })
  ];
}

test('3 顿 × 2 道的 AI 请求目标为 6 道，并把顿与菜数写入真实 prompt', () => {
  const payload = buildAiWeeklyMenuPlanPayload({ recipes: [] }, [], {
    mealCount: 3,
    dishesPerMeal: 2,
    peopleCount: 2,
    priorities: {},
    userRequest: ''
  });
  const prompt = buildAiWeeklyMenuPlanPrompt({
    ...payload,
    preferences: payload.preferences
  });

  assert.equal(payload.mealsCount, 3);
  assert.equal(payload.dishesPerMeal, 2);
  assert.equal(payload.targetDishCount, 6);
  assert.match(prompt, /一顿.*不是一道菜/);
  assert.match(prompt, /目标总菜数约 6 道/);
  assert.match(prompt, /"mealIndex": 1/);
});

test('6 道 AI 菜按 3 个 mealIndex 分组，同组默认日期一致', () => {
  const result = validateWeeklyMenuPlanResult({ meals: sixMeals() }, { mealCount: 3, dishesPerMeal: 2 });
  const pack = { recipes: sixMeals().map(item => ({ id: item.recipeId, name: item.name })) };
  const entries = normalizeAiWeeklyMenuEntries(result, pack, { mealCount: 3, dishesPerMeal: 2 });
  const groups = groupWeeklyMenuEntries(entries, { today: TODAY, dishesPerMeal: 2 });

  assert.equal(entries.length, 6);
  assert.deepEqual(groups.map(group => group.entries.length), [2, 2, 2]);
  assert.deepEqual(groups.map(group => group.mealLabel), ['第1顿', '第2顿', '第3顿']);
  groups.forEach(group => {
    assert.equal(new Set(group.entries.map(item => item.plannedDate)).size, 1, `${group.mealLabel} 的日期一致`);
  });
});

test('修改一顿日期会同步同组菜，批量加入仍保留每道菜一条映射', () => {
  const result = validateWeeklyMenuPlanResult({ meals: sixMeals() }, { mealCount: 3, dishesPerMeal: 2 });
  const entries = normalizeAiWeeklyMenuEntries(result, { recipes: [] }, { mealCount: 3, dishesPerMeal: 2 });

  assert.equal(syncWeeklyMealPlannedDate(entries, 2, '2026-07-15', 2), 2);
  assert.deepEqual(entries.filter(entry => entry.meal.mealIndex === 2).map(entry => entry.plannedDate), ['2026-07-15', '2026-07-15']);
  assert.equal(entries.find(entry => entry.meal.mealIndex === 1).plannedDate, undefined);

  const planEntries = getWeeklyPlanEntries(entries, { today: TODAY, dishesPerMeal: 2 });
  assert.equal(planEntries.length, 6, '每道建议仍有独立的计划写入映射');
  assert.deepEqual(
    planEntries.filter(item => item.entry.meal.mealIndex === 2).map(item => item.plannedDate),
    ['2026-07-15', '2026-07-15']
  );
});

test('本地兜底按 3 顿 × 2 道返回六道；库存不足时保留可用菜且不崩溃', () => {
  const localRows = Array.from({ length: 6 }, (_, index) => ({
    recipe: {
      id: `r${index + 1}`,
      name: index % 2 ? `清炒时蔬${index + 1}` : `家常肉菜${index + 1}`,
      ingredients: [index % 2 ? '青菜' : '鸡肉'],
      method: '炒熟即可'
    },
    row: { missing: [], list: [] },
    score: 100 - index
  }));
  const full = createLocalWeeklyMenuEntries(localRows, 3, 2, 2);
  const short = createLocalWeeklyMenuEntries(localRows.slice(0, 3), 3, 2, 2);

  assert.equal(full.length, 6);
  assert.deepEqual(groupWeeklyMenuEntries(full, { today: TODAY, dishesPerMeal: 2 }).map(group => group.entries.length), [2, 2, 2]);
  assert.equal(short.length, 3);
  assert.doesNotThrow(() => groupWeeklyMenuEntries(short, { today: TODAY, dishesPerMeal: 2 }));
});

test('无效 mealIndex 安全归一，总菜数最多 12', () => {
  const invalid = validateWeeklyMenuPlanResult({
    meals: [
      meal({ name: '菜一', mealIndex: 0 }),
      meal({ name: '菜二', mealIndex: 99 }),
      meal({ name: '菜三' })
    ]
  }, { mealCount: 3, dishesPerMeal: 2 });
  assert.deepEqual(invalid.meals.map(item => item.mealIndex), [1, 2, 3]);
  assert.deepEqual(invalid.meals.map(item => item.mealLabel), ['第1顿', '第2顿', '第3顿']);

  const collapsed = validateWeeklyMenuPlanResult({
    meals: sixMeals().map(item => ({ ...item, mealIndex: 1, daySuggestion: '周一' }))
  }, { mealCount: 3, dishesPerMeal: 2 });
  assert.deepEqual(collapsed.meals.map(item => item.mealIndex), [1, 2, 3, 1, 2, 3]);

  const capped = validateWeeklyMenuPlanResult({
    meals: Array.from({ length: 16 }, (_, index) => meal({ name: `菜${index}`, mealIndex: 1 }))
  }, { mealCount: 10, dishesPerMeal: 3 });
  assert.equal(getWeeklyTargetDishCount(10, 3), WEEKLY_MENU_MAX_DISHES);
  assert.equal(capped.meals.length, WEEKLY_MENU_MAX_DISHES);
});

test('带饭模式 prompt 明确要求耐复热，并按正餐与带饭人数规划 servings', () => {
  const prompt = buildAiWeeklyMenuPlanPrompt({
    mealsCount: 3,
    dishesPerMeal: 2,
    dishesPerMealLocked: false,
    targetDishCount: 6,
    peopleCount: 2,
    preferences: { lunchboxFriendly: true },
    userRequest: '',
    inventory: [],
    expiringItems: [],
    favoriteRecipes: [],
    localCandidateRecipes: [],
    existingPlan: []
  });

  assert.match(prompt, /耐放、复热后口感稳定/);
  assert.match(prompt, /peopleCount \+ 1/);
  assert.match(prompt, /安排 2–3 道/);
});
