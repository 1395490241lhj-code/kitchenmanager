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
