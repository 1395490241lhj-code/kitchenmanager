const path = require('path');
const os = require('os');

const ROOT = path.resolve(__dirname, '..', '..');
const PORT = process.env.PORT || 3000;

const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1';

const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.groq.com/openai/v1';
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'openai/gpt-oss-120b';
const OPENAI_IMPORT_MODEL = process.env.OPENAI_IMPORT_MODEL
  || (/groq\.com/i.test(OPENAI_BASE_URL) ? 'openai/gpt-oss-20b' : OPENAI_MODEL);
const DEFAULT_OPENAI_VISION_MODEL = 'meta-llama/llama-4-scout-17b-16e-instruct';
const OPENAI_VISION_MODEL = process.env.OPENAI_VISION_MODEL || DEFAULT_OPENAI_VISION_MODEL;
const OPENAI_TRANSCRIBE_MODEL = process.env.OPENAI_TRANSCRIBE_MODEL || 'gpt-4o-mini-transcribe';

const AI_PROMPT_MAX_CHARS = 12000;
const AI_IMAGE_MAX_BASE64_BYTES = 4 * 1024 * 1024;
const AI_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
const AI_RATE_LIMIT_MAX = 30;
const IMPORT_RATE_LIMIT_MAX = 10;
const AUTH_ME_RATE_LIMIT_MAX = 60;
const AI_RATE_LIMIT_SWEEP_INTERVAL_MS = 60 * 1000;

// Phase 2D-2: account deletion is rare and destructive — a much tighter
// bucket than /api/me, keyed the same way (userId:IP). The deletion nonce
// is this codebase's Stage-1 fallback for "recent authentication" (see
// docs/ACCOUNT_DELETION_DESIGN.md): rather than relaying a password to this
// backend or assuming a full reauth flow, a preview mints a short-lived
// nonce that confirm must present quickly afterward, approximating "the
// user just took a deliberate, recent action" without real password reauth.
const ACCOUNT_DELETION_RATE_LIMIT_MAX = 10;
const ACCOUNT_DELETION_NONCE_TTL_MS = 5 * 60 * 1000;

// Phase 2C-1: /api/sync/* only. These are a documented starting point (see
// docs/SYNC_API_RATE_LIMITING.md), not empirically tuned against real
// production traffic, since no production cohort exists yet. Hardcoded
// (like the AI limits above) rather than env-configurable — the storage
// backend is what's designed to be swappable, not these thresholds.
const SYNC_READ_RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const SYNC_READ_RATE_LIMIT_MAX = 120;
const SYNC_MUTATION_RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS = 40;
const SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX = 500;

// ── Supabase 环境变量清洗 ─────────────────────────────────────────────────
// 背景：Render 上真实出现过「本地能通过、Render 上 /api/me 一律 401
// invalid_token」的问题，根因是 issuer/audience 在 jose 的 jwtVerify 里是
// 精确字符串比较（不像 URL 会被 WHATWG URL 解析器自动裁掉首尾空白），Render
// 控制台粘贴环境变量时混入的尾随空格/换行会让 SUPABASE_JWT_ISSUER 变成
// "https://xxx.supabase.co/auth/v1\n"，而真实 token 的 payload.iss 永远没有
// 这个换行，于是每一次验证都必然失败，且失败信息完全通用（invalid_token），
// 现场排查非常困难。这里统一 trim，并额外识别「首尾包着引号」「协议重复粘贴
// 两次」这类同样会导致静默失败的粘贴事故，作为明确的启动期配置错误上报，而不
// 是继续悄悄用一个错误的值尝试验证。
function stripWrappingQuotes(value) {
  if (value.length < 2) return { value, wasQuoted: false };
  const first = value[0];
  const last = value[value.length - 1];
  if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
    return { value: value.slice(1, -1), wasQuoted: true };
  }
  return { value, wasQuoted: false };
}

