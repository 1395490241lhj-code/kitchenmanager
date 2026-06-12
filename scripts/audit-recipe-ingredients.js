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

function buildRecipeNameMap(...packs) {
  const map = new Map();
  for (const pack of packs) {
    if (!pack || typeof pack !== 'object') continue;
    const recipes = Array.isArray(pack.recipes)
      ? pack.recipes
      : Object.entries(pack.recipes || {}).map(([id, r]) => ({ id, ...(r || {}) }));
    for (const r of recipes) {
      const id = String((r && r.id) || '').trim();
      const name = String((r && r.name) || '').trim();
      if (id && name && !map.has(id)) map.set(id, name);
    }
  }
  return map;
}

function collectItems(label, ingredientsMap, out, recipeNames = new Map()) {
  if (!ingredientsMap || typeof ingredientsMap !== 'object') return;
  for (const [rid, list] of Object.entries(ingredientsMap)) {
    if (!Array.isArray(list)) continue;
    for (const it of list) {
      const name = String((it && (it.item || it.name)) || (typeof it === 'string' ? it : '')).trim();
      if (!name) continue;
      out.push({ name, source: label, recipeId: rid, recipeName: recipeNames.get(rid) || rid });
    }
  }
}

const COMPOSITE_DELIMITERS = [
  { label: '中文逗号', chars: new Set(['，']) },
  { label: '英文逗号', chars: new Set([',']) },
  { label: '顿号', chars: new Set(['、']) },
  { label: '分号', chars: new Set(['；', ';']) },
  { label: '斜杠', chars: new Set(['／', '/']) }
];
const COMPOSITE_DELIMITER_CHARS = new Set(COMPOSITE_DELIMITERS.flatMap(d => [...d.chars]));

function walkOutsideParens(text, onChar) {
  let depth = 0;
  for (const ch of String(text || '')) {
    if (ch === '（' || ch === '(') depth++;
    const outside = depth === 0;
    onChar(ch, outside);
    if ((ch === '）' || ch === ')') && depth > 0) depth--;
  }
}

function getCompositeDelimiterTypes(name) {
  const seen = new Set();
  walkOutsideParens(name, (ch, outside) => {
    if (!outside) return;
    for (const d of COMPOSITE_DELIMITERS) {
      if (d.chars.has(ch)) seen.add(d.label);
    }
  });
  return [...seen];
}

function splitCompositeIngredientName(name) {
  const parts = [];
  let buf = '';
  walkOutsideParens(name, (ch, outside) => {
    if (outside && COMPOSITE_DELIMITER_CHARS.has(ch)) {
      if (buf.trim()) parts.push(buf.trim());
      buf = '';
      return;
    }
    buf += ch;
  });
  if (buf.trim()) parts.push(buf.trim());
  return parts;
}

function detectCompositeIngredientItem(name, classifyIngredient = null) {
  const text = String(name || '').trim();
  const delimiterTypes = getCompositeDelimiterTypes(text);
  const parts = splitCompositeIngredientName(text);
  const fallback = {
    isComposite: false,
    name: text,
    delimiterType: delimiterTypes.join('、'),
    parts,
    role: classifyIngredient ? classifyIngredient(text).role : null,
    partRoles: []
  };
  if (!delimiterTypes.length || parts.length < 2) return fallback;

  const partRoles = classifyIngredient ? parts.map(part => classifyIngredient(part).role) : [];
  const meaningfulCount = partRoles.length
    ? partRoles.filter(role => role !== 'non-stock').length
    : parts.length;
  return {
    ...fallback,
    isComposite: meaningfulCount >= 2,
    role: classifyIngredient ? classifyIngredient(text).role : null,
    partRoles
  };
}

// 可疑量词形态：纯数字/「X克/两/勺」一类残留在 item 名里的写法。
const QUANTITY_LIKE_RE = /^[\d一二三四五六七八九十半]+(克|斤|两|勺|匙|杯|碗|毫升|升|g|ml)?$/i;
// seasoning 但名字含核心食材词 → 可能误杀。
const CORE_WORD_RE = /(豆腐|肉|菜|蛋|鱼|虾|菇|耳|笋|瓜|薯|藕|茄)/;

async function main() {
  const { classifyRecipeIngredient } = await import('../src/utils/recipe-sanitizer.js');
  const { buildCatalog } = await import('../src/ingredients.js');

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

  const recipeNames = buildRecipeNameMap(curated, full, overlay);
  const items = [];
  for (const [label, map] of sources) collectItems(label, map, items, recipeNames);

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

  const compositeSuspects = items
    .map(entry => ({ ...entry, composite: detectCompositeIngredientItem(entry.name, classifyRecipeIngredient) }))
    .filter(entry => entry.composite.isComposite);

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

  console.log('');
  console.log('Composite item check');
  console.log('--------------------');
  console.log(`Composite item suspects: ${compositeSuspects.length}`);
  for (const row of compositeSuspects) {
    const parts = row.composite.parts.join(' / ');
    console.log(`  - [${row.source}] ${row.recipeName} / ${row.recipeId}: ${row.name}（${row.composite.delimiterType}；${row.composite.role}；拆分候选：${parts}）`);
  }

  // ── Catalog leak check：buildCatalog 收进候选的名字必须全部是 core ──
  console.log('');
  console.log('Catalog leak check');
  console.log('------------------');
  const leaks = [];
  for (const [label, pack] of [['curated', curated], ['full', full]]) {
    if (!pack) continue;
    for (const entry of buildCatalog(pack)) {
      const { role, reason } = classifyRecipeIngredient(entry.name);
      if (role !== 'core') leaks.push({ source: label, name: entry.name, role, reason });
    }
  }
  console.log(`Catalog leaks: ${leaks.length}`);
  for (const l of leaks) console.log(`  - [${l.source}] ${l.name} → ${l.role}（${l.reason}）`);
}

if (require.main === module) {
  main().catch(err => {
    console.error(err);
    process.exitCode = 1;
  });
}

module.exports = {
  detectCompositeIngredientItem,
  splitCompositeIngredientName,
  getCompositeDelimiterTypes
};
