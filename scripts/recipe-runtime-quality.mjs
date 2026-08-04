#!/usr/bin/env node

/**
 * Runtime recipe quality audit.
 *
 * This module intentionally builds the same no-user-overlay chain used by the
 * browser: base pack -> static/HOC sources -> completion overlay -> static
 * method fallback -> empty localStorage overlay. It is a report by default;
 * --strict exits non-zero when the declared hard errors are present.
 */

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import vm from 'node:vm';

import { mergeRecipeMethods, mergeRecipeSources } from '../src/recipe-library.js';
import { applyCompletionOverlay, resetCompletionOverlayCache } from '../src/recipe-completion.js';
import { applyOverlay } from '../src/backup.js';
import { splitMethodSteps } from '../src/utils/method-steps.js';
import {
  INGREDIENT_ALIASES,
  getCanonicalName,
  getIngredientMatchNames,
  isRecipeNonCoreName,
  isSeasoning,
  isSmartIngredientMatch
} from '../src/ingredients.js';

export const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const BASELINE_PATH = join(ROOT_DIR, 'data', 'recipe-runtime-baseline.json');
export const MANIFEST_PATH = join(ROOT_DIR, 'data', 'recipe-runtime-curated-missing-manifest.json');

const LIBRARY_FILES = {
  curated: join(ROOT_DIR, 'data', 'sichuan-recipes.curated.json'),
  full: join(ROOT_DIR, 'data', 'sichuan-recipes.json')
};

const EMPTY_LOCAL_OVERLAY = {
  version: 1,
  recipes: {},
  recipe_ingredients: {},
  deletes: {}
};

const GENERIC_INGREDIENTS = new Set([
  '配菜', '时蔬', '蔬菜', '绿叶菜', '杂粮', '杂粮饭', '调料', '调味料', '调味汁',
  '酱料', '汤料', '汤底', '高汤', '老鸡汤', '牛肉面汤料', '卤料', '卤油', '火锅底料',
  '清油火锅底料', '面胚', '半成品', '配料', '食材', '适量', '少许', '若干'
]);

const GENERIC_INGREDIENT_RE = /^(?:各式|时令|应季)?(?:蔬菜|青菜|配菜|调味|酱料|汤底|汤料|食材|配料)$/;

// Deliberately small, high-confidence terms. This is an explainable heuristic,
// not a claim that every method must repeat every ingredient.
const STRONG_INGREDIENT_TERMS = [
  '猪肉馅', '牛肉馅', '鸡肉馅', '虾仁', '鸡蛋', '排骨', '牛腩', '五花肉', '瘦肉',
  '番茄', '土豆', '白萝卜', '青椒', '豆腐', '鱼片', '鸡腿', '鸡翅', '香菇', '木耳'
];

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

export function readJson(relativePath) {
  return JSON.parse(readFileSync(join(ROOT_DIR, relativePath), 'utf8'));
}

export function loadWindowGlobal(relativePath, key) {
  const context = { window: {} };
  vm.createContext(context);
  vm.runInContext(readFileSync(join(ROOT_DIR, relativePath), 'utf8'), context, {
    filename: relativePath
  });
  return context.window[key];
}

export function loadRuntimeSources() {
  return {
    staticMethods: loadWindowGlobal('data/recipe-methods.js', 'RECIPE_METHODS') || {},
    hocData: loadWindowGlobal('data/hoc-recipes.js', 'HOC_DATA') || [],
    completionOverlay: readJson('data/recipe-completion-overlay.json')
  };
}

export function loadBasePacks() {
  return {
    curated: readJson('data/sichuan-recipes.curated.json'),
    full: readJson('data/sichuan-recipes.json')
  };
}

/**
 * Build both default runtime modes. Completion loading is mocked at the
 * network boundary with the checked-in JSON, while the merge implementation
 * itself is the production applyCompletionOverlay function.
 */
