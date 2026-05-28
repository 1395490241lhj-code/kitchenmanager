import { S, todayISO } from './storage.js?v=159';
import {
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isSeasoning
} from './ingredients.js?v=159';
import {
  daysBetween,
  getStockCoverageAnalysis,
  remainingDays,
  isIngredientMatch
} from './inventory.js?v=159';
import { addShoppingItem } from './shopping.js?v=159';

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

export function analyzeRecipeInventory(recipe, pack, inv, fallbackItems = null) {
  const list = fallbackItems || explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  const core = getRecipeCoreIngredients(recipe, pack, list);
  const matches = [];
  const missing = [];
  const expiringMatches = [];
  const uncertain = [];
  const needsConfirm = [];

  for (const ing of core) {
    const analysis = getStockCoverageAnalysis(inv, ing.item, ing.qty, ing.unit);
    if (analysis.confidence === 'exact') {
      const requiredQty = ing.qty !== '' && ing.qty !== null && ing.qty !== undefined ? +ing.qty : '';
      if (requiredQty !== '' && analysis.coveredQty >= requiredQty) {
        const match = analysis.matchedItems[0];
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
      } else if (requiredQty === '') {
        const match = analysis.matchedItems[0];
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
        const match = analysis.matchedItems[0];
        const days = remainingDays(match);
        if (days <= 3) {
          expiringMatches.push({
            name: match.name,
            recipeItem: ing.item,
            days,
            label: formatDaysText(days)
          });
        }
        missing.push({
          item: ing.item,
          name: ing.item,
          qty: ing.qty ?? '',
          unit: ing.unit || guessKitchenUnit(ing.item) || '',
          missingQty: Math.max(0, requiredQty - analysis.coveredQty)
        });
      }
    } else if (analysis.confidence === 'unit-mismatch') {
      const match = analysis.matchedItems[0];
      const days = remainingDays(match);
      if (days <= 3) {
        expiringMatches.push({
          name: match.name,
          recipeItem: ing.item,
          days,
          label: formatDaysText(days)
        });
      }
      uncertain.push({
        item: ing.item,
        name: ing.item,
        qty: ing.qty ?? '',
        unit: ing.unit || guessKitchenUnit(ing.item) || '',
        reason: 'unit-mismatch'
      });
      needsConfirm.push({
        name: ing.item,
        reason: 'unit-mismatch'
      });
    } else if (analysis.confidence === 'status-only') {
      const match = analysis.matchedItems[0];
      const days = remainingDays(match);
      if (days <= 3) {
        expiringMatches.push({
          name: match.name,
          recipeItem: ing.item,
          days,
          label: formatDaysText(days)
        });
      }
      uncertain.push({
        item: ing.item,
        name: ing.item,
        qty: ing.qty ?? '',
        unit: ing.unit || guessKitchenUnit(ing.item) || '',
        reason: 'status-only'
      });
      needsConfirm.push({
        name: ing.item,
        reason: 'status-only'
      });
    } else {
      // none
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
  const coverage = totalCore ? matchCount / totalCore : 0;

  let coverageConfidence = 'none';
  if (totalCore === 0) {
    coverageConfidence = 'unknown';
  } else if (missing.length > 0) {
    if (matchCount > 0 || uncertain.length > 0) {
      coverageConfidence = 'low';
    } else {
      coverageConfidence = 'none';
    }
  } else if (uncertain.length > 0) {
    const hasMismatch = uncertain.some(x => x.reason === 'unit-mismatch');
    coverageConfidence = hasMismatch ? 'unit-mismatch' : 'status-only';
  } else {
    coverageConfidence = 'exact';
  }

  let status = 'none';
  if (totalCore === 0) {
    status = 'unknown';
  } else if (missing.length === 0 && uncertain.length === 0) {
    status = 'ok';
  } else if (matchCount > 0 || uncertain.length > 0) {
    status = 'partial';
  } else {
    status = 'none';
  }

  return {
    list,
    core,
    matches,
    missing,
    uncertain,
    needsConfirm,
    coverageConfidence,
    expiringMatches: uniqueExpiringMatches(expiringMatches),
    matchCount,
    totalCore,
    coverage,
    status
  };
}

export function calculateStockStatus(recipe, pack, inv) {
  const analysis = analyzeRecipeInventory(recipe, pack, inv);
  return {
    status: analysis.status,
    missing: analysis.missing,
    uncertain: analysis.uncertain,
    needsConfirm: analysis.needsConfirm,
    coverageConfidence: analysis.coverageConfidence
  };
}

export function getMissingRecipeIngredients(recipe, pack, inv, fallbackItems = null) {
  return analyzeRecipeInventory(recipe, pack, inv, fallbackItems).missing;
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

  if (scoreResult.needsConfirm && scoreResult.needsConfirm.length) {
    scoreResult.needsConfirm.forEach(item => {
      if (item.reason === 'unit-mismatch') {
        explain.push(`${item.name}库存单位不同，数量需确认`);
      } else if (item.reason === 'status-only') {
        explain.push(`${item.name}库存状态需确认`);
      }
    });
  }

  if (scoreResult.missing.length) {
    explain.push(`还缺：${explainMissingNames(scoreResult.missing)}`);
  } else {
    if (scoreResult.needsConfirm && scoreResult.needsConfirm.length > 0) {
      explain.push('部分食材单位或状态待确认');
    } else {
      explain.push('食材看起来已经齐了');
    }
  }

  if (scoreResult.isFavorite) explain.push('常做菜，轻微加分');
  if (scoreResult.isPlannedToday) explain.push('今天已计划，避免重复安排');
  else if (scoreResult.isPlannedFuture) explain.push('明/后天已计划，轻微降权');
  if (scoreResult.recentDays !== null && scoreResult.recentDays <= 5) {
    const recentText = scoreResult.recentDays === 0 ? '今天' : `最近 ${scoreResult.recentDays} 天内`;
    explain.push(`${recentText}做过，已轻微降权`);
  }
  if (scoreResult.cookedCount > 0) {
    explain.push(`做过 ${scoreResult.cookedCount} 次，轻微加分`);
  }
  if (scoreResult.hasMethod) explain.push('有完整做法');
  else explain.push('缺少做法，已降权');

  return explain;
}

function pickRecipeReason(result) {
  if (result.expiringMatches.length) {
    const first = result.expiringMatches[0];
    return `${first.name}${first.label}，优先用`;
  }
  if (result.needsConfirm && result.needsConfirm.length > 0) {
    const first = result.needsConfirm[0];
    if (first.reason === 'unit-mismatch') {
      return `${first.name}数量需确认`;
    } else if (first.reason === 'status-only') {
      return `${first.name}状态需确认`;
    }
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
  const activityMap = context.recipeActivity || context.recipe_activity || loadRecipeActivity();
  const activity = activityMap[recipe.id] || { plannedAt: null, cookedAt: null, cookedCount: 0 };
  const today = context.today || todayISO();
  const hasMethod = hasRecipeMethod(recipe);
  const isFavorite = favoriteIds.has(recipe.id);

  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate);
  tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate);
  dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const isPlannedToday = (context.plan || []).some(item => item && item.id === recipe.id && (item.date || today) === today);
  const isPlannedFuture = (context.plan || []).some(item => item && item.id === recipe.id && (item.date === tomorrowISO || item.date === dayAfterISO));
  const isPlanned = isPlannedToday || isPlannedFuture;

  const recentDays = daysSince(activity.cookedAt, today);

  let score = 0;
  const scoreParts = {};

  if (analysis.totalCore === 0) {
    score = -999;
    scoreParts.noCorePenalty = -999;
  } else {
    scoreParts.coverage = analysis.coverage * 100;
    scoreParts.missingPenalty = analysis.missing.length * -18;
    scoreParts.matchDensity = analysis.matchCount * 3;
    scoreParts.uncertainBonus = (analysis.uncertain || []).length * 4;
    scoreParts.almostBonus = (analysis.matchCount > 0 || (analysis.uncertain && analysis.uncertain.length > 0)) && analysis.missing.length > 0 && analysis.missing.length <= 2 ? 8 : 0;
    scoreParts.expiringBonus = Math.min(54, analysis.expiringMatches.reduce((sum, item) => {
      if (item.days <= 0) return sum + 24;
      if (item.days === 1) return sum + 18;
      return sum + 12;
    }, 0));
    scoreParts.favoriteBonus = isFavorite ? 8 : 0;
    scoreParts.methodBonus = hasMethod ? 6 : -8;
    scoreParts.plannedPenalty = isPlannedToday ? -30 : (isPlannedFuture ? -10 : 0);

    if (recentDays === null) scoreParts.recentPenalty = 0;
    else if (recentDays <= 1) scoreParts.recentPenalty = -24;
    else if (recentDays <= 3) scoreParts.recentPenalty = -16;
    else if (recentDays <= 5) scoreParts.recentPenalty = -10;
    else if (recentDays <= 10) scoreParts.recentPenalty = -4;
    else scoreParts.recentPenalty = 0;

    scoreParts.cookedCountBonus = Math.min(6, (activity.cookedCount || 0) * 1.5);

    score = Object.values(scoreParts).reduce((sum, value) => sum + value, 0);
  }

  const result = {
    r: recipe,
    score: Math.round(score * 10) / 10,
    matches: analysis.matches,
    matchCount: analysis.matchCount,
    totalCore: analysis.totalCore,
    missing: analysis.missing,
    uncertain: analysis.uncertain,
    needsConfirm: analysis.needsConfirm,
    coverageConfidence: analysis.coverageConfidence,
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
    isPlannedToday,
    isPlannedFuture,
    recentDays,
    cookedCount: activity.cookedCount || 0,
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

  const effectiveMatches = scored.filter(result => result.matchCount > 0 || (result.uncertain && result.uncertain.length > 0));
  const pool = effectiveMatches.length && !context.includeNoMatch ? effectiveMatches : scored;

  return pool.sort((a, b) =>
    b.score - a.score ||
    b.matchCount - a.matchCount ||
    a.missing.length - b.missing.length ||
    a.r.name.localeCompare(b.r.name, 'zh-Hans-CN')
  );
}

export function buildRecommendationSignature(pack, inv, context) {
  const safeInv = (inv || []).map(item => ({
    name: item.name || '',
    qty: item.qty ?? '',
    unit: item.unit || '',
    stockStatus: item.stockStatus || '',
    buyDate: item.buyDate || '',
    shelf: item.shelf ?? '',
    kind: item.kind || ''
  })).sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN') || (a.buyDate || '').localeCompare(b.buyDate || '') || (a.kind || '').localeCompare(b.kind || ''));

  const safePlan = (context.plan || []).map(p => ({
    id: p.id || '',
    servings: p.servings ?? 1
  })).sort((a, b) => String(a.id).localeCompare(String(b.id)));

  const safeFavorites = (context.favoriteIds || []).slice().sort();

  const activityData = context.recipeActivity || context.recipe_activity || loadRecipeActivity();
  const safeActivity = Object.entries(activityData)
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([id, val]) => {
      if (val && typeof val === 'object') {
        return `${id}:${val.plannedAt || ''}_${val.cookedAt || ''}_${val.cookedCount || 0}`;
      }
      return `${id}:${val}`;
    });

  const recipesCount = (pack.recipes || []).length;
  
  const ingSummary = Object.entries(pack.recipe_ingredients || {})
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([id, list]) => `${id}:${(list || []).length}`);

  return JSON.stringify({
    inv: safeInv,
    plan: safePlan,
    fav: safeFavorites,
    activity: safeActivity,
    recCount: recipesCount,
    ingSum: ingSummary
  });
}

