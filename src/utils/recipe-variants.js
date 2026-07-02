import {
  explodeCombinedItems,
  getCanonicalName,
  guessKitchenUnit,
  isSmartIngredientMatch
} from '../ingredients.js?v=230';
import { isInventoryAvailable, remainingDays } from '../inventory.js?v=230';
import { normalizeText } from '../recipe-search.js?v=230';
import { classifyRecipeIngredient } from './recipe-sanitizer.js?v=230';

const PROCESSED_FOOD_RE = /(水饺|饺子|抄手|馄饨|云吞|汤圆|粽|方便面|泡面|速食|披萨|薯条|鸡块|雪贝|糕点|零食|饮料|小鱼干|鱼干花生|香肠|丸)$/;

export const VARIANT_INGREDIENT_FAMILIES = [
  { key: 'stir_fry_meat', label: '可炒肉类', names: ['猪肉', '牛肉', '鸡肉', '鸡腿'] },
  { key: 'egg_tofu', label: '蛋白轻食', names: ['鸡蛋', '豆腐'] },
  { key: 'leafy_green', label: '绿叶菜', names: ['青菜', '油菜', '小白菜', '上海青', '菠菜', '生菜', '空心菜', '木耳菜', '苋菜', '茼蒿', '芥兰', '豌豆尖', '油麦菜', 'A菜'] },
  { key: 'mushroom', label: '菌菇', names: ['蘑菇', '香菇', '平菇', '口蘑', '金针菇', '杏鲍菇'] },
  { key: 'pepper', label: '椒类', names: ['青椒', '红椒', '尖椒', '辣椒', '二荆条'] }
];

const FAMILY_BY_NAME = new Map();
for (const family of VARIANT_INGREDIENT_FAMILIES) {
  for (const raw of family.names) {
    const canonical = getCanonicalName(raw);
    if (canonical) FAMILY_BY_NAME.set(canonical, family);
  }
}

function isVariantSafeIngredient(name) {
  const canonical = getCanonicalName(name || '');
  if (!canonical || PROCESSED_FOOD_RE.test(canonical)) return false;
  return classifyRecipeIngredient(canonical).role === 'core';
}

function getFamily(name) {
  const canonical = getCanonicalName(name || '');
  if (!canonical || !isVariantSafeIngredient(canonical)) return null;
  if (FAMILY_BY_NAME.has(canonical)) return FAMILY_BY_NAME.get(canonical);
  for (const family of VARIANT_INGREDIENT_FAMILIES) {
    if (family.names.some(item => isSmartIngredientMatch(canonical, item))) return family;
  }
  return null;
}

export function getVariantIngredientFamilyKey(name) {
  return getFamily(name)?.key || '';
}

function getCoreRows(pack, recipe) {
  return explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || [])
    .map(item => {
      const name = getCanonicalName(item.item || item.name || '');
      return { ...item, item: name, name };
    })
    .filter(item => item.item && isVariantSafeIngredient(item.item));
}

function getAllRowsWithReplacement(pack, recipe, replacement) {
  const rows = explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  return rows.map(item => {
    const name = getCanonicalName(item.item || item.name || '');
    if (!name || !isSmartIngredientMatch(name, replacement.from)) return item;
    const next = {
      ...item,
      item: replacement.to,
      name: replacement.to
    };
    if (replacement.familyKey === 'egg_tofu') {
      next.qty = 1;
      next.unit = guessKitchenUnit(replacement.to) || next.unit || '';
    } else if (!next.unit) {
      next.unit = guessKitchenUnit(replacement.to) || '';
    }
    return next;
  });
}

function getInventoryNames(inv) {
  const seen = new Set();
  const names = [];
  for (const item of inv || []) {
    if (!isInventoryAvailable(item)) continue;
    const name = getCanonicalName(item.name || '');
    if (!name || seen.has(name) || !isVariantSafeIngredient(name)) continue;
    seen.add(name);
    names.push(name);
  }
  return names;
}

function hasInventoryMatch(invNames, name) {
  return invNames.some(invName => isSmartIngredientMatch(invName, name));
}

