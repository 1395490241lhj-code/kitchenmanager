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

const CURRENT_BATCH_REPAIRS = [
  ['static-35524600', '贵州鸡', ['鸡脯肉', '干海椒', '姜', '蒜', '葱', '鸡蛋', '豆粉', '化猪油', '料酒', '盐', '味精', '白糖', '清汤', '酱油']],
  ['static-1172519253', '锅贴鸡片', ['鸡脯肉', '猪肥膘肉', '瘦火腿', '鸡蛋清', '干豆粉', '姜', '葱', '料酒', '酱油', '猪油', '香油']],
  ['static-1172291558', '锅贴腰片', ['猪肥膘肉', '火腿', '猪腰', '鸡蛋清', '干豆粉', '白酱油', '料酒', '姜', '葱', '猪油']],
  ['static-994480383', '红烧环喉', ['环喉', '火腿', '兰片', '鸡松', '化猪油', '葱', '姜', '料酒', '胡椒', '味精', '酱油', '盐', '清汤', '水豆粉', '鸡油']],
  ['static-756534817', '红烧卷筒鸡', ['鸡腿', '鸡脯', '火腿', '鲜笋', '鸡松', '蛋清', '豆粉', '菜油', '清汤', '红酱油', '白酱油', '葱', '姜', '料酒', '盐']],
  ['static-32082596', '红烧肉', ['五花肉', '冰糖', '姜', '葱', '八角', '桂皮', '香叶', '酱油', '料酒']],
  ['static-901831824', '煳辣鸡丁', ['鸡肉', '水豆粉', '盐', '葱', '姜', '蒜', '干辣椒', '花生米', '红酱油', '白酱油', '糖', '料酒', '味精', '鸡汤', '油', '花椒', '醋']],
  ['static-901606519', '煳辣腰块', ['猪腰', '料酒', '盐', '水豆粉', '白糖', '醋', '酱油', '味精', '清汤', '辣椒', '花椒', '姜', '蒜', '葱', '油']],
  ['static-40048908', '鸡豆花', ['鸡脯肉', '鸡蛋清', '豆粉', '盐', '味精', '清汤']],
  ['static-1234054558', '鸡淖脊髓', ['猪脊髓', '鸡脯肉', '鸡蛋清', '豆粉', '盐', '味精', '清汤', '猪油', '料酒']],
  ['static-1277523', '鸡塔', ['鸡脯肉', '猪肥膘肉', '鸡蛋清', '干豆粉', '火腿', '盐', '香油']],
  ['static-1701594899', '韭菜炒鸡蛋', ['韭菜', '鸡蛋', '油', '盐']],
  ['static-1496643857', '韭黄炒肉丝', ['韭黄', '肉丝', '盐', '生抽', '淀粉', '油', '味精']],
  ['static-28952792', '烤酥方', ['厚膘连皮带肋骨肉', '香油']],
  ['static-1027973551', '苦瓜炒蛋', ['苦瓜', '鸡蛋', '盐', '料酒', '油']]
];

