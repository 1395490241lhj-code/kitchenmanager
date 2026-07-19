import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  buildGroundedFallbackRecipe,
  findLongestTermSpans
} = require('../src/server/services/grounded-recipe-fallback');

function buildRecipe(overrides = {}) {
  return buildGroundedFallbackRecipe({
    sourceMetadata: { sourceTitle: '青椒肉丝' },
    fallbackReason: 'rate_limit_exceeded',
    ...overrides
  });
}

function allRecipeText(recipe) {
  return JSON.stringify(recipe);
}

test('grounded fallback 不在无鸡腿证据时生成鸡腿或固定藤椒步骤', () => {
  const recipe = buildRecipe({
    transcriptText: '肉丝切好。加入土豆淀粉抓匀。锅中下肉丝翻炒后出锅。'
  });

  assert.doesNotMatch(allRecipeText(recipe), /鸡腿|藤椒|花椒/);
  assert.deepEqual(recipe.method, ['肉丝切好。', '加入土豆淀粉抓匀。', '锅中下肉丝翻炒后出锅。']);
  assert.equal(recipe.needsReview, true);
  assert.equal(recipe.diagnostics.fallbackFabricatedQuantityCount, 0);
});

test('longest-match span 阻止鱼香肉丝把鱼提升为食材', () => {
  const recipe = buildRecipe({ transcriptText: '上次鱼香肉丝讲过这个问题。青椒切丝。' });
  assert.ok(!recipe.ingredients.some(item => item.item === '鱼'));
  assert.doesNotMatch(recipe.method.join('\n'), /鱼/);
  assert.ok(recipe.diagnostics.fallbackRejectedIncidentalCount >= 1);
  assert.deepEqual(findLongestTermSpans('鱼香肉丝').spans.map(span => span.term), ['鱼香肉丝']);
});

test('longest-match span 将土豆淀粉保留为调料而不是土豆', () => {
  const recipe = buildRecipe({ transcriptText: '加入土豆淀粉抓匀。' });
  assert.ok(recipe.seasonings.some(item => item.item === '土豆淀粉'));
  assert.ok(!recipe.ingredients.some(item => item.item === '土豆'));
  assert.ok(recipe.diagnostics.fallbackRejectedCompoundCollisionCount >= 1);
});

test('有媒体证据时不扫描页面推荐牛肉面', () => {
  const recipe = buildRecipe({
    trustedPageText: '青椒肉丝。相关推荐：红烧牛肉面。',
    transcriptText: '青椒切丝。肉丝下锅翻炒。'
  });
  assert.ok(!recipe.ingredients.some(item => item.item === '牛肉'));
  assert.ok(!recipe.ingredients.some(item => item.item === '面条'));
  assert.equal(recipe.diagnostics.fallbackUsedPageText, false);
  assert.equal(recipe.diagnostics.fallbackUsedTranscript, true);
});

test('青椒不会隐式生成辣椒', () => {
  const recipe = buildRecipe({ transcriptText: '青椒切丝后下锅炒。' });
  assert.ok(recipe.ingredients.some(item => item.item === '青椒'));
  assert.ok(!recipe.seasonings.some(item => item.item === '辣椒'));
});

test('鱼露和鸡精不会生成鱼或鸡肉类主料', () => {
  const recipe = buildRecipe({ transcriptText: '加入鱼露和鸡精调味。' });
  assert.ok(recipe.seasonings.some(item => item.item === '鱼露'));
  assert.ok(recipe.seasonings.some(item => item.item === '鸡精'));
  assert.ok(!recipe.ingredients.some(item => ['鱼', '鸡肉', '鸡腿'].includes(item.item)));
});

test('来源没有用量时 qty 和 unit 保持空字符串', () => {
  const recipe = buildRecipe({ transcriptText: '用料：猪肉、青椒、生抽。猪肉切丝后加入生抽抓匀。' });
  const rows = [...recipe.ingredients, ...recipe.seasonings];
  assert.ok(rows.some(row => row.item === '猪肉'));
  assert.ok(rows.some(row => row.item === '青椒'));
  assert.ok(rows.some(row => row.item === '生抽'));
  assert.ok(rows.every(row => row.qty === '' && row.unit === ''));
  assert.doesNotMatch(allRecipeText(recipe), /1份|1适量/);
});

test('来源明确用量时原样保留 qty 和 unit', () => {
  const recipe = buildRecipe({ transcriptText: '用料：猪肉250克，青椒2个，生抽1勺。' });
  assert.deepEqual(recipe.ingredients.find(item => item.item === '猪肉'), { item: '猪肉', qty: '250', unit: '克' });
  assert.deepEqual(recipe.ingredients.find(item => item.item === '青椒'), { item: '青椒', qty: '2', unit: '个' });
  assert.deepEqual(recipe.seasonings.find(item => item.item === '生抽'), { item: '生抽', qty: '1', unit: '勺' });
});

test('只有一条可靠动作时不自动补齐步骤', () => {
  const recipe = buildRecipe({ transcriptText: '青椒切丝。今天聊一下刀工。' });
  assert.deepEqual(recipe.method, ['青椒切丝。']);
  assert.equal(recipe.needsReview, true);
});

test('没有可靠动作时 method 为空并提示人工补充', () => {
  const recipe = buildRecipe({ transcriptText: '今天介绍青椒肉丝，欢迎收藏关注。' });
  assert.deepEqual(recipe.method, []);
  assert.match(recipe.warnings.join('\n'), /未能可靠提取做法步骤/);
});

test('transcript 与推荐页面冲突时只使用 transcript/current-note evidence', () => {
  const recipe = buildRecipe({
    trustedPageText: '相关推荐：红烧牛肉面，牛肉切块后炖煮。',
    transcriptText: '青椒切丝。肉丝下锅翻炒。'
  });
  assert.ok(recipe.ingredients.some(item => item.item === '青椒'));
  assert.ok(!recipe.ingredients.some(item => item.item === '牛肉'));
  assert.doesNotMatch(recipe.method.join('\n'), /牛肉|炖煮/);
});
