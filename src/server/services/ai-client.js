const axios = require('axios');
const {
  OPENAI_API_KEY,
  OPENAI_BASE_URL,
  OPENAI_IMPORT_MODEL
} = require('../config');
const { safeParseModelJson } = require('../utils/json');

function resolveChatUrl(base) {
  const b = String(base || '').trim().replace(/\/+$/, '');
  if (/\/chat\/completions$/.test(b)) return b;
  if (/\/v\d+$/.test(b)) return `${b}/chat/completions`;
  return `${b}/v1/chat/completions`;
}

function resolveAudioTranscriptionsUrl(base) {
  const b = String(base || '').trim().replace(/\/+$/, '');
  if (/\/audio\/transcriptions$/.test(b)) return b;
  if (/\/chat\/completions$/.test(b)) return `${b.replace(/\/chat\/completions$/, '')}/audio/transcriptions`;
  if (/\/v\d+$/.test(b)) return `${b}/audio/transcriptions`;
  return `${b}/v1/audio/transcriptions`;
}

function estimateBase64EncodedBytes(value) {
  const raw = String(value || '');
  if (!raw) return 0;
  const payload = raw.includes(',') ? raw.split(',').pop() : raw;
  const compact = payload.replace(/\s+/g, '');
  return compact.length;
}

function redactSecret(value) {
  let text = String(value || '');
  if (OPENAI_API_KEY) text = text.replaceAll(OPENAI_API_KEY, '[redacted]');
  return text.slice(0, 500);
}

function sendAiJsonError(res, status, code, error, extra = {}) {
  const safeStatus = Number.isInteger(status) && status >= 400 && status < 600 ? status : 502;
  return res.status(safeStatus).json({
    error,
    status: safeStatus,
    code,
    ...extra
  });
}

function getUpstreamAiErrorInfo(err) {
  const status = err && err.response && Number.isInteger(err.response.status)
    ? err.response.status
    : (err && err.code === 'ECONNABORTED' ? 504 : 502);
  const data = err && err.response ? err.response.data : null;
  const upstreamError = data && typeof data === 'object' ? data.error : null;
  const code = upstreamError && typeof upstreamError === 'object' && upstreamError.code
    ? upstreamError.code
    : (upstreamError && typeof upstreamError === 'object' && upstreamError.type)
      ? upstreamError.type
      : data && typeof data === 'object' && data.code
        ? data.code
        : err && err.code
          ? err.code
          : 'upstream_error';
  const detail = upstreamError && typeof upstreamError === 'object' && upstreamError.message
    ? upstreamError.message
    : data && typeof data === 'object' && data.message
      ? data.message
      : typeof data === 'string'
        ? data
        : err && err.message
          ? err.message
          : '上游 AI 服务请求失败。';
  return {
    status,
    code: String(code || 'upstream_error').slice(0, 80),
    detail: redactSecret(detail)
  };
}

function sendAiUpstreamError(res, err, error = 'AI 服务暂时不可用。') {
  const info = getUpstreamAiErrorInfo(err);
  const payload = {
    upstreamStatus: info.status,
    upstreamCode: info.code
  };
  if (process.env.NODE_ENV !== 'production') payload.detail = info.detail;
  return sendAiJsonError(res, info.status, info.code, error, payload);
}

function isRateLimitExceeded(status, code) {
  const normalizedCode = String(code || '').trim().toLowerCase();
  const numericStatus = Number(status || 0);
  return normalizedCode === 'rate_limit_exceeded'
    || normalizedCode === 'rate_limited'
    || normalizedCode === 'rate_limit'
    || numericStatus === 429;
}

function isJsonValidateFailedError(err) {
  const info = getUpstreamAiErrorInfo(err);
  return Number(info.status) === 400 && String(info.code || '').trim().toLowerCase() === 'json_validate_failed';
}

function getAiMessageContent(resp) {
  return resp?.data?.choices?.[0]?.message?.content || '';
}

async function postChatCompletion({ model, messages, temperature = 0.2, responseFormat = true, timeout = 45000 }) {
  const payload = {
    model,
    messages,
    temperature
  };
  if (responseFormat) payload.response_format = { type: 'json_object' };
  return axios.post(
    resolveChatUrl(OPENAI_BASE_URL),
    payload,
    {
      timeout,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
    }
  );
}

async function postJsonChatContentWithFallback({ model, messages, temperature = 0.2, timeout = 45000, useJsonMode = false }) {
  // 默认走普通 chat completion（不带 response_format）。Groq 的 json_object / json_schema 强制模式
  // 会在模型输出不满足校验时返回 400 json_validate_failed；「视频文字 → 菜谱 JSON」这一步改为普通
  // 输出 + safeParseModelJson 解析，从根源上规避该错误，不再依赖强制 JSON 模式。
  if (!useJsonMode) {
    const resp = await postChatCompletion({ model, messages, temperature, responseFormat: false, timeout });
    return getAiMessageContent(resp);
  }
  // 兜底保留：万一某处仍需强制 JSON，遇到 json_validate_failed 时自动改普通输出重试一次。
  try {
    const resp = await postChatCompletion({ model, messages, temperature, responseFormat: true, timeout });
    return getAiMessageContent(resp);
  } catch (err) {
    if (!isJsonValidateFailedError(err)) throw err;
    const resp = await postChatCompletion({ model, messages, temperature, responseFormat: false, timeout });
    return getAiMessageContent(resp);
  }
}

async function repairRecipeJsonContent(rawContent) {
  const repairPrompt = `请把下面内容修复为合法 JSON 对象。字段必须为 name, tags, ingredients, seasonings, method, warnings, needsReview。不要补充内容，只修复格式。只输出 JSON 对象，不要 markdown，不要解释。\n\n${String(rawContent || '').slice(0, 12000)}`;
  const resp = await postChatCompletion({
    model: OPENAI_IMPORT_MODEL,
    messages: [
      { role: 'system', content: 'You repair malformed recipe JSON. Return only one valid JSON object.' },
      { role: 'user', content: repairPrompt }
    ],
    temperature: 0,
    responseFormat: false,
    timeout: 30000
  });
  return safeParseModelJson(getAiMessageContent(resp));
}

function createPublicApiError(status, error, code = '') {
  const err = new Error(error);
  err.publicStatus = status;
  err.publicError = error;
  err.publicCode = code;
  return err;
}

module.exports = {
  createPublicApiError,
  resolveChatUrl,
  resolveAudioTranscriptionsUrl,
  estimateBase64EncodedBytes,
  redactSecret,
  sendAiJsonError,
  getUpstreamAiErrorInfo,
  sendAiUpstreamError,
  isRateLimitExceeded,
  isJsonValidateFailedError,
  getAiMessageContent,
  postChatCompletion,
  postJsonChatContentWithFallback,
  repairRecipeJsonContent
};