const NEXT_BATCH_REPAIRS = [
  ['static-654509853', '兰花鸡丝', ['鸡脯肉', '蛋清', '豆粉', '盐', '料酒', '兰花', '猪油', '味精', '清汤']],
  ['static-648679063', '凉拌三丝', ['海带丝', '粉丝', '胡萝卜丝', '蒜末', '香菜段', '盐', '生抽', '醋', '糖', '辣椒油', '香油']],
  ['static-25997141', '晾干肉', ['大头菜', '葱', '蒜', '猪后腿净瘦肉', '酱油', '胡椒面', '料酒', '菜油', '化猪油', '姜', '醋', '白糖', '清汤', '香油']],
  ['static-29232650', '熘鸡米', ['鸡脯肉', '茨菰', '火腿', '葱', '鸡蛋', '干豆粉', '盐', '料酒', '水豆粉', '味精', '胡椒面', '清汤', '油']],
  ['static-1999150952', '熘珊瑚鸡丁', ['鸡脯', '蛋清', '豆粉', '料酒', '盐', '红萝卜', '化猪油', '香油']],
  ['static-893248609', '熘桃鸡卷', ['鸡脯', '火腿', '口蘑', '桃米', '蛋清', '豆粉', '化猪油', '盐', '料酒', '味精', '清汤', '香油']],
  ['static-1247568140', '龙眼脊髓', ['脊髓', '鱼肉', '猪肥膘', '蛋清', '豆粉', '盐', '猪瘦肉', '火腿', '猪油', '清汤', '料酒', '酱油', '味精', '胡椒']],
  ['static-16669423', '龙眼甜烧白', ['干沙', '红糖', '连皮肥肉', '樱桃', '酒米']],
  ['static-8700811', '龙眼咸烧白', ['五花肉', '红酱油', '菜油', '鱼辣椒', '芽菜', '豆豉', '盐']],
  ['static-40244567', '麻酥鸡', ['鸡肉', '茨菰', '芝麻', '鸡蛋清', '豆粉', '盐', '胡椒面', '香油', '菜油']],
  ['static-39773758', '麻圆肉', ['猪肥膘', '蛋黄', '豆粉', '菜油', '白糖', '芝麻']],
  ['static-1059559366', '蚂蚁上树', ['粉丝', '猪肉', '油', '豆瓣酱', '姜', '蒜', '酱油', '糖', '味精']],
  ['static-892838462', '牡丹鸡片', ['小白菜心', '火腿', '口蘑', '鸡蛋清', '面粉', '鸡脯', '干豆粉', '猪油', '油', '鸡汤', '水豆粉', '盐', '料酒', '味精', '胡椒面', '鸡油']],
  ['static-525063392', '奶汤大杂烩', ['菜油', '猪肉皮', '干笋', '清汤', '肥膘猪肉', '鸡蛋', '干豆粉', '盐', '肥瘦相连猪肉', '猪心', '猪舌', '水豆粉', '胡椒', '火腿', '特级奶汤', '味精', '料酒']],
  ['static-664179745', '南煎圆子', ['茨菰', '香菌', '猪肉', '火腿', '兰片', '葱', '姜', '盐', '酱油', '水豆粉', '鸡蛋', '油', '料酒', '胡椒', '味精', '香油']]
];

const ACTIVE_BATCH_REPAIRS = [
  ['static-21197628', '南卤肉', ['五花肉', '葱', '姜', '油', '盐', '白糖', '料酒', '豆腐乳汁']],
  ['static-27820604', '泥糊鸡', ['仔鸡', '酱油', '花椒', '料酒', '姜', '葱', '芽菜', '泡辣椒', '猪肉', '菜油', '鲜荷叶']],
  ['static-31763773', '糯米鸡', ['仔母鸡', '鲜豌豆仁', '糯米', '莲米', '苡仁', '芡实', '金钩', '香菌', '火腿', '盐', '酱油', '鸡蛋', '干豆粉', '菜油', '香油']],
  ['static-938343985', '皮蛋黄瓜汤', ['黄瓜', '皮蛋', '姜', '油', '盐', '胡椒粉']],
  ['static-22201215', '啤酒鸭', ['鸭肉', '青椒', '红椒', '姜', '蒜', '油', '八角', '桂皮', '干辣椒', '豆瓣酱', '啤酒', '酱油', '糖']],
  ['static-1875218339', '芹菜炒肉丝', ['芹菜', '猪瘦肉', '盐', '生抽', '淀粉', '料酒', '油', '姜丝', '蒜末', '鸡精', '香油']],
  ['static-1030638460', '芹菜香干', ['芹菜', '香干', '红甜椒', '油', '蒜末', '生抽', '糖', '盐']],
  ['static-866782600', '清汤腰方', ['猪腰', '清汤', '盐', '胡椒', '味精', '酱油']],
  ['static-1006716942', '肉末茄子', ['茄子', '盐', '油', '肉末', '姜', '蒜', '豆瓣酱', '酱油', '糖', '水淀粉']],
  ['static-1122669763', '软炸肚头', ['猪肚头', '葱', '蒜', '料酒', '盐', '姜', '鸡蛋清', '豆粉', '猪油', '香油']],
  ['static-1122913213', '软炸鸡糕', ['鸡脯', '肥膘', '蛋清', '水豆粉', '盐', '鸡汤', '味精', '料酒', '胡椒', '茨菰', '干豆粉', '猪油', '香油']],
  ['static-1122674928', '软炸腰卷', ['猪腰', '猪肉', '水发玉兰片', '猪网油', '葱', '鸡蛋清', '干豆粉', '鸡蛋', '料酒', '胡椒面', '盐', '菜油', '香油']],
  ['static-1122712506', '软炸蒸肉', ['猪肉', '花椒', '五香粉', '酱油', '豆腐乳水', '醪糟', '白糖', '姜米', '葱花', '盐', '料酒', '豌豆', '米粉', '鸡蛋', '面包粉', '油']],
  ['static-1122381423', '软炸子盖', ['五花猪肉', '料酒', '红酱油', '白酱油', '老姜', '葱', '鸡蛋清', '干豆粉', '菜油', '香油']],
  ['static-628509470', '三色鸡淖', ['生鸡脯肉', '鸡蛋清', '鸡蛋黄', '清汤', '味精', '盐', '料酒', '胡椒面', '水豆粉', '猪油', '番茄酱']]
];

