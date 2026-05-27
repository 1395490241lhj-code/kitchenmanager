#!/usr/bin/env node
/**
 * build-recipe-overlay.js
 *
 * Merges data/dazhong_chuancai_recipe_completion_pack.v1.json into
 * data/recipe-completion-overlay.json — a safe, additive overlay that
 * supplements the base sichuan-recipes.json WITHOUT modifying it.
 *
 * Overlay schema (compatible with src/backup.js applyOverlay):
 * {
 *   version: 1,
 *   source: "dazhong_chuancai_recipe_completion_pack.v1",
 *   createdAt: "<ISO>",
 *   recipes:              { [id]: { name, tags, method?, ...patch } }
 *   recipe_ingredients:   { [id]: [ { item, qty, unit } ] }
 *   newRecipes:           [ { id, name, tags, method? } ]
 *   newRecipeIngredients: { [id]: [ { item, qty, unit } ] }
 * }
 *
 * Logic:
 *   1. Load base pack + completion pack
 *   2. For each completion entry:
 *      a. Exact name match → base recipe found
 *      b. Alias match / strip-parens match → base recipe found
 *      c. No match → treat as NEW recipe, assign deterministic ID
 *   3. For matched recipes:
 *      - If no method in base → add method to overlay patches
 *      - If ingredients are coarse (single-item comma list or only 1 ingredient)
 *        AND completion has >1 ingredient → replace in overlay
 *      - If ingredients are already fine (≥2 separate items) → SKIP (conflict)
 *   4. Write overlay JSON + print summary
 *
 * Usage:  node scripts/build-recipe-overlay.js
 */

'use strict';
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');

// ── Paths ────────────────────────────────────────────────────────────────────
const ROOT        = path.resolve(__dirname, '..');
const BASE_FILE   = path.join(ROOT, 'data', 'sichuan-recipes.json');
const COMP_FILE   = path.join(ROOT, 'data', 'dazhong_chuancai_recipe_completion_pack.v1.json');
const OUT_FILE    = path.join(ROOT, 'data', 'recipe-completion-overlay.json');

// ── Load ─────────────────────────────────────────────────────────────────────
const base = JSON.parse(fs.readFileSync(BASE_FILE, 'utf8'));
const comp = JSON.parse(fs.readFileSync(COMP_FILE, 'utf8'));

if (!base.recipes || !Array.isArray(base.recipes)) {
  console.error('ERROR: base file has no recipes array'); process.exit(1);
}
if (!comp.entries || !Array.isArray(comp.entries)) {
  console.error('ERROR: completion pack has no entries array'); process.exit(1);
}

const baseIngredients = base.recipe_ingredients || {};

// ── Helpers ───────────────────────────────────────────────────────────────────
function stripParens(s) {
  return s.replace(/[（(][^）)]*[）)]/g, '').trim();
}

/** Returns true when the existing ingredients list is "coarse":
 *  - single entry whose item string contains full-width or half-width comma
 *  - or exactly 1 entry with no comma (single ingredient — too sparse)
 */
function isCoarse(ings) {
  if (!Array.isArray(ings) || ings.length === 0) return true;
  if (ings.length === 1) {
    const item = String(ings[0].item || '');
    if (item.includes('，') || item.includes(',')) return true; // comma-joined
    return true; // single ingredient is always "too coarse" vs a 4–14-item list
  }
  return false; // 2+ separate items → consider fine
}

/** Deterministic ID from name — same algorithm used in app.js for hoc/static recipes */
function deterministicId(name) {
  const h = name.split('').reduce((a, c) => {
    a = ((a << 5) - a) + c.charCodeAt(0); return a & a;
  }, 0);
  return 'comp-' + Math.abs(h).toString(16).padStart(8, '0');
}

/** Normalise a completion ingredient to the shape used in recipe_ingredients */
function normIngredient(ing) {
  return { item: (ing.item || '').trim(), qty: ing.qty ?? null, unit: ing.unit ?? null };
}

