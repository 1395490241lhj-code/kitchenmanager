function stableHash(value) {
  return value.split('').reduce((hash, char) => {
    hash = ((hash << 5) - hash) + char.charCodeAt(0);
    return hash & hash;
  }, 0);
}

/**
 * Merge the browser-loaded static method and HOC recipe sources into a base
 * pack. This is the same source merge used by app.js, exposed as a pure
 * function so runtime quality checks cannot silently drift from the app.
 */
export function mergeRecipeSources(pack, { staticMethods = {}, hocData = [] } = {}) {
  const recipes = Array.isArray(pack?.recipes)
    ? pack.recipes.map(recipe => ({ ...recipe }))
    : [];
  const recipeIngredients = Object.fromEntries(
    Object.entries(pack?.recipe_ingredients || {}).map(([id, list]) => [id, Array.isArray(list) ? list.slice() : list])
  );
  // Keep the exact name/hash semantics of the browser loader. Source files use
  // clean names today, but trimming here would silently change IDs for a future
  // source entry that intentionally contains surrounding whitespace.
  const existingNames = new Set(recipes.map(recipe => recipe?.name));

  for (const name of Object.keys(staticMethods || {})) {
    const sourceName = String(name || '');
    if (!sourceName || existingNames.has(sourceName)) continue;
    recipes.push({
      id: `static-${Math.abs(stableHash(sourceName))}`,
      name: sourceName,
      tags: ['家常菜', '新增']
    });
    existingNames.add(sourceName);
  }

  for (const item of Array.isArray(hocData) ? hocData : []) {
    const name = String(item?.name || '');
    if (!name || existingNames.has(name)) continue;
    const id = `hoc-${Math.abs(stableHash(name))}`;
    recipes.push({
      id,
      name,
      tags: item.tags || ['家常菜'],
      staticMethod: item.method
    });
    if (Array.isArray(item.ingredients)) {
      recipeIngredients[id] = item.ingredients.map(itemName => ({ item: itemName, qty: null, unit: null }));
    }
    existingNames.add(name);
  }

  return { ...pack, recipes, recipe_ingredients: recipeIngredients };
}

/**
 * Merge the browser-loaded static recipe methods into an already enriched pack.
 *
 * The completion overlay must run first so a reviewed completion method wins
 * over the lower-priority static source. User localStorage overlay is applied
 * by app.js after this function returns.
 */
export function mergeRecipeMethods(pack, staticMethods = {}) {
  const recipes = Array.isArray(pack?.recipes)
    ? pack.recipes.map(recipe => ({ ...recipe }))
    : [];
  const recipeIngredients = pack?.recipe_ingredients || {};
  const names = new Map(
    recipes.map((recipe, index) => [String(recipe?.name || '').trim(), index])
  );
  const ids = new Set(recipes.map(recipe => recipe?.id).filter(Boolean));

  for (const [rawName, rawMethod] of Object.entries(staticMethods || {})) {
    const name = String(rawName || '').trim();
    const method = String(rawMethod || '').trim();
    if (!name || !method) continue;

    const existingIndex = names.get(name);
    if (existingIndex !== undefined) {
      const existing = recipes[existingIndex];
      if (!String(existing?.method || '').trim()) {
        recipes[existingIndex] = { ...existing, method };
      }
      continue;
    }

    const hash = name.split('').reduce((value, char) => {
      value = ((value << 5) - value) + char.charCodeAt(0);
      return value & value;
    }, 0);
    const baseId = `static-${Math.abs(hash)}`;
    let id = baseId;
    let suffix = 2;
    while (ids.has(id)) {
      id = `${baseId}-${suffix}`;
      suffix += 1;
    }

    recipes.push({
      id,
      name,
      tags: ['家常菜', '新增'],
      method
    });
    ids.add(id);
    names.set(name, recipes.length - 1);
  }

  return {
    ...pack,
    recipes,
    recipe_ingredients: recipeIngredients
  };
}
