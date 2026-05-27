/**
 * src/recipe-completion.js
 *
 * Loads data/recipe-completion-overlay.json and merges it into the base pack
 * BEFORE the user's localStorage overlay is applied.
 *
 * Merge priority (highest wins):
 *   user localStorage overlay  >  completion overlay  >  base sichuan-recipes.json
 *
 * The completion overlay adds:
 *   - method / refined ingredients for 8 existing recipes
 *   - 58 new everyday Sichuan recipes (as proper recipe objects)
 *
 * This module never touches localStorage and never modifies the original JSON files.
 *
 * @param {Object} basePack  — result of loadBasePack() before user overlay
 * @returns {Object}          — enriched pack  { recipes, recipe_ingredients }
 */

/** Cache so we fetch only once per page load */
let _cached = null;

export async function applyCompletionOverlay(basePack) {
  // Fetch and cache the overlay JSON
  if (!_cached) {
    try {
      const url = new URL('./data/recipe-completion-overlay.json', location).href + '?v=1';
      const res = await fetch(url, { cache: 'force-cache' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      _cached = await res.json();
    } catch (e) {
      console.warn('[recipe-completion] Could not load overlay, skipping:', e.message);
      return basePack;
    }
  }

  const overlay = _cached;

  // Work on deep copies so we never mutate the original pack
  const recipes = basePack.recipes.map(r => ({ ...r }));
  const ingMap  = Object.fromEntries(
    Object.entries(basePack.recipe_ingredients || {}).map(([id, v]) => [id, v.slice()])
  );

  const existingIds   = new Set(recipes.map(r => r.id));
  const existingNames = new Set(recipes.map(r => r.name));

  // ── 1. Patch existing recipes (method + ingredients) ─────────────────────
  const recipePatches = overlay.recipes || {};
  for (const [id, patch] of Object.entries(recipePatches)) {
    const idx = recipes.findIndex(r => r.id === id);
    if (idx === -1) continue;
    // Only fill in method if the base recipe has none
    if (patch.method && !recipes[idx].method) {
      recipes[idx] = { ...recipes[idx], method: patch.method };
    }
  }

  const ingPatches = overlay.recipe_ingredients || {};
  for (const [id, list] of Object.entries(ingPatches)) {
    // Only overwrite if the existing entry is absent or coarse
    const existing = ingMap[id] || [];
    if (isCoarseOrEmpty(existing)) {
      ingMap[id] = list.slice();
    }
  }

  // ── 2. Add new recipes (skip if name already exists) ─────────────────────
  const newRecipes     = overlay.newRecipes || [];
  const newIngredients = overlay.newRecipeIngredients || {};

  for (const recipe of newRecipes) {
    if (existingIds.has(recipe.id) || existingNames.has(recipe.name)) continue;
    recipes.push({ ...recipe });
    if (newIngredients[recipe.id]) {
      ingMap[recipe.id] = newIngredients[recipe.id].slice();
    }
    existingIds.add(recipe.id);
    existingNames.add(recipe.name);
  }

  recipes.sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'));

  return { ...basePack, recipes, recipe_ingredients: ingMap };
}

/**
 * Returns true when the ingredient list is too sparse to be considered "fine":
 *   - empty / missing
 *   - single entry whose item contains a comma (comma-joined multi-ingredient string)
 *   - exactly 1 entry (single ingredient vs a 4–16-item completion list)
 */
function isCoarseOrEmpty(ings) {
  if (!Array.isArray(ings) || ings.length === 0) return true;
  if (ings.length === 1) {
    const item = String(ings[0].item || '');
    if (item.includes('，') || item.includes(',')) return true; // comma-joined string
    return true; // single ingredient is always coarse
  }
  return false; // ≥ 2 separate ingredient entries → fine
}
