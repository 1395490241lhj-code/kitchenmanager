import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('首页备份提醒接入导出和稍后提醒动作', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /shouldShowBackupNudge\(\{/);
  assert.match(home, /isDemoMode/);
  assert.match(home, /id="homeBackupExport"/);
  assert.match(home, /id="homeBackupLater"/);
  assert.match(home, /markKitchenBackupExported\(\)/);
  assert.match(home, /markBackupNudgeDismissed\(\)/);
  assert.match(home, /已导出厨房备份。请把文件保存到 iCloud、网盘或电脑里。/);
});

test('设置页厨房备份导入前使用三按钮确认，不再静默覆盖', () => {
  const settings = read('src/views/settings-view.js');

  assert.match(settings, /showKitchenBackupImportConfirm/);
  assert.match(settings, /导入备份会用备份中的厨房数据覆盖当前本地数据/);
  assert.match(settings, /继续导入/);
  assert.match(settings, /先导出当前数据/);
  assert.match(settings, /取消/);
  assert.match(settings, /onExportCurrent/);
  assert.match(settings, /downloadCurrentKitchenBackup\(\)/);
  assert.doesNotMatch(settings, /window\.confirm\('导入会覆盖当前厨房数据/);
});

test('设置页数据管理说明区分完整备份和菜谱补丁', () => {
  const settings = read('src/views/settings-view.js');

  assert.match(settings, /厨房完整备份/);
  assert.match(settings, /包含库存、今日计划、买菜清单、常备品、设置、菜谱补丁等用户数据/);
  assert.match(settings, /默认不包含 API Key/);
  assert.match(settings, /菜谱补丁/);
  assert.match(settings, /只导出你新增、编辑或删除的菜谱内容/);
});
