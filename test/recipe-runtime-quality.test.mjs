import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  BASELINE_PATH,
  MANIFEST_PATH,
  analyzeRuntimeQuality,
  buildDefaultRuntimePacks,
  buildIdBaseline,
  compareIdsByCodeUnit,
  generateCuratedMissingManifest,
  recipeIdDigest,
  sortedRecipeIds,
  validateManifest
} from '../scripts/recipe-runtime-quality.mjs';

const root = process.cwd();

const BATCH_ONE_REPAIRS = [
  ['static-1044475127', '菠饺白肺', ['猪肺', '猪肉', '菠菜', '面粉', '火腿', '鸡皮', '口蘑']],
  ['static-1981751912', '菠饺玻璃肚', ['猪肚', '瘦肉', '菠菜', '面粉', '草碱']],
  ['static-667502386', '叉烧奶猪', ['乳猪', '红酱油', '香油']],
  ['static-37953915', '陈皮鸡', ['仔鸡', '陈皮', '花椒']],
  ['static-1097826983', '豆渣猪头', ['猪头肉', '豆渣', '草果']],
  ['static-40229706', '鹅黄肉', ['鸡蛋', '肥瘦肉', '豆粉']],
  ['static-1365903158', '肥肠豆沙汤', ['肥肠', '干豌豆', '姜']],
  ['static-1029953942', '芙蓉鸡片', ['鸡脯肉', '鸡蛋', '火腿', '口蘑', '鲜笋']],
  ['static-1029721788', '芙蓉肉糕', ['肥膘肉', '鸡蛋', '豆粉']],
  ['static-1029719086', '芙蓉肉片', ['猪肉', '鸡蛋', '面包粉', '水豆粉']],
  ['static-1029518135', '芙蓉杂烩', ['酥肉', '猪肚', '猪舌', '火腿', '响皮', '笋子', '鸡松', '圆子']],
  ['static-951097944', '福建仔鸡', ['仔鸡', '醪糟', '花椒']],
  ['static-1136685680', '腐乳空心菜', ['腐乳', '蒜', '空心菜']],
  ['static-749272849', '干煸花菜', ['花菜', '五花肉', '干辣椒', '蚝油']],
  ['static-1741552216', '干煸四季豆', ['四季豆', '肉末', '芽菜', '干辣椒', '花椒']]
];

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

test('default runtime quality covers the final Curated and Full merge chain', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const baseline = readJson(BASELINE_PATH);
  const manifest = readJson(MANIFEST_PATH);
  const report = analyzeRuntimeQuality({
    ...runtime,
    baseline,
    manifest
  });

  assert.deepEqual(report.modes.curated.stats, {
    recipes: 403,
    methodsReady: 403,
    missingMethods: 0,
    ingredientMaps: 315,
    missingIngredientMaps: 88,
    ingredientEntries: 1359,
    duplicateIds: 0,
    duplicateNames: 0,
    orphanIngredientMaps: 0
  });
  assert.equal(report.modes.full.stats.recipes, 526);
  assert.equal(report.modes.full.stats.methodsReady, 403);
  assert.equal(report.modes.full.stats.missingMethods, 123);
  assert.equal(report.modes.full.stats.ingredientMaps, 499);
  assert.equal(report.modes.full.stats.missingIngredientMaps, 27);
  assert.equal(report.modes.full.stats.ingredientEntries, 1540);
  assert.equal(report.modes.full.stats.duplicateIds, 0);
  assert.equal(report.modes.full.stats.duplicateNames, 0);
  assert.equal(report.modes.full.stats.orphanIngredientMaps, 0);
  assert.equal(report.modes.curated.errorCounts['curated-missing-method'] || 0, 0);
  assert.equal(report.modes.curated.errorCounts['curated-missing-ingredient-map'], 88);
  assert.ok(report.modes.curated.warningCounts['missing-qty-unit'] > 0);
  assert.ok(report.modes.curated.warningCounts['short-method'] > 0);
  assert.ok(report.modes.curated.warningCounts['generic-ingredient'] > 0);
  assert.ok(report.modes.curated.warningCounts['ingredient-step-mismatch'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-ingredients'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-methods'] > 0);
});