function hasDuplicateProtocol(value) {
  const separatorIndex = value.indexOf('://');
  return separatorIndex >= 0 && value.slice(separatorIndex + 3).includes('://');
}

// 只 trim + 识别引号/重复协议，不做 URL 校验；用于 anon key / service-role
// key / audience 这类「不是 URL，但同样参与精确比较」的值。
function sanitizeSupabaseEnvValue(name, rawValue) {
  const raw = (rawValue === undefined || rawValue === null) ? '' : String(rawValue);
  const trimmed = raw.trim();
  if (!trimmed) return { value: '', error: null };
  const { value: unquoted, wasQuoted } = stripWrappingQuotes(trimmed);
  if (wasQuoted) {
    return {
      value: trimmed,
      error: `${name} 的值首尾包含引号字符，请在环境变量里去掉首尾的 " 或 '（值本身不应该包含引号）`
    };
  }
  if (hasDuplicateProtocol(unquoted)) {
    return { value: unquoted, error: `${name} 包含重复的协议前缀（例如粘贴了两次 https://），请检查该环境变量的值` };
  }
  return { value: unquoted, error: null };
}

// 在上面的基础上再校验 URL 形状：必须是绝对 http/https URL，且生产环境（非
// localhost/127.0.0.1）必须是 HTTPS，用于 SUPABASE_URL / SUPABASE_JWKS_URL /
// SUPABASE_JWT_ISSUER 这三个本质是 URL 的值。
function sanitizeSupabaseUrlValue(name, rawValue) {
  const { value, error } = sanitizeSupabaseEnvValue(name, rawValue);
  if (error || !value) return { value, error };
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    return { value, error: `${name} 不是合法的绝对 URL` };
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return { value, error: `${name} 协议必须是 http 或 https` };
  }
  const isLocalHost = parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1';
  if (parsed.protocol !== 'https:' && !isLocalHost) {
    return { value, error: `${name} 必须使用 HTTPS（本地 127.0.0.1/localhost 除外）` };
  }
  return { value: value.replace(/\/+$/, ''), error: null };
}

const SUPABASE_AUTH_CONFIG_ERRORS = [];
function collect(name, result) {
  if (result.error) SUPABASE_AUTH_CONFIG_ERRORS.push(result.error);
  return result.value;
}

// Supabase public project configuration. SERVICE_ROLE is deliberately not
// consumed by the normal /api/me path: that request is forwarded with the
// verified user's JWT so PostgREST still applies RLS.
const SUPABASE_URL = collect('SUPABASE_URL', sanitizeSupabaseUrlValue('SUPABASE_URL', process.env.SUPABASE_URL));
const SUPABASE_ANON_KEY = collect('SUPABASE_ANON_KEY', sanitizeSupabaseEnvValue('SUPABASE_ANON_KEY', process.env.SUPABASE_ANON_KEY));
const SUPABASE_SERVICE_ROLE_KEY = collect(
  'SUPABASE_SERVICE_ROLE_KEY',
  sanitizeSupabaseEnvValue('SUPABASE_SERVICE_ROLE_KEY', process.env.SUPABASE_SERVICE_ROLE_KEY)
);
const SUPABASE_JWKS_URL = collect('SUPABASE_JWKS_URL', sanitizeSupabaseUrlValue(
  'SUPABASE_JWKS_URL',
  process.env.SUPABASE_JWKS_URL || (SUPABASE_URL ? `${SUPABASE_URL}/auth/v1/.well-known/jwks.json` : '')
));
const SUPABASE_JWT_ISSUER = collect('SUPABASE_JWT_ISSUER', sanitizeSupabaseUrlValue(
  'SUPABASE_JWT_ISSUER',
  process.env.SUPABASE_JWT_ISSUER || (SUPABASE_URL ? `${SUPABASE_URL}/auth/v1` : '')
));
const SUPABASE_JWT_AUDIENCE = collect(
  'SUPABASE_JWT_AUDIENCE',
  sanitizeSupabaseEnvValue('SUPABASE_JWT_AUDIENCE', process.env.SUPABASE_JWT_AUDIENCE || 'authenticated')
);