function getRecommendationContext() {
  return {
    favoriteIds: loadFavoriteRecipeIds(),
    recipeActivity: loadRecipeActivity(),
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
    uncertain: Array.isArray(saved.uncertain) ? saved.uncertain : [],
    needsConfirm: Array.isArray(saved.needsConfirm) ? saved.needsConfirm : [],
    coverageConfidence: saved.coverageConfidence || '',
    expiringMatches: Array.isArray(saved.expiringMatches) ? saved.expiringMatches : [],
    reason: saved.reason || '',
    explain: Array.isArray(saved.explain) ? saved.explain : [],
    list: (pack.recipe_ingredients || {})[r.id] || [],
    coverage: Number(saved.coverage) || 0,
    status: saved.status || ''
  };
}

export function getLocalRecommendations(pack, inv, forceRefresh = false) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0), 10);
  const savedRecs = S.load(S.keys.local_recs, null);
  const savedSignature = S.load(S.keys.rec_signature, null);

  const context = getRecommendationContext();
  const currentSignature = buildRecommendationSignature(pack, inv, context);

  const cacheValid = !forceRefresh && 
                     savedRecs && 
                     (now - lastRecTime < 3600000) && 
                     savedSignature && 
                     (savedSignature === currentSignature);

  if (cacheValid) {
    return savedRecs
      .map(saved => restoreSavedRecommendation(saved, pack))
      .filter(item => item && hasRecipeMethod(item.r));
  }

  const methodReadyRecipes = (pack.recipes || []).filter(hasRecipeMethod);
  let ranked = rankRecipesForRecommendation(pack, inv, context);
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
    uncertain: item.uncertain || [],
    needsConfirm: item.needsConfirm || [],
    coverageConfidence: item.coverageConfidence || '',
    expiringMatches: item.expiringMatches,
    reason: item.reason,
    explain: item.explain,
    coverage: item.coverage || 0,
    status: item.status || ''
  }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);
  S.save(S.keys.rec_signature, currentSignature);
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

