import { S, mustSave, todayISO, addDaysISO } from './storage.js?v=236';
import {
  INGREDIENT_ALIASES,
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isSmartIngredientMatch,
  normalizeIngredientAmount
} from './ingredients.js?v=236';
import { classifyRecipeIngredient } from './utils/recipe-sanitizer.js?v=236';
import {
  daysBetween,
  getStockCoverageAnalysis,
  remainingDays
} from './inventory.js?v=236';
import { addShoppingItem } from './shopping.js?v=236';
import {
  STAPLE_CATALOG,
  getManagedStapleGroups,
  isPantryStaple,
  isStapleOutOfStock
} from './staples.js?v=236';
import { normalizeText, searchRecipes as searchRecipesByText } from './recipe-search.js?v=236';
import { isPlanRowOnDate } from './plan-selectors.js?v=236';
import { isAiRecipeDisliked } from './utils/ai-disliked-recipes.js?v=236';
import {
  buildRecipePackMetadataIndex,
  getEnabledRecipePackIds,
  getRecipePackScoringHint
} from './recipe-packs.js?v=236';
export {
  buildGenericRecipeTemplateRecommendations,
  buildRecipeVariantRecommendations,
  buildVariantMethodDraft,
  getGenericIngredientRecipeRecommendations,
  getRecipeVariantRecommendations
} from './utils/recipe-variants.js?v=236';

const RECIPE_PACK_SCORING_BONUS = 3;

// 用户 overlay 菜谱没有统一的历史 source 字段；兼容现有 id/source/tags
// 约定，供推荐结果持久化和 UI 追踪使用。基础菜谱一律视为 system。
export function getRecipeSource(recipe) {
  if (recipe?.recipeSource === 'user' || recipe?.recipeSource === 'system') return recipe.recipeSource;
  const source = String(recipe?.source || '').trim().toLowerCase();
  if (['user', 'custom', 'user-recipe', 'ai-search', 'ai-creative', 'recipe-detail'].includes(source)) return 'user';
  if (/^(u-|ai-search-)/.test(String(recipe?.id || ''))) return 'user';
  if (Array.isArray(recipe?.tags) && recipe.tags.some(tag => /自定义|我的菜谱|用户/u.test(String(tag)))) return 'user';
  return 'system';
}

function uniqueIngredientNames(items = []) {
  return [...new Set(items.map(item => String(item?.name || item?.item || '').trim()).filter(Boolean))];
}

// Lightweight scoring bridge for formal recipe packs. This intentionally includes
// only id/name/packs metadata and never contributes recipes to the recommendation pool.
const RECIPE_PACK_SCORING_DATA = {
  packs: [
    { id: 'basic-home', name: '基础家常菜', defaultEnabled: true },
    { id: 'quick-solo', name: '快手一人食', defaultEnabled: true },
    { id: 'light-healthy', name: '清淡少油', defaultEnabled: false },
    { id: 'spicy-sichuan-hunan', name: '川湘辣味', defaultEnabled: false },
    { id: 'high-protein', name: '健身高蛋白', defaultEnabled: false }
  ],
  recipes: [
    { id: 'tomato-egg-stir-fry', name: '番茄炒蛋', packs: ['basic-home'] },
    { id: 'tomato-egg-noodles', name: '番茄鸡蛋面', packs: ['basic-home', 'quick-solo'] },
    { id: 'green-pepper-pork', name: '青椒肉丝', packs: ['basic-home'] },
    { id: 'potato-shreds', name: '土豆丝', packs: ['basic-home'] },
    { id: 'mapo-tofu', name: '麻婆豆腐', packs: ['basic-home', 'spicy-sichuan-hunan'] },
    { id: 'kung-pao-chicken', name: '宫保鸡丁', packs: ['basic-home', 'spicy-sichuan-hunan'] },
    { id: 'chicken-curry-rice', name: '咖喱鸡肉饭', packs: ['basic-home', 'quick-solo'] },
    { id: 'teriyaki-chicken-rice', name: '照烧鸡腿饭', packs: ['basic-home', 'quick-solo'] },
    { id: 'beef-roll-rice-bowl', name: '肥牛饭', packs: ['quick-solo'] },
    { id: 'kimchi-fried-rice', name: '韩式泡菜炒饭', packs: ['quick-solo'] },
    { id: 'scallion-oil-noodles', name: '葱油拌面', packs: ['quick-solo'] },
    { id: 'tomato-tofu-soup', name: '番茄豆腐汤', packs: ['light-healthy'] },
    { id: 'steamed-egg-custard', name: '蒸蛋羹', packs: ['basic-home', 'light-healthy'] },
    { id: 'salmon-quinoa-bowl', name: '三文鱼藜麦碗', packs: ['light-healthy', 'high-protein'] },
    { id: 'shrimp-scrambled-eggs', name: '虾仁炒蛋', packs: ['basic-home', 'quick-solo', 'high-protein'] },
    { id: 'garlic-broccoli', name: '蒜蓉西兰花', packs: ['basic-home', 'light-healthy'] },
    { id: 'napa-tofu-soup', name: '白菜豆腐汤', packs: ['basic-home', 'light-healthy'] },
    { id: 'onion-beef-stir-fry', name: '洋葱炒牛肉', packs: ['basic-home', 'quick-solo', 'high-protein'] },
    { id: 'pan-seared-salmon-rice', name: '煎三文鱼饭', packs: ['high-protein', 'light-healthy', 'quick-solo'] },
    { id: 'chicken-quinoa-bowl', name: '鸡肉藜麦碗', packs: ['high-protein', 'light-healthy'] }
  ]
};

