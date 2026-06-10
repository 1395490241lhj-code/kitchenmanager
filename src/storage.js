export const todayISO = () => new Date().toISOString().slice(0, 10);

export const S = {
  save(k, v) {
    try {
      localStorage.setItem(k, JSON.stringify(v));
      return true;
    } catch (e) {
      console.error('localStorage 保存失败', e);
      return false;
    }
  },
  load(k, d) {
    try {
      return JSON.parse(localStorage.getItem(k)) ?? d;
    } catch (e) {
      return d;
    }
  },
  keys: {
    schema_version: 'km_schema_version',
    inventory: 'km_v19_inventory',
    plan: 'km_v19_plan',
    overlay: 'km_v19_overlay',
    settings: 'km_v23_settings',
    ai_recs: 'km_v48_ai_recs',
    local_recs: 'km_v97_local_recs',
    rec_time: 'km_v97_rec_time',
    rec_signature: 'km_v97_rec_signature',
    favorite_recipes: 'km_v80_favorite_recipes',
    recipe_usage: 'km_v95_recipe_usage',
    recipe_activity: 'km_v2_recipe_activity',
    shopping_items: 'km_v87_shopping_items',
    staples: 'km_v1_staples',
    pantry_config: 'km_v1_pantry_config',
    prep_done: 'km_v1_prep_done'
  }
};
