import { S, todayISO } from './storage.js?v=98';
import {
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isSeasoning
} from './ingredients.js?v=1';
import {
  daysBetween,
  findInventoryMatch,
  remainingDays
} from './inventory.js?v=1';
import { addShoppingItem } from './shopping.js?v=1';

export function calculateStockStatus(recipe, pack, inv) {
  const rawIngs = pack.recipe_ingredients[recipe.id] || [];
  let ingredients = explodeCombinedItems(rawIngs);
  ingredients = ingredients.filter(ing => !isSeasoning(ing.item));
  if (ingredients.length === 0) return { status: 'unknown', missing: [] };

  const missing = [];
  let matchCount = 0;

  ingredients.forEach(ing => {
    if (findInventoryMatch(inv, ing.item)) matchCount++;
    else missing.push({ name: ing.item });
  });

  if (missing.length === 0) return { status: 'ok', missing: [] };
  if (matchCount > 0) return { status: 'partial', missing };
  return { status: 'none', missing };
}

export function getRecipeCoreIngredients(recipe, pack, fallbackItems = null) {
  const sourceItems = fallbackItems || explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  return (sourceItems || [])
    .map(item => ({ ...item, item: getCanonicalName(item.item || item.name || '') }))
    .filter(item => item.item && !isSeasoning(item.item));
}

export function getMissingRecipeIngredients(recipe, pack, inv, fallbackItems = null) {
  return getRecipeCoreIngredients(recipe, pack, fallbackItems)
    .filter(item => !findInventoryMatch(inv, item.item));
}

export function addMissingRecipeIngredientsToShopping(recipe, pack, inv, fallbackItems = null) {
  const missing = getMissingRecipeIngredients(recipe, pack, inv, fallbackItems);
  missing.forEach(item => {
    addShoppingItem(item.item, item.qty || '', item.unit || guessKitchenUnit(item.item), recipe.name || '菜谱');
  });
  return missing.length;
}

export function hasRecipeMethod(recipe) {
  return !!String(recipe && recipe.method || '').trim();
}

export function getLocalRecommendations(pack, inv, forceRefresh = false) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0), 10);
  const savedRecs = S.load(S.keys.local_recs, null);

  if (!forceRefresh && savedRecs && (now - lastRecTime < 3600000)) {
    return savedRecs.map(s => {
      const r = (pack.recipes || []).find(x => x.id === s.id);
      return r ? { r, matchCount: s.matchCount, reason: s.reason } : null;
    }).filter(item => item && hasRecipeMethod(item.r));
  }

  const methodReadyRecipes = (pack.recipes || []).filter(hasRecipeMethod);
  const recommendationRecipes = methodReadyRecipes.length ? methodReadyRecipes : (pack.recipes || []);

  let scores = recommendationRecipes.map(r => {
    const rawIngs = explodeCombinedItems(pack.recipe_ingredients[r.id] || []);
    const coreIngs = rawIngs.filter(ing => !isSeasoning(ing.item));

    if (coreIngs.length === 0) return { r, score: 0, matchCount: 0, reason: '基础菜品' };

    let matchCount = 0;
    let expiringBonus = 0;

    coreIngs.forEach(ing => {
      const invItem = findInventoryMatch(inv, ing.item);
      if (invItem) {
        matchCount++;
        if (remainingDays(invItem) <= 2) expiringBonus += 1;
      }
    });

    const completionRatio = matchCount / coreIngs.length;
    const score = (completionRatio * 50) + (expiringBonus * 15) + (matchCount * 10);

    let reason = '';
    if (matchCount > 0) {
      const pct = Math.round(completionRatio * 100);
      reason = `匹配 ${matchCount}/${coreIngs.length} 项食材 (${pct}%)`;
      if (expiringBonus > 0) reason = `⚠️ 优先消耗临期食材 | ${reason}`;
    }

    return { r, score, matchCount, reason };
  });

  const hasMatches = scores.some(s => s.matchCount > 0);
  if (hasMatches) scores = scores.filter(s => s.matchCount > 0);

  scores.sort((a, b) => b.score - a.score);
  let top = scores.slice(0, 6);

  if (top.length === 0) {
    const all = methodReadyRecipes.length ? methodReadyRecipes : (pack.recipes || []);
    top = [...all].sort(() => 0.5 - Math.random()).slice(0, 6).map(r => ({ r, matchCount: 0, reason: '随机探索' }));
  }

  const toSave = top.map(s => ({ id: s.r.id, matchCount: s.matchCount, reason: s.reason }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);
  return top.map(s => ({ r: s.r, matchCount: s.matchCount, reason: s.reason }));
}