export function loadRecipeActivity() {
  return S.load(S.keys.recipe_activity, {});
}

export function saveRecipeActivity(activity) {
  S.save(S.keys.recipe_activity, activity);
}

export function getRecipeActivity(id) {
  const activity = loadRecipeActivity();
  const act = activity[id] || {};
  return {
    plannedAt: act.plannedAt || null,
    cookedAt: act.cookedAt || null,
    cookedCount: act.cookedCount || 0
  };
}

export function markRecipePlanned(id) {
  if (!id || String(id).startsWith('creative-')) return;
  const activity = loadRecipeActivity();
  if (!activity[id]) {
    activity[id] = { plannedAt: null, cookedAt: null, cookedCount: 0 };
  }
  activity[id].plannedAt = todayISO();
  saveRecipeActivity(activity);
}

export function addRecipeToPlan(id, date = null) {
  const plan = S.load(S.keys.plan, []);
  const today = todayISO();
  const targetDate = date || today;
  if (plan.find(x => x.id === id && (x.date || today) === targetDate)) return false;
  plan.push({ id, servings: 1, date: targetDate });
  S.save(S.keys.plan, plan);
  markRecipePlanned(id);
  return true;
}

export function markRecipeCooked(id) {
  if (!id || String(id).startsWith('creative-')) return { removedFromPlan: false };
  const activity = loadRecipeActivity();
  if (!activity[id]) {
    activity[id] = { plannedAt: null, cookedAt: null, cookedCount: 0 };
  }
  activity[id].cookedAt = todayISO();
  activity[id].cookedCount = (activity[id].cookedCount || 0) + 1;
  saveRecipeActivity(activity);

  const plan = S.load(S.keys.plan, []);
  const nextPlan = plan.filter(item => item.id !== id);
  if (nextPlan.length !== plan.length) S.save(S.keys.plan, nextPlan);
  return { removedFromPlan: nextPlan.length !== plan.length };
}

