// 本地日期工具：所有"今天"和"日期加减"业务日期一律走本地时区，不用 UTC。
// new Date().toISOString() 取的是 UTC 日期——在负时区（如多伦多）晚上会提前跨到明天，
// 计划/做饭记录/临期/购买日期全部错一天。这里改用 getFullYear/getMonth/getDate（本地时间字段）。
export const todayISO = (date = new Date()) => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

// 把 "YYYY-MM-DD" 解析成本地日期（而不是 new Date('YYYY-MM-DD')，那样会按 UTC 午夜解析，
// 在非 UTC 时区里再配合本地 getter/setter 使用会产生偏差）。
export function parseLocalDate(iso) {
  const [year, month, day] = String(iso || '').split('-').map(Number);
  return new Date(year || 1970, (month || 1) - 1, day || 1);
}

// 基于本地日期做加减天数，返回本地 "YYYY-MM-DD"。setDate 按本地日历字段运算，
// 跨月/跨年/DST 边界都安全（不是按 86400000ms 累加）。
export function addDaysISO(iso, days = 0) {
  const date = parseLocalDate(iso);
  date.setDate(date.getDate() + (Number(days) || 0));
  return todayISO(date);
}

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
    prep_done: 'km_v1_prep_done',
    ai_disliked_recipes: 'km_v1_ai_disliked_recipes',
    demo_mode: 'km_demo_mode',
    demo_snapshot: 'km_demo_snapshot_v1',
    demo_step: 'km_demo_step_v1',
    backup_nudge_dismissed_at: 'km_backup_nudge_dismissed_at',
    backup_last_exported_at: 'km_backup_last_exported_at',
    pwa_install_dismissed_at: 'km_pwa_install_dismissed_at',
    pwa_install_done: 'km_pwa_install_done'
  }
};