const CURRENT_MANIFEST_BATCH_REPAIRS = [
  ['static-1901364811', '苕菜狮子头', ['金钩', '茨菰', '肥瘦肉', '火腿', '鲜青豆', '鸡蛋清', '豆粉', '盐', '料酒', '胡椒', '味精', '猪油', '清汤', '姜', '葱', '鸡油']],
  ['static-922286956', '生烧鸡翅', ['鸡翅', '火腿', '冬笋', '口蘑', '猪油', '姜', '葱白', '料酒', '酱油', '盐', '鸡汤', '味精', '水豆粉', '香油']],
  ['static-922287398', '生烧鸡腿', ['鸡腿', '姜', '葱', '口蘑', '料酒', '糖汁', '酱油', '盐', '鸡油']],
  ['static-1482694287', '生烧筋尾舌', ['猪舌', '猪尾', '鲜猪蹄筋', '猪油', '姜', '葱', '料酒', '冰糖汁', '盐', '二汤']],
  ['static-775068321', '手撕包菜', ['包菜', '五花肉', '干辣椒', '蒜', '油', '花椒', '生抽', '陈醋', '盐', '白糖']],
  ['static-652528271', '刷把鸡丝', ['熟鸡', '火腿', '丝瓜皮', '兰片', '鸡蛋', '葱叶', '料酒', '盐', '味精', '瘦肉']],
  ['static-672220178', '双色肉糕', ['猪肉', '蛋清', '蛋黄', '葱', '姜', '盐', '花椒面', '豆粉', '味精', '油', '料酒']],
  ['static-315753341', '四上玻璃肚', ['猪肚', '草碱']],
  ['static-26530806', '松花肉', ['蛋黄', '蛋清', '面粉', '味精', '盐', '猪肉', '冬笋', '口蘑', '猪油', '料酒', '葱花', '酱油', '白糖', '五香面']],
  ['static-26218295', '松子肉', ['肥瘦相连猪肉', '松子', '萝卜', '姜', '葱', '鸡蛋', '干豆粉', '味精', '盐', '胡椒', '豆油皮', '菜油', '二汤', '奶汤']],
  ['static-1136930950', '酸豆角肉末', ['酸豆角', '猪肉', '料酒', '油', '姜', '蒜', '干辣椒', '酱油', '糖']],
  ['static-1150194923', '酸辣土豆丝', ['土豆', '干辣椒', '花椒', '油', '姜', '蒜', '白醋', '盐', '青椒', '红椒']],
  ['static-1964437082', '蒜蓉空心菜', ['空心菜', '大蒜', '油', '盐', '味精']],
  ['static-1044456943', '蒜苔炒肉', ['蒜苔', '瘦肉', '盐', '淀粉', '料酒', '油', '酱油']],
  ['static-22248404', '坛子肉', ['海参', '鱼翅', '珧柱', '口蘑', '大金钩', '墨鱼', '猪骨', '猪肘子肉', '肥母鸡', '肥瘦火腿', '冬笋', '肥鸭', '鸡蛋', '猪油', '干豆粉', '姜', '大葱', '胡椒', '二汤', '料酒', '盐', '红酱油', '白酱油', '冰糖汁']]
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
    ingredientMaps: 375,
    missingIngredientMaps: 28,
    ingredientEntries: 1997,
    duplicateIds: 0,
    duplicateNames: 0,
    orphanIngredientMaps: 0
  });
  assert.equal(report.modes.full.stats.recipes, 526);
  assert.equal(report.modes.full.stats.methodsReady, 403);
  assert.equal(report.modes.full.stats.missingMethods, 123);
  assert.equal(report.modes.full.stats.ingredientMaps, 517);
  assert.equal(report.modes.full.stats.missingIngredientMaps, 9);
  assert.equal(report.modes.full.stats.ingredientEntries, 1706);
  assert.equal(report.modes.full.stats.duplicateIds, 0);
  assert.equal(report.modes.full.stats.duplicateNames, 0);
  assert.equal(report.modes.full.stats.orphanIngredientMaps, 0);
  assert.equal(report.modes.curated.errorCounts['curated-missing-method'] || 0, 0);
  assert.equal(report.modes.curated.errorCounts['curated-missing-ingredient-map'], 28);
  assert.ok(report.modes.curated.warningCounts['missing-qty-unit'] > 0);
  assert.ok(report.modes.curated.warningCounts['short-method'] > 0);
  assert.ok(report.modes.curated.warningCounts['generic-ingredient'] > 0);
  assert.ok(report.modes.curated.warningCounts['ingredient-step-mismatch'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-ingredients'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-methods'] > 0);
});

