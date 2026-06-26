import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import {
  dismissPwaInstallPrompt,
  getPwaInstallPromptState,
  isPwaInstallDismissedRecently,
  shouldShowPwaInstallPrompt
} from '../src/pwa-install.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const iosSafariEnv = {
  isMobile: true,
  isStandalone: false,
  isIOS: true,
  isIOSSafari: true,
  isAndroid: false,
  isAndroidChrome: false,
  hasDeferredPrompt: false
};

const androidChromeEnv = {
  isMobile: true,
  isStandalone: false,
  isIOS: false,
  isIOSSafari: false,
  isAndroid: true,
  isAndroidChrome: true,
  hasDeferredPrompt: true
};

test('standalone 模式不显示安装提示，并记录已安装', () => {
  const state = getPwaInstallPromptState({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: { ...iosSafariEnv, isStandalone: true },
    now: 1_800_000_000_000
  });

  assert.equal(state.show, false);
  assert.equal(state.reason, 'standalone');
  assert.equal(localStorage.getItem(S.keys.pwa_install_done), '1');
});

test('demo 模式不显示安装提示', () => {
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    isDemoMode: true,
    environment: iosSafariEnv,
    now: 1_800_000_000_000
  }), false);
});

test('桌面端不显示移动端安装提示', () => {
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: { ...iosSafariEnv, isMobile: false },
    now: 1_800_000_000_000
  }), false);
});

test('iOS Safari 非 standalone 显示分享到主屏幕文案，不显示安装按钮', () => {
  const state = getPwaInstallPromptState({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: iosSafariEnv,
    now: 1_800_000_000_000
  });

  assert.equal(state.show, true);
  assert.equal(state.platform, 'ios');
  assert.equal(state.canPrompt, false);
  assert.match(state.body, /分享/);
  assert.match(state.body, /添加到主屏幕/);
  assert.equal(state.primaryLabel, '我知道了');
});

test('Android Chrome 有 beforeinstallprompt 时显示安装按钮', () => {
  const state = getPwaInstallPromptState({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: androidChromeEnv,
    now: 1_800_000_000_000
  });

  assert.equal(state.show, true);
  assert.equal(state.platform, 'android');
  assert.equal(state.canPrompt, true);
  assert.equal(state.primaryLabel, '安装');
});

test('Android Chrome 没有 beforeinstallprompt 时不显示安装提示', () => {
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: { ...androidChromeEnv, hasDeferredPrompt: false },
    now: 1_800_000_000_000
  }), false);
});

test('点击稍后后设置 dismissed_at，7 天内不重复提示', () => {
  const now = 1_800_000_000_000;
  dismissPwaInstallPrompt(now);

  assert.equal(localStorage.getItem(S.keys.pwa_install_dismissed_at), String(now));
  assert.equal(isPwaInstallDismissedRecently(now + 6 * 24 * 60 * 60 * 1000), true);
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: iosSafariEnv,
    now: now + 6 * 24 * 60 * 60 * 1000
  }), false);
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '鸡蛋', qty: 1 }],
    environment: iosSafariEnv,
    now: now + 8 * 24 * 60 * 60 * 1000
  }), true);
});

test('必须有真实库存或今日计划后才显示安装提示', () => {
  const now = 1_800_000_000_000;

  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [],
    plan: [],
    environment: iosSafariEnv,
    now
  }), false);
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [{ name: '番茄', qty: 2 }],
    plan: [],
    environment: iosSafariEnv,
    now
  }), true);
  assert.equal(shouldShowPwaInstallPrompt({
    inventory: [],
    plan: [{ id: 'recipe-1', date: '2026-06-25' }],
    environment: iosSafariEnv,
    now
  }), true);
});