test('ID baseline and deterministic 88-entry manifest cover exactly the remaining runtime gap', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const baseline = readJson(BASELINE_PATH);
  const manifest = readJson(MANIFEST_PATH);
  const generatedBaseline = buildIdBaseline(runtime.basePacks);
  assert.deepEqual(generatedBaseline, baseline);
  for (const mode of ['curated', 'full']) {
    assert.equal(recipeIdDigest(runtime.basePacks[mode]), baseline.sources[mode].idSha256);
    assert.equal(runtime.basePacks[mode].recipes.length, baseline.sources[mode].count);
  }

  const regenerated = generateCuratedMissingManifest(runtime.packs.curated, runtime.basePacks, runtime.sources);
  assert.deepEqual(regenerated, manifest);
  assert.equal(manifest.length, 88);
  assert.equal(new Set(manifest.map(entry => entry.id)).size, 88);
  assert.equal(new Set(manifest.map(entry => entry.name)).size, 88);
  assert.ok(manifest.every(entry => entry.methodSource === 'recipe-methods'));
  assert.ok(manifest.every(entry => ['P1', 'P2', 'P3'].includes(entry.priority)));
  assert.ok(manifest.every(entry => Array.isArray(entry.suggestedCoreIngredients)));

  const batchSizes = [...manifest.reduce((groups, entry) => {
    groups.set(entry.batch, (groups.get(entry.batch) || 0) + 1);
    return groups;
  }, new Map()).values()];
  assert.deepEqual(batchSizes, [15, 15, 15, 15, 14, 14]);
  assert.ok(batchSizes.every(size => size >= 10 && size <= 20));
  assert.deepEqual(validateManifest(manifest, runtime.packs.curated, runtime.basePacks, runtime.sources), []);
});

test('Curated first-batch repairs keep the exact 15 IDs mapped and out of the manifest', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const manifest = readJson(MANIFEST_PATH);
  const missingIds = new Set(manifest.map(entry => entry.id));
  for (const [id, name, requiredItems] of BATCH_ONE_REPAIRS) {
    const recipe = runtime.packs.curated.recipes.find(item => item.id === id);
    assert.equal(recipe?.name, name);
    assert.ok(String(recipe?.method || '').trim(), `${name} must keep its runtime method`);
    const mapped = runtime.packs.curated.recipe_ingredients[id];
    assert.ok(Array.isArray(mapped) && mapped.length > 0, `${name} must have an ingredient map`);
    assert.ok(mapped.every(entry => !Object.hasOwn(entry, 'qty') && !Object.hasOwn(entry, 'unit')));
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of requiredItems) assert.ok(items.has(item), `${name} should map ${item}`);
    assert.equal(missingIds.has(id), false, `${name} must leave the missing-map manifest`);
  }
  assert.equal(missingIds.size, 88);
});

test('analysis mode stays green while strict mode reports the known nonzero data errors', () => {
  const script = join(root, 'scripts', 'recipe-runtime-quality.mjs');
  const analysis = spawnSync(process.execPath, [script], { cwd: root, encoding: 'utf8' });
  assert.equal(analysis.status, 0, analysis.stderr);
  assert.match(analysis.stdout, /errors total=88/);
  assert.match(analysis.stdout, /strict=analysis-only/);

  const strict = spawnSync(process.execPath, [script, '--strict'], { cwd: root, encoding: 'utf8' });
  assert.equal(strict.status, 1, strict.stdout + strict.stderr);
  assert.match(strict.stdout, /curated-missing-ingredient-map/);
  assert.match(strict.stdout, /strict=enabled/);
});

// --- Baseline digest determinism -------------------------------------------
//
// The digest must be a pure function of the ID *set*. It previously sorted with
// `localeCompare` and no locale argument, so the host's default locale decided
// the order and therefore the hash. These tests pin the behaviour, not the
// source text: every one of them fails if the ordering rule starts consulting
// ICU again, regardless of how it is written.

// Each pair below is ordered differently by code units than by at least one
// real locale. `static-1` vs `static_1` is the case that matters most in
// practice — every generated recipe id contains a hyphen.
const LOCALE_DIVERGENT_IDS = ['static_1', 'static-1', 'aa', 'z', 'a', 'B', 'Z', 'ab'];

const packOfIds = (ids) => ({ recipes: ids.map(id => ({ id })), recipe_ingredients: {} });

// Independent oracle: `Array.prototype.sort()` with no comparator is defined to
// sort by UTF-16 code unit, so this never routes through the code under test.
const codeUnitDigest = (ids) =>
  createHash('sha256').update(JSON.stringify([...ids].sort())).digest('hex');