export async function buildDefaultRuntimePacks({ resetCache = true } = {}) {
  const sources = loadRuntimeSources();
  const basePacks = loadBasePacks();
  if (resetCache) resetCompletionOverlayCache();

  const previousLocation = globalThis.location;
  const previousFetch = globalThis.fetch;
  globalThis.location = new URL('http://recipe-runtime.local/');
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    async json() { return cloneJson(sources.completionOverlay); }
  });

  try {
    const packs = {};
    for (const mode of ['curated', 'full']) {
      const sourced = mergeRecipeSources(cloneJson(basePacks[mode]), sources);
      const completed = await applyCompletionOverlay(sourced);
      const withMethods = mergeRecipeMethods(completed, sources.staticMethods);
      packs[mode] = applyOverlay(withMethods, EMPTY_LOCAL_OVERLAY);
    }
    return { packs, basePacks, sources };
  } finally {
    if (previousLocation === undefined) delete globalThis.location;
    else globalThis.location = previousLocation;
    if (previousFetch === undefined) delete globalThis.fetch;
    else globalThis.fetch = previousFetch;
  }
}

function sortedIds(pack) {
  return (pack?.recipes || [])
    .map(recipe => String(recipe?.id || ''))
    .sort((a, b) => a.localeCompare(b));
}

export function recipeIdDigest(pack) {
  return createHash('sha256').update(JSON.stringify(sortedIds(pack))).digest('hex');
}

export function buildIdBaseline(basePacks) {
  const sources = {};
  for (const mode of ['curated', 'full']) {
    sources[mode] = {
      file: relative(ROOT_DIR, LIBRARY_FILES[mode]),
      count: basePacks[mode]?.recipes?.length || 0,
      idSha256: recipeIdDigest(basePacks[mode])
    };
  }
  return {
    version: 1,
    algorithm: 'sha256(JSON.stringify(sorted recipe IDs))',
    sources
  };
}

function pushIssue(bucket, code, message, detail = {}) {
  bucket.push({ code, message, ...detail });
}

function recipeLabel(recipe) {
  return `${recipe?.id || '<missing-id>'} (${recipe?.name || '<missing-name>'})`;
}

function ingredientItems(pack) {
  return Object.entries(pack?.recipe_ingredients || {}).flatMap(([id, list]) =>
    (Array.isArray(list) ? list : []).map(entry => ({ id, entry }))
  );
}

function mapSignature(list) {
  return (Array.isArray(list) ? list : [])
    .map(entry => String(entry?.item || '').trim())
    .filter(Boolean)
    .sort((a, b) => a.localeCompare(b, 'zh-Hans-CN'))
    .join('|');
}

function methodSignature(method) {
  return String(method || '').replace(/\s+/g, ' ').trim();
}

function countByCode(issues) {
  return issues.reduce((counts, issue) => {
    counts[issue.code] = (counts[issue.code] || 0) + 1;
    return counts;
  }, {});
}

function validateBaseAgainstBaseline(mode, basePack, baseline, errors) {
  const expected = baseline?.sources?.[mode];
  if (!expected) {
    pushIssue(errors, 'missing-id-baseline', `No ID baseline is defined for ${mode}.`, { mode });
    return;
  }
  const actualCount = basePack?.recipes?.length || 0;
  const actualDigest = recipeIdDigest(basePack);
  if (actualCount !== expected.count || actualDigest !== expected.idSha256) {
    pushIssue(
      errors,
      'base-id-baseline-mismatch',
      `${mode} base recipe IDs differ from the checked-in baseline (expected ${expected.count}/${expected.idSha256}, got ${actualCount}/${actualDigest}).`,
      { mode, expectedCount: expected.count, actualCount, expectedDigest: expected.idSha256, actualDigest }
    );
  }
}