test('ID baseline and deterministic 28-entry manifest cover exactly the remaining runtime gap', async () => {
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
  assert.equal(manifest.length, 28);
  assert.equal(new Set(manifest.map(entry => entry.id)).size, 28);
  assert.equal(new Set(manifest.map(entry => entry.name)).size, 28);
  assert.ok(manifest.every(entry => entry.methodSource === 'recipe-methods'));
  assert.ok(manifest.every(entry => ['P1', 'P2', 'P3'].includes(entry.priority)));
  assert.ok(manifest.every(entry => Array.isArray(entry.suggestedCoreIngredients)));

  const batchSizes = [...manifest.reduce((groups, entry) => {
    groups.set(entry.batch, (groups.get(entry.batch) || 0) + 1);
    return groups;
  }, new Map()).values()];
  assert.deepEqual(batchSizes, [14, 14]);
  assert.ok(batchSizes.every(size => size >= 10 && size <= 20));
  assert.deepEqual(validateManifest(manifest, runtime.packs.curated, runtime.basePacks, runtime.sources), []);
});

test('Earlier curated static repairs remain mapped and out of the manifest', async () => {
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
  assert.equal(missingIds.size, 28);
});

test('Current first-batch repairs preserve method-backed local names and split compounds', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const manifest = readJson(MANIFEST_PATH);
  const missingIds = new Set(manifest.map(entry => entry.id));
  const compoundPlaceholders = new Set(['姜蒜', '姜葱', '青红椒', '蛋清豆粉', '红白酱油', '蛋豆粉']);
  for (const [id, name, requiredItems] of CURRENT_BATCH_REPAIRS) {
    const recipe = runtime.packs.curated.recipes.find(item => item.id === id);
    assert.equal(recipe?.name, name);
    assert.ok(String(recipe?.method || '').trim(), `${name} must keep its runtime method`);
    const mapped = runtime.packs.curated.recipe_ingredients[id];
    assert.ok(Array.isArray(mapped) && mapped.length > 0, `${name} must have an ingredient map`);
    assert.ok(mapped.every(entry => Object.keys(entry).every(key => key === 'item')), `${name} map must keep the {item} shape`);
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of requiredItems) assert.ok(items.has(item), `${name} should map ${item}`);
    for (const compound of compoundPlaceholders) assert.equal(items.has(compound), false, `${name} must not retain ${compound}`);
    assert.equal(missingIds.has(id), false, `${name} must leave the missing-map manifest`);
  }
  assert.equal(missingIds.size, 28);
});