// 核心食材记忆化：结果只由「来源用料数组」决定——无论走默认路径（pack 里的原始用料）
// 还是 fallbackItems 路径，都先 explodeCombinedItems 再分类（explode 幂等，已展开的列表
// 原样通过），保证同一个数组键永远只对应一种计算结果，不随调用顺序漂移。
// pack 重建（invalidatePackCache 换新数组）时旧键随之失效；同一次渲染里 rankRecipes /
// 清冰箱 / scoreRecipe 多条路径命中同一缓存。返回数组是只读共享引用——调用方只遍历不修改。
const _coreIngredientsCache = new WeakMap();

function computeCoreIngredients(sourceItems) {
  // 统一菜谱用料口径：只保留 role === 'core' 的核心食材参与库存匹配 / 缺货 / 买菜；
  // 调料（盐/生抽/水淀粉…）与非库存项（水/高汤/汤汁/适量…）一律排除。
  return explodeCombinedItems(sourceItems || [])
    .map(item => {
      const name = getCanonicalName(item.item || item.name || '');
      return { ...item, item: name, name };
    })
    .filter(item => item.item && classifyRecipeIngredient(item.item).role === 'core');
}

export function getRecipeCoreIngredients(recipe, pack, fallbackItems = null) {
  const source = fallbackItems || (pack.recipe_ingredients || {})[recipe.id];
  if (!source || typeof source !== 'object') {
    return computeCoreIngredients(source);
  }
  const cached = _coreIngredientsCache.get(source);
  if (cached) return cached;
  const computed = computeCoreIngredients(source);
  _coreIngredientsCache.set(source, computed);
  return computed;
}

function normalizeRecommendationSet(value) {
  if (value instanceof Set) return value;
  if (Array.isArray(value)) return new Set(value);
  return new Set();
}

function getRecipePackPreferenceScoringContext(context = {}) {
  const safeContext = context && typeof context === 'object' ? context : {};
  if (safeContext.recipePackPreferenceScoring) return safeContext.recipePackPreferenceScoring;

  const data = safeContext.recipePackData || RECIPE_PACK_SCORING_DATA;
  const settings = Object.prototype.hasOwnProperty.call(safeContext, 'settings')
    ? safeContext.settings
    : S.load(S.keys.settings, {});
  const enabledPackIds = Array.isArray(safeContext.enabledRecipePackIds)
    ? getEnabledRecipePackIds(data, { enabledRecipePackIds: safeContext.enabledRecipePackIds })
    : getEnabledRecipePackIds(data, settings);

  return {
    data,
    enabledPackIds,
    index: safeContext.recipePackMetadataIndex || buildRecipePackMetadataIndex(data)
  };
}

