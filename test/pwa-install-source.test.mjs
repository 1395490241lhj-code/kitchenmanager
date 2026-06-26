import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('app 初始化 PWA 安装监听，状态变化时刷新今日页', () => {
  const app = read('app.js');

  assert.match(app, /initPwaInstallPrompt/);
  assert.match(app, /hash === 'today'/);
  assert.match(app, /onRoute\(\)/);
});

test('PWA 安装模块捕获 beforeinstallprompt 并阻止浏览器默认弹窗', () => {
  const source = read('src/pwa-install.js');

  assert.match(source, /beforeinstallprompt/);
  assert.match(source, /event\.preventDefault\(\)/);
  assert.match(source, /deferredInstallPrompt = event/);
  assert.match(source, /appinstalled/);
});

test('今日页安装提示提供 iOS 说明和 Android 安装按钮入口', () => {
  const home = read('src/views/home-view.js');
  const pwa = read('src/pwa-install.js');

  assert.match(home, /home-pwa-install-nudge/);
  assert.match(home, /homePwaInstallPrimary/);
  assert.match(home, /homePwaInstallLater/);
  assert.match(home, /promptPwaInstall\(\)/);
  assert.match(pwa, /在 Safari 底部点“分享”，再选择“添加到主屏幕”。/);
  assert.match(pwa, /primaryLabel: '安装'/);
});