test('Current first-batch repairs exclude optional and decorative-only method items', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const exclusions = new Map([
    ['锅贴鸡片', ['生菜', '白糖', '醋', '葱白', '甜酱', '番茄酱']],
    ['锅贴腰片', ['韭菜', '生菜']],
    ['鸡豆花', ['鲜菜心', '火腿']],
    ['鸡淖脊髓', ['火腿']],
    ['鸡塔', ['韭菜', '醋']]
  ]);
  for (const [name, forbiddenItems] of exclusions) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const mapped = runtime.packs.curated.recipe_ingredients[recipe.id];
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of forbiddenItems) assert.equal(items.has(item), false, `${name} must exclude ${item}`);
  }
  for (const name of ['红烧卷筒鸡', '煳辣鸡丁']) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    assert.equal(items.has('红白酱油'), false, `${name} must split 红白酱油`);
    assert.equal(items.has('红酱油'), true, `${name} must retain 红酱油`);
    assert.equal(items.has('白酱油'), true, `${name} must retain 白酱油`);
  }
});

test('Next curated batch repairs preserve method evidence, split compounds, and exclude optional or decorative items', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const manifest = readJson(MANIFEST_PATH);
  const missingIds = new Set(manifest.map(entry => entry.id));
  const compoundPlaceholders = new Set(['姜蒜', '姜葱', '青红椒', '红白酱油', '蛋清豆粉', '蛋豆粉']);
  for (const [id, name, requiredItems] of NEXT_BATCH_REPAIRS) {
    const recipe = runtime.packs.curated.recipes.find(item => item.id === id);
    assert.equal(recipe?.name, name);
    assert.ok(String(recipe?.method || '').trim(), `${name} must keep its runtime method`);
    assert.ok(Object.hasOwn(runtime.sources.staticMethods, name), `${name} must use recipe-methods`);
    const mapped = runtime.packs.curated.recipe_ingredients[id];
    assert.ok(Array.isArray(mapped) && mapped.length > 0, `${name} must have an ingredient map`);
    assert.ok(mapped.every(entry => Object.keys(entry).every(key => key === 'item')), `${name} map must keep the {item} shape`);
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of requiredItems) assert.ok(items.has(item), `${name} should map ${item}`);
    for (const compound of compoundPlaceholders) assert.equal(items.has(compound), false, `${name} must not retain ${compound}`);
    assert.equal(missingIds.has(id), false, `${name} must leave the missing-map manifest`);
  }
  assert.equal(missingIds.size, 28);
});

test('Next curated batch keeps exact oil spellings and excludes optional/garnish-only items', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const exclusions = new Map([
    ['凉拌三丝', ['干豆腐丝']],
    ['熘鸡米', ['香油', '鸡油']],
    ['熘桃鸡卷', ['建兰菜']],
    ['龙眼甜烧白', ['白糖']],
    ['麻酥鸡', ['生菜', '椒盐', '葱酱']],
    ['蚂蚁上树', ['高汤', '水', '葱花']],
    ['奶汤大杂烩', ['绿色鲜菜']],
    ['南煎圆子', ['菜心']]
  ]);
  for (const [name, forbiddenItems] of exclusions) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of forbiddenItems) assert.equal(items.has(item), false, `${name} must exclude ${item}`);
  }
  const oilExpectations = new Map([
    ['兰花鸡丝', ['猪油']],
    ['晾干肉', ['菜油', '化猪油', '香油']],
    ['熘鸡米', ['油']],
    ['熘珊瑚鸡丁', ['化猪油', '香油']],
    ['熘桃鸡卷', ['化猪油', '香油']],
    ['龙眼咸烧白', ['菜油']],
    ['麻酥鸡', ['香油', '菜油']],
    ['牡丹鸡片', ['猪油', '油', '鸡油']],
    ['奶汤大杂烩', ['菜油']],
    ['南煎圆子', ['油', '香油']]
  ]);
  for (const [name, expectedOils] of oilExpectations) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of expectedOils) assert.equal(items.has(item), true, `${name} must preserve oil spelling ${item}`);
  }
});

