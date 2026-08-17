const OpenAI = require('openai');
const {
  OPENAI_API_KEY,
  OPENAI_BASE_URL,
  OPENAI_IMPORT_MODEL,
  GEMINI_API_KEY,
  resolveAiProviderConfig
} = require('../config');
const { safeParseModelJson } = require('../utils/json');

const RECIPE_DRAFT_JSON_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    name: { type: 'string' },
    tags: { type: 'array', items: { type: 'string' } },
    ingredients: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          item: { type: 'string' },
          qty: { type: 'string' },
          unit: { type: 'string' }
        },
        required: ['item', 'qty', 'unit']
      }
    },
    seasonings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          item: { type: 'string' },
          qty: { type: 'string' },
          unit: { type: 'string' }
        },
        required: ['item', 'qty', 'unit']
      }
    },
    method: { type: 'array', items: { type: 'string' } },
    warnings: { type: 'array', items: { type: 'string' } },
    needsReview: { type: 'boolean' }
  },
  required: ['name', 'tags', 'ingredients', 'seasonings', 'method', 'warnings', 'needsReview']
};

function supportsRecipeDraftStrictStructuredOutputs({ provider = 'groq', baseUrl = OPENAI_BASE_URL, model } = {}) {
  if (provider === 'gemini') return true;
  let hostname = '';
  try {
    hostname = new URL(String(baseUrl || '')).hostname.toLowerCase();
  } catch (_) {
    return false;
  }
  return /(^|\.)groq\.com$/.test(hostname)
    && ['openai/gpt-oss-20b', 'openai/gpt-oss-120b'].includes(String(model || '').trim());
}

function getRecipeDraftResponseFormat({ provider = 'groq', baseUrl = OPENAI_BASE_URL, model } = {}) {
  if (!supportsRecipeDraftStrictStructuredOutputs({ provider, baseUrl, model })) return null;
  return {
    type: 'json_schema',
    json_schema: {
      name: 'recipe_draft',
      strict: true,
      schema: RECIPE_DRAFT_JSON_SCHEMA
    }
  };
}

function resolveChatUrl(base) {
  const b = String(base || '').trim().replace(/\/+$/, '');
  if (/\/chat\/completions$/.test(b)) return b;
  if (/\/v1beta\/openai$/.test(b)) return `${b}/chat/completions`;
  if (/\/v\d+$/.test(b)) return `${b}/chat/completions`;
  return `${b}/v1/chat/completions`;
}

function resolveOpenAIBaseURL(base) {
  return resolveChatUrl(base).replace(/\/chat\/completions$/, '');
}

const openAIClients = new Map();
function getOpenAIClient(provider = 'groq') {
  const config = resolveAiProviderConfig(provider);
  if (!openAIClients.has(config.provider)) {
    openAIClients.set(config.provider, new OpenAI({
      apiKey: config.apiKey,
      baseURL: resolveOpenAIBaseURL(config.baseURL),
      maxRetries: 0
    }));
  }
  return openAIClients.get(config.provider);
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
  if (GEMINI_API_KEY) text = text.replaceAll(GEMINI_API_KEY, '[redacted]');
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
  const isSdkTimeout = (typeof OpenAI.APIConnectionTimeoutError === 'function' && err instanceof OpenAI.APIConnectionTimeoutError)
    || err?.constructor?.name === 'APIConnectionTimeoutError';
  const status = err && err.response && Number.isInteger(err.response.status)
    ? err.response.status
    : err && Number.isInteger(err.status)
      ? err.status
      : (err && (err.code === 'ECONNABORTED' || isSdkTimeout) ? 504 : 502);
  const data = err && err.response ? err.response.data : null;
  const upstreamError = data && typeof data === 'object' && data.error
    ? data.error
    : err && err.error && typeof err.error === 'object'
      ? err.error
      : null;
  const code = upstreamError && typeof upstreamError === 'object' && upstreamError.code
    ? upstreamError.code
    : (upstreamError && typeof upstreamError === 'object' && upstreamError.type)
      ? upstreamError.type
      : data && typeof data === 'object' && data.code
        ? data.code
        : err && err.code
          ? err.code
          : err && err.type
            ? err.type
            : isSdkTimeout
              ? 'ECONNABORTED'
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
  const headers = err?.response?.headers;
  const headerRequestId = (name) => {
    if (typeof headers?.get === 'function') return headers.get(name);
    const key = Object.keys(headers || {}).find((candidate) => candidate.toLowerCase() === name);
    return key ? headers[key] : null;
  };
  return {
    status,
    code: String(code || 'upstream_error').slice(0, 80),
    detail: redactSecret(detail),
    upstreamRequestId: String(
      headerRequestId('x-groq-id')
      || headerRequestId('x-request-id')
      || headerRequestId('x-trace-id')
      || err?.requestID
      || ''
    ).slice(0, 160) || null
  };
}