function validateIdentityAndMaps(mode, pack, errors) {
  const seenIds = new Map();
  const seenNames = new Map();
  for (const recipe of pack?.recipes || []) {
    const id = String(recipe?.id || '');
    const name = String(recipe?.name || '').trim();
    if (seenIds.has(id)) {
      pushIssue(errors, 'duplicate-id', `${mode} has duplicate recipe id ${id}.`, { mode, id });
    } else seenIds.set(id, recipe);
    if (seenNames.has(name)) {
      pushIssue(errors, 'duplicate-name', `${mode} has duplicate recipe name ${name}.`, { mode, name });
    } else seenNames.set(name, recipe);
  }

  const ids = new Set(seenIds.keys());
  for (const id of Object.keys(pack?.recipe_ingredients || {})) {
    if (!ids.has(id)) {
      pushIssue(errors, 'orphan-ingredient-map', `${mode} ingredient map key ${id} has no recipe.`, { mode, id });
    }
  }

  // The compact baseline stores a digest; source IDs are checked by
  // validateBaseAgainstBaseline. Runtime identity preservation is checked by
  // comparing against the corresponding base pack in analyzeRuntimeQuality.
  return { ids, names: seenNames };
}

function isMissingMap(pack, id) {
  return !Object.prototype.hasOwnProperty.call(pack?.recipe_ingredients || {}, id);
}

function collectRepeatGroups(pack, keyFn) {
  const groups = new Map();
  for (const recipe of pack?.recipes || []) {
    const key = keyFn(recipe);
    if (!key) continue;
    const list = groups.get(key) || [];
    list.push(recipe);
    groups.set(key, list);
  }
  return [...groups.values()]
    .filter(group => group.length > 1)
    .sort((a, b) => (b.length - a.length) || recipeLabel(a[0]).localeCompare(recipeLabel(b[0]), 'zh-Hans-CN'));
}

function hasGenericIngredient(item) {
  const normalized = String(item || '').trim();
  return GENERIC_INGREDIENTS.has(normalized) || GENERIC_INGREDIENT_RE.test(normalized);
}

function isSuggestedCoreIngredient(value) {
  const name = String(value || '').trim();
  const canonical = getCanonicalName(name);
  if (!name || isRecipeNonCoreName(name) || isRecipeNonCoreName(canonical) || isSeasoning(name) || isSeasoning(canonical)) return false;
  // A few source-specific seasoning spellings are intentionally covered here
  // so the manifest does not present oil, pepper, starch, or sauce as core
  // stock suggestions merely because the source pack uses a longer label.
  return !/(?:油|盐|糖|醋|酱|料酒|生抽|老抽|豆粉|淀粉|生粉|水豆粉|湿淀粉|花椒|辣椒|胡椒|香油|芝麻油|芝麻|味精|鸡精)/.test(`${name}${canonical}`);
}

function hasStrongMapMatch(term, items) {
  return items.some(item => isSmartIngredientMatch(term, item, {
    allowContains: true,
    allowSiblingFamilyMatch: true,
    includeNonCore: true
  }));
}

