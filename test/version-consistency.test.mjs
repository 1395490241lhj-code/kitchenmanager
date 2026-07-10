import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, extname, relative } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

// S4：把「?v= 版本纪律」变成机制。背景：ES module 的 URL 含查询参数时，
// 同一文件不同 ?v= 会被浏览器当成两个模块加载（状态分叉、体积翻倍）——
// 本仓库真实发生过（home-view 引 ai.js?v=233、其余引用方 ?v=231）。
// 版本统一只允许通过 scripts/stamp-version.js 完成。

const root = process.cwd();
const SKIP_DIRS = new Set(['.git', 'node_modules', 'icons', 'scripts', 'test', 'data']);
const EXTENSIONS = new Set(['.html', '.js']);

function walk(dir, files = []) {
  for (const name of readdirSync(dir)) {
    if (name.startsWith('.')) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      if (SKIP_DIRS.has(name)) continue;
      walk(full, files);
    } else if (EXTENSIONS.has(extname(name))) {
      files.push(full);
    }
  }
  return files;
}

const files = walk(root);

test('全仓 ?v= 版本号唯一（禁止手动单点升版造成双模块实例）', () => {
  const seen = new Map(); // version -> 首个出现的文件
  for (const file of files) {
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(/\?v=(\d+)/g)) {
      if (!seen.has(m[1])) seen.set(m[1], relative(root, file));
    }
  }
  assert.ok(seen.size >= 1, '应存在 ?v= 版本引用');
  assert.equal(
    seen.size, 1,
    `发现多个 ?v= 版本并存：${[...seen.entries()].map(([v, f]) => `v=${v}(${f})`).join('，')}。请运行 node scripts/stamp-version.js 统一。`
  );
});

test('SW 的 CACHE_NAME 与 ?v= 版本同步（由 stamp 脚本统一管理）', () => {
  const sw = readFileSync(join(root, 'sw.v18.js'), 'utf8');
  const cacheName = sw.match(/const CACHE_NAME = 'km-v(\d+)';/);
  assert.ok(cacheName, 'sw.v18.js 应声明 km-v<数字> 形式的 CACHE_NAME');
  const anyVersion = readFileSync(join(root, 'index.html'), 'utf8').match(/\?v=(\d+)/);
  assert.ok(anyVersion, 'index.html 应包含 ?v= 引用');
  assert.equal(
    cacheName[1], anyVersion[1],
    `CACHE_NAME(km-v${cacheName[1]}) 与 ?v=${anyVersion[1]} 不同步。请运行 node scripts/stamp-version.js。`
  );
});

test('sw-register.v18.js 不包含固定 km-v18 缓存保留逻辑（会随升版误删当前缓存）', () => {
  const register = readFileSync(join(root, 'sw-register.v18.js'), 'utf8');
  // 背景：sw.v18.js 的 CACHE_NAME 会随 scripts/stamp-version.js 升版（当前 km-v235），
  // 但 sw-register.v18.js 曾经写死只保留 'km-v18'，导致每次启动都会把当前缓存当成
  // 旧缓存删掉，离线预缓存不可靠。这里锁死：注册脚本里不能再出现这个写死的字符串。
  assert.doesNotMatch(register, /'km-v18'/, "sw-register.v18.js 不应再写死保留 'km-v18'");
});

test('sw-register.v18.js 不调用 caches.keys()/caches.delete() 删除业务缓存', () => {
  const register = readFileSync(join(root, 'sw-register.v18.js'), 'utf8');
  // 缓存清理职责完全交给 sw.v18.js 的 activate 事件（它按当前 CACHE_NAME 动态清理），
  // 注册脚本只应负责注册 / updatefound / reload 提示等注册相关职责，不能再碰 Cache API。
  assert.doesNotMatch(register, /caches\.keys\(\)/, 'sw-register.v18.js 不应调用 caches.keys()');
  assert.doesNotMatch(register, /caches\.delete\(/, 'sw-register.v18.js 不应调用 caches.delete()');
});

test('src 的 ESM 相对导入必须带 ?v=（漏带会绕开缓存刷新）', () => {
  const offenders = [];
  for (const file of files) {
    const rel = relative(root, file);
    if (!rel.startsWith('src/') || rel.startsWith('src/server/')) continue; // src/server 是 CJS
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(/^import[\s\S]*?from\s+'(\.[^']+)'/gm)) {
      if (!m[1].includes('?v=')) offenders.push(`${rel} → ${m[1]}`);
    }
  }
  assert.deepEqual(offenders, []);
});
