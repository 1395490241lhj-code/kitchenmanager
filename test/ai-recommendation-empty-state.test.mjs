import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { validateRecommendationResult } from '../src/ai.js';
import { processAiData } from '../src/recommendations.js';
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

// ── 一：过滤后 local/creative 都为空时不崩溃 ─────────────────────────────────

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
  // processAiData 只负责「不喜欢」过滤（黑暗料理过滤在 validateRecommendationResult 里，
  // 针对刚拿到的 AI 原始结果；processAiData 还要处理已保存过的合法旧数据，两者职责不同）。
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
  const pack = { recipes: [] };
  assert.doesNotThrow(() => {
    const cards = processAiData({ local: [], creative: null }, pack);
    assert.deepEqual(cards, []);
  });
});

// ── 二：initRecsState 在「曾保存过 AI 结果，但过滤后为空」时进入 ai-empty ────────

test('initRecsState：savedAi 存在但 processAiData 后为空 → mode 为 ai-empty，不是静默换回 local', () => {
  const source = homeSource();
  const fn = source.slice(source.indexOf('const initRecsState = () => {'), source.indexOf('const stepRecommendation ='));
  assert.match(fn, /if \(aiCards\.length\) return \{ mode: 'ai', cards: aiCards, idx: 0 \};/);
  assert.match(fn, /if \(savedAi\) return \{ mode: 'ai-empty', cards: \[\], idx: 0 \};/);
  assert.match(fn, /return \{ mode: 'local', cards: getInspirationCached\(\), idx: 0 \};/);
});

// ── 三：友好空状态文案与三个操作按钮 ──────────────────────────────────────────

test('renderRecsTab：mode 为 ai-empty 时渲染友好空状态文案，不是"暂无推荐"或空白', () => {
  const source = homeSource();
  assert.match(source, /mode === 'ai-empty'/);
  assert.match(source, /暂时没有合适的 AI 推荐/);
  assert.match(source, /可能是最近做过、已标记不喜欢，或当前库存组合不适合硬凑。/);
});

test('ai-empty 空状态提供三个操作按钮：换一批 / 看本地推荐 / 规划本周菜单', () => {
  const source = homeSource();
  const branch = source.slice(source.indexOf("} else if (mode === 'ai-empty') {"), source.indexOf("} else if (!cards.length) {"));
  assert.match(branch, /id="wxRecEmptyRefresh">换一批</);
  assert.match(branch, /id="wxRecEmptyLocal">看本地推荐</);
  assert.match(branch, /id="wxRecEmptyPlan">规划本周菜单</);
});

test('「换一批」复用共用的 triggerAiRefresh（不是另起一套 AI 调用逻辑）', () => {
  const source = homeSource();
  const branch = source.slice(source.indexOf("} else if (mode === 'ai-empty') {"), source.indexOf("} else if (!cards.length) {"));
  assert.match(branch, /wxRecEmptyRefresh'\)\.onclick = e => triggerAiRefresh\(e\.currentTarget\)/);
  const footerTrigger = source.slice(source.indexOf("const aiTrigger = foot.querySelector"), source.indexOf("const aiTrigger = foot.querySelector") + 200);
  assert.match(footerTrigger, /triggerAiRefresh\(e\.currentTarget\)/);
});

test('「看本地推荐」清掉保存的 AI 推荐、改用本地推荐，且不调用 callCloudAI', () => {
  const source = homeSource();
  const branch = source.slice(source.indexOf("} else if (mode === 'ai-empty') {"), source.indexOf("} else if (!cards.length) {"));
  const localHandler = branch.slice(branch.indexOf("wxRecEmptyLocal').onclick"));
  assert.match(localHandler, /localStorage\.removeItem\(S\.keys\.ai_recs\)/);
  assert.match(localHandler, /mode: 'local', cards: getInspirationCached\(\)/);
  assert.doesNotMatch(localHandler, /callCloudAI/);
});

test('「规划本周菜单」第一版切到计划 Tab', () => {
  const source = homeSource();
  const branch = source.slice(source.indexOf("} else if (mode === 'ai-empty') {"), source.indexOf("} else if (!cards.length) {"));
  assert.match(branch, /wxRecEmptyPlan'\)\.onclick = \(\) => switchTab\('plan'\)/);
});

// ── 四：triggerAiRefresh 过滤后为空也进入 ai-empty，而不是留旧卡片 + 小提示 ──────

test('triggerAiRefresh：AI 结果过滤后为空时进入 ai-empty 并切回推荐 tab', () => {
  const source = homeSource();
  const fn = source.slice(source.indexOf('const triggerAiRefresh = async'), source.indexOf('const isCardControlTarget ='));
  assert.match(fn, /recsState = aiCards\.length \? \{ mode: 'ai', cards: aiCards, idx: 0 \} : \{ mode: 'ai-empty', cards: \[\], idx: 0 \};/);
  assert.match(fn, /switchTab\('recs'\)/);
});
