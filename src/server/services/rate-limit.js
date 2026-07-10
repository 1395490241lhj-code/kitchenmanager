/*
 * src/server/services/rate-limit.js —— 按 IP 的内存限流桶（共享 AI 桶 + 更严的导入桶）+ 惰性回收。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */
const {
  AI_RATE_LIMIT_MAX,
  AI_RATE_LIMIT_SWEEP_INTERVAL_MS,
  AI_RATE_LIMIT_WINDOW_MS,
  IMPORT_RATE_LIMIT_MAX
} = require('../config');

const aiRateLimitBuckets = new Map();
const importRateLimitBuckets = new Map();
let aiRateLimitLastSweepAt = 0;

// 惰性回收：限流桶按 IP 建、此前从不删除，长跑实例会缓慢累积陌生 IP 的过期桶。
// 每分钟至多整扫一次，把窗口外的桶清掉；单次扫描 O(IP 数)，挂在限流检查入口即可。
function sweepAiRateLimitBuckets(now) {
  if (now - aiRateLimitLastSweepAt < AI_RATE_LIMIT_SWEEP_INTERVAL_MS) return;
  aiRateLimitLastSweepAt = now;
  for (const buckets of [aiRateLimitBuckets, importRateLimitBuckets]) {
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

// 共享 AI 桶：所有会打到上游模型/转录或产生外网抓取的普通接口。
function isAiRateLimited(req) {
  return isBucketRateLimited(req, aiRateLimitBuckets, AI_RATE_LIMIT_MAX);
}

// 导入专用桶（更严）：/api/recipe-import-from-url 单次即整条重活链路。
function isImportRateLimited(req) {
  return isBucketRateLimited(req, importRateLimitBuckets, IMPORT_RATE_LIMIT_MAX);
}

module.exports = {
  aiRateLimitBuckets,
  aiRateLimitLastSweepAt,
  getClientIp,
  importRateLimitBuckets,
  isAiRateLimited,
  isBucketRateLimited,
  isImportRateLimited,
  sweepAiRateLimitBuckets
};
