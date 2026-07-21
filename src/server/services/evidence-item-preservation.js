'use strict';

const MAX_EVIDENCE_INPUT_ITEMS_PER_CATEGORY = 128;
const MAX_PRESERVED_ITEMS_PER_CATEGORY = 32;
const MAX_TOTAL_PRESERVED_ITEMS = 48;
const MAX_EVIDENCE_ITEM_CODEPOINTS = 80;
const MAX_TOTAL_PRESERVED_NAME_CODEPOINTS = 2048;
const UNSAFE_NAME_CHARACTERS_RE = /[\p{Cc}\p{Cf}]/gu;

function cleanName(value) {
  if (typeof value !== 'string') return '';
  return value
    .normalize('NFKC')
    .replace(UNSAFE_NAME_CHARACTERS_RE, '')
    .trim()
    .replace(/\s+/gu, ' ')
    .trim();
}

function normalizeItemName(value) {
  return cleanName(value).toLowerCase();
}

function getSafeInputCount(values) {
  if (!Array.isArray(values)) return 0;
  return Number.isSafeInteger(values.length) && values.length >= 0 ? values.length : 0;
}

function collectEvidenceItems(values, diagnostics) {
  const inputCount = getSafeInputCount(values);
  const checkedCount = Math.min(inputCount, MAX_EVIDENCE_INPUT_ITEMS_PER_CATEGORY);
  diagnostics.evidenceItemCheckedCount += checkedCount;
  if (inputCount > checkedCount) {
    diagnostics.evidenceItemRejectedOverLimitCount += inputCount - checkedCount;
    diagnostics.evidenceItemLimitApplied = true;
  }

  const items = [];
  const seen = new Set();
  for (let index = 0; index < checkedCount; index += 1) {
    const item = cleanName(values[index]);
    if (!item) {
      diagnostics.evidenceItemRejectedInvalidCount += 1;
      continue;
    }
    const codepointCount = Array.from(item).length;
    if (codepointCount > MAX_EVIDENCE_ITEM_CODEPOINTS) {
      diagnostics.evidenceItemRejectedTooLongCount += 1;
      continue;
    }
    const key = item.toLowerCase();
    if (seen.has(key)) {
      diagnostics.evidenceItemRejectedDuplicateCount += 1;
      continue;
    }
    seen.add(key);
    items.push({ item, key, codepointCount });
  }
  return items;
}

function getRecipeItemName(value) {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  if (typeof value.item === 'string') return value.item;
  if (typeof value.name === 'string') return value.name;
  return '';
}

function createDiagnostics(evidence) {
  return {
    evidenceMainIngredientInputCount: getSafeInputCount(evidence?.observedMainIngredients),
    evidenceSeasoningInputCount: getSafeInputCount(evidence?.observedSeasonings),
    evidenceMainIngredientCount: 0,
    evidenceSeasoningCount: 0,
    evidenceItemCheckedCount: 0,
    evidenceItemRejectedInvalidCount: 0,
    evidenceItemRejectedTooLongCount: 0,
    evidenceItemRejectedDuplicateCount: 0,
    evidenceItemRejectedOverLimitCount: 0,
    evidenceItemLimitApplied: false,
    preservedNameCodepointCount: 0,
    sanitizedIngredientCountBeforePreservation: 0,
    sanitizedSeasoningCountBeforePreservation: 0,
    preservedMainIngredientCount: 0,
    preservedSeasoningCount: 0,
    finalIngredientCount: 0,
    finalSeasoningCount: 0,
    finalModelOmittedEvidenceItems: false
  };
}

function preserveEvidenceItemsInRecipe(recipe, evidence = {}) {
  const diagnostics = createDiagnostics(evidence);
  const mainItems = collectEvidenceItems(evidence?.observedMainIngredients, diagnostics);
  const seasoningItems = collectEvidenceItems(evidence?.observedSeasonings, diagnostics);
  diagnostics.evidenceMainIngredientCount = mainItems.length;
  diagnostics.evidenceSeasoningCount = seasoningItems.length;

  if (!recipe || typeof recipe !== 'object' || Array.isArray(recipe)) {
    return { recipe, diagnostics };
  }

  const sourceIngredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  const sourceSeasonings = Array.isArray(recipe?.seasonings) ? recipe.seasonings : [];
  diagnostics.sanitizedIngredientCountBeforePreservation = sourceIngredients.length;
  diagnostics.sanitizedSeasoningCountBeforePreservation = sourceSeasonings.length;

  const existingNames = new Set(
    [...sourceIngredients, ...sourceSeasonings]
      .map(getRecipeItemName)
      .map(normalizeItemName)
      .filter(Boolean)
  );
  const addedIngredients = [];
  const addedSeasonings = [];
  let totalAddedCount = 0;
  let totalNameCodepointCount = 0;
  let globalLimitReached = false;

  function appendEvidenceItems(items, target) {
    let categoryAddedCount = 0;
    let categoryLimitReached = false;
    for (const entry of items) {
      if (globalLimitReached || categoryLimitReached) {
        diagnostics.evidenceItemRejectedOverLimitCount += 1;
        diagnostics.evidenceItemLimitApplied = true;
        continue;
      }
      if (existingNames.has(entry.key)) {
        diagnostics.evidenceItemRejectedDuplicateCount += 1;
        continue;
      }
      if (categoryAddedCount >= MAX_PRESERVED_ITEMS_PER_CATEGORY) {
        categoryLimitReached = true;
        diagnostics.evidenceItemRejectedOverLimitCount += 1;
        diagnostics.evidenceItemLimitApplied = true;
        continue;
      }
      if (
        totalAddedCount >= MAX_TOTAL_PRESERVED_ITEMS
        || totalNameCodepointCount + entry.codepointCount > MAX_TOTAL_PRESERVED_NAME_CODEPOINTS
      ) {
        globalLimitReached = true;
        diagnostics.evidenceItemRejectedOverLimitCount += 1;
        diagnostics.evidenceItemLimitApplied = true;
        continue;
      }
      existingNames.add(entry.key);
      target.push({ item: entry.item, qty: '', unit: '' });
      categoryAddedCount += 1;
      totalAddedCount += 1;
      totalNameCodepointCount += entry.codepointCount;
    }
  }

  appendEvidenceItems(mainItems, addedIngredients);
  appendEvidenceItems(seasoningItems, addedSeasonings);

  diagnostics.preservedNameCodepointCount = totalNameCodepointCount;
  diagnostics.preservedMainIngredientCount = addedIngredients.length;
  diagnostics.preservedSeasoningCount = addedSeasonings.length;
  diagnostics.finalIngredientCount = sourceIngredients.length + addedIngredients.length;
  diagnostics.finalSeasoningCount = sourceSeasonings.length + addedSeasonings.length;
  diagnostics.finalModelOmittedEvidenceItems = totalAddedCount > 0;

  const preservedRecipe = totalAddedCount === 0
    ? recipe
    : {
        ...recipe,
        ingredients: [...sourceIngredients, ...addedIngredients],
        seasonings: [...sourceSeasonings, ...addedSeasonings]
      };

  return { recipe: preservedRecipe, diagnostics };
}

module.exports = {
  preserveEvidenceItemsInRecipe
};