test('Active curated batch repairs preserve final method-backed names and split compounds', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const manifest = readJson(MANIFEST_PATH);
  const missingIds = new Set(manifest.map(entry => entry.id));
  const compoundPlaceholders = new Set(['姜蒜', '姜葱', '青红椒', '红白酱油', '蛋清豆粉', '蛋豆粉']);
  for (const [id, name, requiredItems] of ACTIVE_BATCH_REPAIRS) {
    const recipe = runtime.packs.curated.recipes.find(item => item.id === id);
    assert.equal(recipe?.name, name);
    assert.ok(String(recipe?.method || '').trim(), `${name} must keep its runtime method`);
    assert.ok(Object.hasOwn(runtime.sources.staticMethods, name), `${name} must use recipe-methods`);
    const mapped = runtime.packs.curated.recipe_ingredients[id];
    assert.ok(Array.isArray(mapped) && mapped.length > 0, `${name} must have an ingredient map`);
    assert.ok(mapped.every(entry => Object.keys(entry).every(key => key === 'item')), `${name} map must keep the {item} shape`);
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of requiredItems) assert.ok(items.has(item), `${name} should map ${item}`);
    for (const compound of compoundPlaceholders) assert.equal(items.has(compound), false, `${name} must not retain ${compound}`);
    assert.equal(missingIds.has(id), false, `${name} must leave the missing-map manifest`);
  }
  assert.equal(missingIds.size, 28);
});

test('Active curated batch excludes garnish, side, dipping, wrapper, and generic-only items', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const exclusions = new Map([
    ['泥糊鸡', ['生菜', '糖', '醋', '香油', '土饼泥', '麻绳']],
    ['糯米鸡', ['椒盐']],
    ['清汤腰方', ['青叶菜']],
    ['肉末茄子', ['葱花']],
    ['软炸肚头', ['花椒末', '醋']],
    ['软炸鸡糕', ['生菜']],
    ['软炸腰卷', ['甜酱', '葱白段', '蒜片', '椒盐']],
    ['软炸蒸肉', ['椒盐']],
    ['软炸子盖', ['甜酱', '蒜片', '葱白段']]
  ]);
  for (const [name, forbiddenItems] of exclusions) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of forbiddenItems) assert.equal(items.has(item), false, `${name} must exclude ${item}`);
  }
});

test('Active curated batch keeps exact method oil spellings and local/prepared names', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const oilExpectations = new Map([
    ['南卤肉', ['油']],
    ['泥糊鸡', ['菜油']],
    ['糯米鸡', ['菜油', '香油']],
    ['皮蛋黄瓜汤', ['油']],
    ['啤酒鸭', ['油']],
    ['芹菜炒肉丝', ['油', '香油']],
    ['芹菜香干', ['油']],
    ['肉末茄子', ['油']],
    ['软炸肚头', ['猪油', '香油']],
    ['软炸鸡糕', ['猪油', '香油']],
    ['软炸腰卷', ['菜油', '香油']],
    ['软炸蒸肉', ['油']],
    ['软炸子盖', ['菜油', '香油']],
    ['三色鸡淖', ['猪油']]
  ]);
  for (const [name, expectedOils] of oilExpectations) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of expectedOils) assert.equal(items.has(item), true, `${name} must preserve oil spelling ${item}`);
  }
  const specialNames = new Map([
    ['泥糊鸡', ['鲜荷叶', '泡辣椒']],
    ['糯米鸡', ['仔母鸡', '鲜豌豆仁', '金钩']],
    ['软炸腰卷', ['水发玉兰片', '猪网油']],
    ['软炸子盖', ['五花猪肉', '老姜']],
    ['三色鸡淖', ['生鸡脯肉', '鸡蛋黄']]
  ]);
  for (const [name, expectedItems] of specialNames) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of expectedItems) assert.equal(items.has(item), true, `${name} must preserve method name ${item}`);
  }
});

test('Current manifest batch repairs preserve final method evidence and split compounds', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const manifest = readJson(MANIFEST_PATH);
  const missingIds = new Set(manifest.map(entry => entry.id));
  const compoundPlaceholders = new Set(['姜蒜', '姜葱', '青红椒', '红白酱油', '蛋清豆粉', '蛋豆粉']);
  for (const [id, name, requiredItems] of CURRENT_MANIFEST_BATCH_REPAIRS) {
    const recipe = runtime.packs.curated.recipes.find(item => item.id === id);
    assert.equal(recipe?.name, name);
    assert.ok(String(recipe?.method || '').trim(), `${name} must keep its runtime method`);
    assert.ok(Object.hasOwn(runtime.sources.staticMethods, name), `${name} must use recipe-methods`);
    const mapped = runtime.packs.curated.recipe_ingredients[id];
    assert.ok(Array.isArray(mapped) && mapped.length > 0, `${name} must have an ingredient map`);
    assert.ok(mapped.every(entry => Object.keys(entry).every(key => key === 'item')), `${name} map must keep the {item} shape`);
    const items = new Set(mapped.map(entry => entry.item));
    for (const item of requiredItems) assert.ok(items.has(item), `${name} should map ${item}`);
    for (const compound of compoundPlaceholders) assert.equal(items.has(compound), false, `${name} must not retain ${compound}`);
    assert.equal(missingIds.has(id), false, `${name} must leave the missing-map manifest`);
  }
  assert.equal(missingIds.size, 28);
});

