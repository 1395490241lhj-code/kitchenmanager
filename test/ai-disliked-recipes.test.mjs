import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  getDislikedAiRecipeNames,
  markAiRecipeDisliked,
  isAiRecipeDisliked
} from '../src/utils/ai-disliked-recipes.js';
import { validateRecommendationResult, callCloudAI } from '../src/ai.js';
import { processAiData } from '../src/recommendations.js';
import { S } from '../src/storage.js';

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

const oldLocalStorage = global.localStorage;
const oldFetch = global.fetch;

function createStorage() {
  const data = new Map();
  return {
    getItem(key) { return data.has(key) ? data.get(key) : null; },
    setItem(key, value) { data.set(key, String(value)); },
    removeItem(key) { data.delete(key); },
    clear() { data.clear(); }
  };
}

beforeEach(() => {
  global.localStorage = createStorage();
});

afterEach(() => {
  global.fetch = oldFetch;
  global.localStorage = oldLocalStorage;
});

// ── 一/二：存储 + 工具函数 ──────────────────────────────────────────────────

test('markAiRecipeDisliked 会保存菜名，isAiRecipeDisliked 能命中', () => {
  assert.equal(isAiRecipeDisliked('茭笋青椒瘦肉炒蛋'), false);
  const ok = markAiRecipeDisliked('茭笋青椒瘦肉炒蛋', '用户标记不喜欢');
  assert.equal(ok, true);
  assert.equal(isAiRecipeDisliked('茭笋青椒瘦肉炒蛋'), true);
  assert.deepEqual(getDislikedAiRecipeNames(), ['茭笋青椒瘦肉炒蛋']);
});

test('name 为空不保存', () => {
  assert.equal(markAiRecipeDisliked(''), false);
  assert.equal(markAiRecipeDisliked('   '), false);
  assert.deepEqual(getDislikedAiRecipeNames(), []);
});

test('归一化空格：前后空格不影响命中', () => {
  markAiRecipeDisliked('  茭笋炒蛋  ');
  assert.equal(isAiRecipeDisliked('茭笋炒蛋'), true);
  assert.equal(isAiRecipeDisliked('  茭笋炒蛋  '), true);
});

test('同名覆盖更新时间，不会重复存两条', () => {
  markAiRecipeDisliked('茭笋炒蛋', '第一次');
  const map1 = S.load(S.keys.ai_disliked_recipes, {});
  const firstTs = map1['茭笋炒蛋'].ts;
  markAiRecipeDisliked('茭笋炒蛋', '第二次');
  const map2 = S.load(S.keys.ai_disliked_recipes, {});
  assert.equal(Object.keys(map2).length, 1);
  assert.equal(map2['茭笋炒蛋'].reason, '第二次');
  assert.ok(map2['茭笋炒蛋'].ts >= firstTs);
});

test('最多保存 100 条，超出时删除最旧的', () => {
  for (let i = 0; i < 105; i++) {
    markAiRecipeDisliked(`菜${i}`, '测试', );
  }
  const names = getDislikedAiRecipeNames();
  assert.equal(names.length, 100);
  // 最早的 5 条（菜0..菜4）应被删除，最新的应保留。
  assert.equal(isAiRecipeDisliked('菜0'), false);
  assert.equal(isAiRecipeDisliked('菜4'), false);
  assert.equal(isAiRecipeDisliked('菜104'), true);
  assert.equal(isAiRecipeDisliked('菜5'), true);
});

// ── 四：AI prompt 接入 ───────────────────────────────────────────────────────

test('callCloudAI prompt 包含 disliked 菜名，提示 AI 避免推荐', async () => {
  markAiRecipeDisliked('茭笋青椒瘦肉炒蛋');
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({
        content: JSON.stringify({
          local: [],
          creative: { name: '青椒肉丝', reason: '快手', ingredients: [{ item: '青椒' }, { item: '肉丝' }] }
        })
      })
    };
  };

  const pack = { recipes: [] };
  const inv = [{ name: '青椒' }, { name: '肉丝' }];
  await callCloudAI(pack, inv);

  assert.match(request.body.prompt, /用户之前标记过这些菜不喜欢或不合理/);
  assert.match(request.body.prompt, /茭笋青椒瘦肉炒蛋/);
});

test('没有 disliked 菜名时，prompt 不包含该规则段落', async () => {
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({
        content: JSON.stringify({
          local: [],
          creative: { name: '青椒肉丝', reason: '快手', ingredients: [{ item: '青椒' }, { item: '肉丝' }] }
        })
      })
    };
  };
  await callCloudAI({ recipes: [] }, [{ name: '青椒' }]);
  assert.doesNotMatch(request.body.prompt, /用户之前标记过这些菜不喜欢或不合理/);
});

// ── 五：本地后处理过滤 ───────────────────────────────────────────────────────

