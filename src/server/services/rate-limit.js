/*
 * src/server/services/rate-limit.js —— 按 IP 的内存限流桶（共享 AI 桶 + 更严的导入桶）+ 惰性回收。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */
const {
  AUTH_ME_RATE_LIMIT_MAX,
  AI_RATE_LIMIT_MAX,
  AI_RATE_LIMIT_SWEEP_INTERVAL_MS,
  AI_RATE_LIMIT_WINDOW_MS,
  IMPORT_RATE_LIMIT_MAX
} = require('../config');

const aiRateLimitBuckets = new Map();
const importRateLimitBuckets = new Map();
const authMeRateLimitBuckets = new Map();
let aiRateLimitLastSweepAt = 0;

// 保守假设：真实实例数由 Render 决定且会变，limiter 不应依赖一个它无法验证的
// 数字。取一个小的固定值，只在共享 store 故障期间生效。
const SHARED_STORE_ASSUMED_INSTANCES = 3;

// 惰性回收：限流桶按 IP 建、此前从不删除，长跑实例会缓慢累积陌生 IP 的过期桶。
// 每分钟至多整扫一次，把窗口外的桶清掉；单次扫描 O(IP 数)，挂在限流检查入口即可。
function sweepAiRateLimitBuckets(now) {
  if (now - aiRateLimitLastSweepAt < AI_RATE_LIMIT_SWEEP_INTERVAL_MS) return;
  aiRateLimitLastSweepAt = now;
  for (const buckets of [aiRateLimitBuckets, importRateLimitBuckets, authMeRateLimitBuckets]) {
    for (const [ip, bucket] of buckets) {
      if (now - bucket.start > AI_RATE_LIMIT_WINDOW_MS) buckets.delete(ip);
    }
  }
}

// 限流 key 只能用连接层已验证的地址，不能直接信任客户端可伪造的 X-Forwarded-For——
// 非浏览器客户端可以给每个请求带不同的 X-Forwarded-For 绕开限流。
// req.ip 由 Express 根据 `trust proxy` 配置解析：项目当前没有配置 trust proxy，
// 所以 req.ip 就等于连接的真实 remoteAddress，不会读取未验证的请求头。
// 之后如果要在受信任的反向代理后面部署，应显式配置 app.set('trust proxy', ...)，
// 而不是在这里手工解析 header。
function getClientIp(req) {
  return req.ip || req.socket?.remoteAddress || 'unknown';
}

function isBucketRateLimited(req, buckets, max) {
  const ip = getClientIp(req);
  const now = Date.now();
  sweepAiRateLimitBuckets(now);
  const bucket = buckets.get(ip) || { start: now, count: 0 };
  if (now - bucket.start > AI_RATE_LIMIT_WINDOW_MS) {
    bucket.start = now;
    bucket.count = 0;
  }
  bucket.count += 1;
  buckets.set(ip, bucket);
  return bucket.count > max;
}

// 固定窗口：桶在 bucket.start + AI_RATE_LIMIT_WINDOW_MS 整体重置，所以「还要等多久」
// 就是当前窗口的剩余时间。只读，不推进计数——必须在 isBucketRateLimited 之后调用。
// 没有桶时返回整个窗口长度（保守），秒数至少为 1，避免客户端拿到 0 立刻重试。
function bucketRetryAfterSeconds(req, buckets, now = Date.now()) {
  const bucket = buckets.get(getClientIp(req));
  const elapsed = bucket ? now - bucket.start : 0;
  const remainingMs = Math.max(0, AI_RATE_LIMIT_WINDOW_MS - elapsed);
  return Math.max(1, Math.ceil(remainingMs / 1000));
}

// AI 桶的剩余窗口秒数，用于 429 的标准 Retry-After。
function aiRateLimitRetryAfterSeconds(req, now = Date.now()) {
  return bucketRetryAfterSeconds(req, aiRateLimitBuckets, now);
}

