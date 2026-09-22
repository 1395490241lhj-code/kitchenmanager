// test/ai-conversation-turn-limit.test.mjs
//
// One logical Kitchen AI conversation turn consumes one shared AI quota unit;
// the read-tool continuations of that same turn do not. These tests pin the
// security properties of that ledger: grants exist only for admitted paid
// steps, are keyed by connection IP, expire on a fixed TTL, and are bounded by
// the per-turn step limit. Fake clock via the explicit now argument; fake
// Redis for the shared-store path. No real waits.
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const root = process.cwd();
const {
  checkConversationStepRateLimit,
  isContinuationShaped,
  normalizeTurnId,
  memoryTurnLedger
} = require(resolve(root, 'src/server/services/ai-conversation-turn-limit.js'));
const {
  checkAiRateLimit,
  setSharedAiRateLimitStore,
  aiRateLimitBuckets
} = require(resolve(root, 'src/server/services/rate-limit.js'));
const { createSharedWindowStore } = require(resolve(root, 'src/server/services/shared-window-store.js'));
const {
  AI_RATE_LIMIT_MAX,
  AI_CONVERSATION_MAX_STEPS_PER_TURN,
  AI_CONVERSATION_TURN_TTL_MS
} = require(resolve(root, 'src/server/config.js'));

const T0 = 1_000_000;
const TURN_A = '6f9619ff-8b86-d011-b42d-00cf4fc964ff';
const TURN_B = '0b1d2e3f-4a5b-4c6d-8e7f-901234567890';

function firstStep(turnID) {
  return { turnID, messages: [{ role: 'user', content: '今晚吃什么' }] };
}

function continuationStep(turnID) {
  return {
    turnID,
    messages: [
      { role: 'user', content: '今晚吃什么' },
      { role: 'assistant', tool_calls: [{ id: 'c1', type: 'function', function: { name: 'read_inventory', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'c1', content: '{}' }
    ]
  };
}

function req(body, ip = '10.0.0.1') {
  return { ip, socket: { remoteAddress: ip }, headers: {}, body };
}

// How many shared-quota units have been consumed for this IP (memory backend).
function usedUnits(ip = '10.0.0.1') {
  return aiRateLimitBuckets.get(ip)?.count ?? 0;
}

function createFakeRedis() {
  const data = new Map();
  const expiries = new Map();
  let failing = false;
  return {
    setFailing(value) { failing = value; },
    async incrBy(key, amount) {
      if (failing) throw new Error('connection refused');
      const next = (data.get(key) || 0) + amount;
      data.set(key, next);
      return next;
    },
    async pExpire(key, ms) {
      if (failing) throw new Error('connection refused');
      expiries.set(key, ms);
      return 1;
    },
    async pTTL(key) {
      if (failing) throw new Error('connection refused');
      if (!data.has(key)) return -2;
      return expiries.has(key) ? expiries.get(key) : -1;
    },
    // Real Redis GET semantics: string value, null when missing, never creates.
    // Called both by the store (awaited) and by assertions (value compared as number).
    get(key) {
      if (failing) return Promise.reject(new Error('connection refused'));
      return data.has(key) ? data.get(key) : null;
    },
    keys() { return [...data.keys()]; },
    expire(key) { data.delete(key); expiries.delete(key); }
  };
}

beforeEach(() => {
  setSharedAiRateLimitStore(null);
  aiRateLimitBuckets.clear();
  memoryTurnLedger._clear();
});

test('首步计一次配额，同一 turn 的有效 continuation 不再计', async () => {
  const first = await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  assert.equal(first.limited, false);
  assert.equal(first.accounting, 'charged');
  assert.equal(usedUnits(), 1);

  for (let step = 2; step <= AI_CONVERSATION_MAX_STEPS_PER_TURN; step += 1) {
    const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + step);
    assert.equal(result.limited, false, `step ${step}`);
    assert.equal(result.accounting, 'continuation', `step ${step} should be free`);
  }
  assert.equal(usedUnits(), 1, 'a full six-step turn costs exactly one unit');
});

test('新的逻辑 turn 再计一次配额', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  const second = await checkConversationStepRateLimit(req(firstStep(TURN_B)), T0 + 2);
  assert.equal(second.accounting, 'charged');
  assert.equal(usedUnits(), 2);
});

test('超出每 turn 步数上限后 continuation 重新计费', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  for (let step = 2; step <= AI_CONVERSATION_MAX_STEPS_PER_TURN; step += 1) {
    await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + step);
  }
  assert.equal(usedUnits(), 1);
  const extra = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 100);
  assert.equal(extra.accounting, 'charged');
  assert.equal(usedUnits(), 2);
  const extra2 = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 101);
  assert.equal(extra2.accounting, 'charged', 're-paying does not reset the step bound');
  assert.equal(usedUnits(), 3);
});

