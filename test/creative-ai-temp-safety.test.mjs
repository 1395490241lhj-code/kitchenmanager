import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { addRecipeToPlan } from '../src/recommendations.js';
import { createUserRecipe } from '../src/components/recipe-create-modal.js';
import { loadOverlay } from '../src/backup.js';
import { S } from '../src/storage.js';

const root = process.cwd();
const BASE_PACK = { recipes: [], recipe_ingredients: {} };

function read(relPath) {
  return readFileSync(join(root, relPath), 'utf8');
}

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
  globalThis.window = { invalidatePackCache() {} };
});

test('creative 临时 id 不能写入计划，正式 AI 菜谱 id 仍可加入', () => {
  assert.equal(addRecipeToPlan('creative-ai-temp', '2026-07-09'), false);
  assert.equal(addRecipeToPlan('creative-anything', '2026-07-09'), false);
  assert.deepEqual(S.load(S.keys.plan, []), []);

  assert.equal(addRecipeToPlan('ai-search-123', '2026-07-09'), true);
  assert.deepEqual(S.load(S.keys.plan, []).map(item => item.id), ['ai-search-123']);
});

test('保存 AI creative 草稿会创建唯一正式菜谱，不写回 creative-ai-temp', () => {
  const newId = createUserRecipe(BASE_PACK, {
    name: '藤椒鸡腿',
    tags: ['AI草稿'],
    ingredients: [{ item: '鸡腿', qty: 2, unit: '只' }, { item: '藤椒', qty: '', unit: '' }],
    method: '1. 鸡腿处理干净。\n2. 下锅煎熟。',
    source: 'ai-creative'
  });

  const overlay = loadOverlay();
  assert.match(newId, /^u-/);
  assert.equal(overlay.recipes['creative-ai-temp'], undefined);
  assert.equal(overlay.recipes[newId].name, '藤椒鸡腿');
  assert.equal(overlay.recipes[newId].source, 'ai-creative');
  assert.deepEqual(overlay.recipe_ingredients[newId].map(item => item.item), ['鸡腿', '藤椒']);
});

test('今日 creative 卡只引导补做法，详情页保存后跳转到唯一正式 id', () => {
  const home = read('src/views/home-view.js');
  const detail = read('src/views/recipe-detail-view.js');
  const quick = read('src/components/recipe-quick-modal.js');
  const editor = read('src/views/recipe-editor-view.js');

  assert.match(home, /const isTemporaryCreative = String\(card\.id\)\.startsWith\('creative-'\)/);
  assert.match(home, /home-suggest-creative-detail">补做法/);
  assert.match(quick, /\$\{!isCreative \? `<button type="button" class="btn ok rqm-primary"/);
  assert.match(detail, /const ovRecipe = isTemporaryCreative \? null : \(overlay\.recipes \|\| \{\}\)\[id\]/);
  assert.match(detail, /const newId = createUserRecipe\(pack, \{/);
  assert.match(detail, /source: 'ai-creative'/);
  assert.match(detail, /location\.hash = `#recipe:\$\{newId\}`/);
  assert.match(editor, /const isTemporaryCreative = String\(id \|\| ''\)\.startsWith\('creative-'\)/);
});