test('Current manifest batch excludes decoration, accompaniments, wash water, and tools while retaining edible wrappers', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const exclusions = new Map([
    ['苕菜狮子头', ['苕菜']],
    ['生烧筋尾舌', ['青菜心', '瘦肉']],
    ['四上玻璃肚', ['番茄', '箩粉', '白酱油', '红酱油', '熟油辣椒', '姜米']],
    ['松花肉', ['鲜豆尖']],
    ['酸辣土豆丝', ['清水', '淀粉']],
    ['蒜蓉空心菜', ['热水']],
    ['坛子肉', ['温水', '清水', '开水', '干锯末', '铁质三脚架', '杠炭', '大口料酒坛', '纸', '草纸', '净布', '稀眼净布']]
  ]);
  for (const [name, forbiddenItems] of exclusions) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of forbiddenItems) assert.equal(items.has(item), false, `${name} must exclude ${item}`);
  }
  const wrappers = new Map([
    ['松子肉', ['豆油皮']],
    ['刷把鸡丝', ['葱叶']]
  ]);
  for (const [name, requiredItems] of wrappers) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of requiredItems) assert.equal(items.has(item), true, `${name} must retain edible/necessary wrapper ${item}`);
  }
});

test('Current manifest batch keeps exact oil spellings and specialized prepared names', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const oilExpectations = new Map([
    ['苕菜狮子头', ['猪油', '鸡油']],
    ['生烧鸡翅', ['猪油', '香油']],
    ['生烧鸡腿', ['鸡油']],
    ['生烧筋尾舌', ['猪油']],
    ['手撕包菜', ['油']],
    ['双色肉糕', ['油']],
    ['松花肉', ['猪油']],
    ['松子肉', ['菜油']],
    ['酸豆角肉末', ['油']],
    ['酸辣土豆丝', ['油']],
    ['蒜蓉空心菜', ['油']],
    ['蒜苔炒肉', ['油']],
    ['坛子肉', ['猪油']]
  ]);
  for (const [name, expectedOils] of oilExpectations) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of expectedOils) assert.equal(items.has(item), true, `${name} must preserve oil spelling ${item}`);
  }
  const specialNames = new Map([
    ['苕菜狮子头', ['金钩', '鲜青豆']],
    ['生烧鸡翅', ['鸡翅', '冬笋', '口蘑', '葱白']],
    ['生烧筋尾舌', ['鲜猪蹄筋', '二汤', '冰糖汁']],
    ['刷把鸡丝', ['熟鸡', '丝瓜皮', '兰片', '葱叶']],
    ['四上玻璃肚', ['草碱']],
    ['松子肉', ['肥瘦相连猪肉', '豆油皮', '二汤', '奶汤']],
    ['酸豆角肉末', ['酸豆角']],
    ['坛子肉', ['珧柱', '大金钩', '肥母鸡', '肥鸭', '肥瘦火腿', '猪肘子肉']]
  ]);
  for (const [name, expectedItems] of specialNames) {
    const recipe = runtime.packs.curated.recipes.find(item => item.name === name);
    const items = new Set(runtime.packs.curated.recipe_ingredients[recipe.id].map(entry => entry.item));
    for (const item of expectedItems) assert.equal(items.has(item), true, `${name} must preserve method name ${item}`);
  }
});

test('analysis mode stays green while strict mode reports the known nonzero data errors', () => {
  const script = join(root, 'scripts', 'recipe-runtime-quality.mjs');
  const analysis = spawnSync(process.execPath, [script], { cwd: root, encoding: 'utf8' });
  assert.equal(analysis.status, 0, analysis.stderr);
  assert.match(analysis.stdout, /errors total=28/);
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
