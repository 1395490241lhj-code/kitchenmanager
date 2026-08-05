import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import {
  HOME_REC_SESSION_VERSION,
  createHomeRecSession,
  getRecommendationCardKey,
  parseHomeRecSession,
  restoreHomeRecSession
} from '../src/utils/home-rec-session.js';
import {
  buildRecommendationSignature,
  getNextUnshownRecommendationIndex,
  getReasonableInventoryRecipeRecommendations,
  processAiData
} from '../src/recommendations.js';
import { S } from '../src/storage.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const root = process.cwd();
const homeSource = () => readFileSync(join(root, 'src/views/home-view.js'), 'utf8');

const PACK = {
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
const INV = [{ name: '番茄', qty: 4, unit: '个', stockStatus: 'ok' }];
const CONTEXT = { favoriteIds: [], recipeActivity: {}, plan: [], today: '2026-06-11' };
const TODAY = '2026-06-11';

function localCards() {
  return getReasonableInventoryRecipeRecommendations(PACK, INV, CONTEXT).map(item => ({
    recipeId: item.recipeId,
    id: item.r.id,
    source: item.source,
    name: item.r.name
  }));
}

function signature() {
  return buildRecommendationSignature(PACK, INV, CONTEXT);
}

// 模拟一次完整 renderHome：面板闭包被丢弃，只剩 localStorage 里的会话。
function simulateRenderHome({ cards = localCards(), creativeCards = [], date = TODAY, sig = signature() } = {}) {
  const restored = restoreHomeRecSession(S.load(S.keys.home_rec_session, null), {
    date,
    signature: sig,
    cards,
    creativeCards
  });
  if (!restored.ok) {
    const shown = new Set();
    if (cards.length) shown.add(getRecommendationCardKey(cards[0]));
    return { fresh: true, reason: restored.reason, mode: cards.length ? 'local' : 'local-empty', idx: 0, shown };
  }
  return {
    fresh: false,
    mode: restored.state.mode,
    idx: restored.state.idx,
    shown: new Set(restored.state.shownIds)
  };
}

function saveSession(mode, currentCardKey, shownIds, extra = {}) {
  S.save(S.keys.home_rec_session, createHomeRecSession({
    date: TODAY,
    signature: signature(),
    mode,
    currentCardKey,
    shownIds,
    ...extra
  }));
}

test('local 模式：currentCardKey 与 shownIds 保存后可跨 render 恢复', () => {
  const cards = localCards();
  assert.equal(cards.length, 4);
  saveSession('local', cards[1].recipeId, [cards[0].recipeId, cards[1].recipeId]);

  const after = simulateRenderHome();
  assert.equal(after.fresh, false);
  assert.equal(after.mode, 'local');
  assert.equal(after.idx, 1);
  assert.deepEqual([...after.shown].sort(), [cards[0].recipeId, cards[1].recipeId].sort());
});

test('返回首页后继续换批不会重复展示已看过的菜谱', () => {
  const cards = localCards();
  // 第一段会话：看过前两张。
  saveSession('local', cards[1].recipeId, [cards[0].recipeId, cards[1].recipeId]);

  const after = simulateRenderHome();
  const nextIndex = getNextUnshownRecommendationIndex(cards, after.idx, after.shown);
  assert.equal(nextIndex, 2, '返回首页后应直接换到第三道，而不是回到第一道');
  assert.equal(after.shown.has(cards[0].recipeId), true);
  assert.equal(after.shown.has(cards[1].recipeId), true);
  assert.equal(after.shown.has(cards[nextIndex].recipeId), false);
});

test('local-exhausted 跨 render 保持耗尽状态', () => {
  const cards = localCards();
  saveSession('local-exhausted', cards[3].recipeId, cards.map(card => card.recipeId));

  const after = simulateRenderHome();
  assert.equal(after.mode, 'local-exhausted');
  assert.equal(after.idx, 3);
  assert.equal(getNextUnshownRecommendationIndex(cards, after.idx, after.shown), -1);
});

test('显式 creative 结果可跨 render 恢复', () => {
  const aiResult = { local: [], creative: { name: 'AI 番茄烩饭', reason: '库存组合', ingredients: [{ item: '番茄' }] } };
  const creativeCards = processAiData(aiResult, PACK).filter(card => card.source === 'creative');
  assert.equal(creativeCards.length, 1);
  saveSession('creative', 'AI 番茄烩饭', [], { explicitCreativeRequested: true });

  const after = simulateRenderHome({ creativeCards });
  assert.equal(after.fresh, false);
  assert.equal(after.mode, 'creative');
  assert.equal(after.idx, 0);
});

test('只有 ai_recs、没有有效 session 标记时首屏仍走本地池', () => {
  const aiResult = { local: [], creative: { name: 'AI 番茄烩饭', reason: '库存组合', ingredients: [{ item: '番茄' }] } };
  const creativeCards = processAiData(aiResult, PACK).filter(card => card.source === 'creative');
  assert.equal(creativeCards.length, 1);

  // ① 完全没有 session
  let after = simulateRenderHome({ creativeCards });
  assert.equal(after.fresh, true);
  assert.equal(after.mode, 'local');

  // ② session 存在但没有 explicitCreativeRequested 标记
  saveSession('creative', 'AI 番茄烩饭', []);
  after = simulateRenderHome({ creativeCards });
  assert.equal(after.fresh, true);
  assert.equal(after.reason, 'creative-unavailable');
  assert.equal(after.mode, 'local');
});

test('creative 结果被过滤为空时安全重置回本地池', () => {
  saveSession('creative', 'AI 番茄烩饭', [], { explicitCreativeRequested: true });
  const after = simulateRenderHome({ creativeCards: [] });
  assert.equal(after.fresh, true);
  assert.equal(after.reason, 'creative-unavailable');
  assert.equal(after.mode, 'local');
  assert.equal(after.idx, 0);
});

test('日期变化重置为最新本地池第一项', () => {
  const cards = localCards();
  saveSession('local', cards[2].recipeId, [cards[0].recipeId, cards[1].recipeId, cards[2].recipeId]);

  const after = simulateRenderHome({ date: '2026-06-12' });
  assert.equal(after.fresh, true);
  assert.equal(after.reason, 'date-changed');
  assert.equal(after.idx, 0);
  assert.deepEqual([...after.shown], [cards[0].recipeId]);
});

test('recommendation signature 变化重置；库存变化确实改变签名', () => {
  const cards = localCards();
  saveSession('local', cards[2].recipeId, cards.slice(0, 3).map(card => card.recipeId));

  const changedInv = [...INV, { name: '豆腐', qty: 1, unit: '块', stockStatus: 'ok' }];
  const changedSignature = buildRecommendationSignature(PACK, changedInv, CONTEXT);
  assert.notEqual(changedSignature, signature(), '库存变化必须改变签名');

  const after = simulateRenderHome({ sig: changedSignature });
  assert.equal(after.fresh, true);
  assert.equal(after.reason, 'signature-changed');
  assert.equal(after.idx, 0);
});

test('收藏与计划变化也会改变签名，从而让旧会话失效', () => {
  const base = signature();
  assert.notEqual(buildRecommendationSignature(PACK, INV, { ...CONTEXT, favoriteIds: ['user-1'] }), base);
  assert.notEqual(buildRecommendationSignature(PACK, INV, { ...CONTEXT, plan: [{ id: 'user-1', servings: 1 }] }), base);
});

test('当前卡片已从候选池移除时安全重置', () => {
  const cards = localCards();
  saveSession('local', cards[2].recipeId, [cards[0].recipeId, cards[2].recipeId]);

  const shrunk = cards.filter(card => card.recipeId !== cards[2].recipeId);
  const after = simulateRenderHome({ cards: shrunk });
  assert.equal(after.fresh, true);
  assert.equal(after.reason, 'card-missing');
  assert.equal(after.idx, 0);
  assert.deepEqual([...after.shown], [shrunk[0].recipeId]);
});

test('损坏或版本不支持的 session 不抛错，直接安全重置', () => {
  const broken = [
    null,
    undefined,
    'not-an-object',
    42,
    [],
    {},
    { version: 999, date: TODAY, signature: signature(), mode: 'local' },
    { version: HOME_REC_SESSION_VERSION, mode: 'local' },
    { version: HOME_REC_SESSION_VERSION, date: TODAY, signature: signature(), mode: 'nonsense' },
    { version: HOME_REC_SESSION_VERSION, date: TODAY, signature: signature(), mode: 'local', shownIds: 'oops' }
  ];
  for (const raw of broken) {
    assert.doesNotThrow(() => parseHomeRecSession(raw));
    const result = restoreHomeRecSession(raw, { date: TODAY, signature: signature(), cards: localCards() });
    assert.equal(result.ok, false, `${JSON.stringify(raw)} 应判为失效`);
    assert.equal(typeof result.reason, 'string');
  }

  // 存进 localStorage 的非法 JSON 也不能让首屏崩溃。
  localStorage.setItem(S.keys.home_rec_session, '{not json');
  assert.doesNotThrow(() => simulateRenderHome());
  assert.equal(simulateRenderHome().fresh, true);
});

test('目标食材搜索不写会话，普通推荐 session 不被污染', () => {
  const cards = localCards();
  saveSession('local', cards[1].recipeId, [cards[0].recipeId, cards[1].recipeId]);
  const before = S.load(S.keys.home_rec_session, null);

  // 搜索态只改面板内存态（mode: 'target' / 'search'），源码中不调用 saveRecsSession。
  const source = homeSource();
  const searchBranch = source.slice(
    source.indexOf("} else if (hasSearchQuery) {"),
    source.indexOf('const { mode, cards, idx } = recsState;')
  );
  assert.doesNotMatch(searchBranch, /saveRecsSession/);

  assert.deepEqual(S.load(S.keys.home_rec_session, null), before);
  const after = simulateRenderHome();
  assert.equal(after.mode, 'local');
  assert.equal(after.idx, 1);
});

test('「看本地推荐」是显式重置：开新会话并清空 shown 集合', () => {
  const cards = localCards();
  saveSession('local', cards[2].recipeId, cards.slice(0, 3).map(card => card.recipeId));

  // 显式重置等价于重新从第一项开会话并写回。
  saveSession('local', cards[0].recipeId, [cards[0].recipeId]);
  const after = simulateRenderHome();
  assert.equal(after.mode, 'local');
  assert.equal(after.idx, 0);
  assert.deepEqual([...after.shown], [cards[0].recipeId]);

  const source = homeSource();
  const localBtn = source.slice(source.indexOf("const localBtn = foot.querySelector('#wxRecLocal')"));
  assert.match(localBtn.slice(0, 400), /startFreshLocalSession\(\)/);
});

test('会话写入时机覆盖初始化 / 换一批 / 耗尽 / creative / 显式重置', () => {
  const source = homeSource();
  assert.match(source, /const startFreshLocalSession = \(\) => \{[\s\S]*?saveRecsSession\('local'/);
  const step = source.slice(source.indexOf('const stepRecommendation ='), source.indexOf('const triggerCreativeRecipe = async'));
  assert.match(step, /saveRecsSession\('local-exhausted'/);
  assert.match(step, /saveRecsSession\('local', getCardKey\(recsState\.cards\[nextIndex\]\)\)/);
  const creative = source.slice(source.indexOf('const triggerCreativeRecipe = async'), source.indexOf('const isCardControlTarget ='));
  assert.match(creative, /saveRecsSession\('creative'[\s\S]*?explicitCreativeRequested: true/);
  // 恢复成功的普通 render 不回写，避免无条件覆盖仍然有效的会话。
  const init = source.slice(source.indexOf('const initRecsState = () => {'), source.indexOf('const stepRecommendation ='));
  assert.match(init, /if \(restored\.ok\) \{/);
  assert.doesNotMatch(init.slice(init.indexOf('if (restored.ok) {'), init.indexOf('return startFreshLocalSession')), /saveRecsSession/);
});

test('会话恢复不改变「本地耗尽后才显示 AI 入口」规则', () => {
  const source = homeSource();
  const renderRecsTab = source.slice(source.indexOf('const renderRecsTab'), source.indexOf('export function renderHome'));
  assert.match(renderRecsTab, /const hasNextLocal = mode === 'local'/);
  assert.match(renderRecsTab, /const showCreativeEntry = mode === 'local-exhausted' \|\| \(mode === 'local' && !hasNextLocal\)/);
  assert.doesNotMatch(renderRecsTab, /callCloudAI/);

  // 恢复出来的 local 会话仍有未展示候选时，不应显示 AI 入口。
  const cards = localCards();
  saveSession('local', cards[0].recipeId, [cards[0].recipeId]);
  const after = simulateRenderHome();
  assert.equal(after.mode, 'local');
  assert.ok(getNextUnshownRecommendationIndex(cards, after.idx, after.shown) >= 0);
});

test('createHomeRecSession 只保存稳定 key，不序列化整个候选池', () => {
  const session = createHomeRecSession({
    date: TODAY,
    signature: signature(),
    mode: 'local',
    currentCardKey: 'user-1',
    shownIds: ['user-1', 'user-1', '', null, 'system-1'],
    explicitCreativeRequested: false
  });
  assert.deepEqual(Object.keys(session).sort(), [
    'currentCardKey', 'date', 'explicitCreativeRequested', 'mode', 'shownIds', 'signature', 'version'
  ]);
  assert.deepEqual(session.shownIds, ['user-1', 'system-1']);
  assert.equal(JSON.stringify(session).includes('recipe_ingredients'), false);
  assert.deepEqual(parseHomeRecSession(JSON.parse(JSON.stringify(session))), session);
});

test('getRecommendationCardKey 与 home-view 的卡片 key 口径一致', () => {
  assert.equal(getRecommendationCardKey({ recipeId: 'r1', id: 'x', name: 'n' }), 'r1');
  assert.equal(getRecommendationCardKey({ id: 'x', name: 'n' }), 'x');
  assert.equal(getRecommendationCardKey({ name: 'n' }), 'n');
  assert.equal(getRecommendationCardKey(null), '');
  assert.match(homeSource(), /const getCardKey = getRecommendationCardKey;/);
});