// ── 跨实例共享的 AI 限流 ─────────────────────────────────────────────────────
// Render 会同时跑多个实例，进程内 Map 意味着每个实例各记各的数：同一个客户端
// 会随机落到不同计数上（生产实测：429 之后 1 秒即 200；"全新"会话第 3 次就
// 429）。配置了共享 store 之后，30/10min 才第一次真正表示"一个身份在整个服务
// 上的 30 次"。配额与 key 都不变，只有计数的存放位置变了。
let sharedAiStore = null;

function setSharedAiRateLimitStore(store) {
  sharedAiStore = store || null;
}

function hasSharedAiRateLimitStore() {
  return Boolean(sharedAiStore);
}

// store 短暂不可用时的策略：既不能让 limiter 故障把 AI 功能整个打死，也不能
// 无保护地放行昂贵的 provider 调用。这里退回本进程计数，但**配额按实例数收紧**
// （下取整、至少 1），这样 N 个实例加起来仍不超过全局配额，不会退回成当前这种
// "每实例一份完整 30 次"的放大问题。
function degradedInstanceMax(max, instanceCount = SHARED_STORE_ASSUMED_INSTANCES) {
  return Math.max(1, Math.floor(max / Math.max(1, instanceCount)));
}

// 返回 { limited, retryAfterSeconds, backend }。backend 用于结构化日志，
// 让生产可以证明限流到底走的是共享 store 还是降级路径。
async function checkAiRateLimit(req, now = Date.now()) {
  const key = `ai:${getClientIp(req)}`;
  if (sharedAiStore) {
    try {
      const { count, retryAfterSeconds } = await sharedAiStore.consume(key, AI_RATE_LIMIT_WINDOW_MS, now);
      return { limited: count > AI_RATE_LIMIT_MAX, retryAfterSeconds, backend: 'shared' };
    } catch (error) {
      sharedAiStore._onError?.('limiter_store_unavailable');
      const limited = isBucketRateLimited(req, aiRateLimitBuckets, degradedInstanceMax(AI_RATE_LIMIT_MAX));
      return { limited, retryAfterSeconds: aiRateLimitRetryAfterSeconds(req, now), backend: 'degraded' };
    }
  }
  const limited = isAiRateLimited(req);
  return { limited, retryAfterSeconds: aiRateLimitRetryAfterSeconds(req, now), backend: 'memory' };
}

// 共享 AI 桶：所有会打到上游模型/转录或产生外网抓取的普通接口。
function isAiRateLimited(req) {
  return isBucketRateLimited(req, aiRateLimitBuckets, AI_RATE_LIMIT_MAX);
}

// 导入专用桶（更严）：/api/recipe-import-from-url 单次即整条重活链路。
function isImportRateLimited(req) {
  return isBucketRateLimited(req, importRateLimitBuckets, IMPORT_RATE_LIMIT_MAX);
}

// /api/me is cheap but authenticated and internet-facing. Key by the verified
// subject plus connection-derived IP; never by a client supplied userId.
function isAuthMeRateLimited(req) {
  const userId = req.auth?.userId || 'unauthenticated';
  const scopedRequest = {
    ip: `${userId}:${getClientIp(req)}`,
    socket: req.socket
  };
  return isBucketRateLimited(scopedRequest, authMeRateLimitBuckets, AUTH_ME_RATE_LIMIT_MAX);
}

module.exports = {
  aiRateLimitBuckets,
  aiRateLimitRetryAfterSeconds,
  authMeRateLimitBuckets,
  aiRateLimitLastSweepAt,
  bucketRetryAfterSeconds,
  checkAiRateLimit,
  degradedInstanceMax,
  getClientIp,
  hasSharedAiRateLimitStore,
  importRateLimitBuckets,
  isAiRateLimited,
  isAuthMeRateLimited,
  isBucketRateLimited,
  isImportRateLimited,
  setSharedAiRateLimitStore,
  sweepAiRateLimitBuckets
};
