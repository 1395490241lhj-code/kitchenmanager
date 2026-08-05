import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { validateRecommendationResult } from '../src/ai.js';
import { getNextUnshownRecommendationIndex, getReasonableInventoryRecipeRecommendations, processAiData } from '../src/recommendations.js';
import { markAiRecipeDisliked } from '../src/utils/ai-disliked-recipes.js';

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

const oldLocalStorage = global.localStorage;
function createStorage() {
  const data = new Map();
  return {
    getItem(key) { return data.has(key) ? data.get(key) : null; },
    setItem(key, value) { data.set(key, String(value)); },
    removeItem(key) { data.delete(key); },
    clear() { data.clear(); }
  };
}
beforeEach(() => { global.localStorage = createStorage(); });
afterEach(() => { global.localStorage = oldLocalStorage; });

function homeSource() {
  return read('src/views/home-view.js');
}

test('黑暗料理 + 不喜欢过滤都命中后，validateRecommendationResult 抛出可预期错误而不是崩溃', () => {
  markAiRecipeDisliked('青椒肉丝');
  assert.throws(() => validateRecommendationResult(JSON.stringify({
    local: [{ name: '青椒肉丝', reason: '快手' }],
    creative: {
      name: '茭笋青椒瘦肉炒蛋',
      reason: '用掉库存',
      ingredients: [{ item: '茭笋' }, { item: '青椒' }, { item: '瘦肉' }, { item: '鸡蛋' }]
    }
  })), /推荐结果里没有可用菜谱/);
});

test('processAiData 面对全部被过滤的 aiResult：返回空数组，不抛异常', () => {
  markAiRecipeDisliked('青椒肉丝');
  markAiRecipeDisliked('茭笋青椒瘦肉炒蛋');
  const pack = { recipes: [{ id: 'r1', name: '青椒肉丝', tags: [] }] };
  assert.doesNotThrow(() => {
    const cards = processAiData({
      local: [{ name: '青椒肉丝', reason: '快手' }],
      creative: {
        name: '茭笋青椒瘦肉炒蛋',
        reason: '用掉库存',
        ingredients: [{ item: '茭笋' }, { item: '青椒' }, { item: '瘦肉' }, { item: '鸡蛋' }]
      }
    }, pack);
    assert.deepEqual(cards, []);
  });
});

test('processAiData 面对 local:[]/creative:null 的空 aiResult：返回空数组，不抛异常', () => {
  assert.doesNotThrow(() => {
    const cards = processAiData({ local: [], creative: null }, { recipes: [] });
    assert.deepEqual(cards, []);
  });
});

test('processAiData 为 AI 创意菜明确标记 creative 且不伪装成正式菜谱', () => {
  const cards = processAiData({
    local: [],
    creative: { name: '番茄炒蛋', reason: '库存没有现成候选', ingredients: [{ item: '番茄' }, { item: '鸡蛋' }] }
  }, { recipes: [] });
  assert.equal(cards[0].recipeId, null);
  assert.equal(cards[0].source, 'creative');
  assert.deepEqual(cards[0].matchedIngredients, ['番茄', '鸡蛋']);
});