function collectWarnings(mode, pack, warnings) {
  const recipesById = new Map((pack?.recipes || []).map(recipe => [recipe.id, recipe]));
  const entries = ingredientItems(pack);
  const missingQtyUnit = entries.filter(({ entry }) =>
    entry?.qty == null || entry?.unit == null || String(entry?.qty || '').trim() === '' || String(entry?.unit || '').trim() === ''
  );
  if (missingQtyUnit.length) {
    pushIssue(warnings, 'missing-qty-unit', `${mode} has ${missingQtyUnit.length} ingredient entries without qty and/or unit.`, {
      mode, count: missingQtyUnit.length
    });
  }

  for (const recipe of pack?.recipes || []) {
    const steps = splitMethodSteps(recipe.method);
    if (steps.length > 0 && steps.length < 2) {
      pushIssue(warnings, 'short-method', `${recipeLabel(recipe)} has only ${steps.length} method step.`, {
        mode, id: recipe.id, name: recipe.name, steps: steps.length
      });
    }
  }

  for (const { id, entry } of entries) {
    if (hasGenericIngredient(entry?.item)) {
      pushIssue(warnings, 'generic-ingredient', `${recipeLabel(recipesById.get(id))} uses generic ingredient “${entry.item}”.`, {
        mode, id, item: entry.item
      });
    }
  }

  for (const recipe of pack?.recipes || []) {
    const method = String(recipe?.method || '');
    if (!method || isMissingMap(pack, recipe.id)) continue;
    const items = (pack.recipe_ingredients[recipe.id] || []).map(entry => String(entry?.item || '').trim()).filter(Boolean);
    for (const term of STRONG_INGREDIENT_TERMS) {
      if (method.includes(term) && !hasStrongMapMatch(term, items)) {
        pushIssue(warnings, 'ingredient-step-mismatch', `${recipeLabel(recipe)} method mentions ${term}, but its map has no matching ingredient.`, {
          mode, id: recipe.id, term
        });
      }
    }
  }

  const repeatedIngredients = collectRepeatGroups(pack, recipe => mapSignature(pack.recipe_ingredients?.[recipe.id]));
  if (repeatedIngredients.length) {
    for (const group of repeatedIngredients) {
      pushIssue(warnings, 'repeated-ingredients', `${mode} repeats one ingredient list across ${group.length} recipes.`, {
        mode, ids: group.map(recipe => recipe.id), names: group.map(recipe => recipe.name)
      });
    }
  }
  const repeatedMethods = collectRepeatGroups(pack, recipe => methodSignature(recipe.method));
  if (repeatedMethods.length) {
    for (const group of repeatedMethods) {
      pushIssue(warnings, 'repeated-methods', `${mode} repeats one method across ${group.length} recipes.`, {
        mode, ids: group.map(recipe => recipe.id), names: group.map(recipe => recipe.name)
      });
    }
  }

  return {
    missingQtyUnit: missingQtyUnit.length,
    shortMethods: warnings.filter(issue => issue.code === 'short-method' && issue.mode === mode).length,
    genericIngredients: warnings.filter(issue => issue.code === 'generic-ingredient' && issue.mode === mode).length,
    mismatchWarnings: warnings.filter(issue => issue.code === 'ingredient-step-mismatch' && issue.mode === mode).length,
    repeatedIngredientGroups: repeatedIngredients.length,
    repeatedMethodGroups: repeatedMethods.length
  };
}

function deriveSource(name, sources) {
  if (Object.prototype.hasOwnProperty.call(sources.staticMethods || {}, name)) return 'recipe-methods';
  if ((sources.hocData || []).some(item => String(item?.name || '').trim() === name)) return 'hoc';
  if ((sources.completionOverlay?.newRecipes || []).some(item => String(item?.name || '').trim() === name)) return 'completion';
  return 'base';
}

function buildIngredientLexicon(basePacks, sources) {
  const lexicon = new Set(Object.keys(INGREDIENT_ALIASES));
  for (const pack of Object.values(basePacks || {})) {
    for (const entry of ingredientItems(pack)) {
      const value = String(entry.entry?.item || '').trim();
      if (value) lexicon.add(value);
    }
  }
  for (const item of sources.hocData || []) {
    for (const value of item.ingredients || []) if (String(value || '').trim()) lexicon.add(String(value).trim());
  }
  return [...lexicon]
    .filter(value => value.length >= 2 && isSuggestedCoreIngredient(value) && !hasGenericIngredient(value))
    .sort((a, b) => (b.length - a.length) || a.localeCompare(b, 'zh-Hans-CN'));
}

