import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import { validateCompleteDraftRecipeResult } from '../src/ai.js';

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}
function ai() {
  return read('src/ai.js');
}
function draftPrompt() {
  const source = ai();
  return source.slice(
    source.indexOf('export async function callAiCompleteDraftRecipe'),
    source.indexOf('export async function callAiForCookedMeal')
  );
}

// ── 一 / 二：prompt 文案要求 ────────────────────────────────────────────────

test('AI 草稿补全 prompt 要求保持原菜名', () => {
  assert.match(draftPrompt(), /必须保持原菜名/);
});

test('AI 草稿补全 prompt 要求不要新增核心主材', () => {
  assert.match(draftPrompt(), /不要新增核心主材/);
});

test('AI 草稿补全 prompt 对肉类要求切配、腌制、先炒/滑散', () => {
  const prompt = draftPrompt();
  assert.match(prompt, /切片\/切丝\/切块/);
  assert.match(prompt, /简单腌制/);
  assert.match(prompt, /先炒肉\/滑散肉/);
});

test('AI 草稿补全 prompt 要求调料只出现在 method 文字里，不进 ingredients', () => {
  const prompt = draftPrompt();
  assert.match(prompt, /盐、生抽、老抽、料酒、淀粉、胡椒、食用油、葱姜蒜/);
  assert.match(prompt, /调料不要写进 ingredients 数组/);
});

test('AI 草稿补全 prompt 要求只输出 JSON，不要 markdown', () => {
  assert.match(draftPrompt(), /只输出 JSON 本身，不要 markdown 代码块/);
});

// ── 四：method 步骤太少直接拒绝 ─────────────────────────────────────────────

test('method 少于 3 步时被拒绝（内容质量问题，不是网络失败）', () => {
  const raw = JSON.stringify({
    name: '茭笋炒肉',
    ingredients: [{ item: '茭笋' }, { item: '瘦肉' }],
    method: '1. 洗净切好。\n2. 下锅炒熟。'
  });
  assert.throws(
    () => validateCompleteDraftRecipeResult(raw, { name: '茭笋炒肉', ingredients: [{ item: '茭笋' }, { item: '瘦肉' }] }),
    err => err.isDraftQualityIssue === true
  );
});

test('method 恰好 3 步及以上可以通过', () => {
  const original = [{ item: '茭笋' }, { item: '瘦肉' }];
  const draft = validateCompleteDraftRecipeResult(JSON.stringify({
    name: '茭笋炒肉',
    ingredients: original,
    method: '1. 茭笋洗净切片，瘦肉切丝。\n2. 瘦肉加生抽料酒淀粉抓匀腌 10 分钟。\n3. 热锅下油炒香出锅。'
  }), { name: '茭笋炒肉', ingredients: original });
  assert.equal(draft.method.split('\n').length, 3);
});

// ── 五：调料不会进入 ingredients ─────────────────────────────────────────────

test('AI 混入调料/新核心食材时，合并结果只保留原有核心食材名（不新增、不新增调料）', () => {
  const original = [{ item: '茭笋' }, { item: '瘦肉' }];
  const draft = validateCompleteDraftRecipeResult(JSON.stringify({
    name: '茭笋炒肉',
    ingredients: [
      { item: '茭笋', qty: '1', unit: '根' },
      { item: '瘦肉', qty: '150', unit: '克' },
      { item: '盐', qty: '1', unit: '克' },       // 调料，不应进入
      { item: '青椒', qty: '1', unit: '个' }       // AI 新增核心主材，不应进入
    ],
    method: '1. 茭笋洗净切片，瘦肉切丝。\n2. 瘦肉加生抽料酒淀粉抓匀腌 10 分钟。\n3. 热锅下油，先炒瘦肉盛出，再下茭笋炒香回锅调味出锅。'
  }), { name: '茭笋炒肉', ingredients: original });
  assert.deepEqual(draft.ingredients.map(it => it.item), ['茭笋', '瘦肉']);
  assert.equal(draft.ingredients.find(it => it.item === '茭笋').qty, '1');
});

test('原本没有已知核心食材时（空 ingredients 兜底分支），AI 返回的调料仍被过滤掉', () => {
  const draft = validateCompleteDraftRecipeResult(JSON.stringify({
    name: '番茄炒蛋',
    ingredients: [
      { item: '番茄' }, { item: '鸡蛋' }, { item: '盐' }, { item: '食用油' }
    ],
    method: '1. 番茄切块，鸡蛋打散。\n2. 热锅下油炒散鸡蛋盛出。\n3. 下番茄炒软，倒回鸡蛋加盐翻炒出锅。'
  }), { name: '番茄炒蛋', ingredients: [] });
  assert.deepEqual(draft.ingredients.map(it => it.item), ['番茄', '鸡蛋']);
});

// ── 四：黑暗料理回流拦截 ─────────────────────────────────────────────────────