test('initRecsState：默认读取完整本地候选池，ai_recs 只能经会话闸门被消费', () => {
  const source = homeSource();
  const fn = source.slice(source.indexOf('const initRecsState = () => {'), source.indexOf('const stepRecommendation ='));
  assert.match(fn, /const cards = getLocalCached\(\);/);
  // 没有可恢复的会话时一律开新的本地轮换会话（第一项），不看 AI。
  assert.match(fn, /return startFreshLocalSession\(\);/);
  assert.match(source, /const startFreshLocalSession = \(\) => \{[\s\S]*?return \{ mode: 'local', cards, idx: 0 \};/);
  // ai_recs 只用于给 restoreHomeRecSession 提供候选，且只有 mode='creative' +
  // explicitCreativeRequested 的有效会话才会走进 creative 分支（行为断言见
  // test/home-rec-session.test.mjs：「只有 ai_recs、没有有效 session 标记时首屏仍走本地池」）。
  assert.match(fn, /restoreHomeRecSession\(S\.load\(S\.keys\.home_rec_session, null\)/);
  assert.match(fn, /if \(restored\.state\.mode === 'creative'\)/);
  const beforeRestore = fn.slice(0, fn.indexOf('const restored ='));
  assert.doesNotMatch(beforeRestore, /return \{ mode: 'creative'/);
});

test('首页首次推荐和推荐 tab 共用本地候选调用链，不从 ai_recs 自动接管', () => {
  const source = homeSource();
  const renderHome = source.slice(source.indexOf('export function renderHome'));
  assert.match(renderHome, /getLocalRecommendationCards\(pack, inv\)\.slice\(0, 3\)/);
  assert.match(source, /const getLocalCached = \(\) => \{[\s\S]*?getLocalRecommendationCards\(pack, inv\)/);
  assert.doesNotMatch(renderHome, /S\.load\(S\.keys\.ai_recs/);
});

test('renderRecsTab：没有本地候选时渲染独立 AI 创作空状态', () => {
  const source = homeSource();
  const branch = source.slice(source.indexOf("} else if (mode === 'local-empty') {"), source.indexOf("} else if (mode === 'creative') {"));
  assert.match(branch, /暂时没有合适的本地菜谱/);
  assert.match(branch, /只用一部分库存/);
  assert.match(branch, /id="wxRecCreative">✨ AI 创作新菜/);
});

test('本地候选耗尽后只显示 AI 创作入口，不把“换一批”变成 AI 请求', () => {
  const source = homeSource();
  const renderRecsTab = source.slice(source.indexOf('const renderRecsTab'), source.indexOf('export function renderHome'));
  assert.match(renderRecsTab, /const hasNextLocal = mode === 'local'/);
  assert.match(renderRecsTab, /const showCreativeEntry = mode === 'local-exhausted' \|\| \(mode === 'local' && !hasNextLocal\)/);
  assert.match(renderRecsTab, /id="wxRecNext">换一批/);
  assert.match(renderRecsTab, /id="wxRecCreative">✨ AI 创作新菜/);
  assert.match(renderRecsTab, /nextBtn\.onclick = \(\) => stepRecommendation\(1\)/);
  assert.doesNotMatch(renderRecsTab, /callCloudAI/);
});

test('连续换批只寻找未展示的本地 recipeId，并保留 source', async () => {
  const cards = [
    { recipeId: 'user-1', source: 'user', name: '用户菜' },
    { recipeId: 'system-1', source: 'system', name: '系统菜' },
    { recipeId: 'user-2', source: 'user', name: '用户第二道' }
  ];
  const shown = new Set(['user-1']);
  const firstNext = getNextUnshownRecommendationIndex(cards, 0, shown);
  assert.equal(firstNext, 1);
  shown.add(cards[firstNext].recipeId);
  const secondNext = getNextUnshownRecommendationIndex(cards, firstNext, shown);
  assert.equal(secondNext, 2);
  assert.equal(cards[secondNext].recipeId, 'user-2');
  assert.equal(cards[secondNext].source, 'user');
});

test('四个合理本地候选可连续换到第 4 个，候选耗尽前不进入 AI', () => {
  const pack = {
    recipes: [
      { id: 'user-1', name: '用户菜一', method: '做', source: 'user' },
      { id: 'system-1', name: '系统菜一', method: '做' },
      { id: 'user-2', name: '用户菜二', method: '做', source: 'user' },
      { id: 'system-2', name: '系统菜二', method: '做' }
    ],
    recipe_ingredients: {
      'user-1': [{ item: '番茄', qty: 1, unit: '个' }],
      'system-1': [{ item: '番茄', qty: 1, unit: '个' }],
      'user-2': [{ item: '番茄', qty: 1, unit: '个' }],
      'system-2': [{ item: '番茄', qty: 1, unit: '个' }]
    }
  };
  const cards = getReasonableInventoryRecipeRecommendations(pack, [
    { name: '番茄', qty: 2, unit: '个', stockStatus: 'ok' }
  ], { source: 'test' }).map(item => ({
    recipeId: item.recipeId,
    source: item.source,
    name: item.r.name
  }));
  assert.equal(cards.length, 4);

  const shown = new Set([cards[0].recipeId]);
  let currentIndex = 0;
  for (let count = 1; count < cards.length; count += 1) {
    const nextIndex = getNextUnshownRecommendationIndex(cards, currentIndex, shown);
    assert.notEqual(nextIndex, -1, `第 ${count + 1} 道本地菜谱应仍可换出`);
    currentIndex = nextIndex;
    shown.add(cards[currentIndex].recipeId);
  }
  assert.equal(shown.size, 4);
  assert.equal(currentIndex, cards.length - 1);
  assert.equal(getNextUnshownRecommendationIndex(cards, currentIndex, shown), -1);

  const source = homeSource();
  const localPool = source.slice(source.indexOf('function getInspirationCards'), source.indexOf('function getLocalRecommendationCards'));
  const renderRecsTab = source.slice(source.indexOf('const renderRecsTab'), source.indexOf('export function renderHome'));
  assert.match(localPool, /if \(cards\.length < maxCards\) pushRecipe\(row\);/);
  assert.match(renderRecsTab, /const showCreativeEntry = mode === 'local-exhausted'/);
  assert.doesNotMatch(renderRecsTab, /callCloudAI/);
});

test('只有显式点击 AI 创作入口的 handler 才传 allowCreative:true', () => {
  const source = homeSource();
  const handler = source.slice(source.indexOf('const triggerCreativeRecipe = async'), source.indexOf('const isCardControlTarget ='));
  assert.match(handler, /callCloudAI\(pack, inv, \{ allowCreative: true \}\)/);
  assert.match(handler, /processAiData\(aiResult, pack\)\.filter\(card => card\.source === 'creative'\)/);
  assert.doesNotMatch(source.slice(source.indexOf('const stepRecommendation ='), source.indexOf('const triggerCreativeRecipe = async')), /callCloudAI/);
});
