export const RECIPE_QUANTITY_SEMANTICS_SCHEMA = 'kitchenmanager.recipe-quantity-semantics.v1';

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const isPositiveFinite = (value) => Number.isFinite(Number(value)) && Number(value) > 0;

export function validateRecipeQuantitySemantics(sidecar, basePack) {
  const problems = [];
  const joins = [];
  const fail = (code, key = '') => problems.push(key ? `${code}:${key}` : code);

  if (!isObject(sidecar)) return { valid: false, problems: ['sidecar-not-object'], joins };
  if (sidecar.schema !== RECIPE_QUANTITY_SEMANTICS_SCHEMA) fail('invalid-schema');
  if (!isObject(sidecar.recipes)) return { valid: false, problems: [...problems, 'recipes-not-object'], joins };
  if (!isObject(basePack) || !Array.isArray(basePack.recipes) || !isObject(basePack.recipe_ingredients)) {
    return { valid: false, problems: [...problems, 'base-pack-malformed'], joins };
  }

  const recipeIds = new Set(basePack.recipes.map((recipe) => recipe?.id).filter(Boolean));
  for (const [recipeId, recipeSemantics] of Object.entries(sidecar.recipes)) {
    if (/^\d+$/.test(recipeId)) fail('array-index-recipe-key', recipeId);
    if (!recipeIds.has(recipeId)) fail('orphan-recipe', recipeId);
    if (!isObject(recipeSemantics) || !isObject(recipeSemantics.ingredients)) {
      fail('ingredients-not-object', recipeId);
      continue;
    }
    const baseIngredients = basePack.recipe_ingredients[recipeId];
    if (!Array.isArray(baseIngredients)) fail('missing-base-ingredient-map', recipeId);

    for (const [item, semantics] of Object.entries(recipeSemantics.ingredients)) {
      const key = `${recipeId}:${item}`;
      if (/^\d+$/.test(item)) fail('array-index-item-key', key);
      const matches = Array.isArray(baseIngredients)
        ? baseIngredients.filter((ingredient) => ingredient?.item === item)
        : [];
      if (matches.length === 0) fail('orphan-item', key);
      if (matches.length > 1) fail('duplicate-base-item', key);
      if (!isObject(semantics)) {
        fail('entry-not-object', key);
        continue;
      }

      const input = semantics.input;
      const consumed = semantics.consumed;
      if (!isObject(input) || !isPositiveFinite(input.qty) || typeof input.unit !== 'string' || !input.unit.trim()) {
        fail('invalid-input', key);
      }
      if (matches.length === 1 && isObject(input)) {
        if (!isPositiveFinite(matches[0].qty)
          || Number(matches[0].qty) !== Number(input.qty)
          || String(matches[0].unit || '') !== input.unit) {
          fail('input-base-mismatch', key);
        }
      }

      if (!isObject(consumed) || typeof consumed.unit !== 'string' || !consumed.unit.trim()) {
        fail('invalid-consumed', key);
      } else if (consumed.qty !== null) {
        if (!isPositiveFinite(consumed.qty)
          || consumed.referenceQty !== null
          || consumed.qualifier !== null) {
          fail('invalid-exact-consumed', key);
        }
      } else if (!isPositiveFinite(consumed.referenceQty)
        || typeof consumed.qualifier !== 'string'
        || !consumed.qualifier.trim()) {
        fail('invalid-approximate-consumed', key);
      }

      if (typeof semantics.rawQuantityText !== 'string' || !semantics.rawQuantityText.trim()) {
        fail('invalid-raw-quantity-text', key);
      }
      const provenance = semantics.provenance;
      if (!isObject(provenance)
        || typeof provenance.sourceId !== 'string' || !provenance.sourceId.trim()
        || provenance.entryId !== recipeId
        || !Number.isInteger(provenance.pdfPage) || provenance.pdfPage <= 0
        || !Number.isInteger(provenance.bookPage) || provenance.bookPage <= 0) {
        fail('invalid-provenance', key);
      }
      if (matches.length === 1) joins.push({ recipeId, item });
    }
  }
  return { valid: problems.length === 0, problems, joins };
}

export function assertValidRecipeQuantitySemantics(sidecar, basePack) {
  const result = validateRecipeQuantitySemantics(sidecar, basePack);
  if (!result.valid) throw new Error(`invalid recipe quantity semantics: ${result.problems.join(', ')}`);
  return result;
}