function inferSuggestedCoreIngredients(recipe, lexicon) {
  const method = String(recipe?.method || '');
  const name = String(recipe?.name || '');
  const hits = [];
  for (const candidate of lexicon) {
    const names = [candidate, ...getIngredientMatchNames(candidate)].filter(value => String(value).length >= 2);
    const positions = names.map(value => method.indexOf(value)).filter(position => position >= 0);
    const namePositions = names.map(value => name.indexOf(value)).filter(position => position >= 0);
    if (!positions.length && !namePositions.length) continue;
    hits.push({
      candidate: getCanonicalName(candidate) || candidate,
      position: positions.length ? Math.min(...positions) : 9999,
      namePosition: namePositions.length ? Math.min(...namePositions) : 9999,
      length: candidate.length
    });
  }
  const unique = new Map();
  for (const hit of hits) {
    const existing = unique.get(hit.candidate);
    if (!existing || hit.position < existing.position || (hit.position === existing.position && hit.length > existing.length)) {
      unique.set(hit.candidate, hit);
    }
  }
  return [...unique.values()]
    .sort((a, b) => (a.position - b.position) || (a.namePosition - b.namePosition) || (b.length - a.length) || a.candidate.localeCompare(b.candidate, 'zh-Hans-CN'))
    .slice(0, 5)
    .map(hit => hit.candidate);
}

function balancedBatchNumber(index, total) {
  const batchCount = Math.ceil(total / 15);
  const small = Math.floor(total / batchCount);
  const remainder = total % batchCount;
  let cursor = 0;
  for (let batch = 1; batch <= batchCount; batch += 1) {
    const size = small + (batch <= remainder ? 1 : 0);
    if (index < cursor + size) return batch;
    cursor += size;
  }
  return batchCount;
}

export function generateCuratedMissingManifest(runtimePack, basePacks, sources) {
  const lexicon = buildIngredientLexicon(basePacks, sources);
  const missing = (runtimePack?.recipes || [])
    .filter(recipe => isMissingMap(runtimePack, recipe.id))
    .map(recipe => {
      const suggested = inferSuggestedCoreIngredients(recipe, lexicon);
      const priority = suggested.length >= 2 ? 'P1' : suggested.length === 1 ? 'P2' : 'P3';
      return {
        id: recipe.id,
        name: recipe.name,
        methodSource: deriveSource(recipe.name, sources),
        priority,
        priorityReason: suggested.length >= 2 ? 'method/name inferred at least two core ingredients' : suggested.length === 1 ? 'method/name inferred one core ingredient' : 'no high-confidence core ingredient match; manual review required',
        suggestedCoreIngredients: suggested,
        methodStepCount: splitMethodSteps(recipe.method).length
      };
    })
    .sort((a, b) => a.priority.localeCompare(b.priority) || a.name.localeCompare(b.name, 'zh-Hans-CN') || a.id.localeCompare(b.id));

  return missing.map((entry, index) => ({ ...entry, batch: balancedBatchNumber(index, missing.length) }));
}