function sendAiUpstreamError(res, err, error = 'AI 服务暂时不可用。') {
  const info = getUpstreamAiErrorInfo(err);
  const payload = {
    upstreamStatus: info.status,
    upstreamCode: info.code,
    ...(info.upstreamRequestId ? { upstreamRequestId: info.upstreamRequestId } : {})
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
  const content = resp?.data?.choices?.[0]?.message?.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (typeof part === 'string') return part;
      return part && typeof part.text === 'string' ? part.text : '';
    }).join('');
  }
  return content && typeof content.text === 'string' ? content.text : '';
}

function summarizeAiResponse(resp) {
  const data = resp?.data && typeof resp.data === 'object' ? resp.data : {};
  const choices = Array.isArray(data.choices) ? data.choices : [];
  const message = choices[0]?.message && typeof choices[0].message === 'object'
    ? choices[0].message
    : {};
  const content = message.content;
  const reasoning = message.reasoning;
  const usage = data.usage && typeof data.usage === 'object' ? data.usage : {};
  const headers = resp?.headers && typeof resp.headers === 'object' ? resp.headers : {};
  const headerRequestId = headers['x-groq-id'] || headers['x-request-id'] || headers['x-trace-id'];
  const groqRequestId = data.x_groq && typeof data.x_groq === 'object' ? data.x_groq.id : null;
  return {
    upstreamRequestId: String(headerRequestId || groqRequestId || '').slice(0, 160) || null,
    model: typeof data.model === 'string' ? data.model.slice(0, 160) : null,
    choicesCount: choices.length,
    finishReason: choices[0]?.finish_reason == null ? null : String(choices[0].finish_reason).slice(0, 80),
    contentType: content === null ? 'null' : Array.isArray(content) ? 'array' : typeof content,
    contentLength: typeof content === 'string' ? content.length : Array.isArray(content) ? content.length : 0,
    reasoningLength: typeof reasoning === 'string' ? reasoning.length : 0,
    toolCallsCount: Array.isArray(message.tool_calls) ? message.tool_calls.length : 0,
    promptTokens: Number.isFinite(usage.prompt_tokens) ? usage.prompt_tokens : null,
    completionTokens: Number.isFinite(usage.completion_tokens) ? usage.completion_tokens : null,
    reasoningTokens: Number.isFinite(usage.reasoning_tokens) ? usage.reasoning_tokens : null
  };
}

async function postChatCompletion({ provider = 'groq', model, messages, temperature = 0.2, responseFormat = true, reasoningEffort = null, timeout = 45000 }) {
  const config = resolveAiProviderConfig(provider, { model });
  const payload = {
    model: config.model,
    messages
  };
  if (config.provider !== 'gemini' || config.model !== 'gemini-3.6-flash') payload.temperature = temperature;
  if (responseFormat) payload.response_format = responseFormat === true ? { type: 'json_object' } : responseFormat;
  if (reasoningEffort) payload.reasoning_effort = reasoningEffort;
  const { data, response, request_id: requestId } = await getOpenAIClient(config.provider)
    .chat.completions.create(payload, { timeout })
    .withResponse();
  return {
    data,
    headers: {
      'x-groq-id': response.headers.get('x-groq-id'),
      'x-request-id': requestId || data?._request_id || response.headers.get('x-request-id'),
      'x-trace-id': response.headers.get('x-trace-id')
    }
  };
}

async function postJsonChatContentWithFallback({ provider = 'groq', model, messages, temperature = 0.2, timeout = 45000, useJsonMode = false, responseFormat = null }) {
  const enforcedResponseFormat = responseFormat || (useJsonMode ? true : null);
  if (!enforcedResponseFormat) {
    const resp = await postChatCompletion({ provider, model, messages, temperature, responseFormat: false, timeout });
    return getAiMessageContent(resp);
  }
  try {
    const resp = await postChatCompletion({ provider, model, messages, temperature, responseFormat: enforcedResponseFormat, timeout });
    return getAiMessageContent(resp);
  } catch (err) {
    if (!isJsonValidateFailedError(err)) throw err;
    const resp = await postChatCompletion({ provider, model, messages, temperature, responseFormat: false, timeout });
    return getAiMessageContent(resp);
  }
}

async function repairRecipeJsonContent(rawContent, { provider = 'groq', model = OPENAI_IMPORT_MODEL } = {}) {
  const repairPrompt = `请把下面内容修复为合法 JSON 对象。字段必须为 name, tags, ingredients, seasonings, method, warnings, needsReview。不要补充内容，只修复格式。只输出 JSON 对象，不要 markdown，不要解释。\n\n${String(rawContent || '').slice(0, 12000)}`;
  const resp = await postChatCompletion({
    provider,
    model,
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
  resolveOpenAIBaseURL,
  resolveAudioTranscriptionsUrl,
  estimateBase64EncodedBytes,
  redactSecret,
  sendAiJsonError,
  getUpstreamAiErrorInfo,
  sendAiUpstreamError,
  isRateLimitExceeded,
  isJsonValidateFailedError,
  supportsRecipeDraftStrictStructuredOutputs,
  getRecipeDraftResponseFormat,
  getOpenAIClient,
  getAiMessageContent,
  summarizeAiResponse,
  postChatCompletion,
  postJsonChatContentWithFallback,
  repairRecipeJsonContent
};
