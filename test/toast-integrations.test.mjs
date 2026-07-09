import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('饭后记一下确认成功和无选择都会显示 Toast', () => {
  const cookedMeal = read('src/views/home/cooked-meal-modal.js');

  assert.match(cookedMeal, /showToast\('已更新库存', \{ tone: 'success' \}\)/);
  assert.match(cookedMeal, /showToast\('没有选择要更新的食材', \{ tone: 'warning' \}\)/);
});

test('购物清单高频操作接入 Toast', () => {
  const shopping = read('src/views/shopping-view.js');
  const modal = read('src/components/modal.js');
  const cookFeedback = read('src/components/cook-feedback.js');

  assert.match(shopping, /showToast\('已加入买菜清单', \{ tone: 'success' \}\)/);
  assert.match(shopping, /showToast\('已标记买到', \{ tone: 'success' \}\)/);
  assert.match(shopping, /showToast\('已删除', \{ tone: 'info' \}\)/);
  assert.match(shopping, /showToast\('已入库', \{ tone: 'success' \}\)/);
  assert.match(modal, /showToast\('已加入买菜清单', \{ tone: 'success' \}\)/);
  assert.match(cookFeedback, /showToast\('已加入买菜清单', \{ tone: 'success' \}\)/);
});

test('小票确认导入成功和空结果都有 Toast', () => {
  const modal = read('src/components/modal.js');
  const home = read('src/views/home-view.js');
  const inventory = read('src/views/inventory-view.js');

  assert.match(modal, /小票已导入/);
  assert.match(modal, /已记住，下次会自动识别/);
  assert.match(home, /showToast\('没有识别到可入库食材', \{ tone: 'warning' \}\)/);
  assert.match(inventory, /showToast\('没有识别到可入库食材', \{ tone: 'warning' \}\)/);
});

test('菜谱保存、AI 草稿保存和 AI 不可用接入 Toast', () => {
  const editor = read('src/views/recipe-editor-view.js');
  const createModal = read('src/components/recipe-create-modal.js');
  const recipeCard = read('src/components/recipe-card.js');
  const importModal = read('src/components/recipe-import-modal.js');
  const detail = read('src/views/recipe-detail-view.js');

  assert.match(editor, /showToast\(isAiImportDraft \? 'AI 草稿已保存' : '已保存菜谱'/);
  assert.match(createModal, /showToast\('已保存菜谱', \{ tone: 'success' \}\)/);
  assert.match(recipeCard, /showToast\('AI 草稿已保存', \{ tone: 'success' \}\)/);
  assert.match(recipeCard, /showToast\('AI 暂不可用', \{ tone: 'error' \}\)/);
  assert.match(importModal, /showToast\('AI 暂不可用', \{ tone: 'error' \}\)/);
  // AI 草稿详情页「AI 生成草稿」：网络/超时等失败保留原草稿，提示可稍后再试；
  // 黑暗料理/步骤过少这类内容质量问题走单独的提示文案（见 callAiCompleteDraftRecipe）。
  assert.match(detail, /showToast\('AI 暂时不可用，可以稍后再试', \{ tone: 'error' \}\)/);
  assert.match(detail, /showToast\(e\.message \|\| 'AI 生成的草稿不够合理，请重试', \{ tone: 'error' \}\)/);
});

test('备份导入导出接入 Toast，错误处理仍保留 inline status', () => {
  const settings = read('src/views/settings-view.js');

  assert.match(settings, /showToast\(KITCHEN_BACKUP_EXPORT_MESSAGE, \{ tone: 'success' \}\)/);
  assert.match(settings, /showToast\('备份已导入', \{ tone: 'success' \}\)/);
  assert.match(settings, /showToast\('备份导入失败', \{ tone: 'error' \}\)/);
  assert.match(settings, /setInlineStatus\(statusEl, err\.message \|\| '备份文件无法读取', 'bad'\)/);
});