export function loadFavoriteRecipeIds() {
  return S.load(S.keys.favorite_recipes, []);
}

export function saveFavoriteRecipeIds(ids) {
  S.save(S.keys.favorite_recipes, Array.from(new Set(ids)));
}

export function isFavoriteRecipe(id) {
  return loadFavoriteRecipeIds().includes(id);
}

export function toggleFavoriteRecipe(id) {
  const ids = loadFavoriteRecipeIds();
  const index = ids.indexOf(id);
  if (index >= 0) ids.splice(index, 1);
  else ids.push(id);
  saveFavoriteRecipeIds(ids);
}

export function loadRecipeUsage() {
  return S.load(S.keys.recipe_usage, {});
}

export function markRecipePlanned(id) {
  if (!id || String(id).startsWith('creative-')) return;
  const usage = loadRecipeUsage();
  usage[id] = todayISO();
  S.save(S.keys.recipe_usage, usage);
}

export function addRecipeToPlan(id) {
  const plan = S.load(S.keys.plan, []);
  if (plan.find(x => x.id === id)) return false;
  plan.push({ id, servings: 1 });
  S.save(S.keys.plan, plan);
  markRecipePlanned(id);
  return true;
}

export function markRecipeCooked(id) {
  markRecipePlanned(id);
  const plan = S.load(S.keys.plan, []);
  const nextPlan = plan.filter(item => item.id !== id);
  if (nextPlan.length !== plan.length) S.save(S.keys.plan, nextPlan);
  return { removedFromPlan: nextPlan.length !== plan.length };
}

export function recipeUsageText(lastDate) {
  if (!lastDate) return '还没安排过';
  const days = Math.max(0, daysBetween(lastDate, todayISO()));
  if (days === 0) return '今天已安排';
  if (days === 1) return '昨天安排过';
  return `${days} 天没安排`;
}

export function getFavoriteRecipeCards(pack) {
  const ids = loadFavoriteRecipeIds();
  return ids.map(id => {
    const r = (pack.recipes || []).find(x => x.id === id);
    return r ? { r, list: (pack.recipe_ingredients || {})[id], reason: '常做菜' } : null;
  }).filter(Boolean);
}

export function getForgottenFavoriteCards(pack) {
  const usage = loadRecipeUsage();
  return getFavoriteRecipeCards(pack)
    .map(item => ({ ...item, lastDate: usage[item.r.id] || '' }))
    .sort((a, b) => {
      if (!a.lastDate && b.lastDate) return -1;
      if (a.lastDate && !b.lastDate) return 1;
      return String(a.lastDate || '').localeCompare(String(b.lastDate || ''));
    })
    .slice(0, 3)
    .map(item => ({ ...item, reason: recipeUsageText(item.lastDate) }));
}

export function processAiData(aiResult, pack) {
  const cards = [];

  if (aiResult.local && Array.isArray(aiResult.local)) {
    aiResult.local.forEach(l => {
      let found = (pack.recipes || []).find(r => r.name === l.name);
      if (!found) found = (pack.recipes || []).find(r => r.name.includes(l.name) || l.name.includes(r.name));
      if (found) cards.push({ r: found, reason: l.reason, isAi: true });
    });
  }

  if (aiResult.creative) {
    const rawIngredients = typeof aiResult.creative.ingredients === 'string'
      ? aiResult.creative.ingredients.split(/[，,、/;；|]+/).map(item => item.trim()).filter(Boolean)
      : aiResult.creative.ingredients;
    const ingList = Array.isArray(rawIngredients)
      ? rawIngredients.map(item => ({
        item: String(item?.item || item?.name || item || '').trim(),
        qty: item?.qty || '',
        unit: item?.unit || ''
      })).filter(item => item.item)
      : [];

    cards.push({
      r: { id: 'creative-ai-temp', name: aiResult.creative.name, tags: ['AI草稿'], isAiDraft: true },
      list: ingList,
      reason: aiResult.creative.reason || 'AI 草稿，确认后再使用',
      isAi: true
    });
  }
  return cards;
}
