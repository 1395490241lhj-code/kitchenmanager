import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

// 注意：config.js 按 import 时的 location 决定 API_BASE，且模块每进程只求值一次，
// 所以本文件先伪造 github.io 的 location 再动态 import（node --test 每文件独立进程）。
globalThis.location = { hostname: '1395490241lhj-code.github.io' };
const { API_BASE, apiUrl } = await import('../src/config.js');

test('github.io 域名下 API_BASE 指向 Render，apiUrl 正确拼接', () => {
  assert.equal(API_BASE, 'https://kitchenmanager-b8px.onrender.com');
  assert.equal(apiUrl('/api/ai-chat'), 'https://kitchenmanager-b8px.onrender.com/api/ai-chat');
});

test('同源部署（无 github.io location）时 API_BASE 为空、走相对路径', () => {
  // 源码层面锁定分支逻辑：非 github.io（含 node 环境 location 未定义）→ 空基址。
  const config = read('src/config.js');
  assert.match(config, /typeof location !== 'undefined'/);
  assert.match(config, /\\\.github\\\.io\$/);
  assert.match(config, /: ''/);
});

test('前端所有 /api 调用都经过 apiUrl，无裸 fetch', () => {
  const ai = read('src/ai.js');
  const settings = read('src/views/settings-view.js');

  // ai.js 内 getAiConfig 有同名局部变量（BYOK 用户自填地址），导入时改名为 buildApiUrl。
  assert.match(ai, /import \{ apiUrl as buildApiUrl/);
  assert.match(ai, /buildApiUrl\('\/api\/ai-chat'\)/);
  assert.match(ai, /fetch\(buildApiUrl\(`\/api\/xhs-extract\?url=/);
  assert.match(ai, /fetch\(buildApiUrl\('\/api\/ai-parse'\)/);
  assert.match(ai, /fetch\(buildApiUrl\('\/api\/recipe-import-from-url'\)/);
  assert.match(settings, /fetch\(apiUrl\('\/api\/ai-status'\), \{ cache: 'no-store' \}\)/);

  // 防回退：src 里不允许再出现裸的相对路径 fetch('/api/...')。
  for (const source of [ai, settings]) {
    assert.doesNotMatch(source, /fetch\('\/api\//);
    assert.doesNotMatch(source, /fetch\(`\/api\//);
  }
});

test('server.js 为 /api 提供精确来源的 CORS 与预检响应', () => {
  const server = read('server.js');

  assert.match(server, /CORS_ALLOWED_ORIGINS = new Set\(\[/);
  assert.match(server, /'https:\/\/1395490241lhj-code\.github\.io'/);
  assert.match(server, /CORS_EXTRA_ORIGIN/);
  assert.match(server, /app\.use\('\/api', /);
  assert.match(server, /Access-Control-Allow-Origin', origin\)/);
  assert.match(server, /Access-Control-Allow-Methods', 'GET,POST,OPTIONS'\)/);
  assert.match(server, /Access-Control-Allow-Headers', 'Content-Type'\)/);
  assert.match(server, /req\.method === 'OPTIONS'\) return res\.status\(204\)\.end\(\)/);
  // 白名单外不回显任意 Origin（禁止通配）。
  assert.doesNotMatch(server, /Access-Control-Allow-Origin', '\*'/);
});