function findReplacementCandidates(fromName, invNames) {
  const family = getFamily(fromName);
  if (!family) return [];
  return invNames
    .filter(name => !isSmartIngredientMatch(name, fromName))
    .filter(name => getFamily(name)?.key === family.key)
    .map(name => ({ from: getCanonicalName(fromName), to: name, familyKey: family.key, familyLabel: family.label }));
}

function getNameTerms(name) {
  const canonical = getCanonicalName(name || '');
  return [...new Set([name, canonical].filter(Boolean))].sort((a, b) => b.length - a.length);
}

function replaceGenericMeatName(baseName, toName) {
  const patterns = [
    ['肉丝', `${toName}丝`],
    ['肉片', `${toName}片`],
    ['肉末', `${toName}末`],
    ['肉丁', `${toName}丁`],
    ['肉块', `${toName}块`],
    ['炒肉', `炒${toName}`]
  ];
  for (const [from, to] of patterns) {
    if (baseName.includes(from)) return baseName.replace(from, to);
  }
  return baseName;
}

export function buildVariantRecipeName(baseName, replacements = []) {
  let name = String(baseName || '').trim();
  for (const replacement of replacements) {
    const before = name;
    for (const term of getNameTerms(replacement.from)) {
      if (term && name.includes(term)) {
        name = name.replace(term, replacement.to);
        break;
      }
    }
    if (name === before && replacement.familyKey === 'stir_fry_meat') {
      name = replaceGenericMeatName(name, replacement.to);
    }
    if (name === before) {
      name = `${replacement.to}版${name}`;
    }
  }
  return name
    .replace(/肉肉/g, '肉')
    .replace(/丝丝/g, '丝')
    .replace(/片片/g, '片')
    .replace(/丁丁/g, '丁')
    .replace(/块块/g, '块');
}

function formatNames(names, limit = 3) {
  const clean = [...new Set((names || []).filter(Boolean))];
  const head = clean.slice(0, limit).join('、');
  return `${head}${clean.length > limit ? '等' : ''}`;
}

const GENERIC_LEAFY_TEMPLATES = [
  {
    key: 'egg_drop_leafy_soup',
    requires: ['鸡蛋'],
    priority: 90,
    name: ingredient => `${ingredient}蛋花汤`,
    reason: ingredient => `${ingredient}适合做清爽蛋花汤，家里有鸡蛋时很顺手。`,
    ingredients: ingredient => [
      { item: ingredient, qty: 1, unit: guessKitchenUnit(ingredient) || '把' },
      { item: '鸡蛋', qty: 1, unit: '个' },
      { item: '盐', qty: '', unit: '' },
      { item: '香油', qty: '', unit: '' }
    ],
    method: ingredient => [
      `1. ${ingredient}洗净切段，鸡蛋打散。`,
      '2. 锅里加水或高汤煮开。',
      `3. 下${ingredient}煮到变软。`,
      '4. 淋入蛋液，轻轻搅开，加盐调味。'
    ].join('\n')
  },
  {
    key: 'tofu_leafy_soup',
    requires: ['豆腐'],
    priority: 82,
    name: ingredient => `${ingredient}豆腐汤`,
    reason: ingredient => `${ingredient}和豆腐一起煮汤，清淡不费事。`,
    ingredients: ingredient => [
      { item: ingredient, qty: 1, unit: guessKitchenUnit(ingredient) || '把' },
      { item: '豆腐', qty: 1, unit: '盒' },
      { item: '盐', qty: '', unit: '' },
      { item: '香油', qty: '', unit: '' }
    ],
    method: ingredient => [
      `1. 豆腐切块，${ingredient}洗净。`,
      '2. 水开后下豆腐煮几分钟。',
      `3. 下${ingredient}煮到变软。`,
      '4. 加盐和少量香油调味。'
    ].join('\n')
  },
  {
    key: 'garlic_stir_fry_leafy',
    requires: [],
    priority: 70,
    name: ingredient => `蒜蓉清炒${ingredient}`,
    reason: ingredient => `${ingredient}适合蒜蓉清炒，也可以做汤。`,
    ingredients: ingredient => [
      { item: ingredient, qty: 1, unit: guessKitchenUnit(ingredient) || '把' },
      { item: '蒜', qty: '', unit: '' },
      { item: '油', qty: '', unit: '' },
      { item: '盐', qty: '', unit: '' }
    ],
    method: ingredient => [
      `1. ${ingredient}洗净沥干，蒜切末。`,
      '2. 热锅下油，先爆香蒜末。',
      `3. 下${ingredient}大火快炒，炒到变软。`,
      '4. 加盐调味，出锅前可以滴一点香油。'
    ].join('\n')
  }
];

