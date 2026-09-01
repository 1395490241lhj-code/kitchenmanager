// test/ai-rate-limit-shared-store.test.mjs
//
// Render 跑多个实例，进程内 Map 让每个实例各记各的数：同一个客户端会随机遇到
// 不同计数（生产实测 429 后 1 秒即 200、"全新"会话第 3 次就 429）。这些测试钉住
// 共享 store 的语义：无论请求落在哪个实例，全局只有一个 30 次的桶。
// 全部使用假 store + 假时钟，不连真 Redis，也不做真实等待。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const sharedStorePath = resolve(process.cwd(), 'src/server/services/shared-window-store.js');
const rateLimitPath = resolve(process.cwd(), 'src/server/services/rate-limit.js');
const configPath = resolve(process.cwd(), 'src/server/config.js');

const { createSharedWindowStore, toRetryAfterSeconds } = require(sharedStorePath);
const {
  checkAiRateLimit,
  setSharedAiRateLimitStore,
  hasSharedAiRateLimitStore,
  degradedInstanceMax,
  aiRateLimitBuckets
} = require(rateLimitPath);
const { AI_RATE_LIMIT_MAX, AI_RATE_LIMIT_WINDOW_MS } = require(configPath);

// 一个最小的 Redis 替身：只实现 store 用到的三个原子命令。所有"实例"共用同一份
// 数据，这正是被测的性质。
function createFakeRedis() {
  const data = new Map();
  const expiries = new Map();
  let failing = false;
  return {
    setFailing(value) { failing = value; },
    get calls() { return data; },
    async incrby(key, amount) {
      if (failing) throw new Error('connection refused');
      const next = (data.get(key) || 0) + amount;
      data.set(key, next);
      return next;
    },
    async pexpire(key, ms) {
      if (failing) throw new Error('connection refused');
      expiries.set(key, ms);
      return 1;
    },
    async pttl(key) {
      if (failing) throw new Error('connection refused');
      if (!data.has(key)) return -2;
      return expiries.has(key) ? expiries.get(key) : -1;
    },
    // 测试用：模拟窗口过期。
    expire(key) { data.delete(key); expiries.delete(key); }
  };
}

function fakeReq(ip = '10.0.0.1') {
  return { ip, socket: { remoteAddress: ip }, headers: {} };
}

beforeEach(() => {
  setSharedAiRateLimitStore(null);
  aiRateLimitBuckets.clear();
});

// ── 一：跨实例共享计数 ──────────────────────────────────────────────────────

test('实例 A 用掉 1–15、实例 B 用掉 16–30，第 31 次无论落在哪个实例都必须 429', async () => {
  const redis = createFakeRedis();
  // 两个"实例"各自建自己的 store 对象，但指向同一份共享数据——正是生产拓扑。
  const instanceA = createSharedWindowStore({ client: redis });
  const instanceB = createSharedWindowStore({ client: redis });
  const req = fakeReq();

  for (let i = 1; i <= 15; i += 1) {
    setSharedAiRateLimitStore(instanceA);
    const result = await checkAiRateLimit(req);
    assert.equal(result.limited, false, `实例 A 第 ${i} 次不应被限流`);
  }
  for (let i = 16; i <= AI_RATE_LIMIT_MAX; i += 1) {
    setSharedAiRateLimitStore(instanceB);
    const result = await checkAiRateLimit(req);
    assert.equal(result.limited, false, `实例 B 第 ${i} 次不应被限流`);
  }

  // 第 31 次：两个实例都必须认为已超限。
  setSharedAiRateLimitStore(instanceA);
  const viaA = await checkAiRateLimit(req);
  assert.equal(viaA.limited, true, '第 31 次落在实例 A 必须 429');
  setSharedAiRateLimitStore(instanceB);
  const viaB = await checkAiRateLimit(req);
  assert.equal(viaB.limited, true, '第 31 次落在实例 B 也必须 429');
});

test('超限后不再出现「换个实例就放行」的随机交替', async () => {
  const redis = createFakeRedis();
  const stores = [
    createSharedWindowStore({ client: redis }),
    createSharedWindowStore({ client: redis }),
    createSharedWindowStore({ client: redis })
  ];
  const req = fakeReq();
  for (let i = 0; i < AI_RATE_LIMIT_MAX; i += 1) {
    setSharedAiRateLimitStore(stores[i % stores.length]);
    await checkAiRateLimit(req);
  }
  // 连续 12 次轮流打到不同实例：必须全部 429，一次放行都不能有。
  for (let i = 0; i < 12; i += 1) {
    setSharedAiRateLimitStore(stores[i % stores.length]);
    const result = await checkAiRateLimit(req);
    assert.equal(result.limited, true, `第 ${i + 1} 次跨实例探测不应被放行`);
  }
});

test('不同客户端身份互不影响', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  setSharedAiRateLimitStore(store);
  const reqA = fakeReq('10.0.0.1');
  const reqB = fakeReq('10.0.0.2');
  for (let i = 0; i < AI_RATE_LIMIT_MAX + 1; i += 1) await checkAiRateLimit(reqA);
  assert.equal((await checkAiRateLimit(reqA)).limited, true);
  assert.equal((await checkAiRateLimit(reqB)).limited, false, 'B 不应被 A 的用量影响');
});