// issuer 与 SUPABASE_URL 指向的项目是否一致（同源）。两者都能各自合法解析成
// URL 时才检查——各自的格式错误已经在上面各自报告过了。
if (SUPABASE_URL && SUPABASE_JWT_ISSUER) {
  try {
    if (new URL(SUPABASE_JWT_ISSUER).origin !== new URL(SUPABASE_URL).origin) {
      SUPABASE_AUTH_CONFIG_ERRORS.push('SUPABASE_JWT_ISSUER 与 SUPABASE_URL 指向的 Supabase 项目不一致（origin 不同）');
    }
  } catch { /* 不合法的那一个已经在上面报告过了 */ }
}

function safeHostname(url) {
  if (!url) return '(not configured)';
  try { return new URL(url).hostname || '(unknown)'; } catch { return '(invalid)'; }
}

function safePathname(url) {
  if (!url) return '';
  try { return new URL(url).pathname || '/'; } catch { return ''; }
}

// 启动日志用：只暴露 host/path 这些非密钥信息，绝不暴露完整 URL 或任何 key
// 内容。
function describeSupabaseAuthConfig() {
  return {
    supabaseHost: safeHostname(SUPABASE_URL),
    jwksHost: safeHostname(SUPABASE_JWKS_URL),
    jwksPath: safePathname(SUPABASE_JWKS_URL),
    issuer: SUPABASE_JWT_ISSUER || '(not configured)',
    audience: SUPABASE_JWT_AUDIENCE || '(not configured)',
    nodeVersion: process.version
  };
}

Object.freeze(SUPABASE_AUTH_CONFIG_ERRORS);

const MEDIA_TMP_DIR = path.join(os.tmpdir(), 'kitchenmanager-media');
const MEDIA_MAX_VIDEO_BYTES = 80 * 1024 * 1024;
const MEDIA_DOWNLOAD_TIMEOUT_MS = 30000;
const MEDIA_FILE_TTL_MS = 60 * 60 * 1000;
const MEDIA_MAX_FRAME_COUNT = 3;
const MEDIA_MAX_FRAME_BYTES = 700 * 1024;
const RECIPE_IMPORT_MEDIA_CACHE_TTL_MS = 30 * 60 * 1000;

// ── Trust proxy hops（Render 等反代环境下，rate-limit 靠 req.ip 识别真实客户端）──
// 背景：Render Web Service 的公网入口是 Render 自己的边缘代理，Node 进程看到的
// socket 对端永远是那层代理，不是终端用户。不显式配置 trust proxy 时，所有用户
// 会共享同一个（或少数几个）rate-limit 桶。
//
// 只接受正整数字符串（如 '1'/'2'），代表"信任离自己最近的 N 跳反代"：
//   - 未设置 / 空字符串 / '0' → 0（本地开发默认值，不信任任何代理，不算非法）。
//   - 'true' / 负数 / 小数（如 '2.5'）/ 任意非纯数字字符串 → 一律视为非法，
//     回退到 0，并通过 TRUST_PROXY_HOPS_INVALID_RAW 让调用方打印明确 warning。
// 绝不接受布尔值 true（等价于信任整条转发链，会被客户端伪造的 X-Forwarded-For
// 完全绕过），只允许具体的跳数。
function parseTrustProxyHops(rawValue) {
  const raw = (rawValue === undefined || rawValue === null) ? '' : String(rawValue).trim();
  if (raw === '' || raw === '0') {
    return { hops: 0, invalidRaw: null };
  }
  const isPositiveIntegerString = /^[1-9]\d*$/.test(raw);
  if (!isPositiveIntegerString) {
    return { hops: 0, invalidRaw: raw };
  }
  return { hops: Number.parseInt(raw, 10), invalidRaw: null };
}