test('原本没有已知核心食材时，AI 硬凑出的黑暗料理组合会被拒绝', () => {
  const raw = JSON.stringify({
    name: '茭笋炒肉',
    ingredients: [
      { item: '茭笋' }, { item: '青椒' }, { item: '瘦肉' }, { item: '鸡蛋' }
    ],
    method: '1. 全部食材洗净切好。\n2. 热锅下油依次下入炒熟。\n3. 加盐调味出锅。'
  });
  assert.throws(
    () => validateCompleteDraftRecipeResult(raw, { name: '茭笋炒肉', ingredients: [] }),
    err => err.isDraftQualityIssue === true && /不够合理/.test(err.message)
  );
});

test('name 永远保持调用方传入的原名，不会被 AI 返回的 name 顶替', () => {
  const original = [{ item: '茭笋' }, { item: '瘦肉' }];
  const draft = validateCompleteDraftRecipeResult(JSON.stringify({
    name: '茭笋青椒瘦肉炒蛋', // AI 擅自改了名字
    ingredients: original,
    method: '1. 茭笋洗净切片，瘦肉切丝。\n2. 瘦肉腌制后先炒变色盛出。\n3. 下茭笋炒香，回锅瘦肉调味出锅。'
  }), { name: '茭笋炒肉', ingredients: original });
  assert.equal(draft.name, '茭笋炒肉');
});

// ── 六、验收标准：茭笋炒肉 + [茭笋、瘦肉] ────────────────────────────────────

test('验收示例：茭笋炒肉 + 茭笋/瘦肉 的合理草稿可以通过校验', () => {
  const original = [{ item: '茭笋' }, { item: '瘦肉' }];
  const method = [
    '茭笋洗净切片，瘦肉切片或切丝。',
    '瘦肉加少许生抽、料酒、淀粉抓匀腌 10 分钟。',
    '热锅下油，先把瘦肉炒至变色盛出。',
    '下茭笋翻炒至断生，加入瘦肉回锅。',
    '加盐或生抽调味，翻炒均匀出锅。'
  ].map((s, i) => `${i + 1}. ${s}`).join('\n');
  const draft = validateCompleteDraftRecipeResult(
    JSON.stringify({ name: '茭笋炒肉', ingredients: original, method }),
    { name: '茭笋炒肉', ingredients: original }
  );
  assert.equal(draft.name, '茭笋炒肉');
  assert.deepEqual(draft.ingredients.map(it => it.item), ['茭笋', '瘦肉']);
  assert.equal(draft.method.split('\n').length, 5);
});

test('验收标准：不应生成"茭笋青椒瘦肉炒蛋"这类堆砌组合（模拟 AI 在无原始食材约束时的偏差）', () => {
  const raw = JSON.stringify({
    name: '茭笋青椒瘦肉炒蛋',
    ingredients: [
      { item: '茭笋' }, { item: '青椒' }, { item: '瘦肉' }, { item: '鸡蛋' }
    ],
    method: '1. 全部食材切好。\n2. 依次下锅炒熟。\n3. 调味出锅。'
  });
  assert.throws(() => validateCompleteDraftRecipeResult(raw, { name: '茭笋炒肉', ingredients: [] }));
});

// ── 七：页面交互——生成成功不自动保存，用户点击保存才写入 ────────────────────

test('详情页：AI 草稿生成后不自动保存，保存到菜谱只在按钮 onclick 内触发', () => {
  const source = read('src/views/recipe-detail-view.js');
  const showMethodDraftFn = source.slice(
    source.indexOf('const showMethodDraft ='),
    source.indexOf('const generateMethodDraft =')
  );
  // 渲染草稿卡片时不能直接调用 saveOverlay；saveOverlay 只能出现在 #saveAiMethodBtn 的 onclick 里。
  const beforeSaveClick = showMethodDraftFn.slice(0, showMethodDraftFn.indexOf('#saveAiMethodBtn'));
  assert.doesNotMatch(beforeSaveClick, /saveOverlay\(/);
  const saveHandler = showMethodDraftFn.slice(showMethodDraftFn.indexOf("querySelector('#saveAiMethodBtn').onclick"));
  assert.match(saveHandler, /saveOverlay\(currentOverlay\)/);
  assert.match(saveHandler, /showToast\('已保存到菜谱', \{ tone: 'success' \}\)/);
});

test('详情页：生成成功后提示"已生成草稿，请确认后保存"', () => {
  const source = read('src/views/recipe-detail-view.js');
  assert.match(source, /showToast\('已生成草稿，请确认后保存', \{ tone: 'success' \}\)/);
});

test('详情页：生成调用 callAiCompleteDraftRecipe，且只传入核心食材（不含调料）', () => {
  const source = read('src/views/recipe-detail-view.js');
  assert.match(source, /const coreIngredients = foodItems\.map/);
  assert.match(source, /callAiCompleteDraftRecipe\(\{ name: r\.name, ingredients: coreIngredients \}\)/);
});
