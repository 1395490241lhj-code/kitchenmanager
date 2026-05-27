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

export function getRecipeCoreIngredients(recipe, pack, fallbackItems = null) {
  const sourceItems = fallbackItems || explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  return (sourceItems || [])
    .map(item => {
      const name = getCanonicalName(item.item || item.name || '');
      return { ...item, item: name, name };
    })
    .filter(item => item.item && !isSeasoning(item.item));
}

function normalizeRecommendationSet(value) {
  if (value instanceof Set) return value;
  if (Array.isArray(value)) return new Set(value);
  return new Set();
}

function getPlanIds(context = {}) {
  if (context.plannedIds) return normalizeRecommendationSet(context.plannedIds);
  return new Set((context.plan || []).map(item => item && item.id).filter(Boolean));
}

function getUsageMap(context = {}) {
  return context.recipeUsage || context.usage || {};
}

function daysSince(date, today) {
  if (!date) return null;
  const days = daysBetween(date, today || todayISO());
  return Number.isFinite(days) ? Math.max(0, days) : null;
}

function formatDaysText(days) {
  if (days < 0) return '已过期';
  if (days === 0) return '今天到期';
  return `${days} 天内到期`;
}

function uniqueExpiringMatches(items) {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    const key = item.name || item.recipeItem || '';
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

function explainMissingNames(missing, limit = 3) {
  const names = (missing || []).map(item => item.name || item.item).filter(Boolean);
  const head = names.slice(0, limit).join('、');
  return `${head}${names.length > limit ? '等' : ''}`;
}

export function analyzeRecipeInventory(recipe, pack, inv) {
  const list = explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  const core = getRecipeCoreIngredients(recipe, pack, list);
  const matches = [];
  const missing = [];
  const expiringMatches = [];

  for (const ing of core) {
    const match = findInventoryMatch(inv, ing.item);
    if (match) {
      const days = remainingDays(match);
      matches.push({ recipeItem: ing.item, inventoryItem: match.name, days, item: ing });
      if (days <= 3) {
        expiringMatches.push({
          name: match.name,
          recipeItem: ing.item,
          days,
          label: formatDaysText(days)
        });
      }
    } else {
      missing.push({
        item: ing.item,
        name: ing.item,
        qty: ing.qty ?? '',
        unit: ing.unit || guessKitchenUnit(ing.item) || ''
      });
    }
  }

  const matchCount = matches.length;
  const totalCore = core.length;
  return {
    list,
    core,
    matches,
    missing,
    expiringMatches: uniqueExpiringMatches(expiringMatches),
    matchCount,
    totalCore,
    coverage: totalCore ? matchCount / totalCore : 0,
    status: totalCore === 0 ? 'unknown' : (missing.length === 0 ? 'ok' : (matchCount > 0 ? 'partial' : 'none'))
  };
}

export function calculateStockStatus(recipe, pack, inv) {
  const analysis = analyzeRecipeInventory(recipe, pack, inv);
  if (analysis.totalCore === 0) return { status: 'unknown', missing: [] };
  if (analysis.missing.length === 0) return { status: 'ok', missing: [] };
  if (analysis.matchCount > 0) return { status: 'partial', missing: analysis.missing };
  return { status: 'none', missing: analysis.missing };
}

export function getMissingRecipeIngredients(recipe, pack, inv, fallbackItems = null) {
  if (fallbackItems) {
    return getRecipeCoreIngredients(recipe, pack, fallbackItems)
      .filter(item => !findInventoryMatch(inv, item.item))
      .map(item => ({ ...item, name: item.item, unit: item.unit || guessKitchenUnit(item.item) || '' }));
  }
  return analyzeRecipeInventory(recipe, pack, inv).missing;
}

export function addMissingRecipeIngredientsToShopping(recipe, pack, inv, fallbackItems = null) {
  const missing = getMissingRecipeIngredients(recipe, pack, inv, fallbackItems);
  missing.forEach(item => {
    addShoppingItem(item.item || item.name, item.qty || '', item.unit || guessKitchenUnit(item.item || item.name), recipe.name || '菜谱');
  });
  return missing.length;
}

export function hasRecipeMethod(recipe) {
  return !!String(recipe && recipe.method || '').trim();
}

export function explainRecipeScore(scoreResult) {
  const explain = [];
  if (!scoreResult || scoreResult.totalCore === 0) {
    return ['没有明确核心食材，暂不作为主要推荐'];
  }

  explain.push(`已有 ${scoreResult.matchCount}/${scoreResult.totalCore} 项核心食材`);

  if (scoreResult.expiringMatches.length) {
    const first = scoreResult.expiringMatches[0];
    explain.push(`${first.name}${first.label}，建议优先使用`);
  }

  if (scoreResult.missing.length) {
    explain.push(`还缺：${explainMissingNames(scoreResult.missing)}`);
  } else {
    explain.push('食材看起来已经齐了');
  }

  if (scoreResult.isFavorite) explain.push('常做菜，轻微加分');
  if (scoreResult.isPlanned) explain.push('已在今日计划，避免重复安排');
  if (scoreResult.recentDays !== null && scoreResult.recentDays <= 5) {
    const recentText = scoreResult.recentDays === 0 ? '今天' : `最近 ${scoreResult.recentDays} 天内`;
    explain.push(`${recentText}做过/安排过，已轻微降权`);
  }
  if (scoreResult.hasMethod) explain.push('有完整做法');
  else explain.push('缺少做法，已降权');

  return explain;
}

function pickRecipeReason(result) {
  if (result.expiringMatches.length) {
    const first = result.expiringMatches[0];
    if (result.missing.length > 0 && result.missing.length <= 2 && result.matchCount > 0) {
      return `${first.name}${first.label}，只缺 ${explainMissingNames(result.missing, 2)}`;
    }
    return `${first.name}${first.label}，优先用`;
  }
  if (result.missing.length > 0 && result.missing.length <= 2 && result.matchCount > 0) {
    return `只缺 ${explainMissingNames(result.missing, 2)}`;
  }
  if (result.matchCount > 0) {
    return `已有 ${result.matchCount}/${result.totalCore} 项核心食材`;
  }
  return result.totalCore ? `还缺 ${result.missing.length} 项核心食材` : '缺少核心食材信息';
}

export function scoreRecipe(recipe, pack, inv, context = {}) {
  const analysis = analyzeRecipeInventory(recipe, pack, inv);
  const favoriteIds = normalizeRecommendationSet(context.favoriteIds);
  const plannedIds = getPlanIds(context);
  const usage = getUsageMap(context);
  const today = context.today || todayISO();
  const hasMethod = hasRecipeMethod(recipe);
  const isFavorite = favoriteIds.has(recipe.id);
  const isPlanned = plannedIds.has(recipe.id);
  const recentDays = daysSince(usage[recipe.id], today);

  let score = 0;
  const scoreParts = {};

  if (analysis.totalCore === 0) {
    score = -999;
    scoreParts.noCorePenalty = -999;
  } else {
    scoreParts.coverage = analysis.coverage * 100;
    scoreParts.missingPenalty = analysis.missing.length * -18;
    scoreParts.matchDensity = analysis.matchCount * 3;
    scoreParts.almostBonus = analysis.matchCount > 0 && analysis.missing.length > 0 && analysis.missing.length <= 2 ? 8 : 0;
    scoreParts.expiringBonus = Math.min(54, analysis.expiringMatches.reduce((sum, item) => {
      if (item.days <= 0) return sum + 24;
      if (item.days === 1) return sum + 18;
      return sum + 12;
    }, 0));
    scoreParts.favoriteBonus = isFavorite ? 8 : 0;
    scoreParts.methodBonus = hasMethod ? 6 : -8;
    scoreParts.plannedPenalty = isPlanned ? -30 : 0;

    if (recentDays === null) scoreParts.recentPenalty = 0;
    else if (recentDays <= 1) scoreParts.recentPenalty = -24;
    else if (recentDays <= 3) scoreParts.recentPenalty = -16;
    else if (recentDays <= 5) scoreParts.recentPenalty = -10;
    else if (recentDays <= 10) scoreParts.recentPenalty = -4;
    else scoreParts.recentPenalty = 0;

    score = Object.values(scoreParts).reduce((sum, value) => sum + value, 0);
  }

  const result = {
    r: recipe,
    score: Math.round(score * 10) / 10,
    matchCount: analysis.matchCount,
    totalCore: analysis.totalCore,
    missing: analysis.missing,
    expiringMatches: analysis.expiringMatches,
    reason: '',
    explain: [],
    list: analysis.list,
    core: analysis.core,
    status: analysis.status,
    coverage: analysis.coverage,
    hasMethod,
    isFavorite,
    isPlanned,
    recentDays,
    scoreParts
  };
  result.explain = explainRecipeScore(result);
  result.reason = pickRecipeReason(result);
  return result;
}

export function rankRecipesForRecommendation(pack, inv, context = {}) {
  const scored = (pack.recipes || [])
    .map(recipe => scoreRecipe(recipe, pack, inv, context))
    .filter(result => result.totalCore > 0);

  const effectiveMatches = scored.filter(result => result.matchCount > 0);
  const pool = effectiveMatches.length && !context.includeNoMatch ? effectiveMatches : scored;

  return pool.sort((a, b) =>
    b.score - a.score ||
    b.matchCount - a.matchCount ||
    a.missing.length - b.missing.length ||
    a.r.name.localeCompare(b.r.name, 'zh-Hans-CN')
  );
}

function getRecommendationContext() {
  return {
    favoriteIds: loadFavoriteRecipeIds(),
    recipeUsage: loadRecipeUsage(),
    plan: S.load(S.keys.plan, []),
    today: todayISO()
  };
}

function restoreSavedRecommendation(saved, pack) {
  const r = (pack.recipes || []).find(x => x.id === saved.id);
  if (!r) return null;
  return {
    r,
    score: Number(saved.score) || 0,
    matchCount: Number(saved.matchCount) || 0,
    totalCore: Number(saved.totalCore) || 0,
    missing: Array.isArray(saved.missing) ? saved.missing : [],
    expiringMatches: Array.isArray(saved.expiringMatches) ? saved.expiringMatches : [],
    reason: saved.reason || '',
    explain: Array.isArray(saved.explain) ? saved.explain : [],
    list: (pack.recipe_ingredients || {})[r.id] || []
  };
}

export function getLocalRecommendations(pack, inv, forceRefresh = false) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0), 10);
  const savedRecs = S.load(S.keys.local_recs, null);

  if (!forceRefresh && savedRecs && (now - lastRecTime < 3600000)) {
    return savedRecs
      .map(saved => restoreSavedRecommendation(saved, pack))
      .filter(item => item && hasRecipeMethod(item.r));
  }

  const methodReadyRecipes = (pack.recipes || []).filter(hasRecipeMethod);
  let ranked = rankRecipesForRecommendation(pack, inv, getRecommendationContext());
  if (methodReadyRecipes.length) ranked = ranked.filter(item => hasRecipeMethod(item.r));
  let top = ranked.slice(0, 6);

  if (top.length === 0) {
    const all = methodReadyRecipes.length ? methodReadyRecipes : (pack.recipes || []);
    top = [...all].sort(() => 0.5 - Math.random()).slice(0, 6).map(r => ({
      r,
      score: 0,
      matchCount: 0,
      totalCore: 0,
      missing: [],
      expiringMatches: [],
      reason: '随机探索',
      explain: ['当前库存还没有明显匹配，先随便看看'],
      list: (pack.recipe_ingredients || {})[r.id] || []
    }));
  }

  const toSave = top.map(item => ({
    id: item.r.id,
    score: item.score,
    matchCount: item.matchCount,
    totalCore: item.totalCore,
    missing: item.missing,
    expiringMatches: item.expiringMatches,
    reason: item.reason,
    explain: item.explain
  }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);
  return top;
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
      ? aiResult.creative.ingredients.split(/[，、;；]/).map(item => item.trim()).filter(Boolean)
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