function getExistingRecipeNameSet(pack = {}, extraNames = []) {
  return new Set([
    ...(pack.recipes || []).map(recipe => recipe?.name || ''),
    ...(extraNames || [])
  ].map(name => normalizeText(name)).filter(Boolean));
}

function getInventoryEntryScore(item, targetNames) {
  const name = getCanonicalName(item.name || '');
  const targetHit = targetNames.some(target => isSmartIngredientMatch(target, name)) ? 200 : 0;
  const days = remainingDays(item);
  const expiryScore = Number.isFinite(days) ? Math.max(0, 45 - Math.max(-5, days)) : 0;
  const qty = Number(item.qty);
  const qtyScore = Number.isFinite(qty) ? Math.min(30, Math.max(0, qty)) : 0;
  return targetHit + expiryScore + qtyScore;
}

function getGenericTemplateInventoryItems(inv, targetNames) {
  const byName = new Map();
  for (const item of inv || []) {
    if (!isInventoryAvailable(item)) continue;
    const name = getCanonicalName(item.name || '');
    if (!name || !isVariantSafeIngredient(name) || getFamily(name)?.key !== 'leafy_green') continue;
    const score = getInventoryEntryScore(item, targetNames);
    const previous = byName.get(name);
    if (!previous || score > previous.score) byName.set(name, { item, name, score });
  }
  return [...byName.values()].sort((a, b) => b.score - a.score || a.name.localeCompare(b.name, 'zh-Hans-CN'));
}

function buildGenericTemplateCard(ingredientName, template, score) {
  const ingredients = template.ingredients(ingredientName);
  const recipeIngredients = ingredients.map(item => ({ ...item }));
  return {
    id: `generic:${ingredientName}:${template.key}`,
    name: template.name(ingredientName),
    ingredientName,
    templateKey: template.key,
    matchLabel: '简单做法',
    sourceLabel: '通用做法 · 适合绿叶菜',
    reason: template.reason(ingredientName),
    ingredients,
    recipeIngredients,
    methodDraft: template.method(ingredientName),
    tags: ['简单做法'],
    tone: 'generic',
    score,
    isGenericTemplate: true
  };
}

export function buildVariantMethodDraft(variant) {
  const replacements = variant.replacements || [];
  const changeText = replacements.map(item => `${item.from}换成${item.to}`).join('、');
  const tips = replacements.map(item => {
    if (item.to === '牛肉') return '牛肉建议切薄片或丝，用生抽、淀粉和少量油抓匀，快炒避免变老。';
    if (item.to === '鸡腿' || item.to === '鸡肉') return '鸡腿肉可以切块或切条，炒前简单腌一下会更入味。';
    if (item.to === '豆腐') return '豆腐易碎，翻炒动作轻一点，也可以先煎定型。';
    return '';
  }).filter(Boolean);
  const baseMethod = String(variant.baseMethod || '').trim();
  return [
    `这道变化菜由「${variant.baseRecipeName}」调整而来：${changeText}。`,
    ...tips,
    baseMethod ? `原菜谱做法参考：${baseMethod}` : '按原菜的处理思路做，调味和火候根据替换食材微调。'
  ].join('\n');
}

