// test/trust-proxy.test.mjs
// Render 部署在反代之后：不配置 Express `trust proxy` 时，req.ip 在生产环境上
// 等于 Render 自己的边缘代理地址，所有用户会共享同一个（或少数几个）rate-limit
// 桶。这里用真正启动的临时 Express app + Node 内置 http 客户端验证：
//   1. TRUST_PROXY_HOPS 环境变量解析（config.js）只接受正整数，'true'/负数/
//      小数/非法字符串一律安全回退为 0，不会被谁不小心配置成信任整条转发链。
//   2. app.set('trust proxy', N) 之后，Express 真实解析出的 req.ip 语义符合
//      预期：只信任最近 N 跳，客户端自己伪造的更左侧前缀不会被采信。
//   3. 配合真实的 rate-limit 桶：同一真实客户端（不同伪造前缀）落同一个桶，
//      不同真实客户端落不同桶。
import test, { after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const require = createRequire(import.meta.url);
const express = require('express');
const { parseTrustProxyHops } = require('../src/server/config.js');
const { aiRateLimitBuckets, isAiRateLimited, getClientIp } = require('../src/server/services/rate-limit.js');

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

const openServers = new Set();
after(() => {
  for (const server of openServers) server.close();
});

function startApp(app) {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, '127.0.0.1', () => {
      openServers.add(server);
      resolve({ server, port: server.address().port });
    });
    server.on('error', reject);
  });
}

function closeApp(server) {
  openServers.delete(server);
  return new Promise(resolve => server.close(resolve));
}

