// test/rate-limit-client-ip.test.mjs
// 限流 key 必须来自连接层已验证的地址（req.ip / req.socket.remoteAddress），
// 不能直接信任客户端可伪造的 X-Forwarded-For 请求头，否则非浏览器客户端可以
// 每个请求换一个 X-Forwarded-For 绕开限流。见 src/server/services/rate-limit.js。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const rateLimitPath = resolve(process.cwd(), 'src/server/services/rate-limit.js');
const {
  getClientIp,
  isAiRateLimited,
  aiRateLimitBuckets
} = require(rateLimitPath);

beforeEach(() => {
  aiRateLimitBuckets.clear();
});

function fakeReq({ ip, remoteAddress, forwardedFor } = {}) {
  return {
    ip,
    socket: remoteAddress !== undefined ? { remoteAddress } : undefined,
    headers: forwardedFor !== undefined ? { 'x-forwarded-for': forwardedFor } : {}
  };
}

// ── 一：getClientIp 只信 req.ip / req.socket.remoteAddress，不读 X-Forwarded-For ──

test('getClientIp：忽略 X-Forwarded-For，只用 req.ip', () => {
  const req = fakeReq({ ip: '1.2.3.4', remoteAddress: '1.2.3.4', forwardedFor: '9.9.9.9' });
  assert.equal(getClientIp(req), '1.2.3.4');
});

test('getClientIp：没有 req.ip 时 fallback 到 req.socket.remoteAddress，仍不读 X-Forwarded-For', () => {
  const req = fakeReq({ remoteAddress: '5.6.7.8', forwardedFor: '9.9.9.9' });
  assert.equal(getClientIp(req), '5.6.7.8');
});

test('getClientIp：req.ip 和 socket 都没有时 fallback 为 \'unknown\'', () => {
  const req = { headers: { 'x-forwarded-for': '9.9.9.9' } };
  assert.equal(getClientIp(req), 'unknown');
});

// ── 二：相同 remoteAddress 但不同 X-Forwarded-For → 必须命中同一个限流桶 ──

test('两个请求 remoteAddress 相同但 X-Forwarded-For 不同：应命中同一个限流桶', () => {
  const reqA = fakeReq({ ip: '10.0.0.1', remoteAddress: '10.0.0.1', forwardedFor: '1.1.1.1' });
  const reqB = fakeReq({ ip: '10.0.0.1', remoteAddress: '10.0.0.1', forwardedFor: '2.2.2.2' });

  assert.equal(getClientIp(reqA), getClientIp(reqB));

  isAiRateLimited(reqA);
  isAiRateLimited(reqB);

  assert.equal(aiRateLimitBuckets.size, 1); // 只有一个桶
  assert.equal(aiRateLimitBuckets.get('10.0.0.1').count, 2); // 两次请求都计到同一个桶里
});

// ── 三：remoteAddress 不同 → 必须是不同限流桶 ──

test('remoteAddress 不同：应是不同限流桶，互不影响配额', () => {
  const reqA = fakeReq({ ip: '10.0.0.1', remoteAddress: '10.0.0.1' });
  const reqB = fakeReq({ ip: '10.0.0.2', remoteAddress: '10.0.0.2' });

  assert.notEqual(getClientIp(reqA), getClientIp(reqB));

  isAiRateLimited(reqA);
  isAiRateLimited(reqA);
  isAiRateLimited(reqB);

  assert.equal(aiRateLimitBuckets.size, 2);
  assert.equal(aiRateLimitBuckets.get('10.0.0.1').count, 2);
  assert.equal(aiRateLimitBuckets.get('10.0.0.2').count, 1);
});

// ── 四：没有 req.ip 时 fallback 到 socket.remoteAddress（限流行为层面再验证一次）──

test('没有 req.ip 时限流仍按 socket.remoteAddress 分桶', () => {
  const reqA = fakeReq({ remoteAddress: '172.16.0.5' });
  const reqB = fakeReq({ remoteAddress: '172.16.0.5' });
  const reqC = fakeReq({ remoteAddress: '172.16.0.6' });

  isAiRateLimited(reqA);
  isAiRateLimited(reqB);
  isAiRateLimited(reqC);

  assert.equal(aiRateLimitBuckets.size, 2);
  assert.equal(aiRateLimitBuckets.get('172.16.0.5').count, 2);
  assert.equal(aiRateLimitBuckets.get('172.16.0.6').count, 1);
});