test('伪造 / 未知 turnID 的 continuation 不能绕过限流', async () => {
  const forged = await checkConversationStepRateLimit(req(continuationStep(TURN_B)), T0);
  assert.equal(forged.accounting, 'charged');
  assert.equal(usedUnits(), 1);
});

test('畸形 turnID 与缺省 turnID 走普通限流，且不留下 grant', async () => {
  for (const turnID of ['not-a-uuid', '', 42, ['x'], { id: TURN_A }, undefined]) {
    const body = continuationStep(TURN_A);
    body.turnID = turnID;
    const result = await checkConversationStepRateLimit(req(body), T0);
    assert.equal(result.accounting, 'charged', `turnID=${JSON.stringify(turnID)}`);
  }
  assert.equal(usedUnits(), 6);
  assert.equal(normalizeTurnId(' ' + TURN_A.toUpperCase() + ' '), TURN_A);
});

test('过期的 turn grant 不能继续免计', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  const expired = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + AI_CONVERSATION_TURN_TTL_MS);
  assert.equal(expired.accounting, 'charged');
});

test('非 continuation 形状的请求即使复用已付费 turnID 也计费', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  const reused = await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0 + 1);
  assert.equal(reused.accounting, 'charged');
  assert.equal(usedUnits(), 2);
  assert.equal(isContinuationShaped({ messages: [{ role: 'tool' }] }), true);
  assert.equal(isContinuationShaped({ messages: [{ role: 'user' }] }), false);
  assert.equal(isContinuationShaped({ messages: 'tool' }), false);
});

test('grant 绑定连接 IP：别的 IP 拿同一 turnID 仍然计费', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A), '10.0.0.1'), T0);
  const other = await checkConversationStepRateLimit(req(continuationStep(TURN_A), '10.0.0.2'), T0 + 1);
  assert.equal(other.accounting, 'charged');
  assert.equal(usedUnits('10.0.0.2'), 1);
});

test('被 429 的首步不写 grant：超额客户端无法铸造免费 continuation', async () => {
  for (let i = 0; i < AI_RATE_LIMIT_MAX; i += 1) await checkAiRateLimit(req({}), T0);
  const limited = await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0 + 1);
  assert.equal(limited.limited, true);
  const follow = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 2);
  assert.equal(follow.limited, true);
  assert.equal(follow.accounting, 'charged');
});

test('/api/ai-chat 使用的 checkAiRateLimit 语义不变：每次调用各计一次', async () => {
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  for (let i = 0; i < AI_RATE_LIMIT_MAX - 1; i += 1) {
    const r = await checkAiRateLimit(req({ turnID: TURN_A, messages: [{ role: 'tool' }] }), T0 + 2);
    assert.equal(r.limited, false);
  }
  const over = await checkAiRateLimit(req({}), T0 + 3);
  assert.equal(over.limited, true, 'shared bucket still caps at AI_RATE_LIMIT_MAX');
});

test('共享 store：turn 账本跨实例生效，且与配额同源', async () => {
  const redis = createFakeRedis();
  const instanceA = createSharedWindowStore({ client: redis });
  const instanceB = createSharedWindowStore({ client: redis });

  setSharedAiRateLimitStore(instanceA);
  const first = await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  assert.equal(first.accounting, 'charged');
  setSharedAiRateLimitStore(instanceB);
  const cont = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  assert.equal(cont.accounting, 'continuation');
  assert.equal(redis.get('ai:10.0.0.1'), 1);
  assert.equal(aiRateLimitBuckets.size, 0, 'no per-process fallback counting');
});

test('共享 store 故障时 continuation 不免计（fail closed）', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  redis.setFailing(true);
  const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  assert.equal(result.accounting, 'charged');
  assert.equal(result.backend, 'degraded');
});

// ── Grant lookup is read-only: probes never create ledger state ─────────────

function turnKeys(redis) {
  return redis.keys().filter((key) => key.startsWith('ai-turn:'));
}

function exhaustQuota(ip = '10.0.0.1') {
  return (async () => {
    for (let i = 0; i < AI_RATE_LIMIT_MAX; i += 1) await checkAiRateLimit(req({}, ip), T0);
  })();
}

function forgedTurnId(index) {
  return `deadbeef-0000-4000-8000-${String(index).padStart(12, '0')}`;
}

test('内存账本：未知 turnID 的 continuation 正常计费，且不留下 grant / steps 条目', async () => {
  const result = await checkConversationStepRateLimit(req(continuationStep(TURN_B)), T0);
  assert.equal(result.limited, false);
  assert.equal(result.accounting, 'charged');
  assert.equal(usedUnits(), 1);
  assert.equal(memoryTurnLedger._size(), 0);
  // And it still cannot be followed by a free step.
  const next = await checkConversationStepRateLimit(req(continuationStep(TURN_B)), T0 + 1);
  assert.equal(next.accounting, 'charged');
  assert.equal(memoryTurnLedger._size(), 0);
});