// ── Build name → recipe map (base pack) ──────────────────────────────────────
const nameToRecipe = new Map(); // canonical name → recipe object
for (const r of base.recipes) {
  nameToRecipe.set(r.name, r);
  const stripped = stripParens(r.name);
  if (stripped !== r.name && !nameToRecipe.has(stripped)) nameToRecipe.set(stripped, r);
}

// ── Counters & output containers ─────────────────────────────────────────────
const overlay = {
  version: 1,
  schema:  'kitchenmanager.recipeCompletionOverlay.v1',
  source:  'dazhong_chuancai_recipe_completion_pack.v1',
  createdAt: new Date().toISOString(),
  // Patches for existing recipes
  recipes:              {},   // id → { method? }
  recipe_ingredients:   {},   // id → [ { item, qty, unit } ]
  // New recipes to append
  newRecipes:           [],
  newRecipeIngredients: {},
};

const report = {
  matchedExact:       [],
  matchedAlias:       [],
  matchedStripParens: [],
  skippedIngredients: [],   // fine ingredients, not replaced
  newRecipes:         [],
};

// ── Process each completion entry ─────────────────────────────────────────────
for (const entry of comp.entries) {
  const name      = (entry.name || '').trim();
  const method    = (entry.method || '').trim();
  const compIngs  = (entry.ingredients || []).map(normIngredient).filter(i => i.item);
  const aliases   = entry.aliases || [];

  // ── Step 1: find base recipe ─────────────────────────────────────────────
  let baseRecipe = null;
  let matchType  = null;

  if (nameToRecipe.has(name)) {
    baseRecipe = nameToRecipe.get(name);
    matchType  = 'exact';
  }

  if (!baseRecipe) {
    for (const alias of aliases) {
      if (nameToRecipe.has(alias)) {
        baseRecipe = nameToRecipe.get(alias);
        matchType  = 'alias';
        break;
      }
    }
  }

  if (!baseRecipe) {
    const stripped = stripParens(name);
    if (stripped !== name && nameToRecipe.has(stripped)) {
      baseRecipe = nameToRecipe.get(stripped);
      matchType  = 'stripParens';
    }
  }

  // ── Step 2a: MATCHED — patch existing recipe ─────────────────────────────
  if (baseRecipe) {
    const id          = baseRecipe.id;
    const hasMethod   = !!(baseRecipe.method && baseRecipe.method.trim());
    const existingIngs = baseIngredients[id] || [];
    const coarse      = isCoarse(existingIngs);

    let patched = false;

    // Supplement method if missing from base
    if (!hasMethod && method) {
      overlay.recipes[id] = overlay.recipes[id] || {};
      overlay.recipes[id].method = method;
      patched = true;
    }

    // Supplement ingredients if coarse AND completion has a richer list
    if (coarse && compIngs.length > existingIngs.length) {
      overlay.recipe_ingredients[id] = compIngs;
      patched = true;
    } else if (!coarse) {
      report.skippedIngredients.push({ name, id, reason: `existing has ${existingIngs.length} items (fine)` });
    }

    const matchRecord = { name, id: baseRecipe.id, matchType, patchedMethod: !hasMethod && !!method, patchedIngs: coarse && compIngs.length > existingIngs.length };
    if (matchType === 'exact')       report.matchedExact.push(matchRecord);
    else if (matchType === 'alias')  report.matchedAlias.push(matchRecord);
    else                             report.matchedStripParens.push(matchRecord);
    continue;
  }

  // ── Step 2b: UNMATCHED — add as new recipe ───────────────────────────────
  const newId = deterministicId(name);
  const newRecipe = {
    id:   newId,
    name: name,
    tags: inferTags(name, compIngs),
  };
  if (method) newRecipe.method = method;

  overlay.newRecipes.push(newRecipe);
  if (compIngs.length > 0) overlay.newRecipeIngredients[newId] = compIngs;

  report.newRecipes.push({ name, id: newId, ingCount: compIngs.length, hasMethod: !!method });
}