function getRecipePackPreferenceHint(recipe, context = {}) {
  const scoring = getRecipePackPreferenceScoringContext(context);
  return getRecipePackScoringHint(recipe, scoring.data, null, {
    index: scoring.index,
    enabledPackIds: scoring.enabledPackIds,
    bonus: RECIPE_PACK_SCORING_BONUS
  });
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
  // 用 fallbackItems（而非已展开的 list）取核心食材：默认路径才能命中按原始用料数组
  // 记忆化的缓存。两者推导出的核心食材完全一致（fallbackItems 为空时内部会展开同一份用料）。
  const core = getRecipeCoreIngredients(recipe, pack, fallbackItems);
  const matches = [];
  const missing = [];
  const expiringMatches = [];
  const uncertain = [];
  const needsConfirm = [];

  for (const ing of core) {
    const requiredAmount = normalizeIngredientAmount(ing.qty, ing.unit);
    const analysis = getStockCoverageAnalysis(inv, ing.item, ing.qty, ing.unit);
    if (analysis.confidence === 'exact') {
      const parsedRequiredQty = Number(requiredAmount.qty);
      const requiredQty = requiredAmount.qty === '' || !Number.isFinite(parsedRequiredQty)
        ? ''
        : parsedRequiredQty;
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
          qty: requiredAmount.qty,
          unit: requiredAmount.unit || guessKitchenUnit(ing.item) || '',
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
        qty: requiredAmount.qty,
        unit: requiredAmount.unit || guessKitchenUnit(ing.item) || '',
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
        qty: requiredAmount.qty,
        unit: requiredAmount.unit || guessKitchenUnit(ing.item) || '',
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
        qty: requiredAmount.qty,
        unit: requiredAmount.unit || guessKitchenUnit(ing.item) || ''
      });
    }
  }

  // ── 常备拦截机制 ───────────────────────────────────────────────────────
  // 常备调味品（盐、生抽、香油 等）由「常备货架」按双态管理，不参与普通库存
  // 缺货判定：
  //   · 货架状态 ≠ 断货 → 默认充足，强制从缺货明细剔除（不报警、不进弹窗）。
  //   · 货架状态 = 断货 → 才允许它作为缺货项出现，并补进缺货明细。
  // 第一步：剔除「有货」的常备品（防御 isSeasoning 漏判，例如别名未归一的写法）。
  for (let i = missing.length - 1; i >= 0; i--) {
    const item = missing[i];
    if (isPantryStaple(item.name || item.item) && !isStapleOutOfStock(item.name || item.item)) {
      missing.splice(i, 1);
    }
  }
  // 第二步：把菜谱里「断货」的常备品补进缺货明细（若主循环未覆盖）。
  for (const ing of list) {
    const name = getCanonicalName(ing.item || ing.name || '');
    if (!name || !isPantryStaple(name) || !isStapleOutOfStock(name)) continue;
    if (missing.some(m => (m.name || m.item) === name)) continue;
    missing.push({
      item: name,
      name,
      qty: ing.qty ?? '',
      unit: ing.unit || guessKitchenUnit(name) || '',
      source: 'staple'
    });
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

export function addMissingRecipeIngredientsToShopping(recipe, pack, inv, fallbackItems = null, missingOverride = null) {
  const missing = Array.isArray(missingOverride)
    ? missingOverride
    : getMissingRecipeIngredients(recipe, pack, inv, fallbackItems);
  const remark = `菜谱缺货：${recipe.name || '菜谱'}`;
  missing.forEach(item => {
    // 显式写入「血统备注」，新代买项天生自带来源说明，且允许用户后续覆盖。
    addShoppingItem(item.item || item.name, item.qty || '', item.unit || guessKitchenUnit(item.item || item.name), recipe.name || '菜谱', remark);
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
        explain.push(`${item.name}食材单位不同，数量需确认`);
      } else if (item.reason === 'status-only') {
        explain.push(`${item.name}食材状态需确认`);
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
  if (scoreResult.recipePackPreference && scoreResult.recipePackPreference.reason) {
    explain.push(scoreResult.recipePackPreference.reason);
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

function formatIngredientList(names, limit = 4) {
  const clean = (names || []).filter(Boolean);
  const head = clean.slice(0, limit).join('、');
  return `${head}${clean.length > limit ? '等' : ''}`;
}

export function normalizeTargetIngredientNames(targetNames, limit = 5) {
  const seen = new Set();
  const out = [];
  for (const raw of (targetNames || [])) {
    const name = getCanonicalName(String(raw || '').trim());
    if (!name || seen.has(name)) continue;
    if (classifyRecipeIngredient(name).role !== 'core') continue;
    seen.add(name);
    out.push(name);
    if (out.length >= limit) break;
  }
  return out;
}

// 单个候选词 vs 菜谱核心食材：同义词/别名（isIngredientMatch 双向）+ 包含兜底（鸡翅中→鸡翅）。
function candidateMatchesCore(candidate, coreName) {
  if (!candidate || !coreName) return false;
  return isSmartIngredientMatch(coreName, candidate);
}

// 目标（含类别展开候选组）vs 菜谱核心食材：任一候选命中即算命中。
function targetMatchesCore(target, coreItem) {
  const coreName = coreItem && (coreItem.item || coreItem.name);
  if (!coreName) return false;
  return (target.candidates || [target.canonical]).some(c => candidateMatchesCore(c, coreName));
}

function buildTargetRecipeReason({ targetHits, missingTargets, inventoryMissing }) {
  if (targetHits.length && !missingTargets.length && !inventoryMissing.length) {
    return `${formatIngredientList(targetHits)}都在，今天可以做`;
  }
  if (targetHits.length && !missingTargets.length) {
    const missingNames = (inventoryMissing || []).map(item => item.name || item.item).filter(Boolean);
    return `会用到${formatIngredientList(targetHits)}，还缺${formatIngredientList(missingNames, 2)}`;
  }
  if (targetHits.length) {
    return `用到了${formatIngredientList(targetHits)}，没用到${formatIngredientList(missingTargets)}`;
  }
  return '没有命中指定食材';
}

function getRecipeCoreSearchTerms(name) {
  const canonical = getCanonicalName(name || '');
  if (!canonical) return [];
  const names = new Set([canonical, name]);
  for (const alias of (INGREDIENT_ALIASES[canonical] || [])) {
    if (alias) names.add(alias);
  }
  return [...names]
    .map(item => normalizeText(item))
    .filter(item => item && (item.length >= 2 || item === '蛋'));
}

function getCompactRecipeIngredientHits(recipe, pack, queryNorm) {
  if (!queryNorm) return [];
  const hits = [];
  const seen = new Set();
  for (const core of getRecipeCoreIngredients(recipe, pack)) {
    const name = core.item || core.name;
    const terms = getRecipeCoreSearchTerms(name);
    if (!terms.some(term => queryNorm.includes(term))) continue;
    const canonical = getCanonicalName(name);
    if (!canonical || seen.has(canonical)) continue;
    seen.add(canonical);
    hits.push(canonical);
  }
  return hits;
}

export function findRecipesByName(pack, query, options = {}) {
  const q = String(query || '').trim();
  const qNorm = normalizeText(q);
  if (!qNorm) return [];
  const recipes = pack.recipes || [];
  const limit = options.limit || 5;
  const context = options.context || {};
  const searchOptions = {
    ...options,
    context: {
      ...context,
      favoriteIds: context.favoriteIds ? normalizeRecommendationSet(context.favoriteIds) : undefined,
      stockableIds: context.stockableIds ? normalizeRecommendationSet(context.stockableIds) : undefined,
      almostIds: context.almostIds ? normalizeRecommendationSet(context.almostIds) : undefined,
      recentIds: context.recentIds ? normalizeRecommendationSet(context.recentIds) : undefined
    }
  };
  const resultMap = new Map();

  const remember = (recipe, score, reasons = []) => {
    if (!recipe || !recipe.id || score <= 0) return;
    const prev = resultMap.get(recipe.id);
    const nextReasons = [...new Set([...(prev?.reasons || []), ...reasons].filter(Boolean))];
    resultMap.set(recipe.id, {
      recipe,
      score: Math.max(prev?.score || 0, score),
      reasons: nextReasons
    });
  };

  for (const result of searchRecipesByText(recipes, q, pack, searchOptions).slice(0, Math.max(limit * 2, 8))) {
    const nameNorm = normalizeText(result.recipe?.name || '');
    const nameReason = nameNorm === qNorm
      ? '菜名完全匹配'
      : nameNorm.includes(qNorm) || qNorm.includes(nameNorm)
        ? '菜名匹配'
        : '';
    remember(result.recipe, result.score, [nameReason, ...(result.reasons || [])]);
  }

  for (const recipe of recipes) {
    const nameNorm = normalizeText(recipe.name || '');
    const hits = getCompactRecipeIngredientHits(recipe, pack, qNorm);
    if (hits.length < 2 && !(nameNorm && (nameNorm.includes(qNorm) || qNorm.includes(nameNorm)))) continue;
    const score = hits.length * 90 + (nameNorm === qNorm ? 500 : nameNorm.includes(qNorm) ? 180 : 0);
    remember(recipe, score, hits.length ? [`用到${formatIngredientList(hits, 3)}`] : ['菜名匹配']);
  }

  return [...resultMap.values()]
    .sort((a, b) => b.score - a.score || String(a.recipe.name || '').localeCompare(String(b.recipe.name || ''), 'zh-Hans-CN'))
    .slice(0, limit)
    .map(item => ({
      id: item.recipe.id,
      name: item.recipe.name,
      r: item.recipe,
      recipe: item.recipe,
      score: Math.round(item.score * 10) / 10,
      matchLabel: '现有菜谱',
      reason: item.reasons[0] || '本地菜谱匹配'
    }));
}

export function findRecipesUsingIngredients(pack, inv, targetNames, options = {}) {
  // 目标描述符：优先用上层传入的解析结果（含类别展开候选组 + 库存辅助排序）；
  // 否则把规范名数组包装成单候选描述符（向后兼容旧调用）。
  const descriptors = Array.isArray(options.targetDescriptors) && options.targetDescriptors.length
    ? options.targetDescriptors
        .filter(t => t && t.canonical)
        .map(t => ({ canonical: t.canonical, candidates: (t.candidates && t.candidates.length) ? t.candidates : [t.canonical] }))
        .slice(0, options.limitTargets || 5)
    : normalizeTargetIngredientNames(targetNames, options.limitTargets || 5)
        .map(name => ({ canonical: name, candidates: [name] }));
  if (!descriptors.length) return [];

  const baseContext = options.context || getRecommendationContextSnapshot();
  const context = {
    ...baseContext,
    recipePackPreferenceScoring: getRecipePackPreferenceScoringContext(baseContext)
  };
  const limit = options.limit || 6;

  return (pack.recipes || [])
    .map(recipe => {
      const scored = scoreRecipe(recipe, pack, inv, context);
      if (!scored.totalCore) return null;
      const core = scored.core; // scoreRecipe 必定带回 core，无需再次计算
      const hitDescriptors = descriptors.filter(target => core.some(item => targetMatchesCore(target, item)));
      if (!hitDescriptors.length) return null;
      const targets = descriptors.map(d => d.canonical);
      const targetHits = hitDescriptors.map(d => d.canonical);
      const missingTargets = targets.filter(name => !targetHits.includes(name));
      const hitCount = targetHits.length;
      const completeTargetHit = hitCount === targets.length;
      const inventoryMissing = scored.missing || [];
      const recentPenalty = scored.recentDays === null
        ? 0
        : scored.recentDays <= 1
          ? -16
          : scored.recentDays <= 5
            ? -8
            : 0;
      const plannedPenalty = scored.isPlannedToday ? -20 : (scored.isPlannedFuture ? -10 : 0);
      const methodBonus = scored.hasMethod ? 8 : -8;
      const recipePackPreferenceBonus = scored.scoreParts?.recipePackPreferenceBonus || 0;
      const score = (
        hitCount * 100 +
        (completeTargetHit ? 60 : 0) +
        (scored.matchCount || 0) * 8 +
        (scored.coverage || 0) * 25 -
        inventoryMissing.length * 10 +
        methodBonus +
        recentPenalty +
        plannedPenalty +
        recipePackPreferenceBonus
      );
      const missingNames = inventoryMissing.map(item => item.name || item.item).filter(Boolean);
      const tone = inventoryMissing.length > 0 && inventoryMissing.length <= 2
        ? 'almost'
        : completeTargetHit
          ? 'ready'
          : 'idea';
      const matchLabel = completeTargetHit && inventoryMissing.length > 0 && inventoryMissing.length <= 2
        ? `缺 ${inventoryMissing.length} 样`
        : `用到 ${hitCount}/${targets.length}`;
      const row = {
        ...scored,
        targetHits,
        targetTotal: targets.length,
        missingTargets,
        inventoryMissing
      };
      return {
        id: recipe.id,
        recipeId: recipe.id,
        name: recipe.name,
        source: scored.source,
        matchedIngredients: scored.matchedIngredients,
        missingIngredients: scored.missingIngredients,
        matchLabel,
        missing: missingNames,
        reason: buildTargetRecipeReason({ targetHits, missingTargets, inventoryMissing }),
        tone,
        row,
        targetHits,
        targetTotal: targets.length,
        targetMatchedNames: targetHits,
        targetMissingNames: missingTargets,
        missingTargets,
        inventoryMissing,
        score: Math.round(score * 10) / 10,
        completeTargetHit,
        targetNames: targets
      };
    })
    .filter(Boolean)
    .sort((a, b) =>
      Number(b.completeTargetHit) - Number(a.completeTargetHit) ||
      b.targetHits.length - a.targetHits.length ||
      (b.row?.coverage || 0) - (a.row?.coverage || 0) ||
      a.inventoryMissing.length - b.inventoryMissing.length ||
      (a.source === 'user' ? 0 : 1) - (b.source === 'user' ? 0 : 1) ||
      b.score - a.score ||
      a.name.localeCompare(b.name, 'zh-Hans-CN')
    )
    .slice(0, limit);
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

  const tomorrowISO = addDaysISO(today, 1);
  const dayAfterISO = addDaysISO(today, 2);

  const isPlannedToday = (context.plan || []).some(item => item && item.id === recipe.id && isPlanRowOnDate(item, today, today));
  const isPlannedFuture = (context.plan || []).some(item => item && item.id === recipe.id
    && (isPlanRowOnDate(item, tomorrowISO, today) || isPlanRowOnDate(item, dayAfterISO, today)));
  const isPlanned = isPlannedToday || isPlannedFuture;

  const recentDays = daysSince(activity.cookedAt, today);
  const recipePackHint = getRecipePackPreferenceHint(recipe, context);

  let score = 0;
  const scoreParts = {};

  if (analysis.totalCore === 0) {
    score = -999;
    scoreParts.noCorePenalty = -999;
    scoreParts.recipePackPreferenceBonus = 0;
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
    scoreParts.recipePackPreferenceBonus = recipePackHint.scoreBonus;

    score = Object.values(scoreParts).reduce((sum, value) => sum + value, 0);
  }

  const result = {
    r: recipe,
    recipeId: recipe.id,
    source: getRecipeSource(recipe),
    score: Math.round(score * 10) / 10,
    matches: analysis.matches,
    matchCount: analysis.matchCount,
    totalCore: analysis.totalCore,
    missing: analysis.missing,
    matchedIngredients: uniqueIngredientNames(analysis.matches.map(item => ({ item: item.recipeItem }))),
    missingIngredients: uniqueIngredientNames(analysis.missing),
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
    recipePackPreference: recipePackHint,
    scoreParts
  };
  result.explain = explainRecipeScore(result);
  result.reason = pickRecipeReason(result);
  return result;
}

export function rankRecipesForRecommendation(pack, inv, context = {}) {
  const scoringContext = {
    ...context,
    recipePackPreferenceScoring: getRecipePackPreferenceScoringContext(context)
  };
  const scored = (pack.recipes || [])
    .map(recipe => scoreRecipe(recipe, pack, inv, scoringContext))
    .filter(result => result.totalCore > 0);

  const effectiveMatches = scored.filter(result => result.matchCount > 0 || (result.uncertain && result.uncertain.length > 0));
  const pool = effectiveMatches.length && !context.includeNoMatch ? effectiveMatches : scored;

  return pool.sort(compareRecipeRecommendationRows);
}

const SOURCE_PREFERENCE_SCORE_GAP = 12;

// 覆盖率、缺口和命中数是用户/系统菜谱共用的硬质量顺序；只有这些质量指标相同，
// 且综合分差距很小时，才用来源偏好打破平局。这样用户菜谱不会因为 source 标签
// 抢过明显更匹配的系统菜谱，同时仍保留“质量接近时优先用户菜谱”的体验。
function compareRecipeRecommendationRows(a, b) {
  const qualityOrder =
    (b.coverage || 0) - (a.coverage || 0) ||
    (a.missing?.length || 0) - (b.missing?.length || 0) ||
    (b.matchCount || 0) - (a.matchCount || 0);
  if (qualityOrder) return qualityOrder;

  const scoreGap = Math.abs((Number(a.score) || 0) - (Number(b.score) || 0));
  if (scoreGap <= SOURCE_PREFERENCE_SCORE_GAP) {
    const sourceOrder = (a.source === 'user' ? 0 : 1) - (b.source === 'user' ? 0 : 1);
    if (sourceOrder) return sourceOrder;
  }

  return (Number(b.score) || 0) - (Number(a.score) || 0) ||
    String(a.r?.name || '').localeCompare(String(b.r?.name || ''), 'zh-Hans-CN');
}

// 首页“换一批”与首次推荐共用这一份合理本地候选池，避免 UI 自己重新排序或把
// 没有做法/缺口过大的菜谱误当成 AI 降级前的候选。返回值保留 scoreRecipe 的
// recipeId/source/matchedIngredients/missingIngredients 追踪字段。
export function getReasonableInventoryRecipeRecommendations(pack, inv, context = {}, options = {}) {
  const excludedIds = new Set(Array.isArray(options.excludeRecipeIds) ? options.excludeRecipeIds : []);
  const limit = Number.isFinite(options.limit) ? Math.max(0, Math.trunc(options.limit)) : null;
  const candidates = rankRecipesForRecommendation(pack, inv, context)
    .filter(item => item.hasMethod && item.matchCount > 0 && item.missing.length <= 2)
    .filter(item => !excludedIds.has(item.recipeId));
  return limit === null ? candidates : candidates.slice(0, limit);
}

// 推荐 UI 的“换一批”只向前寻找尚未展示的正式菜谱；纯函数便于回归测试，
// 也避免把轮换逻辑和 AI 请求耦合在一起。
export function getNextUnshownRecommendationIndex(cards, currentIndex = 0, shownIds = new Set()) {
  const seen = shownIds instanceof Set ? shownIds : new Set(shownIds || []);
  const start = Number.isInteger(currentIndex) ? currentIndex : 0;
  return (Array.isArray(cards) ? cards : []).findIndex((card, index) => {
    if (index <= start) return false;
    const key = String(card?.recipeId || card?.id || card?.name || '').trim();
    return key && !seen.has(key);
  });
}

// “合理候选”用于决定是否需要 AI 创意降级：至少命中一项核心食材，且缺口不超过两项，
// 并且有可打开的做法。库存里有很多食材但没有同一道菜能合理承接时，仍返回 false。
export function hasReasonableInventoryRecipeCandidates(pack, inv, context = {}) {
  return getReasonableInventoryRecipeRecommendations(pack, inv, context, { limit: 1 }).length > 0;
}

function compareSignatureObjects(a, b) {
  return JSON.stringify(a).localeCompare(JSON.stringify(b), 'en');
}

function normalizeRecipeSignatureValue(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  return value;
}

function buildRecipeIngredientSignature(pack) {
  return Object.entries(pack?.recipe_ingredients || {})
    .sort((a, b) => String(a[0]).localeCompare(String(b[0]), 'zh-Hans-CN'))
    .map(([id, list]) => {
      const source = Array.isArray(list)
        ? list.map(item => typeof item === 'string' ? { item } : item)
        : [];
      const ingredients = explodeCombinedItems(source)
        .map(item => {
          const rawName = String(item?.item || item?.name || '').trim();
          const canonical = getCanonicalName(rawName);
          if (!canonical) return null;
          return {
            canonical,
            role: classifyRecipeIngredient(canonical).role,
            qty: normalizeRecipeSignatureValue(item?.qty),
            unit: normalizeRecipeSignatureValue(item?.unit)
          };
        })
        .filter(Boolean)
        .sort(compareSignatureObjects);
      return { id: String(id), ingredients };
    });
}

function getSignatureStapleNames(context = {}) {
  const names = new Set();
  for (const group of STAPLE_CATALOG) {
    for (const raw of group.items || []) {
      const canonical = getCanonicalName(raw);
      if (canonical) names.add(canonical);
    }
  }
  for (const raw of (Array.isArray(context.stapleNames) ? context.stapleNames : [])) {
    const canonical = getCanonicalName(raw);
    if (canonical) names.add(canonical);
  }
  return names;
}

function getSignatureStapleStates(context = {}) {
  const source = context.stapleStates || context.stapleStatusByName || context.staples || {};
  const entries = source instanceof Map ? Array.from(source.entries()) : Object.entries(source || {});
  const states = new Map();
  for (const [rawName, value] of entries) {
    const canonical = getCanonicalName(rawName);
    if (!canonical) continue;
    const status = value && typeof value === 'object' ? value.status : value;
    states.set(canonical, status === 'INSUFFICIENT' ? 'INSUFFICIENT' : 'SUFFICIENT');
  }
  return states;
}

function buildRecipeStapleStateSignature(recipeIngredients, context = {}) {
  const knownStaples = getSignatureStapleNames(context);
  const states = getSignatureStapleStates(context);
  const recipeNames = new Set();
  for (const recipe of recipeIngredients) {
    for (const ingredient of recipe.ingredients || []) {
      if (knownStaples.has(ingredient.canonical)) recipeNames.add(ingredient.canonical);
    }
  }
  return Array.from(recipeNames)
    .sort((a, b) => a.localeCompare(b, 'zh-Hans-CN'))
    .map(canonical => ({
      canonical,
      status: states.get(canonical) || 'SUFFICIENT'
    }));
}

export function buildRecommendationSignature(pack, inv, context = {}) {
  // Keep signature generation pure: callers that need persisted settings or
  // activity must snapshot them into context (getRecommendationContextSnapshot does so
  // at the cache boundary). Missing fields use deterministic empty defaults.
  const signatureContext = {
    ...(context && typeof context === 'object' ? context : {}),
    settings: context?.settings ?? {},
    recipeActivity: context?.recipeActivity ?? context?.recipe_activity ?? {}
  };
  const safeInv = (inv || []).map(item => ({
    name: item.name || '',
    qty: item.qty ?? '',
    unit: item.unit || '',
    stockStatus: item.stockStatus || '',
    buyDate: item.buyDate || '',
    shelf: item.shelf ?? '',
    kind: item.kind || ''
  })).sort(compareSignatureObjects);

  const safePlan = (signatureContext.plan || []).map(p => ({
    id: p.id || '',
    servings: p.servings ?? 1
  })).sort(compareSignatureObjects);

  const safeFavorites = Array.from(normalizeRecommendationSet(signatureContext.favoriteIds)).sort();
  const safeRecipePackPreferences = getRecipePackPreferenceScoringContext(signatureContext)
    .enabledPackIds
    .slice()
    .sort();

  const activityData = signatureContext.recipeActivity;
  const safeActivity = Object.entries(activityData)
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([id, val]) => {
      if (val && typeof val === 'object') {
        return `${id}:${val.plannedAt || ''}_${val.cookedAt || ''}_${val.cookedCount || 0}`;
      }
      return `${id}:${val}`;
    });

  const recipesCount = (pack.recipes || []).length;
  const recipeIngredients = buildRecipeIngredientSignature(pack);
  const ingSummary = Object.entries(pack.recipe_ingredients || {})
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([id, list]) => `${id}:${(list || []).length}`);

  return JSON.stringify({
    inv: safeInv,
    plan: safePlan,
    fav: safeFavorites,
    recipePackPrefs: safeRecipePackPreferences,
    activity: safeActivity,
    recCount: recipesCount,
    ingSum: ingSummary,
    recipeIngredients,
    stapleStates: buildRecipeStapleStateSignature(recipeIngredients, signatureContext)
  });
}

// buildRecommendationSignature 是纯函数，所有 storage 读取都集中在这里。签名的
// 唯一 context 来源：推荐缓存和首页推荐会话都必须用它，不要在 view 层另拼一份
// 缺字段的 context——少了 settings / stapleNames / stapleStates 会让菜谱包偏好和
// 常备品状态变化无法让缓存或会话失效。
export function getRecommendationContextSnapshot() {
  const stapleNames = getManagedStapleGroups()
    .flatMap(group => (group.items || []).map(item => item.name))
    .sort((a, b) => String(a).localeCompare(String(b), 'zh-Hans-CN'));
  return {
    favoriteIds: loadFavoriteRecipeIds(),
    recipeActivity: loadRecipeActivity(),
    plan: S.load(S.keys.plan, []),
    settings: S.load(S.keys.settings, {}),
    // Snapshot storage at the context boundary so buildRecommendationSignature
    // stays pure/testable and only includes states related to recipe ingredients.
    stapleNames,
    stapleStates: S.load(S.keys.staples, {}),
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
    recipeId: r.id,
    source: getRecipeSource(r),
    matchedIngredients: Array.isArray(saved.matchedIngredients) ? saved.matchedIngredients : [],
    missingIngredients: Array.isArray(saved.missingIngredients) ? saved.missingIngredients : (Array.isArray(saved.missing) ? uniqueIngredientNames(saved.missing) : []),
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

  const context = getRecommendationContextSnapshot();
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
      explain: ['当前食材还没有明显匹配，先随便看看'],
      list: (pack.recipe_ingredients || {})[r.id] || []
    }));
  }

  const toSave = top.map(item => ({
    id: item.r.id,
    score: item.score,
    matchCount: item.matchCount,
    totalCore: item.totalCore,
    missing: item.missing,
    matchedIngredients: item.matchedIngredients || [],
    missingIngredients: item.missingIngredients || uniqueIngredientNames(item.missing),
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

// 写入失败（配额满/隐私模式限制等）时抛错（.code='STORAGE_WRITE_FAILED'），而不是
// 静默丢弃这次加入计划的操作——调用方 addRecipeToPlanWithMissingCheck 会据此
// 不显示"已加入"成功提示。
export function addRecipeToPlan(id, date = null) {
  // creative-* 只用于当前一次 AI 推荐展示，不能成为持久计划项。
  if (!id || String(id).startsWith('creative-')) return false;
  const plan = S.load(S.keys.plan, []);
  const today = todayISO();
  const targetDate = date || today;
  if (plan.find(x => x.id === id && isPlanRowOnDate(x, targetDate, today))) return false;
  plan.push({ id, servings: 1, date: targetDate });
  mustSave(S.keys.plan, plan);
  markRecipePlanned(id);
  return true;
}

export function markRecipeCooked(id) {
  if (!id || String(id).startsWith('creative-')) return { removedFromPlan: false };
  const activity = loadRecipeActivity();
  if (!activity[id]) {
    activity[id] = { plannedAt: null, cookedAt: null, cookedCount: 0, lastCookedAt: null };
  }
  activity[id].cookedAt = todayISO();
  activity[id].cookedCount = (activity[id].cookedCount || 0) + 1;
  activity[id].lastCookedAt = Date.now(); // 反疲劳：精确到毫秒的最后烹饪时间
  saveRecipeActivity(activity);

  const plan = S.load(S.keys.plan, []);
  const nextPlan = plan.filter(item => item.id !== id);
  if (nextPlan.length !== plan.length) S.save(S.keys.plan, nextPlan);
  return { removedFromPlan: nextPlan.length !== plan.length };
}

// 记录「做完」成就但保留在计划里（首页菜单计划用：做好后行仍显示为已完成成就，不移除）。
export function markRecipeCookedKeepPlan(id) {
  if (!id || String(id).startsWith('creative-')) return;
  const activity = loadRecipeActivity();
  if (!activity[id]) activity[id] = { plannedAt: null, cookedAt: null, cookedCount: 0, lastCookedAt: null };
  activity[id].cookedAt = todayISO();
  activity[id].cookedCount = (activity[id].cookedCount || 0) + 1;
  activity[id].lastCookedAt = Date.now(); // 反疲劳：精确到毫秒的最后烹饪时间
  saveRecipeActivity(activity);
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
      if (isAiRecipeDisliked(l.name)) return;
      let found = (pack.recipes || []).find(r => r.name === l.name);
      if (!found) found = (pack.recipes || []).find(r => r.name.includes(l.name) || l.name.includes(r.name));
      if (found) cards.push({
        r: found,
        recipeId: found.id,
        source: getRecipeSource(found),
        matchedIngredients: [],
        missingIngredients: [],
        reason: l.reason,
        isAi: true
      });
    });
  }

  // 已保存过的 aiResult 可能是在用户点「不喜欢/不合理」之前生成的，这里再兜底过滤一次
  // creative，避免刷新页面后已 disliked 的菜名又从 localStorage 里冒出来。
  if (aiResult.creative && !isAiRecipeDisliked(aiResult.creative.name)) {
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
      recipeId: null,
      source: 'creative',
      matchedIngredients: ingList.map(item => item.item),
      missingIngredients: [],
      list: ingList,
      reason: aiResult.creative.reason || 'AI 草稿，确认后再使用',
      isAi: true
    });
  }
  return cards;
}

export function getCleanFridgeRecommendations(pack, inv, context = {}) {
  const today = context.today || todayISO();
  const baseContext = { ...context, today };
  const safeContext = {
    ...baseContext,
    recipePackPreferenceScoring: getRecipePackPreferenceScoringContext(baseContext)
  };
  
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
      const matchedItem = priorityItems.find(pItem => isSmartIngredientMatch(ing.item, pItem.name));
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