test('内存账本：已超额客户端用大量伪造 turnID 探测，全部限流且账本不增长', async () => {
  await exhaustQuota();
  for (let i = 0; i < 50; i += 1) {
    const result = await checkConversationStepRateLimit(req(continuationStep(forgedTurnId(i))), T0 + 1);
    assert.equal(result.limited, true);
    assert.equal(result.accounting, 'charged');
  }
  assert.equal(memoryTurnLedger._size(), 0);
});

test('共享 store：未知 turnID 的 continuation 不留下 grant / steps key', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  const result = await checkConversationStepRateLimit(req(continuationStep(TURN_B)), T0);
  assert.equal(result.limited, false);
  assert.equal(result.accounting, 'charged');
  assert.equal(redis.get('ai:10.0.0.1'), 1);
  assert.deepEqual(turnKeys(redis), []);
});

test('共享 store：已超额客户端用大量伪造 turnID 探测，全部限流且 key 数不增长', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await exhaustQuota();
  const before = redis.keys().length;
  for (let i = 0; i < 50; i += 1) {
    const result = await checkConversationStepRateLimit(req(continuationStep(forgedTurnId(i))), T0 + 1);
    assert.equal(result.limited, true);
  }
  assert.deepEqual(turnKeys(redis), []);
  assert.equal(redis.keys().length, before, 'only the existing quota key');
  assert.equal(memoryTurnLedger._size(), 0);
});

test('共享 store：合法首步写 grant，合法 continuation 仍免计', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  assert.equal(redis.get(`ai-turn:10.0.0.1:${TURN_A}:grant`), 1);
  for (let step = 2; step <= AI_CONVERSATION_MAX_STEPS_PER_TURN; step += 1) {
    const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + step);
    assert.equal(result.accounting, 'continuation');
  }
  assert.equal(redis.get('ai:10.0.0.1'), 1);
});

test('内存账本：过期 grant 读取为 0 且被移除，读路径不会重建它', async () => {
  const grantKey = `ai-turn:10.0.0.1:${TURN_A}:grant`;
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  assert.equal(await memoryTurnLedger.peek(grantKey, T0 + 1), 1);
  assert.equal(await memoryTurnLedger.peek(grantKey, T0 + AI_CONVERSATION_TURN_TTL_MS), 0);
  assert.equal(memoryTurnLedger._size(), 0);
  assert.equal(await memoryTurnLedger.peek(grantKey, T0 + AI_CONVERSATION_TURN_TTL_MS + 1), 0);
  assert.equal(memoryTurnLedger._size(), 0);
});

test('共享 store：过期（被 store 回收）的 grant 不可用，读路径不会重建', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  for (const key of turnKeys(redis)) redis.expire(key);
  await exhaustQuota();
  const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  assert.equal(result.limited, true);
  assert.equal(result.accounting, 'charged');
  assert.deepEqual(turnKeys(redis), []);
});

test('共享 store 读取故障：fail closed 走降级限流，且不回退写内存账本', async () => {
  const redis = createFakeRedis();
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  redis.setFailing(true);
  const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 1);
  assert.equal(result.accounting, 'charged');
  assert.equal(result.backend, 'degraded');
  assert.equal(memoryTurnLedger._size(), 0);
});

test('共享 store（camelCase-only）：六步合法 turn 只计 1 个配额单位，第七步按既有上限重新计费', async () => {
  const redis = createFakeRedis();
  assert.equal(redis.incrby, undefined);
  setSharedAiRateLimitStore(createSharedWindowStore({ client: redis }));
  const first = await checkConversationStepRateLimit(req(firstStep(TURN_A)), T0);
  assert.equal(first.backend, 'shared', 'shared store must actually be used, not degraded');
  assert.equal(redis.get('ai:10.0.0.1'), 1);
  assert.equal(redis.get(`ai-turn:10.0.0.1:${TURN_A}:grant`), 1);
  for (let step = 2; step <= AI_CONVERSATION_MAX_STEPS_PER_TURN; step += 1) {
    const result = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + step);
    assert.equal(result.accounting, 'continuation', `step ${step}`);
  }
  assert.equal(redis.get('ai:10.0.0.1'), 1, 'six legitimate provider steps = one unit');
  const seventh = await checkConversationStepRateLimit(req(continuationStep(TURN_A)), T0 + 100);
  assert.equal(seventh.accounting, 'charged');
  assert.equal(seventh.backend, 'shared');
  assert.equal(redis.get('ai:10.0.0.1'), 2);
  assert.equal(aiRateLimitBuckets.size, 0, 'never touched the degraded per-instance path');
});