export function recipeUsageText(activityOrDate) {
  if (!activityOrDate) return '没计划/没做过';
  let plannedAt = null;
  let cookedAt = null;
  let cookedCount = 0;
  if (typeof activityOrDate === 'string') {
    plannedAt = activityOrDate;
  } else if (activityOrDate && typeof activityOrDate === 'object') {
    plannedAt = activityOrDate.plannedAt || null;
    cookedAt = activityOrDate.cookedAt || null;
    cookedCount = activityOrDate.cookedCount || 0;
  }

  const today = todayISO();
  if (plannedAt === today) {
    return '今天已计划';
  }
  if (cookedAt) {
    const cookedDays = daysSince(cookedAt, today);
    if (cookedDays !== null && cookedDays <= 5) {
      return '最近做过';
    }
  }
  if (cookedCount > 0) {
    return `做过 ${cookedCount} 次`;
  }
  return '没计划/没做过';
}

export function getFavoriteRecipeCards(pack) {
  const ids = loadFavoriteRecipeIds();
  return ids.map(id => {
    const r = (pack.recipes || []).find(x => x.id === id);
    return r ? { r, list: (pack.recipe_ingredients || {})[id], reason: '常做菜' } : null;
  }).filter(Boolean);
}

export function getForgottenFavoriteCards(pack) {
  const activity = loadRecipeActivity();
  return getFavoriteRecipeCards(pack)
    .map(item => ({ ...item, activity: activity[item.r.id] || null }))
    .sort((a, b) => {
      const aCooked = a.activity ? a.activity.cookedAt || '' : '';
      const bCooked = b.activity ? b.activity.cookedAt || '' : '';
      if (!aCooked && bCooked) return -1;
      if (aCooked && !bCooked) return 1;
      return String(aCooked || '').localeCompare(String(bCooked || ''));
    })
    .slice(0, 3)
    .map(item => ({ ...item, reason: recipeUsageText(item.activity) }));
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

export function getCleanFridgeRecommendations(pack, inv, context = {}) {
  const today = context.today || todayISO();
  const safeContext = { ...context, today };
  
  // 1. Find priority items
  const priorityItems = (inv || []).filter(item => {
    if ((item.kind || 'raw') !== 'dry') {
      const days = remainingDays(item);
      if (days <= 3) return true;
    }
    if (item.stockStatus === 'low' && (+item.qty || 0) > 0) return true;
    if (item.opened || item.isOpened) return true;
    return false;
  });

  if (priorityItems.length === 0) return [];

  // 2. Score recipes containing at least one priority item
  const scored = (pack.recipes || []).map(recipe => {
    const core = getRecipeCoreIngredients(recipe, pack);
    const matchedPriorities = [];

    for (const ing of core) {
      const matchedItem = priorityItems.find(pItem => isIngredientMatch(ing.item, pItem.name));
      if (matchedItem) {
        matchedPriorities.push({ ing, pItem: matchedItem });
      }
    }

    if (matchedPriorities.length === 0) return null;

    const baseResult = scoreRecipe(recipe, pack, inv, safeContext);
    if (baseResult.score < -900) return null;

    let cleanFridgeBonus = 0;
    const reasons = [];

    for (const { ing, pItem } of matchedPriorities) {
      let urgencyScore = 0;
      let reasonText = '';
      const isDry = (pItem.kind || 'raw') === 'dry';
      const days = isDry ? 999 : remainingDays(pItem);

      if (!isDry && days <= 0) {
        urgencyScore = 50;
        reasonText = `${pItem.name}已过期或今日到期`;
      } else if (!isDry && days === 1) {
        urgencyScore = 40;
        reasonText = `${pItem.name} 1 天内到期`;
      } else if (!isDry && days <= 3) {
        urgencyScore = 30;
        reasonText = `${pItem.name} ${days} 天后到期`;
      } else if (pItem.opened || pItem.isOpened) {
        urgencyScore = 20;
        reasonText = `${pItem.name}已开封`;
      } else if (pItem.stockStatus === 'low') {
        urgencyScore = 15;
        reasonText = `${pItem.name}快没了`;
      }

      cleanFridgeBonus += urgencyScore;
      if (reasonText) {
        reasons.push({ name: pItem.name, days, reason: reasonText });
      }
    }

    if (reasons.length === 0) return null;

    reasons.sort((a, b) => {
      const getPriority = r => {
        if (r.reason.includes('已过期') || r.reason.includes('今日到期') || r.days <= 0) return 3;
        if (r.days <= 3) return 2;
        return 1;
      };
      return getPriority(b) - getPriority(a);
    });

    const primary = reasons[0];
    let expPart = '';
    if (primary.days <= 0) {
      expPart = `${primary.name}今天到期`;
    } else if (primary.days === 2) {
      expPart = `${primary.name} 2 天后到期`;
    } else if (primary.days === 3) {
      expPart = `${primary.name} 3 天后到期`;
    } else {
      expPart = `${primary.name}快到期`;
    }

    let reasonText = '';
    const missingList = baseResult.missing;
    if (missingList.length === 1) {
      reasonText = `${expPart}，只缺${missingList[0].name}`;
    } else if (primary.days <= 0) {
      reasonText = `${expPart}，建议优先使用`;
    } else {
      const matchedIngs = [
        ...baseResult.matches.map(m => m.inventoryItem || m.recipeItem),
        ...baseResult.uncertain.map(u => u.name || u.item)
      ];
      const otherMatches = matchedIngs.filter(name => getCanonicalName(name) !== getCanonicalName(primary.name));
      if (otherMatches.length > 0) {
        const partner = otherMatches[0];
        reasonText = `${expPart}，搭配${partner}可做${recipe.name}`;
      } else {
        reasonText = `${expPart}，建议优先使用`;
      }
    }

    return {
      ...baseResult,
      score: Math.round((baseResult.score + cleanFridgeBonus) * 10) / 10,
      reason: reasonText,
      isCleanFridge: true
    };
  }).filter(Boolean);

  return scored.sort((a, b) => b.score - a.score);
}
