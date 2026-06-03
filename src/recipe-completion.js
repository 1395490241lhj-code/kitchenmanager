/**
 * src/recipe-completion.js
 *
 * Loads data/recipe-completion-overlay.json and merges it into the base pack
 * BEFORE the user's localStorage overlay is applied.
 *
 * Merge priority (highest wins):
 *   user localStorage overlay  >  completion overlay  >  base sichuan-recipes.json
 *
 * The completion overlay supports four merge actions, applied in order:
 *
 *   1. patchById   — overlay.recipes[id] patches an existing recipe by exact id.
 *                    Only fills method if the base recipe has none.
 *   2. patchIngById — overlay.recipe_ingredients[id] refines ingredient lists
 *                    that are absent or coarse in the base pack.
 *   3. patchByName — overlay.newRecipes entries whose name already exists in base
 *                    (but with a different id) are treated as name-based patches:
 *                    the existing recipe gets the completion method/ingredients
 *                    back-filled under its own id (no duplicate is created).
 *   4. addNew      — overlay.newRecipes entries whose id AND name are both absent
 *                    from the base pack are appended as brand-new recipes.
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
      const url = new URL('./data/recipe-completion-overlay.json', location).href + '?v=204';
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

  // Build lookup structures — use trimmed name for matching
  const existingIds    = new Set(recipes.map(r => r.id));
  const nameToIdx      = new Map(recipes.map((r, i) => [String(r.name || '').trim(), i]));

  // Counters for diagnostics
  let patchById       = 0;
  let patchIngById    = 0;
  let patchByName     = 0;
  let addedNewRecipes = 0;
  let skippedDuplicate = 0;

  // ── 1. Patch existing recipes by id (method only) ─────────────────────────
  const recipePatches = overlay.recipes || {};
  for (const [id, patch] of Object.entries(recipePatches)) {
    const idx = recipes.findIndex(r => r.id === id);
    if (idx === -1) continue;
    // Only fill in method if the base recipe has none
    if (patch.method && !recipes[idx].method && !recipes[idx].staticMethod) {
      recipes[idx] = { ...recipes[idx], method: patch.method };
      patchById++;
    }
  }

  // ── 2. Patch existing ingredient lists by id ───────────────────────────────
  const ingPatches = overlay.recipe_ingredients || {};
  for (const [id, list] of Object.entries(ingPatches)) {
    const existing = ingMap[id] || [];
    if (isCoarseOrEmpty(existing)) {
      ingMap[id] = list.slice();
      patchIngById++;
    }
  }

  // ── 3 & 4. Process newRecipes ──────────────────────────────────────────────
  const newRecipes     = overlay.newRecipes || [];
  const newIngredients = overlay.newRecipeIngredients || {};

  for (const recipe of newRecipes) {
    const trimmedName = String(recipe.name || '').trim();

    if (existingIds.has(recipe.id)) {
      // The completion overlay id collides with a base id — already patched
      // above via recipePatches; nothing more to do.
      skippedDuplicate++;
      continue;
    }

    if (nameToIdx.has(trimmedName)) {
      // ── 3. PATCH BY NAME ─────────────────────────────────────────────────
      // A recipe with this name already exists in base but has a different id.
      // Back-fill missing method and/or ingredients under the existing recipe's id.
      const idx        = nameToIdx.get(trimmedName);
      const existingId = recipes[idx].id;

      // Back-fill method if the existing recipe has none
      if (recipe.method && !recipes[idx].method && !recipes[idx].staticMethod) {
        recipes[idx] = { ...recipes[idx], method: recipe.method };
        patchByName++;
      }

      // Back-fill ingredients if absent or coarse under the existing id
      const existingIng = ingMap[existingId] || [];
      if (isCoarseOrEmpty(existingIng) && newIngredients[recipe.id]) {
        ingMap[existingId] = newIngredients[recipe.id].slice();
        patchByName++;
      }

      // Never create a duplicate entry
      continue;
    }

    // ── 4. ADD NEW RECIPE ───────────────────────────────────────────────────
    recipes.push({ ...recipe });
    if (newIngredients[recipe.id]) {
      ingMap[recipe.id] = newIngredients[recipe.id].slice();
    }
    existingIds.add(recipe.id);
    nameToIdx.set(trimmedName, recipes.length - 1);
    addedNewRecipes++;
  }

  console.debug(
    `[recipe-completion] patchById=${patchById} patchIngById=${patchIngById}` +
    ` patchByName=${patchByName} addedNew=${addedNewRecipes} skipped=${skippedDuplicate}`
  );

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

