function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function hasPackId(recipe, enabledPackIds) {
  const recipePacks = asArray(recipe && recipe.packs);
  return recipePacks.some((packId) => enabledPackIds.has(packId));
}

export function getRecipePacks(data) {
  return asArray(data && data.packs);
}

export function getRecipePackRecipes(data) {
  return asArray(data && data.recipes);
}

export function getDefaultEnabledRecipePackIds(data) {
  return getRecipePacks(data)
    .filter((pack) => pack && pack.defaultEnabled === true && typeof pack.id === 'string')
    .map((pack) => pack.id);
}

export function getRecipePackById(data, packId) {
  if (typeof packId !== 'string') return null;
  return getRecipePacks(data).find((pack) => pack && pack.id === packId) || null;
}

export function getRecipesByEnabledPacks(data, enabledPackIds) {
  if (!Array.isArray(enabledPackIds) || enabledPackIds.length === 0) return [];
  const enabled = new Set(enabledPackIds);
  return getRecipePackRecipes(data).filter((recipe) => hasPackId(recipe, enabled));
}

export function getRecipesGroupedByPack(data) {
  const groups = {};
  for (const pack of getRecipePacks(data)) {
    if (pack && typeof pack.id === 'string') {
      groups[pack.id] = [];
    }
  }

  // Only group recipes under pack ids declared in data.packs so unknown recipe pack ids
  // do not leak into future UI or settings surfaces.
  for (const recipe of getRecipePackRecipes(data)) {
    for (const packId of asArray(recipe && recipe.packs)) {
      if (Object.prototype.hasOwnProperty.call(groups, packId)) {
        groups[packId].push(recipe);
      }
    }
  }

  return groups;
}

export function normalizeRecipePackPreferenceIds(data, candidateIds) {
  if (!Array.isArray(candidateIds)) return [];

  const validPackIds = new Set(
    getRecipePacks(data)
      .map((pack) => pack && pack.id)
      .filter((packId) => typeof packId === 'string')
  );
  const seen = new Set();
  const out = [];

  for (const packId of candidateIds) {
    if (typeof packId !== 'string') continue;
    if (!validPackIds.has(packId) || seen.has(packId)) continue;
    seen.add(packId);
    out.push(packId);
  }

  return out;
}

export function getEnabledRecipePackIds(data, settings) {
  const hasSettingsObject = settings && typeof settings === 'object' && !Array.isArray(settings);
  if (!hasSettingsObject || !Object.prototype.hasOwnProperty.call(settings, 'enabledRecipePackIds')) {
    return getDefaultEnabledRecipePackIds(data);
  }

  // Missing/undefined means "use defaults"; [] means "user explicitly disabled all packs".
  if (settings.enabledRecipePackIds === undefined) {
    return getDefaultEnabledRecipePackIds(data);
  }

  if (!Array.isArray(settings.enabledRecipePackIds)) {
    return getDefaultEnabledRecipePackIds(data);
  }

  return normalizeRecipePackPreferenceIds(data, settings.enabledRecipePackIds);
}

export function createRecipePackSettingsPatch(data, enabledPackIds) {
  return {
    enabledRecipePackIds: normalizeRecipePackPreferenceIds(data, enabledPackIds)
  };
}

export function getRecipesForSettings(data, settings) {
  return getRecipesByEnabledPacks(data, getEnabledRecipePackIds(data, settings));
}

export function summarizeRecipePackData(data) {
  const groups = getRecipesGroupedByPack(data);
  const recipesByPackCount = {};
  for (const [packId, recipes] of Object.entries(groups)) {
    recipesByPackCount[packId] = recipes.length;
  }

  return {
    packCount: getRecipePacks(data).length,
    recipeCount: getRecipePackRecipes(data).length,
    defaultEnabledPackIds: getDefaultEnabledRecipePackIds(data),
    recipesByPackCount
  };
}
