// test/ai-rate-limit-retry-after.test.mjs
// AI 限流是固定窗口：超限后必须告诉客户端「还要等多久」，而不是让客户端盲目
// 指数重试。Retry-After 用标准 HTTP 头发出，值来自当前桶的真实窗口剩余时间。
// 全部使用注入的假时钟，不做真实等待。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const rateLimitPath = resolve(process.cwd(), 'src/server/services/rate-limit.js');
const aiClientPath = resolve(process.cwd(), 'src/server/services/ai-client.js');
const configPath = resolve(process.cwd(), 'src/server/config.js');

const {
  isAiRateLimited,
  aiRateLimitRetryAfterSeconds,
  aiRateLimitBuckets
} = require(rateLimitPath);
const { sendAiJsonError } = require(aiClientPath);
const { AI_RATE_LIMIT_MAX, AI_RATE_LIMIT_WINDOW_MS } = require(configPath);

beforeEach(() => {
  aiRateLimitBuckets.clear();
});

function fakeReq(ip = '10.0.0.1') {
  return { ip, socket: { remoteAddress: ip }, headers: {} };
}

// 最小 res 替身：只记录 sendAiJsonError 实际用到的行为。
function fakeRes() {
  const captured = { status: null, headers: {}, body: null };
  return {
    captured,
    set(name, value) { captured.headers[name] = value; return this; },
    status(code) { captured.status = code; return this; },
    json(payload) { captured.body = payload; return this; }
  };
}

function exhaustBucket(req) {
  let limited = false;
  for (let i = 0; i <= AI_RATE_LIMIT_MAX; i += 1) limited = isAiRateLimited(req);
  return limited;
}

test('未超限时请求正常通过', () => {
  const req = fakeReq();
  for (let i = 0; i < AI_RATE_LIMIT_MAX; i += 1) {
    assert.equal(isAiRateLimited(req), false, `第 ${i + 1} 次请求不应被限流`);
  }
});

test('超限后返回 true', () => {
  assert.equal(exhaustBucket(fakeReq()), true);
});

test('Retry-After 反映真实窗口剩余时间，并随假时钟递减', () => {
  const req = fakeReq();
  assert.equal(exhaustBucket(req), true);

  const bucketStart = aiRateLimitBuckets.get('10.0.0.1').start;
  const windowSeconds = AI_RATE_LIMIT_WINDOW_MS / 1000;

  // 窗口刚开始：剩余接近整个窗口。
  const atStart = aiRateLimitRetryAfterSeconds(req, bucketStart);
  assert.equal(atStart, windowSeconds);

  // 走过一半：剩余约一半，且严格小于刚开始时。
  const halfway = aiRateLimitRetryAfterSeconds(req, bucketStart + AI_RATE_LIMIT_WINDOW_MS / 2);
  assert.equal(halfway, windowSeconds / 2);
  assert.ok(halfway < atStart, 'Retry-After 必须随时间递减');

  // 接近窗口末尾：仍为正数，绝不返回 0。
  const nearEnd = aiRateLimitRetryAfterSeconds(req, bucketStart + AI_RATE_LIMIT_WINDOW_MS - 1);
  assert.ok(nearEnd >= 1, 'Retry-After 至少为 1 秒，避免客户端立刻重试');
  assert.ok(nearEnd < halfway);
});

test('Retry-After 不是写死的窗口长度：桶已存在一段时间后必须更小', () => {
  const req = fakeReq();
  exhaustBucket(req);
  const bucketStart = aiRateLimitBuckets.get('10.0.0.1').start;
  const later = aiRateLimitRetryAfterSeconds(req, bucketStart + 120_000);
  assert.notEqual(later, AI_RATE_LIMIT_WINDOW_MS / 1000);
  assert.equal(later, (AI_RATE_LIMIT_WINDOW_MS - 120_000) / 1000);
});

test('窗口过期后请求重新放行，且计数已重置', () => {
  const req = fakeReq();
  exhaustBucket(req);
  const bucket = aiRateLimitBuckets.get('10.0.0.1');
  // 把窗口起点推到过去，等价于窗口自然过期，不做真实等待。
  bucket.start = Date.now() - AI_RATE_LIMIT_WINDOW_MS - 1000;
  assert.equal(isAiRateLimited(req), false, '窗口过期后应重新放行');
});

test('sendAiJsonError 在给出 retryAfterSeconds 时发出标准 Retry-After 头', () => {
  const res = fakeRes();
  sendAiJsonError(res, 429, 'rate_limited', 'AI 请求太频繁，请稍后再试。', { retryAfterSeconds: 42 });
  assert.equal(res.captured.status, 429);
  assert.equal(res.captured.headers['Retry-After'], '42');
  assert.equal(res.captured.body.code, 'rate_limited');
  assert.equal(res.captured.body.retryAfterSeconds, 42);
});

test('非限流错误不发 Retry-After', () => {
  const res = fakeRes();
  sendAiJsonError(res, 400, 'missing_prompt', '缺少 prompt。');
  assert.equal(res.captured.status, 400);
  assert.equal(res.captured.headers['Retry-After'], undefined);
});

test('429 响应体不含任何密钥、上游细节或其他桶的信息', () => {
  const res = fakeRes();
  sendAiJsonError(res, 429, 'rate_limited', 'AI 请求太频繁，请稍后再试。', { retryAfterSeconds: 30 });
  const serialized = JSON.stringify(res.captured.body);
  for (const forbidden of ['apiKey', 'api_key', 'sk-', 'gsk_', 'bucket', 'ip']) {
    assert.ok(!serialized.includes(forbidden), `响应体不应包含 ${forbidden}`);
  }
  assert.deepEqual(
    Object.keys(res.captured.body).sort(),
    ['code', 'error', 'retryAfterSeconds', 'status']
  );
});

test('不同客户端身份拥有各自独立的桶', () => {
  const reqA = fakeReq('10.0.0.1');
  const reqB = fakeReq('10.0.0.2');
  assert.equal(exhaustBucket(reqA), true);
  // A 已超限，B 必须完全不受影响。
  assert.equal(isAiRateLimited(reqB), false);
});