test('digest orders locale-divergent ids by code unit, not by host locale', () => {
  // Guard against a vacuous test: prove this input really is locale-sensitive.
  const byCodeUnit = [...LOCALE_DIVERGENT_IDS].sort();
  const localeOrders = ['en-US', 'da-DK', 'sv-SE'].map(
    locale => JSON.stringify([...LOCALE_DIVERGENT_IDS].sort((a, b) => a.localeCompare(b, locale)))
  );
  assert.ok(
    localeOrders.some(order => order !== JSON.stringify(byCodeUnit)),
    'fixture must be a set whose locale ordering differs from code-unit ordering'
  );

  assert.deepEqual(sortedRecipeIds(packOfIds(LOCALE_DIVERGENT_IDS)), byCodeUnit);
  assert.equal(recipeIdDigest(packOfIds(LOCALE_DIVERGENT_IDS)), codeUnitDigest(LOCALE_DIVERGENT_IDS));

  // The comparator itself follows code units, including for the hyphen case.
  assert.equal(compareIdsByCodeUnit('static-1', 'static_1'), -1);
  assert.equal(compareIdsByCodeUnit('B', 'a'), -1);
  assert.equal(compareIdsByCodeUnit('static-1', 'static-1'), 0);
});

test('replacing String.prototype.localeCompare cannot change any digest', () => {
  const original = String.prototype.localeCompare;
  const realPacks = [];
  try {
    // Any read of localeCompare on the digest path is now a hard failure.
    // eslint-disable-next-line no-extend-native
    String.prototype.localeCompare = function poisoned() {
      throw new Error('digest must not depend on localeCompare');
    };
    assert.equal(recipeIdDigest(packOfIds(LOCALE_DIVERGENT_IDS)), codeUnitDigest(LOCALE_DIVERGENT_IDS));
    assert.deepEqual(sortedRecipeIds(packOfIds(LOCALE_DIVERGENT_IDS)), [...LOCALE_DIVERGENT_IDS].sort());
    realPacks.push(recipeIdDigest(packOfIds(['static-2', 'hoc-1', 'ex--9'])));
  } finally {
    // eslint-disable-next-line no-extend-native
    String.prototype.localeCompare = original;
  }
  // Same value once the real implementation is back — the patch changed nothing.
  assert.equal(realPacks[0], recipeIdDigest(packOfIds(['static-2', 'hoc-1', 'ex--9'])));
});

test('digest depends on the id set, not on input order', () => {
  const ids = [...LOCALE_DIVERGENT_IDS];
  const expected = recipeIdDigest(packOfIds(ids));
  const permutations = [
    [...ids].reverse(),
    [...ids.slice(3), ...ids.slice(0, 3)],
    [...ids].sort((a, b) => a.length - b.length || (a < b ? 1 : -1))
  ];
  for (const permutation of permutations) {
    assert.deepEqual([...permutation].sort(), [...ids].sort(), 'permutation must hold the same set');
    assert.equal(recipeIdDigest(packOfIds(permutation)), expected);
  }
});

test('digest changes whenever the id set or an id value changes', () => {
  const base = recipeIdDigest(packOfIds(LOCALE_DIVERGENT_IDS));
  const added = recipeIdDigest(packOfIds([...LOCALE_DIVERGENT_IDS, 'static-999']));
  const removed = recipeIdDigest(packOfIds(LOCALE_DIVERGENT_IDS.slice(1)));
  const mutated = recipeIdDigest(packOfIds(
    LOCALE_DIVERGENT_IDS.map(id => (id === 'static-1' ? 'static-2' : id))
  ));
  for (const [label, digest] of [['added', added], ['removed', removed], ['mutated', mutated]]) {
    assert.notEqual(digest, base, `${label} id set must produce a different digest`);
  }
  assert.equal(new Set([base, added, removed, mutated]).size, 4);
});

test('curated and full base id sets and counts are unchanged by the ordering fix', () => {
  const baseline = readJson(BASELINE_PATH);
  const packs = {
    curated: readJson(join(root, 'data', 'sichuan-recipes.curated.json')),
    full: readJson(join(root, 'data', 'sichuan-recipes.json'))
  };

  const expectedCounts = { curated: 126, full: 264 };
  for (const mode of ['curated', 'full']) {
    const ids = packs[mode].recipes.map(recipe => String(recipe?.id || ''));
    assert.equal(ids.length, expectedCounts[mode]);
    assert.equal(baseline.sources[mode].count, expectedCounts[mode]);
    assert.equal(new Set(ids).size, expectedCounts[mode], `${mode} base ids must be unique`);
    // Code-unit digest still equals the checked-in baseline: the ordering rule
    // changed, the set did not, and on this data the two orders coincide.
    assert.equal(recipeIdDigest(packs[mode]), baseline.sources[mode].idSha256);
    assert.equal(codeUnitDigest(ids), baseline.sources[mode].idSha256);
  }
  assert.deepEqual(buildIdBaseline(packs), baseline);
});
