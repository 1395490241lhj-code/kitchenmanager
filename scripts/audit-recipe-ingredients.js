/*
 * scripts/audit-recipe-ingredients.js —— 菜谱用料分类审阅报告（只读，不改任何 data 文件）。
 *
 * 扫描 curated / full / completion-overlay 三处的 recipe_ingredients（含 overlay 的
 * newRecipeIngredients），用 src/utils/recipe-sanitizer.js 的统一口径分类，输出：
 * 总数、core/seasoning/non-stock 计数、Top seasoning/non-stock、可疑项清单。
 *
 * 运行：node scripts/audit-recipe-ingredients.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

function loadJson(rel) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) {
    console.error(`! 解析失败 ${rel}: ${e.message}`);
    return null;
  }
}

function collectItems(label, ingredientsMap, out) {
  if (!ingredientsMap || typeof ingredientsMap !== 'object') return;
  for (const [rid, list] of Object.entries(ingredientsMap)) {
    if (!Array.isArray(list)) continue;
    for (const it of list) {
      const name = String((it && (it.item || it.name)) || (typeof it === 'string' ? it : '')).trim();
      if (!name) continue;
      out.push({ name, source: label, recipeId: rid });
    }
  }
}

// 可疑量词形态：纯数字/「X克/两/勺」一类残留在 item 名里的写法。
const QUANTITY_LIKE_RE = /^[\d一二三四五六七八九十半]+(克|斤|两|勺|匙|杯|碗|毫升|升|g|ml)?$/i;
// seasoning 但名字含核心食材词 → 可能误杀。
const CORE_WORD_RE = /(豆腐|肉|菜|蛋|鱼|虾|菇|耳|笋|瓜|薯|藕|茄)/;

(async () => {
  const { classifyRecipeIngredient } = await import('../src/utils/recipe-sanitizer.js');

  const sources = [];
  const curated = loadJson('data/sichuan-recipes.curated.json');
  if (curated) sources.push(['curated', curated.recipe_ingredients]);
  const full = loadJson('data/sichuan-recipes.json');
  if (full) sources.push(['full', full.recipe_ingredients]);
  const overlay = loadJson('data/recipe-completion-overlay.json');
  if (overlay) {
    sources.push(['overlay', overlay.recipe_ingredients]);
    sources.push(['overlay-new', overlay.newRecipeIngredients]);
  }

  const items = [];
  for (const [label, map] of sources) collectItems(label, map, items);

  const counts = { core: 0, seasoning: 0, 'non-stock': 0 };
  const byRoleName = { seasoning: new Map(), 'non-stock': new Map() };
  const suspicious = new Map(); // name -> { roles:Set, why:Set, n }

  const flag = (name, role, why) => {
    const cur = suspicious.get(name) || { role, why: new Set(), n: 0 };
    cur.why.add(why); cur.n++; cur.role = role;
    suspicious.set(name, cur);
  };

  for (const { name } of items) {
    const { role } = classifyRecipeIngredient(name);
    counts[role]++;
    if (byRoleName[role]) byRoleName[role].set(name, (byRoleName[role].get(name) || 0) + 1);

    if (role === 'core') {
      if (/[水汤汁]/.test(name) && !/^水发/.test(name) && !/(汤圆|汤面|汤粉|米粉|河粉|凉粉|粉丝|粉条|水果)/.test(name)) flag(name, role, '含 水/汤/汁');
      if (/适量|少许|若干|按需/.test(name)) flag(name, role, '含量词');
      if (name.length <= 1) flag(name, role, '单字名');
      if (name.includes('调料')) flag(name, role, '含「调料」');
      if (QUANTITY_LIKE_RE.test(name)) flag(name, role, '像数量词');
    } else if (role === 'seasoning') {
      if (CORE_WORD_RE.test(name) && !/(豆瓣|豆豉|腐乳|鱼露|虾皮|虾米|菜油|菜籽油)/.test(name)) flag(name, role, 'seasoning 含核心食材词');
    }
  }

  const top = (m, k = 10) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, k);

  console.log('Recipe Ingredient Audit');
  console.log('=======================');
  console.log(`Sources: ${sources.map(([l]) => l).join(', ')}`);
  console.log(`Total items: ${items.length}`);
  console.log(`Core: ${counts.core}`);
  console.log(`Seasoning: ${counts.seasoning}`);
  console.log(`Non-stock: ${counts['non-stock']}`);
  console.log('');
  console.log('Top seasoning:');
  for (const [n, c] of top(byRoleName.seasoning)) console.log(`  ${n} ${c}`);
  console.log('');
  console.log('Top non-stock:');
  for (const [n, c] of top(byRoleName['non-stock'])) console.log(`  ${n} ${c}`);
  console.log('');
  if (suspicious.size) {
    console.log(`Suspicious items (${suspicious.size}):`);
    const rows = [...suspicious.entries()].sort((a, b) => b[1].n - a[1].n);
    for (const [n, info] of rows) {
      console.log(`  - [${info.role}] ${n} ×${info.n}（${[...info.why].join('；')}）`);
    }
  } else {
    console.log('Suspicious items: 无 🎉');
  }
})();