const trustProxyHopsResult = parseTrustProxyHops(process.env.TRUST_PROXY_HOPS);
const TRUST_PROXY_HOPS = trustProxyHopsResult.hops;
// null 表示没有非法输入（未设置，或已经是合法值）；非 null 时是用户实际传入的原始字符串，
// 供 server.js 打印一次性的 warning——config.js 本身不直接 console，保持纯配置解析。
const TRUST_PROXY_HOPS_INVALID_RAW = trustProxyHopsResult.invalidRaw;

const MEDIA_TOO_LARGE_ERROR = new Error('MEDIA_TOO_LARGE');
const MEDIA_DOWNLOAD_ERROR = new Error('MEDIA_DOWNLOAD_FAILED');
const MEDIA_FFMPEG_ERROR = new Error('MEDIA_FFMPEG_FAILED');
const MEDIA_FRAME_TOO_LARGE_ERROR = new Error('MEDIA_FRAME_TOO_LARGE');
const MEDIA_FRAME_OCR_ERROR = new Error('MEDIA_FRAME_OCR_FAILED');
const MEDIA_TRANSCRIBE_ERROR = new Error('MEDIA_TRANSCRIBE_FAILED');
const MEDIA_EMPTY_TRANSCRIPT_ERROR = new Error('MEDIA_EMPTY_TRANSCRIPT');

module.exports = {
  ROOT,
  PORT,
  MOBILE_UA,
  OPENAI_API_KEY,
  OPENAI_BASE_URL,
  OPENAI_MODEL,
  OPENAI_IMPORT_MODEL,
  DEFAULT_OPENAI_VISION_MODEL,
  OPENAI_VISION_MODEL,
  OPENAI_TRANSCRIBE_MODEL,
  AI_PROMPT_MAX_CHARS,
  AI_IMAGE_MAX_BASE64_BYTES,
  AI_RATE_LIMIT_WINDOW_MS,
  AI_RATE_LIMIT_MAX,
  IMPORT_RATE_LIMIT_MAX,
  AUTH_ME_RATE_LIMIT_MAX,
  ACCOUNT_DELETION_RATE_LIMIT_MAX,
  ACCOUNT_DELETION_NONCE_TTL_MS,
  AI_RATE_LIMIT_SWEEP_INTERVAL_MS,
  SYNC_READ_RATE_LIMIT_WINDOW_MS,
  SYNC_READ_RATE_LIMIT_MAX,
  SYNC_MUTATION_RATE_LIMIT_WINDOW_MS,
  SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS,
  SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS,
  SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX,
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_JWKS_URL,
  SUPABASE_JWT_ISSUER,
  SUPABASE_JWT_AUDIENCE,
  SUPABASE_AUTH_CONFIG_ERRORS,
  describeSupabaseAuthConfig,
  sanitizeSupabaseEnvValue,
  sanitizeSupabaseUrlValue,
  TRUST_PROXY_HOPS,
  TRUST_PROXY_HOPS_INVALID_RAW,
  parseTrustProxyHops,
  MEDIA_TMP_DIR,
  MEDIA_MAX_VIDEO_BYTES,
  MEDIA_DOWNLOAD_TIMEOUT_MS,
  MEDIA_FILE_TTL_MS,
  MEDIA_MAX_FRAME_COUNT,
  MEDIA_MAX_FRAME_BYTES,
  RECIPE_IMPORT_MEDIA_CACHE_TTL_MS,
  MEDIA_TOO_LARGE_ERROR,
  MEDIA_DOWNLOAD_ERROR,
  MEDIA_FFMPEG_ERROR,
  MEDIA_FRAME_TOO_LARGE_ERROR,
  MEDIA_FRAME_OCR_ERROR,
  MEDIA_TRANSCRIBE_ERROR,
  MEDIA_EMPTY_TRANSCRIPT_ERROR
};