test('validateRecommendationResult：disliked 的 creative 名字被丢弃为 null，local 保留', () => {
  markAiRecipeDisliked('茭笋青椒瘦肉炒蛋');
  const result = validateRecommendationResult(JSON.stringify({
    local: [{ name: '番茄炒蛋', reason: '库存齐全' }],
    creative: {
      name: '茭笋青椒瘦肉炒蛋',
      reason: '用掉库存',
      ingredients: [{ item: '茭笋' }, { item: '肉丝' }]
    }
  }));
  assert.equal(result.creative, null);
  assert.deepEqual(result.local, [{ name: '番茄炒蛋', reason: '库存齐全' }]);
});

test('validateRecommendationResult：disliked 的 local 菜名会被过滤，其它 local 保留', () => {
  markAiRecipeDisliked('麻婆豆腐');
  const result = validateRecommendationResult(JSON.stringify({
    local: [{ name: '麻婆豆腐', reason: '常备' }, { name: '青椒肉丝', reason: '快手' }],
    creative: null
  }));
  assert.deepEqual(result.local.map(x => x.name), ['青椒肉丝']);
});

test('validateRecommendationResult：过滤后 local 和 creative 都还有一个可用即可，不报错', () => {
  markAiRecipeDisliked('麻婆豆腐');
  const result = validateRecommendationResult(JSON.stringify({
    local: [{ name: '麻婆豆腐', reason: '常备' }],
    creative: { name: '青椒肉丝', reason: '快手', ingredients: [{ item: '青椒' }, { item: '肉丝' }] }
  }));
  assert.equal(result.local.length, 0);
  assert.equal(result.creative.name, '青椒肉丝');
});

test('processAiData：disliked 的 creative 不生成卡片，local 中 disliked 名字被过滤', () => {
  markAiRecipeDisliked('茭笋青椒瘦肉炒蛋');
  markAiRecipeDisliked('麻婆豆腐');
  const pack = { recipes: [{ id: 'r1', name: '麻婆豆腐', tags: [] }, { id: 'r2', name: '青椒肉丝', tags: [] }] };
  const cards = processAiData({
    local: [{ name: '麻婆豆腐', reason: '常备' }, { name: '青椒肉丝', reason: '快手' }],
    creative: { name: '茭笋青椒瘦肉炒蛋', reason: '用掉库存', ingredients: [{ item: '茭笋' }] }
  }, pack);
  assert.deepEqual(cards.map(c => c.r.name), ['青椒肉丝']);
});

// ── 六/七：UI 接线 + 不影响正式菜谱数据 ──────────────────────────────────────

test('AI creative 推荐卡：点击「不合理/不喜欢」只调用 markAiRecipeDisliked，不写 overlay/plan', () => {
  const source = read('src/components/recipe-card.js');
  const handler = source.slice(
    source.indexOf("dislikeBtn.onclick = (event) => {"),
    source.indexOf("card.querySelector('.controls').appendChild(dislikeBtn);")
  );
  assert.match(handler, /markAiRecipeDisliked\(r\.name\)/);
  assert.doesNotMatch(handler, /saveOverlay\(/);
  assert.doesNotMatch(handler, /S\.save\(S\.keys\.plan/);
});

test('AI 草稿详情页：点击「不合理/不喜欢」只调用 markAiRecipeDisliked，不改动正式菜谱库', () => {
  const source = read('src/views/recipe-detail-view.js');
  const handler = source.slice(
    source.indexOf('dislikeBtn.onclick = () => {'),
    source.indexOf('const actionFeedback = ')
  );
  assert.match(handler, /markAiRecipeDisliked\(r\.name\)/);
  assert.doesNotMatch(handler, /saveOverlay\(/);
  assert.doesNotMatch(handler, /overlay\.recipes/);
});

test('详情页：不喜欢按钮只在 AI 草稿（isCreative/isAiDraft）时渲染', () => {
  const source = read('src/views/recipe-detail-view.js');
  assert.match(source, /const aiDislikeBtnHtml = \(r\.isCreative \|\| r\.isAiDraft\)/);
});

test('今日推荐「更多操作」弹层：只在 AI creative 卡片上出现「不合理/不喜欢」，点击只调用 markAiRecipeDisliked', () => {
  const source = read('src/views/home-view.js');
  const fn = source.slice(
    source.indexOf('function openTodayMoreActionsSheet'),
    source.indexOf('function openTodayMoreActionsSheet') + source.slice(source.indexOf('function openTodayMoreActionsSheet')).indexOf('\n}\n')
  );
  assert.match(fn, /const isAiCreative = String\(recipeId\)\.startsWith\('creative-'\)/);
  assert.match(fn, /isAiCreative && dislikeName \? '<button type="button" class="today-sheet-action is-danger" data-action="dislike">不合理\/不喜欢<\/button>' : ''/);
  const dislikeHandler = fn.slice(fn.indexOf("if (action === 'dislike'"));
  assert.match(dislikeHandler, /markAiRecipeDisliked\(dislikeName\)/);
  assert.doesNotMatch(dislikeHandler, /saveOverlay\(/);
  assert.doesNotMatch(dislikeHandler, /deleteRecipeFromOverlay/);
});
