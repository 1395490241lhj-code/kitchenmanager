import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('首页首屏用生活化“今晚吃什么”定位，不出现工程化推荐文案', () => {
  const home = read('src/views/home-view.js');
  const recommendations = read('src/recommendations.js');
  const inventoryView = read('src/views/inventory-view.js');
  const combined = `${home}\n${recommendations}\n${inventoryView}`;

  assert.match(home, /今晚吃什么？/);
  assert.match(home, /冰箱里有 \$\{usableCount\} 样食材，可以推荐 \$\{recommendationCount\} 道菜/);
  assert.doesNotMatch(combined, /执行推荐计算|库存状态模块|AI 结构化入口/);
});

test('内置数据不主动使用“韭葱”或 leek 作为食材名', () => {
  const curated = read('data/sichuan-recipes.curated.json');
  const raw = read('data/sichuan-recipes.json');
  const overlay = read('data/recipe-completion-overlay.json');
  assert.doesNotMatch(`${curated}\n${raw}\n${overlay}`, /韭葱|leeks?/i);
});

test('首页菜谱预览区区分本地菜谱和 AI 草稿来源', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /本地菜谱 · 可以直接加入今日计划/);
  assert.match(home, /AI 草稿 ·/);
  assert.match(home, /AI 草稿，确认后才会保存/);
});

test('首页推荐菜谱使用弹窗预览，AI 草稿不伪装成本地菜谱', () => {
  const home = read('src/views/home-view.js');
  const card = read('src/components/recipe-card.js');

  assert.match(home, /renderSuggestCard\(cards\[idx\], pack, inv, \{\s*onPreviewRecipe: openRecipePreviewModal,\s*onPreviewVariant: openRecipeVariantPreviewModal,\s*onRoute\s*\}\)/);
  assert.match(home, /showRecommendationCards\(cardWrap, \[cards\[idx\]\], pack, \{ onRoute, onPreviewRecipe: openRecipePreviewModal, inv \}\)/);
  assert.match(card, /onPreviewRecipe = null/);
  assert.match(card, /!isCreative/);
});

test('首页加入今日计划入口接入统一 Toast，且保留按钮反馈', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /showToast/);
  assert.match(home, /brieflyConfirmButton/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.match(home, /已加入今日计划，缺的食材已加入买菜清单/);
  assert.match(home, /已加入今日计划，缺的食材可稍后处理/);
});
