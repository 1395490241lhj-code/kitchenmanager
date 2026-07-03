import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('Service Worker 永不缓存 /api 请求', () => {
  const sw = read('sw.v18.js');
  const fetchHandler = sw.slice(sw.indexOf("self.addEventListener('fetch'"));

  // /api 放行必须发生在任何 respondWith 之前，否则 GET /api/ai-status 会被
  // 兜底的 cacheFirst 永久钉死（cache:'no-store' 绕不过 SW），POST 则会触发
  // cache.put 的未处理 rejection。
  const apiBypass = fetchHandler.indexOf("/\\/api\\//.test(url.pathname)");
  const firstRespondWith = fetchHandler.indexOf('respondWith');
  assert.ok(apiBypass > 0, 'fetch handler 应包含 /api/ 放行判断');
  assert.ok(firstRespondWith > 0, 'fetch handler 应有 respondWith');
  assert.ok(apiBypass < firstRespondWith, '/api/ 放行必须在所有 respondWith 之前');
});

test('设置页 ai-status 检测使用 no-store（HTTP 缓存层）', () => {
  const settings = read('src/views/settings-view.js');
  assert.match(settings, /fetch\(apiUrl\('\/api\/ai-status'\), \{ cache: 'no-store' \}\)/);
});
