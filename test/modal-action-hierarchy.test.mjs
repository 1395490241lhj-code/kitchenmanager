import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

function cssRule(source, selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = source.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{[\\s\\S]*?\\n\\}`));
  assert.ok(match, `Missing CSS rule for ${selector}`);
  return match[0];
}

test('缺菜确认弹窗使用统一结构和主弱按钮层级', () => {
  const source = read('src/components/plan-missing-check.js');

  assert.match(source, /id="planMissingTitle">还缺几样食材/);
  assert.match(source, /class="km-modal-subtitle"/);
  assert.match(source, /plan-missing-list/);
  assert.match(source, /id="planMissingSkip">暂时不用/);
  assert.match(source, /btn km-action-weak" id="planMissingSkip"/);
  assert.match(source, /id="planMissingAdd">加入买菜清单/);
  assert.match(source, /btn ok km-action-primary" id="planMissingAdd"/);
});

test('AI action status 统一为次按钮在前、主按钮在后', () => {
  const source = read('src/components/status.js');

  assert.match(source, /ai-action-status km-action-panel/);
  assert.match(source, /km-action-secondary" data-ai-action="secondary"/);
  assert.match(source, /km-action-primary" data-ai-action="primary"/);
  assert.match(source, /secondaryText[\s\S]*primaryText/);
});

test('小票识别失败兜底保留两个可继续动作', () => {
  const home = read('src/views/home-view.js');
  const inventory = read('src/views/inventory-view.js');

  assert.match(home, /primaryText: '改用手动输入'/);
  assert.match(home, /secondaryText: '重新选择图片'/);
  assert.match(home, /setTab\('text'\)/);
  assert.match(inventory, /primaryText: '改用手动输入'/);
  assert.match(inventory, /secondaryText: '重新选择图片'/);
});

test('小票确认主界面只展示结构化结果，不默认展示 OCR 原文', () => {
  const modal = read('src/components/modal.js');
  const styles = read('styles.css');

  assert.match(modal, /<h3>识别结果/);
  assert.match(modal, /确认入库/);
  assert.doesNotMatch(modal, /原文：/);
  assert.doesNotMatch(modal, /依据：/);
  assert.doesNotMatch(modal, /提示：/);
  assert.doesNotMatch(modal, /receipt-original-name/);
  assert.doesNotMatch(modal, /receipt-ignored-item/);
  assert.doesNotMatch(styles, /\.receipt-original-name/);
  assert.doesNotMatch(styles, /\.receipt-ignored-item/);
});

test('AI 菜谱导入弹窗接入统一 modal 外壳和失败兜底', () => {
  const source = read('src/components/recipe-import-modal.js');

  assert.match(source, /km-modal-overlay open ai-import-overlay/);
  assert.match(source, /km-modal-content ai-import-modal/);
  assert.match(source, /km-modal-title ai-import-title/);
  assert.match(source, /km-modal-subtitle/);
  assert.match(source, /primaryText: '编辑后重试'/);
  assert.match(source, /secondaryText: '稍后再试'/);
  assert.match(source, /btn ok km-action-primary ai-import-go/);
});

test('备份导入确认使用三按钮层级且不会静默覆盖', () => {
  const source = read('src/views/settings-view.js');

  assert.match(source, /导入厨房备份？/);
  assert.match(source, /class="km-modal-subtitle"/);
  assert.match(source, /id="settingsImportCancel">取消/);
  assert.match(source, /km-action-secondary" id="settingsImportExportCurrent">先导出当前数据/);
  assert.match(source, /km-action-primary" id="settingsImportContinue">继续导入/);
  assert.match(source, /showKitchenBackupImportConfirm/);
});

test('记录消耗弹窗保留更新库存入口并使用统一按钮层级', () => {
  const source = read('src/views/home/cooked-meal-modal.js');

  assert.match(source, /<span class="km-modal-title">记录消耗<\/span>/);
  assert.match(source, /选择实际做了哪些菜，库存会按用量更新/);
  assert.match(source, /id="cookedMealCancel">稍后/);
  assert.match(source, /id="cookedMealAddAction" hidden>添加食材/);
  assert.match(source, /id="cookedMealAnalyze">生成建议/);
  assert.match(source, /analyzeBtn\.textContent = '更新库存'/);
  assert.match(source, /btn ok km-action-primary" id="cookedMealAnalyze"/);
});

test('通用 modal 和按钮层级样式存在且互相区分', () => {
  const styles = read('styles.css');

  assert.match(styles, /\.km-modal-subtitle\s*\{/);
  assert.match(styles, /\.km-modal-note\s*\{/);
  assert.match(styles, /\.km-modal-actions \.km-action-primary/);
  assert.match(styles, /\.km-modal-actions \.km-action-secondary/);
  assert.match(styles, /\.km-modal-actions \.km-action-weak/);
  assert.match(styles, /\.km-modal-actions \.km-action-danger/);
  assert.match(styles, /\.ai-action-status-actions \.km-action-primary/);
});

test('modal action/footer 容器使用透明背景，避免浅色白块', () => {
  const styles = read('styles.css');
  const sharedSelectors = [
    '.km-modal-actions',
    '.modal-actions',
    '.receipt-confirm-actions',
    '.recipe-preview-actions',
  ];

  for (const selector of sharedSelectors) {
    const rule = cssRule(styles, selector);
    assert.match(rule, /background: transparent;/);
    assert.match(rule, /box-shadow: none;/);
    assert.match(rule, /backdrop-filter: none;/);
    assert.doesNotMatch(rule, /background:\s*(?:#fff|white|var\(--bg-card\))/);
    assert.doesNotMatch(rule, /rgba\(255,\s*255,\s*255,\s*0\.(?:5|6|7|8|9)/);
  }

  assert.match(
    styles,
    /html\[data-theme="light"\] \.km-modal-actions,[\s\S]*?html\[data-theme="light"\] \.receipt-confirm-actions\s*\{\s*background: transparent;/,
  );
  assert.match(
    styles,
    /html\[data-theme="dark"\] \.km-modal-actions,[\s\S]*?html\[data-theme="dark"\] \.receipt-confirm-actions\s*\{\s*background: transparent;/,
  );
});

test('记食材弹窗 action 区使用透明专用背景，避免浅色白块', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /class="km-modal-actions batch-input-actions"/);
  assert.match(styles, /\.batch-input-body \.km-modal-actions\.batch-input-actions/);
  assert.match(styles, /html\[data-theme="light"\] \.batch-input-body \.km-modal-actions\.batch-input-actions/);
  assert.match(styles, /background: transparent;/);
  assert.match(styles, /backdrop-filter: none;/);
});
