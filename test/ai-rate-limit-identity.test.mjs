// test/ai-rate-limit-identity.test.mjs
//
// 把限流搬到共享 store 之前必须先确认身份是可信的：否则只会把一个可伪造的
// identity 变成全局可伪造。生产拓扑是 Cloudflare → Render LB → Express，
// 限流 key 只能来自连接层已验证的地址，不能来自客户端可自带的请求头。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const rateLimitPath = resolve(process.cwd(), 'src/server/services/rate-limit.js');
const sharedStorePath = resolve(process.cwd(), 'src/server/services/shared-window-store.js');

const {
  getClientIp,
  checkAiRateLimit,
  setSharedAiRateLimitStore,
  aiRateLimitBuckets
} = require(rateLimitPath);
const { createSharedWindowStore } = require(sharedStorePath);

function createFakeRedis() {
  const data = new Map();
  const ttls = new Map();
  return {
    async incrby(key, amount) { const n = (data.get(key) || 0) + amount; data.set(key, n); return n; },
    async pexpire(key, ms) { ttls.set(key, ms); return 1; },
    async pttl(key) { return data.has(key) ? (ttls.get(key) ?? -1) : -2; },
    keys() { return [...data.keys()]; }
  };
}

// Express 在 trust proxy 关闭时把 req.ip 固定为 socket 地址；打开 N 跳时才从
// X-Forwarded-For 右往左数第 N 个。这里直接构造两种结果，验证限流只用 req.ip。
function reqBehindTrustedProxy(resolvedIp, forwardedHeader) {
  return { ip: resolvedIp, socket: { remoteAddress: '10.1.1.1' }, headers: { 'x-forwarded-for': forwardedHeader } };
}

beforeEach(() => {
  setSharedAiRateLimitStore(null);
  aiRateLimitBuckets.clear();
});

test('客户端自带的 X-Forwarded-For 不能改变限流身份', () => {
  const a = reqBehindTrustedProxy('203.0.113.10', '1.2.3.4, 203.0.113.10');
  const b = reqBehindTrustedProxy('203.0.113.10', '9.9.9.9, 203.0.113.10');
  assert.equal(getClientIp(a), '203.0.113.10');
  assert.equal(getClientIp(b), '203.0.113.10');
  assert.equal(getClientIp(a), getClientIp(b), '伪造前缀不得产生新身份');
});

test('伪造 header 不能为自己开一个全新的共享桶', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit(reqBehindTrustedProxy('203.0.113.10', '1.2.3.4, 203.0.113.10'));
  await checkAiRateLimit(reqBehindTrustedProxy('203.0.113.10', '5.5.5.5, 203.0.113.10'));
  assert.deepEqual(redis.keys(), ['ai:203.0.113.10'], '两次请求必须命中同一个桶');
});

test('两个不同的可信身份得到不同的桶', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit(reqBehindTrustedProxy('203.0.113.10', '203.0.113.10'));
  await checkAiRateLimit(reqBehindTrustedProxy('198.51.100.7', '198.51.100.7'));
  assert.equal(redis.keys().length, 2);
});

test('同一身份经过不同实例仍共享同一个桶', async () => {
  const redis = createFakeRedis();
  const req = reqBehindTrustedProxy('203.0.113.10', '203.0.113.10');
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit(req);
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit(req);
  assert.deepEqual(redis.keys(), ['ai:203.0.113.10']);
});

test('header 缺失时安全回退到 socket 地址，而不是变成无限额', () => {
  const req = { socket: { remoteAddress: '10.2.2.2' }, headers: {} };
  assert.equal(getClientIp(req), '10.2.2.2');
});

test('畸形 header 不能绕过限流：身份仍来自 req.ip', () => {
  const req = reqBehindTrustedProxy('203.0.113.10', ',,,not-an-ip,,');
  assert.equal(getClientIp(req), '203.0.113.10');
});

test('完全没有可用身份时仍落到一个确定的桶，不会被放行', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit({ headers: {} });
  assert.deepEqual(redis.keys(), ['ai:unknown']);
});

test('限流 key 不含原始请求头内容', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkAiRateLimit(reqBehindTrustedProxy('203.0.113.10', 'secret-looking-value'));
  for (const key of redis.keys()) {
    assert.ok(!key.includes('secret-looking-value'));
  }
});