export function getRecipeVariantRecommendations(pack = {}, inv = [], options = {}) {
  const limit = options.limit ?? 5;
  const perBaseLimit = options.perBaseLimit ?? 2;
  const invNames = getInventoryNames(inv);
  if (!invNames.length) return [];

  const existingNames = new Set((pack.recipes || []).map(recipe => normalizeText(recipe.name || '')).filter(Boolean));
  const targetNames = (options.targetNames || []).map(getCanonicalName).filter(Boolean);
  const scored = [];
  const seenNames = new Map();

  for (const recipe of pack.recipes || []) {
    if (!recipe || !recipe.id || !recipe.name) continue;
    const core = getCoreRows(pack, recipe);
    if (core.length < 2) continue;
    const baseHits = core.filter(item => hasInventoryMatch(invNames, item.item)).map(item => item.item);
    let madeForBase = 0;

    for (const missing of core.filter(item => !hasInventoryMatch(invNames, item.item))) {
      const candidates = findReplacementCandidates(missing.item, invNames);
      for (const replacement of candidates) {
        if (core.some(item => isSmartIngredientMatch(item.item, replacement.to))) continue;
        const finalCore = core.map(item => isSmartIngredientMatch(item.item, replacement.from)
          ? { ...item, item: replacement.to, name: replacement.to }
          : item);
        const finalHits = finalCore.filter(item => hasInventoryMatch(invNames, item.item)).map(item => item.item);
        if (baseHits.length < 1 && finalHits.length < 2) continue;
        if (targetNames.length && !targetNames.some(target => finalCore.some(item => isSmartIngredientMatch(target, item.item)))) continue;

        const name = buildVariantRecipeName(recipe.name, [replacement]);
        const nameKey = normalizeText(name);
        if (!nameKey || existingNames.has(nameKey)) continue;
        const score = finalHits.length * 50 + baseHits.length * 16 + (recipe.method ? 8 : 0);
        const previous = seenNames.get(nameKey);
        if (previous && previous.score >= score) continue;

        const variant = {
          id: `variant:${recipe.id}:${replacement.from}->${replacement.to}`,
          name,
          baseRecipeId: recipe.id,
          baseRecipeName: recipe.name,
          baseMethod: recipe.method || '',
          replacements: [replacement],
          ingredients: finalCore.map(item => ({
            item: item.item,
            qty: item.qty ?? '',
            unit: item.unit || guessKitchenUnit(item.item) || ''
          })),
          recipeIngredients: getAllRowsWithReplacement(pack, recipe, replacement),
          reason: `你有${formatNames(finalHits)}，可由${recipe.name}变化。`,
          sourceLabel: `变化菜 · 由 ${recipe.name} 改`,
          matchLabel: '变化菜',
          tone: 'variant',
          score,
          isVariant: true
        };
        variant.methodDraft = buildVariantMethodDraft(variant);
        seenNames.set(nameKey, variant);
        madeForBase++;
        if (madeForBase >= perBaseLimit) break;
      }
      if (madeForBase >= perBaseLimit) break;
    }
  }

  for (const variant of seenNames.values()) scored.push(variant);
  return scored
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name, 'zh-Hans-CN'))
    .slice(0, limit);
}

export function getGenericIngredientRecipeRecommendations(pack = {}, inv = [], options = {}) {
  const limit = options.limit ?? 3;
  const perIngredientLimit = options.perIngredientLimit ?? 2;
  const targetNames = (options.targetNames || []).map(getCanonicalName).filter(Boolean);
  const invNames = getInventoryNames(inv);
  if (!invNames.length || limit <= 0) return [];

  const existingNames = getExistingRecipeNameSet(pack, options.existingNames || []);
  const rows = getGenericTemplateInventoryItems(inv, targetNames);
  const results = [];
  const seen = new Set();

  for (const row of rows) {
    let madeForIngredient = 0;
    const templates = GENERIC_LEAFY_TEMPLATES
      .filter(template => (template.requires || []).every(name => hasInventoryMatch(invNames, name)))
      .sort((a, b) => b.priority - a.priority);

    for (const template of templates) {
      if (madeForIngredient >= perIngredientLimit || results.length >= limit) break;
      const card = buildGenericTemplateCard(row.name, template, row.score + template.priority);
      const nameKey = normalizeText(card.name);
      if (!nameKey || existingNames.has(nameKey) || seen.has(nameKey)) continue;
      seen.add(nameKey);
      results.push(card);
      madeForIngredient++;
    }
    if (results.length >= limit) break;
  }

  return results
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name, 'zh-Hans-CN'))
    .slice(0, limit);
}

export const buildRecipeVariantRecommendations = getRecipeVariantRecommendations;
export const buildGenericRecipeTemplateRecommendations = getGenericIngredientRecipeRecommendations;