export function validateManifest(manifest, runtimePack, basePacks, sources) {
  const errors = [];
  if (!Array.isArray(manifest)) {
    return [{ code: 'manifest-invalid', message: 'Curated missing-map manifest must be an array.' }];
  }
  const expected = generateCuratedMissingManifest(runtimePack, basePacks, sources);
  if (JSON.stringify(manifest) !== JSON.stringify(expected)) {
    pushIssue(errors, 'manifest-nondeterministic', 'Curated missing-map manifest differs from deterministic regeneration.');
  }
  const seenIds = new Set();
  const seenNames = new Set();
  const byBatch = new Map();
  for (const entry of manifest) {
    if (!entry || typeof entry !== 'object') {
      pushIssue(errors, 'manifest-entry-invalid', 'Manifest entries must be objects.');
      continue;
    }
    for (const field of ['id', 'name', 'methodSource', 'priority', 'suggestedCoreIngredients', 'batch']) {
      if (!Object.prototype.hasOwnProperty.call(entry, field)) pushIssue(errors, 'manifest-field-missing', `Manifest entry is missing ${field}.`, { field });
    }
    if (seenIds.has(entry.id)) pushIssue(errors, 'manifest-duplicate-id', `Manifest repeats recipe id ${entry.id}.`, { id: entry.id });
    if (seenNames.has(entry.name)) pushIssue(errors, 'manifest-duplicate-name', `Manifest repeats recipe name ${entry.name}.`, { name: entry.name });
    seenIds.add(entry.id);
    seenNames.add(entry.name);
    if (!['P1', 'P2', 'P3'].includes(entry.priority)) pushIssue(errors, 'manifest-priority-invalid', `Manifest priority ${entry.priority} is invalid.`, { priority: entry.priority });
    if (!Array.isArray(entry.suggestedCoreIngredients)) pushIssue(errors, 'manifest-suggestions-invalid', `Manifest suggestions for ${entry.id} must be an array.`, { id: entry.id });
    const list = byBatch.get(entry.batch) || [];
    list.push(entry);
    byBatch.set(entry.batch, list);
  }
  const expectedIds = new Set(expected.map(entry => entry.id));
  for (const id of expectedIds) if (!seenIds.has(id)) pushIssue(errors, 'manifest-id-missing', `Manifest omits missing-map recipe ${id}.`, { id });
  for (const id of seenIds) if (!expectedIds.has(id)) pushIssue(errors, 'manifest-id-unexpected', `Manifest contains non-missing recipe ${id}.`, { id });
  for (const [batch, entries] of byBatch) {
    if (entries.length < 10 || entries.length > 20) pushIssue(errors, 'manifest-batch-size', `Manifest batch ${batch} has ${entries.length} recipes; expected 10–20.`, { batch, size: entries.length });
  }
  return errors;
}

export function analyzeRuntimeQuality({ packs, basePacks, sources, baseline, manifest }) {
  const modes = {};
  for (const mode of ['curated', 'full']) {
    const pack = packs?.[mode] || { recipes: [], recipe_ingredients: {} };
    const errors = [];
    const warnings = [];
    const identity = validateIdentityAndMaps(mode, pack, errors);
    validateBaseAgainstBaseline(mode, basePacks?.[mode], baseline, errors);

    const baseIds = new Set((basePacks?.[mode]?.recipes || []).map(recipe => recipe.id));
    for (const id of baseIds) {
      if (!identity.ids.has(id)) pushIssue(errors, 'baseline-id-missing', `${mode} runtime is missing base recipe id ${id}.`, { mode, id });
    }

    const missingMethods = (pack.recipes || []).filter(recipe => !String(recipe?.method || '').trim());
    const missingMaps = (pack.recipes || []).filter(recipe => isMissingMap(pack, recipe.id));
    if (mode === 'curated') {
      for (const recipe of missingMethods) pushIssue(errors, 'curated-missing-method', `${recipeLabel(recipe)} has no method in curated runtime.`, { mode, id: recipe.id, name: recipe.name });
      for (const recipe of missingMaps) pushIssue(errors, 'curated-missing-ingredient-map', `${recipeLabel(recipe)} has no ingredient map in curated runtime.`, { mode, id: recipe.id, name: recipe.name });
    }

    const warningSummary = collectWarnings(mode, pack, warnings);
    const stats = {
      recipes: pack.recipes?.length || 0,
      methodsReady: (pack.recipes || []).filter(recipe => String(recipe?.method || '').trim()).length,
      missingMethods: missingMethods.length,
      ingredientMaps: Object.keys(pack.recipe_ingredients || {}).length,
      missingIngredientMaps: missingMaps.length,
      ingredientEntries: ingredientItems(pack).length,
      duplicateIds: errors.filter(issue => issue.code === 'duplicate-id').length,
      duplicateNames: errors.filter(issue => issue.code === 'duplicate-name').length,
      orphanIngredientMaps: errors.filter(issue => issue.code === 'orphan-ingredient-map').length
    };
    modes[mode] = {
      mode,
      stats,
      errors,
      warnings,
      errorCounts: countByCode(errors),
      warningCounts: countByCode(warnings),
      warningSummary
    };
  }

  const manifestErrors = validateManifest(manifest, packs?.curated, basePacks, sources);
  if (manifestErrors.length) modes.curated.errors.push(...manifestErrors);
  modes.curated.errorCounts = countByCode(modes.curated.errors);

  return {
    modes,
    errors: [...modes.curated.errors, ...modes.full.errors],
    warnings: [...modes.curated.warnings, ...modes.full.warnings],
    manifest: {
      entries: Array.isArray(manifest) ? manifest.length : 0,
      batches: Array.isArray(manifest) ? [...new Set(manifest.map(entry => entry.batch))].sort((a, b) => a - b).length : 0,
      batchSizes: Array.isArray(manifest) ? Object.values(manifest.reduce((groups, entry) => {
        groups[entry.batch] = (groups[entry.batch] || 0) + 1;
        return groups;
      }, {})) : []
    }
  };
}