test('窗口过期后重新放行', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  setSharedAiRateLimitStore(store);
  const req = fakeReq();
  for (let i = 0; i < AI_RATE_LIMIT_MAX + 1; i += 1) await checkAiRateLimit(req);
  assert.equal((await checkAiRateLimit(req)).limited, true);
  redis.expire('ai:10.0.0.1'); // 等价于 TTL 到期，不做真实等待
  assert.equal((await checkAiRateLimit(req)).limited, false);
});

// ── 二：原子性与 TTL ───────────────────────────────────────────────────────

test('计数使用原子 INCRBY，并发不会丢增量', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  const req = fakeReq();
  setSharedAiRateLimitStore(store);
  // 30 个并发请求同时发出：读-改-写实现会丢增量，INCRBY 不会。
  await Promise.all(Array.from({ length: 30 }, () => checkAiRateLimit(req)));
  assert.equal(redis.calls.get('ai:10.0.0.1'), 30, '并发下计数必须精确为 30');
});

test('只有创建窗口的那次请求设置过期时间，窗口不会被不断顺延', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  let pexpireCalls = 0;
  const original = redis.pexpire.bind(redis);
  redis.pexpire = async (key, ms) => { pexpireCalls += 1; return original(key, ms); };
  setSharedAiRateLimitStore(store);
  const req = fakeReq();
  for (let i = 0; i < 10; i += 1) await checkAiRateLimit(req);
  assert.equal(pexpireCalls, 1, '窗口只应在第一次请求时设定，否则永远不会重置');
});

test('Retry-After 来自共享 TTL，随时间递减，且永不为 0', () => {
  assert.equal(toRetryAfterSeconds(600000, AI_RATE_LIMIT_WINDOW_MS), 600);
  assert.equal(toRetryAfterSeconds(60000, AI_RATE_LIMIT_WINDOW_MS), 60);
  // 毫秒 TTL 必须向上取整：还剩 500ms 仍然是被限流状态，不能回 0。
  assert.equal(toRetryAfterSeconds(500, AI_RATE_LIMIT_WINDOW_MS), 1);
  assert.ok(toRetryAfterSeconds(60000, AI_RATE_LIMIT_WINDOW_MS) < toRetryAfterSeconds(600000, AI_RATE_LIMIT_WINDOW_MS));
});

test('多个实例读到近似一致的剩余时间（同一个共享 TTL）', async () => {
  const redis = createFakeRedis();
  const instanceA = createSharedWindowStore({ client: redis });
  const instanceB = createSharedWindowStore({ client: redis });
  const req = fakeReq();
  setSharedAiRateLimitStore(instanceA);
  for (let i = 0; i < AI_RATE_LIMIT_MAX + 1; i += 1) await checkAiRateLimit(req);
  const fromA = await checkAiRateLimit(req);
  setSharedAiRateLimitStore(instanceB);
  const fromB = await checkAiRateLimit(req);
  assert.equal(fromA.retryAfterSeconds, fromB.retryAfterSeconds);
});

test('丢失过期时间的 key 会被修复，不会把某个身份永久限死', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  await store.consume('ai:x', AI_RATE_LIMIT_WINDOW_MS, Date.now());
  // 模拟 PEXPIRE 丢失：key 存在但没有 TTL。
  redis.pttl = async () => -1;
  let repaired = false;
  redis.pexpire = async () => { repaired = true; return 1; };
  const result = await store.consume('ai:x', AI_RATE_LIMIT_WINDOW_MS, Date.now());
  assert.ok(repaired, '没有 TTL 的 key 必须被重新设定过期时间');
  assert.ok(result.retryAfterSeconds > 0);
});

// ── 三：store 故障策略 ─────────────────────────────────────────────────────

test('共享 store 故障时降级到本进程计数，但配额按实例数收紧', async () => {
  const redis = createFakeRedis();
  const errors = [];
  const store = createSharedWindowStore({ client: redis, onError: (c) => errors.push(c) });
  setSharedAiRateLimitStore(store);
  redis.setFailing(true);
  const req = fakeReq();

  const degradedMax = degradedInstanceMax(AI_RATE_LIMIT_MAX);
  assert.ok(degradedMax < AI_RATE_LIMIT_MAX, '降级配额必须小于全局配额');

  let limitedAt = null;
  for (let i = 1; i <= AI_RATE_LIMIT_MAX && limitedAt === null; i += 1) {
    const result = await checkAiRateLimit(req);
    assert.equal(result.backend, 'degraded');
    if (result.limited) limitedAt = i;
  }
  assert.equal(limitedAt, degradedMax + 1, '降级后必须在收紧的配额处限流');
  assert.ok(errors.includes('limiter_store_unavailable'), 'store 故障必须被记录');
});

test('store 故障不会永久关闭 AI 功能：恢复后回到共享计数', async () => {
  const redis = createFakeRedis();
  const store = createSharedWindowStore({ client: redis });
  setSharedAiRateLimitStore(store);
  const req = fakeReq();
  redis.setFailing(true);
  assert.equal((await checkAiRateLimit(req)).backend, 'degraded');
  redis.setFailing(false);
  assert.equal((await checkAiRateLimit(req)).backend, 'shared');
});

test('未配置共享 store 时保持现有进程内行为（配置可先于资源上线）', async () => {
  assert.equal(hasSharedAiRateLimitStore(), false);
  const result = await checkAiRateLimit(fakeReq());
  assert.equal(result.backend, 'memory');
  assert.equal(result.limited, false);
});

test('配额与窗口本轮未改变', () => {
  assert.equal(AI_RATE_LIMIT_MAX, 30);
  assert.equal(AI_RATE_LIMIT_WINDOW_MS, 10 * 60 * 1000);
});