// ── Tag inference for new recipes ─────────────────────────────────────────────
function inferTags(name, ings) {
  const tags = ['家常菜'];
  const allText = name + ' ' + ings.map(i => i.item).join(' ');
  if (/猪|肉丝|肉片|排骨|肘子|五花|腊肉|肥肠|丸子|猪肝|腰花|白肉/.test(allText)) tags.push('猪肉');
  if (/牛肉|牛/.test(allText) && !/牛奶/.test(allText)) tags.push('牛肉');
  if (/鸡蛋|鸡|鸭/.test(name)) tags.push('禽蛋');
  if (/鱼|虾|蟹|海/.test(name)) tags.push('海鲜');
  if (/豆腐|豆/.test(name)) tags.push('素菜');
  if (/蒸|蒸肉|荷叶|粉蒸/.test(name)) tags.push('蒸菜');
  if (/红烧|卤|炖|煨|焖/.test(name)) tags.push('红烧');
  if (/炒|爆|煸/.test(name)) tags.push('快炒');
  if (/汤|煮|丸子汤/.test(name)) tags.push('汤羹');
  if (/拌|凉/.test(name)) tags.push('凉菜');
  if (/糖醋|甜/.test(name)) tags.push('糖醋');
  if (/麻辣|辣|豆瓣|泡椒|花椒|宫保/.test(allText)) tags.push('麻辣');
  if (/鱼香/.test(name)) tags.push('鱼香');
  return [...new Set(tags)];
}

// ── Write overlay JSON ────────────────────────────────────────────────────────
fs.writeFileSync(OUT_FILE, JSON.stringify(overlay, null, 2), 'utf8');

// ── Print report ──────────────────────────────────────────────────────────────
const allMatched = [...report.matchedExact, ...report.matchedAlias, ...report.matchedStripParens];
console.log('\n══════════════════════════════════════════════════');
console.log('  Recipe Completion Overlay Build Report');
console.log('══════════════════════════════════════════════════');
console.log(`  Base recipes:        ${base.recipes.length}`);
console.log(`  Completion entries:  ${comp.entries.length}`);
console.log('');
console.log(`  ✅ Matched (existing recipes patched): ${allMatched.length}`);
console.log(`     • Exact name match:    ${report.matchedExact.length}`);
console.log(`     • Alias match:         ${report.matchedAlias.length}`);
console.log(`     • Strip-parens match:  ${report.matchedStripParens.length}`);
console.log('');
if (allMatched.length) {
  console.log('  Matched detail:');
  for (const m of allMatched) {
    const flags = [];
    if (m.patchedMethod) flags.push('+method');
    if (m.patchedIngs)   flags.push('+ingredients');
    if (!flags.length)   flags.push('(no change needed)');
    console.log(`    ${m.name.padEnd(18)} [${m.id}]  ${flags.join(', ')}`);
  }
  console.log('');
}

if (report.skippedIngredients.length) {
  console.log(`  ⏭  Skipped ingredient replacement (already fine): ${report.skippedIngredients.length}`);
  for (const s of report.skippedIngredients) {
    console.log(`    ${s.name.padEnd(18)} ${s.reason}`);
  }
  console.log('');
}

console.log(`  🆕 New recipes added to overlay: ${report.newRecipes.length}`);
if (report.newRecipes.length) {
  for (const n of report.newRecipes) {
    console.log(`    ${n.name.padEnd(18)} [${n.id}]  ings:${n.ingCount}  method:${n.hasMethod ? 'yes' : 'no'}`);
  }
  console.log('');
}

console.log(`  📄 Overlay written to: ${OUT_FILE}`);
console.log('══════════════════════════════════════════════════\n');
