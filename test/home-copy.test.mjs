import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('首页泛化时间文案使用“今天”，不默认说“今晚可以做”', () => {
  const home = read('src/views/home-view.js');
  const recommendations = read('src/recommendations.js');
  const inventoryView = read('src/views/inventory-view.js');
  const combined = `${home}\n${recommendations}\n${inventoryView}`;

  assert.match(home, /今天可以做 \$\{recommendationCount\} 道菜/);
  assert.doesNotMatch(combined, /今晚可以做|今晚推荐|今晚想吃|今晚吃什么|今晚安排|今晚能做|看今晚推荐/);
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
