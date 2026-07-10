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
const AI_RATE_LIMIT_SWEEP_INTERVAL_MS = 60 * 1000;

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
  AI_RATE_LIMIT_SWEEP_INTERVAL_MS,
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