function getJson(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method: 'GET', headers }, res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch (err) { reject(err); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function buildIpApp(trustProxyHops) {
  const app = express();
  if (Number.isInteger(trustProxyHops) && trustProxyHops > 0) {
    app.set('trust proxy', trustProxyHops);
  }
  app.get('/ip', (req, res) => {
    res.json({ ip: req.ip });
  });
  return app;
}

// ── 一：TRUST_PROXY_HOPS 环境变量解析（纯函数，config.js）───────────────────

test("TRUST_PROXY_HOPS='1'：应配置为数字 1", () => {
  const result = parseTrustProxyHops('1');
  assert.equal(result.hops, 1);
  assert.equal(result.invalidRaw, null);
});

test("TRUST_PROXY_HOPS='2'：应配置为数字 2", () => {
  const result = parseTrustProxyHops('2');
  assert.equal(result.hops, 2);
  assert.equal(result.invalidRaw, null);
});

test("TRUST_PROXY_HOPS 未设置 / 空字符串 / '0'：默认必须为 0，且不是非法值", () => {
  assert.deepEqual(parseTrustProxyHops(undefined), { hops: 0, invalidRaw: null });
  assert.deepEqual(parseTrustProxyHops(''), { hops: 0, invalidRaw: null });
  assert.deepEqual(parseTrustProxyHops('0'), { hops: 0, invalidRaw: null });
});

test("TRUST_PROXY_HOPS='true'：不能启用（不是合法整数）", () => {
  const result = parseTrustProxyHops('true');
  assert.equal(result.hops, 0);
  assert.equal(result.invalidRaw, 'true');
});

test("TRUST_PROXY_HOPS='2.5'：不能启用（小数不是整数）", () => {
  const result = parseTrustProxyHops('2.5');
  assert.equal(result.hops, 0);
  assert.equal(result.invalidRaw, '2.5');
});

test("TRUST_PROXY_HOPS='-1'：不能启用（负数）", () => {
  const result = parseTrustProxyHops('-1');
  assert.equal(result.hops, 0);
  assert.equal(result.invalidRaw, '-1');
});

test("TRUST_PROXY_HOPS='abc' / ' 1 '：非纯数字字符串不能启用；带空格的合法数字允许 trim", () => {
  assert.equal(parseTrustProxyHops('abc').hops, 0);
  assert.equal(parseTrustProxyHops('abc').invalidRaw, 'abc');
  // trim 之后是合法正整数，不算非法输入。
  assert.deepEqual(parseTrustProxyHops(' 1 '), { hops: 1, invalidRaw: null });
});

// ── 二：真实 Express app 下 trust proxy 的 req.ip 解析行为 ───────────────────

test('trust proxy = 1，无 X-Forwarded-For：req.ip 应为 socket 地址', async () => {
  const app = buildIpApp(1);
  const { server, port } = await startApp(app);
  try {
    const { ip } = await getJson(port, '/ip');
    assert.match(ip, /127\.0\.0\.1/);
  } finally {
    await closeApp(server);
  }
});

test('trust proxy = 1，X-Forwarded-For: 203.0.113.10：req.ip 应为 203.0.113.10', async () => {
  const app = buildIpApp(1);
  const { server, port } = await startApp(app);
  try {
    const { ip } = await getJson(port, '/ip', { 'X-Forwarded-For': '203.0.113.10' });
    assert.equal(ip, '203.0.113.10');
  } finally {
    await closeApp(server);
  }
});

test('trust proxy = 1，客户端伪造前缀 "1.2.3.4, 203.0.113.10"：req.ip 应为 203.0.113.10，不能是 1.2.3.4', async () => {
  const app = buildIpApp(1);
  const { server, port } = await startApp(app);
  try {
    const { ip } = await getJson(port, '/ip', { 'X-Forwarded-For': '1.2.3.4, 203.0.113.10' });
    assert.equal(ip, '203.0.113.10');
    assert.notEqual(ip, '1.2.3.4');
  } finally {
    await closeApp(server);
  }
});

test('trust proxy = 0（禁用）：即使提供 X-Forwarded-For，req.ip 仍是 socket 地址', async () => {
  const app = buildIpApp(0);
  const { server, port } = await startApp(app);
  try {
    const { ip } = await getJson(port, '/ip', { 'X-Forwarded-For': '203.0.113.10' });
    assert.match(ip, /127\.0\.0\.1/);
    assert.notEqual(ip, '203.0.113.10');
  } finally {
    await closeApp(server);
  }
});

// ── 三：真实 Express + 真实 rate-limit 桶 ────────────────────────────────────

beforeEach(() => {
  aiRateLimitBuckets.clear();
});

function buildRateLimitApp() {
  const app = express();
  app.set('trust proxy', 1);
  app.get('/ping', (req, res) => {
    const limited = isAiRateLimited(req);
    res.json({ ip: getClientIp(req), limited });
  });
  return app;
}

test('同一真实客户端 IP、不同伪造左侧 XFF 前缀：应落入同一个限流桶', async () => {
  const app = buildRateLimitApp();
  const { server, port } = await startApp(app);
  try {
    const a = await getJson(port, '/ping', { 'X-Forwarded-For': '1.1.1.1, 203.0.113.10' });
    const b = await getJson(port, '/ping', { 'X-Forwarded-For': '2.2.2.2, 203.0.113.10' });
    assert.equal(a.ip, '203.0.113.10');
    assert.equal(b.ip, '203.0.113.10');
    assert.equal(aiRateLimitBuckets.size, 1);
    assert.equal(aiRateLimitBuckets.get('203.0.113.10').count, 2);
  } finally {
    await closeApp(server);
  }
});

test('不同真实客户端 IP：应落入不同限流桶', async () => {
  const app = buildRateLimitApp();
  const { server, port } = await startApp(app);
  try {
    const a = await getJson(port, '/ping', { 'X-Forwarded-For': '9.9.9.9, 203.0.113.10' });
    const b = await getJson(port, '/ping', { 'X-Forwarded-For': '9.9.9.9, 203.0.113.20' });
    assert.equal(a.ip, '203.0.113.10');
    assert.equal(b.ip, '203.0.113.20');
    assert.equal(aiRateLimitBuckets.size, 2);
    assert.equal(aiRateLimitBuckets.get('203.0.113.10').count, 1);
    assert.equal(aiRateLimitBuckets.get('203.0.113.20').count, 1);
  } finally {
    await closeApp(server);
  }
});

// ── 四：源码护栏 ─────────────────────────────────────────────────────────────

test('server.js / config.js 不允许 app.set(\'trust proxy\', true)', () => {
  const server = read('server.js');
  const config = read('src/server/config.js');
  assert.doesNotMatch(server, /trust proxy'\s*,\s*true\)/);
  assert.doesNotMatch(config, /trust proxy'\s*,\s*true\)/);
});

test('rate-limit.js 不直接读取 req.headers[\'x-forwarded-for\']，只用 req.ip / req.socket.remoteAddress', () => {
  const rateLimit = read('src/server/services/rate-limit.js');
  assert.doesNotMatch(rateLimit, /req\.headers\[['"]x-forwarded-for['"]\]/i);
  assert.match(rateLimit, /function getClientIp\(req\) \{\s*\n\s*return req\.ip \|\| req\.socket\?\.remoteAddress \|\| 'unknown';/);
});

test('trust proxy 必须来自 TRUST_PROXY_HOPS 的整数解析，默认必须为 0，不散落在 server.js 里手写环境变量解析', () => {
  const config = read('src/server/config.js');
  const server = read('server.js');

  assert.match(config, /process\.env\.TRUST_PROXY_HOPS/);
  assert.doesNotMatch(server, /process\.env\.TRUST_PROXY_HOPS/, '环境变量解析应集中在 config.js，不散落在 server.js');

  assert.match(server, /if \(Number\.isInteger\(TRUST_PROXY_HOPS\) && TRUST_PROXY_HOPS > 0\)/);
  assert.match(server, /app\.set\('trust proxy', TRUST_PROXY_HOPS\)/);

  // 默认值语义：未设置 / 空 / '0' 都归一为整数 0。
  assert.deepEqual(parseTrustProxyHops(undefined).hops, 0);
});

test('server.js 启动日志不打印真实用户 IP 或完整 X-Forwarded-For', () => {
  const server = read('server.js');
  const trustProxyBlock = server.slice(server.indexOf("const app = express();"), server.indexOf('// 解析 JSON 请求体'));
  assert.match(trustProxyBlock, /\[server\] trust proxy hops: \$\{TRUST_PROXY_HOPS\}/);
  assert.match(trustProxyBlock, /\[server\] trust proxy disabled/);
  // 只检查实际的 console.log/console.warn 调用本身，不检查解释性注释里出现的这些词。
  const logCalls = [...trustProxyBlock.matchAll(/console\.(?:log|warn)\(([\s\S]*?)\);/g)].map(m => m[1]);
  assert.ok(logCalls.length >= 2, '应该至少有 warning + 状态两条日志');
  for (const call of logCalls) {
    assert.doesNotMatch(call, /x-forwarded-for/i);
    assert.doesNotMatch(call, /req\.ip/);
    assert.doesNotMatch(call, /req\.socket/);
  }
});
