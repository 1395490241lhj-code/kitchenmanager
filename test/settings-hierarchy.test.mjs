import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('设置页默认分层为常用设置、AI 服务和数据安全', () => {
  const source = read('src/views/settings-view.js');

  assert.match(source, /<div class="settings-group-label">常用设置<\/div>/);
  assert.match(source, /<div class="settings-group-label">AI 服务<\/div>/);
  assert.match(source, /<div class="settings-group-label">数据安全<\/div>/);
  assert.match(source, /默认不需要自己配置 API Key/);
  assert.match(source, /你的厨房数据仍保存在本地/);
});

test('默认区域显示内置 AI 状态和测试按钮', () => {
  const source = read('src/views/settings-view.js');
  const aiSection = source.indexOf('<div class="settings-group-label">AI 服务</div>');
  const advancedToggle = source.indexOf('id="advToggle"');

  assert.ok(aiSection >= 0);
  assert.ok(advancedToggle > aiSection);
  assert.match(source, /id="cloudAiStatusCard"/);
  assert.match(source, /id="testCloudAiBtn">测试 AI 服务/);
  assert.match(source, /fetch\('\/api\/ai-status', \{ cache: 'no-store' \}\)/);
});

test('设置页显示菜谱偏好但不接入推荐结果', () => {
  const source = read('src/views/settings-view.js');

  assert.match(source, /<div class="settings-group-label">菜谱偏好<\/div>/);
  assert.match(source, /当前只是保存偏好，不会改变推荐结果/);
  assert.match(source, /data-recipe-pack-id/);
  assert.match(source, /createRecipePackSettingsPatch/);
  assert.match(source, /enabledRecipePackIds/);
  assert.doesNotMatch(source, /getRecipesForSettings/);
});

test('API Base URL 和文本模型字段只位于 BYOK 高级区域', () => {
  const source = read('src/views/settings-view.js');
  const byokBox = source.indexOf('id="byokAiBox"');
  const apiUrlInput = source.indexOf('id="sUrl"');
  const modelInput = source.indexOf('id="sModel"');
  const advancedPanel = source.indexOf('id="advPanel" hidden');

  assert.ok(advancedPanel >= 0);
  assert.ok(byokBox > advancedPanel);
  assert.ok(apiUrlInput > byokBox);
  assert.ok(modelInput > byokBox);
  assert.match(source, /API Base URL/);
  assert.match(source, /文本模型/);
  assert.match(source, /byokAiBox\.hidden = !isByok;/);
  assert.match(source, /使用自己的 API Key/);
});

test('数据安全区域说明厨房完整备份且默认不包含 API Key', () => {
  const source = read('src/views/settings-view.js');

  assert.match(source, /Kitchen Manager 主要把数据保存在当前浏览器/);
  assert.match(source, /换设备、清缓存或卸载前，建议导出一份厨房备份/);
  assert.match(source, /包含库存、今日计划、买菜清单、常备品、设置、菜谱补丁等用户数据/);
  assert.match(source, /默认不包含 API Key/);
  assert.match(source, /id="exportKitchenBackup"/);
  assert.match(source, /id="importKitchenBackup"/);
});

test('高级设置默认折叠，展开后保留高级工具', () => {
  const source = read('src/views/settings-view.js');
  const advancedPanel = source.indexOf('id="advPanel" hidden');
  const recipePatch = source.indexOf('id="exportRecipeOverlay"');
  const clearCache = source.indexOf('id="clearCacheBtn"');
  const report = source.indexOf('id="curationReport"');

  assert.match(source, /id="advToggle" aria-expanded="false"/);
  assert.match(source, /展开高级设置/);
  assert.match(source, /<div class="settings-group-label">高级设置<\/div>/);
  assert.ok(recipePatch > advancedPanel);
  assert.ok(clearCache > advancedPanel);
  assert.ok(report > advancedPanel);
});