export function formatReport(report, { strict = false } = {}) {
  const lines = ['Recipe runtime quality audit (default localStorage overlay: empty)'];
  for (const mode of ['curated', 'full']) {
    const result = report.modes[mode];
    const s = result.stats;
    lines.push(`${mode}: recipes=${s.recipes} methods=${s.methodsReady} missingMethods=${s.missingMethods} maps=${s.ingredientMaps} missingMaps=${s.missingIngredientMaps} entries=${s.ingredientEntries}`);
    lines.push(`  errors: ${JSON.stringify(result.errorCounts)}`);
    lines.push(`  warnings: ${JSON.stringify(result.warningCounts)}`);
  }
  lines.push(`manifest: entries=${report.manifest.entries} batches=${report.manifest.batches} sizes=${report.manifest.batchSizes.join(',')}`);
  lines.push(`errors total=${report.errors.length}; warnings total=${report.warnings.length}; strict=${strict ? 'enabled' : 'analysis-only'}`);
  if (report.errors.length) {
    lines.push('error samples:');
    for (const issue of report.errors.slice(0, 12)) lines.push(`  - [${issue.code}] ${issue.message}`);
  }
  return lines.join('\n');
}

async function loadArtifact(file) {
  if (!existsSync(file)) return null;
  return JSON.parse(await readFile(file, 'utf8'));
}

async function writeArtifact(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

export async function runCli(argv = process.argv.slice(2)) {
  const strict = argv.includes('--strict');
  const writeArtifacts = argv.includes('--write-artifacts');
  const runtime = await buildDefaultRuntimePacks();
  const baseline = buildIdBaseline(runtime.basePacks);
  const manifest = generateCuratedMissingManifest(runtime.packs.curated, runtime.basePacks, runtime.sources);
  if (writeArtifacts) {
    await writeArtifact(BASELINE_PATH, baseline);
    await writeArtifact(MANIFEST_PATH, manifest);
  }
  // Missing committed artifacts are quality errors, not an invitation to
  // regenerate an allowlist at validation time. --write-artifacts is the
  // explicit maintenance command for intentional regeneration.
  const checkedBaseline = writeArtifacts ? baseline : await loadArtifact(BASELINE_PATH);
  const checkedManifest = writeArtifacts ? manifest : await loadArtifact(MANIFEST_PATH);
  const report = analyzeRuntimeQuality({
    packs: runtime.packs,
    basePacks: runtime.basePacks,
    sources: runtime.sources,
    baseline: checkedBaseline,
    manifest: checkedManifest
  });
  process.stdout.write(`${formatReport(report, { strict })}\n`);
  return report.errors.length && strict ? 1 : 0;
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : '';
if (import.meta.url === invokedPath) {
  runCli().then(code => { process.exitCode = code; }).catch(error => {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  });
}
