// apiUrl 改名导入：getAiConfig 内部有同名局部变量（BYOK 的用户自填地址），避免遮蔽。
import { apiUrl as buildApiUrl, CUSTOM_AI } from './config.js?v=231';
import { S } from './storage.js?v=231';
import { classifyRecipeIngredient } from './utils/recipe-sanitizer.js?v=231';
import {
  classifyReceiptCandidate,
  postProcessReceiptItems
} from './utils/receipt-import.js?v=231';

const CLOUD_AI_ERROR = 'AI 暂不可用：云端服务暂时不可用。本地功能仍可正常使用。';
const BYOK_MISSING_KEY_ERROR = 'AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。';
const CLOUD_IMAGE_TARGET_BASE64_BYTES = Math.floor(3.6 * 1024 * 1024);
const RECEIPT_IMAGE_COMPRESSION_ATTEMPTS = [
  { maxSide: 896, quality: 0.68 },
  { maxSide: 768, quality: 0.62 },
  { maxSide: 640, quality: 0.56 },
  { maxSide: 512, quality: 0.5 }
];

function createCloudAiError({
  status = 0,
  code = '',
  upstreamStatus = 0,
  upstreamCode = '',
  detail = '',
  fallback = '云端服务请求失败',
  importTextReady = false,
  mediaDiagnostics = null,
  transcriptPreview = '',
  ocrPreview = '',
  pageTextPreview = ''
} = {}) {
  const statusText = status ? String(status) : '';
  const codeText = String(code || upstreamCode || '').trim();
  const marker = statusText || codeText ? ` (${statusText}${codeText ? `/${codeText}` : ''})` : '';
  const message = `${fallback}${marker}${detail ? `：${detail}` : ''}`;
  const error = new Error(message);
  if (status) error.status = Number(status);
  if (codeText) error.code = codeText;
  if (upstreamStatus) error.upstreamStatus = Number(upstreamStatus);
  if (upstreamCode) error.upstreamCode = String(upstreamCode);
  if (importTextReady) error.importTextReady = true;
  if (mediaDiagnostics && typeof mediaDiagnostics === 'object') error.mediaDiagnostics = mediaDiagnostics;
  if (transcriptPreview) error.transcriptPreview = String(transcriptPreview);
  if (ocrPreview) error.ocrPreview = String(ocrPreview);
  if (pageTextPreview) error.pageTextPreview = String(pageTextPreview);
  return error;
}

export function getAiErrorDetails(error) {
  const msg = String(error?.message || error || '');
  const statusMatch = msg.match(/\((\d{3})(?:\/([^)：]+))?\)/);
  const status = Number(error?.status || statusMatch?.[1] || 0) || 0;
  const upstreamStatus = Number(error?.upstreamStatus || 0) || 0;
  const code = String(error?.code || statusMatch?.[2] || '').trim();
  const upstreamCode = String(error?.upstreamCode || '').trim();
  return {
    status,
    code,
    upstreamStatus,
    upstreamCode,
    message: msg,
    importTextReady: Boolean(error?.importTextReady),
    mediaDiagnostics: error?.mediaDiagnostics || null,
    transcriptPreview: error?.transcriptPreview || '',
    ocrPreview: error?.ocrPreview || '',
    pageTextPreview: error?.pageTextPreview || ''
  };
}

function isRateLimitExceededError(error) {
  const details = getAiErrorDetails(error);
  const code = String(details.code || details.upstreamCode || '').trim().toLowerCase();
  return code === 'rate_limit_exceeded'
    || code === 'rate_limited'
    || code === 'rate_limit'
    || details.status === 429
    || details.upstreamStatus === 429;
}

function isRecipeJsonFailedError(error) {
  const details = getAiErrorDetails(error);
  const code = String(details.code || details.upstreamCode || '').trim().toLowerCase();
  return code === 'recipe_json_failed';
}

function formatAiStatusCode(details) {
  const status = details?.status || details?.upstreamStatus || 0;
  const code = details?.code || details?.upstreamCode || '';
  if (!status && !code) return '';
  return `（${status || 'error'}${code ? `/${code}` : ''}）`;
}

export function getAiConfig() {
  const localSettings = S.load(S.keys.settings, {});
  const aiProviderMode = localSettings.aiProviderMode === 'byok' ? 'byok' : 'cloud';

  if (aiProviderMode === 'cloud') {
    return {
      mode: 'cloud',
      apiUrl: buildApiUrl('/api/ai-chat')
    };
  }

  let apiKey = localSettings.apiKey || CUSTOM_AI.KEY;
  let apiUrl = localSettings.apiUrl || CUSTOM_AI.URL;
  let model = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;

  if (apiUrl && apiUrl.includes('api.groq.com') && !apiUrl.includes('/chat/completions')) {
    apiUrl = apiUrl.replace(/\/$/, '');
    if (apiUrl.endsWith('/v1')) apiUrl += '/chat/completions';
    else apiUrl = 'https://api.groq.com/openai/v1/chat/completions';
  }

  if (!apiKey) return { mode: 'byok', missingKey: true };
  return { mode: 'byok', apiKey, apiUrl, textModel: model, visionModel };
}

function extractJsonText(text) {
  const cleaned = String(text || '')
    .replace(/<think>[\s\S]*?<\/think>/gi, '')
    .replace(/<think>[\s\S]*/gi, '')
    .replace(/```json/gi, '')
    .replace(/```/g, '')
    .trim();

  const firstOpenBrace = cleaned.indexOf('{');
  const lastCloseBrace = cleaned.lastIndexOf('}');
  const firstOpenBracket = cleaned.indexOf('[');
  const lastCloseBracket = cleaned.lastIndexOf(']');

  if (firstOpenBracket !== -1 && lastCloseBracket !== -1 && (firstOpenBrace === -1 || firstOpenBracket < firstOpenBrace)) {
    return cleaned.substring(firstOpenBracket, lastCloseBracket + 1);
  }
  if (firstOpenBrace !== -1 && lastCloseBrace !== -1 && lastCloseBrace > firstOpenBrace) {
    return cleaned.substring(firstOpenBrace, lastCloseBrace + 1);
  }
  throw new Error('AI 没有返回可识别的 JSON。可以稍后重试，或手动录入。');
}

export function safeParseJson(input, label = 'AI 返回') {
  if (input && typeof input === 'object') return input;
  try {
    return JSON.parse(extractJsonText(input));
  } catch (error) {
    throw new Error(`${label}格式不正确：${error.message || error}`);
  }
}

function normalizeAiIngredientDisplayName(name) {
  const raw = String(name || '').trim();
  if (!raw) return '';
  const lower = raw.toLowerCase();
  if (raw === '韭葱' || /\bleeks?\b/.test(lower)) return '葱';
  return raw;
}

export function normalizeAiIngredients(value) {
  let list = value;
  if (typeof value === 'string') list = value.split(/[，,、/;；|]+/).map(item => item.trim());
  if (!Array.isArray(list)) return [];

  return list.map(item => {
    if (typeof item === 'string') {
      return { item: normalizeAiIngredientDisplayName(item), qty: '', unit: '' };
    }
    if (!item || typeof item !== 'object') return null;
    const name = normalizeAiIngredientDisplayName(item.item || item.name || '');
    if (!name) return null;
    return {
      item: name,
      qty: item.qty ?? item.amount ?? '',
      unit: String(item.unit || '').trim()
    };
  }).filter(Boolean);
}

const RECIPE_STEP_COVERAGE_RULES = [
  {
    label: '水',
    ingredient: /^(?:水|清水|开水|温水|热水|凉水|高汤|清汤|鲜汤|肉汤|鸡汤|骨汤|汤|汤汁)$/u,
    method: /加水|倒水|添水|注水|兑水|清水|高汤|加汤|倒汤|焖|炖|煮|烧开|收汁|盖盖焖/u,
    warning: (name) => `原内容列出了${name}，但做法未明确说明${name}的用途，请确认。`
  },
  { label: '鲜藤椒', ingredient: /^(?:鲜藤椒|新鲜藤椒)$/u, method: /鲜藤椒|新鲜藤椒/u },
  { label: '藤椒粉', ingredient: /^藤椒粉$/u, method: /藤椒粉/u },
  { label: '藤椒', ingredient: /^藤椒$/u, method: /藤椒/u },
  { label: '花椒', ingredient: /花椒|麻椒/u, method: /花椒|麻椒/u },
  { label: '辣椒', ingredient: /辣椒|小米辣|二荆条|干辣椒|辣椒粉|辣椒面|剁椒|泡椒/u, method: /辣椒|小米辣|二荆条|干辣椒|辣椒粉|辣椒面|剁椒|泡椒|辣/u },
  { label: '豆瓣酱', ingredient: /豆瓣/u, method: /豆瓣/u },
  { label: '咖喱块', ingredient: /咖喱/u, method: /咖喱/u },
  { label: '泡菜', ingredient: /泡菜/u, method: /泡菜/u },
  { label: '蒜', ingredient: /^(?:蒜|大蒜|蒜末|蒜蓉|蒜片|蒜瓣)$/u, method: /蒜/u },
  { label: '姜', ingredient: /^(?:姜|生姜|姜片|姜丝|姜末)$/u, method: /姜/u },
  { label: '葱', ingredient: /^(?:葱|小葱|香葱|大葱|葱花|葱段|葱末)$/u, method: /葱/u }
];

function getRecipeStepCoverageWarning(rule, ingredientName) {
  if (typeof rule.warning === 'function') return rule.warning(ingredientName);
  return `关键风味材料${ingredientName}未在做法中明确出现，请确认加入时机。`;
}

const MEAT_RECIPE_INGREDIENT_PATTERN = /鸡腿|鸡肉|鸡翅|鸡胸|鸡丁|牛肉|猪肉|羊肉|肉片|肉丝|肉末|五花肉|里脊|排骨|鱼片|虾仁/u;
const MARINADE_SOURCE_PATTERN = /腌|腌制|抓匀|拌匀|料酒|生抽|老抽|盐|糖|胡椒|淀粉/u;
const MARINADE_METHOD_PATTERN = /腌|腌制|抓匀|拌匀/u;
const IMPORTANT_SEASONING_PATTERN = /^(?:鲜藤椒|新鲜藤椒|藤椒粉|藤椒|花椒|麻椒|生抽|老抽|料酒|盐|糖|白糖|胡椒|白胡椒粉|黑胡椒粉|淀粉|小苏打|食用油|植物油|油)$/u;
const WATER_LIKE_PATTERN = /^(?:水|清水|开水|温水|热水|凉水|高汤|清汤|鲜汤|肉汤|鸡汤|骨汤|汤|汤汁)$/u;
const GENERIC_UNSUPPORTED_METHOD_PATTERN = /进行烹饪|按个人口味调味|煮熟即可|加水焖熟|加水焖煮|鸡腿清洗并沥干/u;
const SHORT_GENERIC_FINISH_PATTERN = /^翻炒均匀后出锅[。！!，,]*$/u;

function countRecipeMethodSteps(methodText) {
  return String(methodText || '')
    .split(/\n+|[。；;]+/u)
    .map(step => step.trim())
    .filter(Boolean).length;
}

function countRecipeMethodStages(methodText) {
  const text = String(methodText || '');
  const stages = new Set();
  if (/洗净|擦干|去骨|切|改刀|处理/u.test(text)) stages.add('prep');
  if (/腌|腌制|抓匀|拌匀/u.test(text)) stages.add('marinade');
  if (/煎|炒|烤|空气炸|蒸|炸|下锅/u.test(text)) stages.add('cook');
  if (/调味|加入|放入|倒入|藤椒|生抽|老抽|料酒|盐|糖/u.test(text)) stages.add('season');
  if (/出锅|装盘|盛出/u.test(text)) stages.add('finish');
  return stages.size;
}

function hasUsefulEvidenceActions(evidence) {
  return Array.isArray(evidence?.observedActions) && evidence.observedActions.length >= 2;
}

function stripUnsupportedGenericMethodLines(method, evidence) {
  if (!method || hasUsefulEvidenceActions(evidence)) return String(method || '');
  return String(method || '')
    .split(/\n+/)
    .filter(line => !GENERIC_UNSUPPORTED_METHOD_PATTERN.test(line) && !SHORT_GENERIC_FINISH_PATTERN.test(line.trim()))
    .join('\n')
    .trim();
}

function isIngredientMentionedInMethod(name, methodText) {
  const item = String(name || '').trim();
  if (!item) return false;
  if (/^(?:鲜藤椒|新鲜藤椒)$/u.test(item)) return /鲜藤椒|新鲜藤椒/u.test(methodText);
  if (item === '藤椒粉') return /藤椒粉/u.test(methodText);
  if (item === '藤椒') return /藤椒/u.test(methodText);
  if (/^(?:糖|白糖)$/u.test(item)) return /糖|白糖/u.test(methodText);
  if (/胡椒/u.test(item)) return /胡椒/u.test(methodText);
  if (/^(?:食用油|植物油|油)$/u.test(item)) return /油/u.test(methodText);
  return methodText.includes(item);
}

function listEvidenceItems(evidence) {
  if (!evidence || typeof evidence !== 'object') return [];
  const fields = [
    'observedMainIngredients',
    'observedSeasonings',
    'observedAromatics',
    'observedLiquids',
    'uncertainItems'
  ];
  return fields.flatMap(key => Array.isArray(evidence[key]) ? evidence[key] : [])
    .map(item => String(item?.item || item?.name || item || '').trim())
    .filter(Boolean);
}

function listEvidenceField(evidence, field) {
  if (!evidence || typeof evidence !== 'object' || !Array.isArray(evidence[field])) return [];
  return evidence[field]
    .map(item => String(item?.item || item?.name || item || '').trim())
    .filter(Boolean);
}

function getEvidenceActionText(evidence) {
  if (!evidence || typeof evidence !== 'object' || !Array.isArray(evidence.observedActions)) return '';
  return evidence.observedActions.map(action => [
    action?.action,
    Array.isArray(action?.ingredients) ? action.ingredients.join('、') : '',
    action?.evidenceText
  ].filter(Boolean).join(' ')).join('\n');
}

const SOCIAL_EMOJI_PATTERN = /\[[^\]\n]{1,16}\]/gu;
const LEADING_EMOJI_PATTERN = /^[\p{Extended_Pictographic}\uFE0F\s]+/u;
const HASHTAG_PATTERN = /#[\p{L}\p{N}_-]+/gu;
const SOCIAL_NOISE_PATTERN = /老师|这题我会|好怀念|视频号|分享给家人|太喜欢|求教程|为什么|为啥|是不是|希望|我觉得|一次性解决|一定不能错过|详细教程|收藏|点赞|关注|转发|评论|回复|弹幕|用户|段老师|不要了|粘锅问题|教程来了|安排上|好吃吗|求做法|同款|看起来就很好吃/u;
const SOCIAL_DISTRACTOR_PATTERN = /黄金薯|小龙虾|双椒鸡拌面|炒面/u;
const SOCIAL_SEGMENT_MARKER_PATTERN = /段老师|这题我会|黄金薯|双椒鸡拌面|视频号|分享给家人|好怀念|有村|希望珠宝|一次性解决|小龙虾|求教程|为什么|为啥|是不是|太喜欢|\[doge\]|\[哭惹R\]|\[黄金薯R\]|\[飞吻R\]|\[萌萌哒R\]/u;
const SOCIAL_SEGMENT_MARKER_GLOBAL_PATTERN = /(段老师|这题我会|黄金薯|双椒鸡拌面|视频号|分享给家人|好怀念|有村|希望珠宝|一次性解决|小龙虾|求教程|为什么|为啥|是不是|太喜欢|老师|\[doge\]|\[哭惹R\]|\[黄金薯R\]|\[飞吻R\]|\[萌萌哒R\])/gu;
const RECIPE_SIGNAL_PATTERN = /食材|用料|配料|调料|做法|步骤|洗净|擦干|去骨|切|改刀|加入|放入|倒入|撒入|腌|腌制|抓匀|拌匀|煎|炒|焖|炖|煮|蒸|烤|炸|空气炸|调味|翻炒|出锅|装盘|生抽|老抽|料酒|鲜藤椒|藤椒粉|花椒|辣椒|豆瓣|咖喱|泡菜/u;
const AUTHOR_RECIPE_DESCRIPTION_PATTERN = /教程|详细版|家常版|前期处理|腌制比例|精确到克|铁锅|看起来就很好吃|都会讲到|一道.+菜|做法|比例|细节/u;
const COMMENT_STYLE_PATTERN = /^(?:如果|可以|建议|为啥|为什么|是不是|求|老师|我|你|他|她|这|太|好|希望|感觉|觉得|评论区)/u;

function normalizeSourceLine(line) {
  return String(line || '')
    .replace(SOCIAL_EMOJI_PATTERN, '')
    .replace(LEADING_EMOJI_PATTERN, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function cleanAuthorCandidateLine(line) {
  return normalizeSourceLine(line)
    .replace(HASHTAG_PATTERN, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function isHashtagOnlyLine(line) {
  const withoutTags = String(line || '').replace(HASHTAG_PATTERN, '').trim();
  return !withoutTags && (String(line || '').match(HASHTAG_PATTERN) || []).length > 0;
}

function isSocialNoiseLine(line) {
  const raw = String(line || '').trim();
  const normalized = normalizeSourceLine(raw);
  if (!normalized) return true;
  SOCIAL_EMOJI_PATTERN.lastIndex = 0;
  if (SOCIAL_EMOJI_PATTERN.test(raw)) {
    SOCIAL_EMOJI_PATTERN.lastIndex = 0;
    return true;
  }
  SOCIAL_EMOJI_PATTERN.lastIndex = 0;
  if (SOCIAL_NOISE_PATTERN.test(normalized)) return true;
  if (SOCIAL_DISTRACTOR_PATTERN.test(normalized)) return true;
  if (/[一-龥]{1,10}R$/u.test(normalized)) return true;
  if (/一丢丢|一点点|少少|丢一点/u.test(normalized) && !/作者|正文|步骤/u.test(normalized)) return true;
  if (COMMENT_STYLE_PATTERN.test(normalized) && !/^[^，。；;]{0,12}(?:食材|做法|步骤|用料|配料)/u.test(normalized)) return true;
  return false;
}

function isTrustedRecipeLine(line) {
  const normalized = normalizeSourceLine(line);
  if (!normalized || isHashtagOnlyLine(normalized) || isSocialNoiseLine(line)) return false;
  return RECIPE_SIGNAL_PATTERN.test(normalized);
}

function splitRawSourceIntoCandidateSegments(rawText) {
  const raw = String(rawText || '').trim();
  if (!raw) return [];
  return raw
    .replace(/\r|\u2028|\u2029/g, '\n')
    .replace(/(#[\p{L}\p{N}_-]+)/gu, '\n$1\n')
    .replace(SOCIAL_SEGMENT_MARKER_GLOBAL_PATTERN, '\n$1')
    .replace(/(\[[^\]\n]{1,16}\])/gu, '$1\n')
    .replace(/([。！？!?]+|…{2,}|\.{3,})/gu, '$1\n')
    .split(/\n+/g)
    .map(segment => segment.trim())
    .filter(Boolean);
}

function classifyRecipeSourceSegment(segment, { index = 0, afterSocialMarker = false } = {}) {
  const text = String(segment || '').trim();
  const normalizedText = normalizeSourceLine(text);
  const authorText = cleanAuthorCandidateLine(text);
  const reasons = [];
  if (!normalizedText) return { text, normalizedText: '', type: 'excluded', reasons: ['empty'] };
  if (isHashtagOnlyLine(text)) {
    return { text, normalizedText, type: 'hashtag', reasons: ['hashtag'] };
  }
  const hasSocialMarker = SOCIAL_SEGMENT_MARKER_PATTERN.test(text) || SOCIAL_SEGMENT_MARKER_PATTERN.test(normalizedText);
  const hasDistractor = SOCIAL_DISTRACTOR_PATTERN.test(normalizedText);
  const hasAuthorRecipeDescription = AUTHOR_RECIPE_DESCRIPTION_PATTERN.test(authorText);
  const hasRecipeSignal = RECIPE_SIGNAL_PATTERN.test(normalizedText);
  const hasCommentSuggestion = /一丢丢|一点点|少少|丢一点/u.test(normalizedText);

  if (hasDistractor) {
    reasons.push('related-recommendation');
    return { text, normalizedText, type: 'relatedRecommendation', reasons };
  }
  if (hasCommentSuggestion || (hasSocialMarker && !hasAuthorRecipeDescription)) {
    reasons.push(hasCommentSuggestion ? 'comment-style' : 'social-marker');
    return { text, normalizedText, type: 'comment', reasons };
  }
  if (afterSocialMarker && !hasRecipeSignal && !hasAuthorRecipeDescription) {
    return { text, normalizedText, type: 'comment', reasons: ['after-social-marker'] };
  }
  if (hasRecipeSignal && !afterSocialMarker) {
    return {
      text,
      normalizedText: cleanAuthorCandidateLine(text) || normalizedText,
      type: 'recipeStep',
      reasons: ['recipe-signal']
    };
  }
  if (hasAuthorRecipeDescription) {
    return {
      text,
      normalizedText: authorText || normalizedText,
      type: 'authorCandidate',
      reasons: ['recipe-description']
    };
  }
  if (index <= 1 && authorText && authorText.length > 6 && !isSocialNoiseLine(text)) {
    return {
      text,
      normalizedText: authorText,
      type: 'authorCandidate',
      reasons: ['title-like']
    };
  }
  if (isSocialNoiseLine(text) || afterSocialMarker) {
    return { text, normalizedText, type: 'comment', reasons: ['social-noise'] };
  }
  return {
    text,
    normalizedText: authorText || normalizedText,
    type: 'weakHint',
    reasons: ['weak-title-or-context']
  };
}

export function segmentSocialRecipeText(rawText) {
  const rawSegments = splitRawSourceIntoCandidateSegments(rawText);
  const segments = [];
  let afterSocialMarker = false;
  rawSegments.forEach((segment, index) => {
    const classified = classifyRecipeSourceSegment(segment, { index, afterSocialMarker });
    if (['comment', 'relatedRecommendation'].includes(classified.type)) afterSocialMarker = true;
    segments.push(classified);
  });
  return segments;
}

function uniqueTextList(list, limit = 12) {
  const seen = new Set();
  return list.map(item => String(item || '').trim())
    .filter(Boolean)
    .filter(item => !seen.has(item) && seen.add(item))
    .slice(0, limit);
}

export function splitRecipeSourceText(rawText) {
  const raw = String(rawText || '').trim();
  const trusted = [];
  const weak = [];
  const excluded = [];
  const segments = segmentSocialRecipeText(raw);

  for (const segment of segments) {
    if (['authorCandidate', 'recipeStep'].includes(segment.type)) {
      trusted.push(segment.normalizedText);
    } else if (['hashtag', 'weakHint'].includes(segment.type)) {
      weak.push(segment.normalizedText);
    } else {
      excluded.push(segment.text);
    }
  }

  const uniqueTrusted = uniqueTextList(trusted, 24);
  const uniqueWeak = uniqueTextList(weak, 12);
  const uniqueExcluded = uniqueTextList(excluded, 24);
  const cleanedRecipeText = uniqueTrusted.join('\n').trim();
  const excludedSocialText = uniqueExcluded.join('\n').trim();
  return {
    titleText: uniqueWeak[0] || '',
    authorCandidateText: uniqueTrusted.join('\n'),
    authorCaptionText: uniqueTrusted.join('\n'),
    descriptionText: uniqueTrusted.join('\n'),
    ocrText: '',
    transcriptText: '',
    hashtagText: uniqueWeak.filter(line => /#/.test(line)).join('\n'),
    commentText: uniqueExcluded.join('\n'),
    relatedRecommendationText: uniqueExcluded.filter(line => SOCIAL_DISTRACTOR_PATTERN.test(line)).join('\n'),
    rawText: raw,
    cleanedRecipeText,
    weakRecipeHints: uniqueWeak,
    excludedSocialTextPreview: excludedSocialText.slice(0, 400),
    sourceBuckets: {
      trusted: uniqueTrusted,
      weak: uniqueWeak,
      excluded: uniqueExcluded
    },
    sourceSegments: segments,
    sourceSegmentsPreview: segments.slice(0, 12).map(segment => ({
      type: segment.type,
      text: segment.normalizedText || segment.text,
      reasons: segment.reasons || []
    }))
  };
}

function normalizeRecipeImportSourceType(sourceType, { imageBase64 = null } = {}) {
  const raw = String(sourceType || '').trim().toLowerCase();
  if (['xiaohongshu', 'video', 'web', 'manual'].includes(raw)) return raw;
  return imageBase64 ? 'manual' : 'manual';
}

function getObservedIngredientCount(evidence) {
  return [...new Set([
    ...listEvidenceField(evidence, 'observedMainIngredients'),
    ...listEvidenceField(evidence, 'observedAromatics'),
    ...listEvidenceField(evidence, 'observedLiquids')
  ])].length;
}

function getObservedSeasoningCount(evidence) {
  return [...new Set(listEvidenceField(evidence, 'observedSeasonings'))].length;
}

export function buildRecipeImportSourceDiagnostics({ sourceType = 'manual', sourceText = '', imageBase64 = null, evidence = null, method = '', sourceSplit = null } = {}) {
  const normalizedSourceType = normalizeRecipeImportSourceType(sourceType, { imageBase64 });
  const rawText = String(sourceText || '').trim();
  const split = sourceSplit || splitRecipeSourceText(rawText);
  const cleanedRecipeText = String(split.cleanedRecipeText || '').trim();
  const excludedSocialText = String(split.excludedSocialTextPreview || split.commentText || '').trim();
  const observedIngredientCount = getObservedIngredientCount(evidence);
  const observedSeasoningCount = getObservedSeasoningCount(evidence);
  const observedActionCount = Array.isArray(evidence?.observedActions) ? evidence.observedActions.length : 0;
  const methodText = Array.isArray(method) ? method.join('\n') : String(method || '');
  const methodStepCount = methodText ? countRecipeMethodSteps(methodText) : 0;
  const hasImages = Boolean(imageBase64);
  const hasEvidenceFromImage = hasImages && (observedIngredientCount + observedSeasoningCount + observedActionCount > 0);
  const hasDescription = rawText.length > 0;
  const hasCaption = normalizedSourceType === 'xiaohongshu' && rawText.length > 0;
  const hasTranscript = /字幕|transcript|旁白|口播/u.test(rawText);
  const hasOcrText = hasEvidenceFromImage || /ocr|截图文字|图片文字/u.test(rawText);
  const hasVideoFrames = false;
  const hasAnyExtractedContent = rawText.length > 0 || hasImages || observedIngredientCount + observedSeasoningCount + observedActionCount > 0;
  const evidenceConfidence = String(evidence?.sourceConfidence || '').trim().toLowerCase();
  const warnings = [];

  if (rawText && rawText.length < 100) warnings.push('来源文本很短，可能只包含零散关键词。');
  if (rawText && cleanedRecipeText.length < 80) warnings.push('清洗后可用菜谱正文较少，可能只提取到标题或话题，食材、调料和步骤需要人工确认。');
  if (excludedSocialText) warnings.push('已忽略疑似评论/弹幕/推荐文案，避免污染菜谱。');
  if (observedIngredientCount < 3) warnings.push('识别到的核心食材较少。');
  if (observedActionCount < 3) warnings.push('识别到的明确做法步骤较少。');
  if (!hasCaption && !hasDescription && !hasOcrText && !hasTranscript && !hasVideoFrames && !hasImages) {
    warnings.push('未获取到可用的正文、字幕、OCR、视频帧或图片信息。');
  }
  if (['xiaohongshu', 'video', 'web'].includes(normalizedSourceType) && methodStepCount > 0 && methodStepCount < 3) {
    warnings.push('生成的做法步骤少于 3 步。');
  }

  let sourceConfidence = 'medium';
  if (
    evidenceConfidence === 'low' ||
    rawText && rawText.length < 100 ||
    (rawText && cleanedRecipeText.length < 80) ||
    observedIngredientCount < 3 ||
    observedActionCount < 3 ||
    !hasAnyExtractedContent ||
    (['xiaohongshu', 'video', 'web'].includes(normalizedSourceType) && methodStepCount > 0 && methodStepCount < 3)
  ) {
    sourceConfidence = 'low';
  } else if (
    evidenceConfidence === 'high' &&
    (rawText.length >= 160 || hasImages) &&
    observedIngredientCount >= 3 &&
    observedActionCount >= 3
  ) {
    sourceConfidence = 'high';
  }

  return {
    sourceType: normalizedSourceType,
    rawTextLength: rawText.length,
    rawTextPreview: rawText.slice(0, 400),
    authorCandidateTextPreview: String(split.authorCandidateText || '').trim().slice(0, 400),
    cleanedTextLength: cleanedRecipeText.length,
    cleanedTextPreview: cleanedRecipeText.slice(0, 400),
    excludedSocialTextLength: excludedSocialText.length,
    excludedSocialTextPreview: excludedSocialText.slice(0, 400),
    weakRecipeHints: uniqueTextList(split.weakRecipeHints || [], 8),
    sourceBuckets: {
      trusted: uniqueTextList(split.sourceBuckets?.trusted || [], 8),
      weak: uniqueTextList(split.sourceBuckets?.weak || [], 8),
      excluded: uniqueTextList(split.sourceBuckets?.excluded || [], 8)
    },
    sourceSegmentsPreview: Array.isArray(split.sourceSegmentsPreview) ? split.sourceSegmentsPreview.slice(0, 12) : [],
    hasTitle: listEvidenceField(evidence, 'dishNameCandidates').length > 0,
    hasCaption,
    hasDescription,
    hasOcrText,
    hasTranscript,
    hasVideoFrames,
    hasImages,
    observedIngredientCount,
    observedActionCount,
    observedSeasoningCount,
    methodStepCount,
    sourceConfidence,
    warnings: [...new Set(warnings)]
  };
}

function getSourceDiagnosticsWarnings(diagnostics) {
  if (!diagnostics || typeof diagnostics !== 'object') return [];
  return diagnostics.sourceConfidence === 'low'
    ? ['链接可提取信息较少，菜谱可能缺少食材、调料或步骤，请人工确认。']
    : [];
}

export function checkImportedRecipeStepCoverage({ ingredients = [], seasonings = [], method = '', sourceText = '', evidence = null, diagnostics = null } = {}) {
  const items = [
    ...(Array.isArray(ingredients) ? ingredients : []),
    ...(Array.isArray(seasonings) ? seasonings : []),
    ...listEvidenceItems(evidence)
  ].map(item => String(item?.item || item?.name || item || '').trim()).filter(Boolean);
  const methodText = Array.isArray(method) ? method.join('\n') : String(method || '');
  const missingInSteps = [];
  const evidenceActionText = getEvidenceActionText(evidence);

  for (const rule of RECIPE_STEP_COVERAGE_RULES) {
    const matched = items.find(name => rule.ingredient.test(name));
    if (!matched) continue;
    if (!rule.method.test(methodText)) missingInSteps.push(matched);
  }

  const uniqueMissing = [...new Set(missingInSteps)];
  const warnings = uniqueMissing.map(name => {
    const rule = RECIPE_STEP_COVERAGE_RULES.find(item => item.ingredient.test(name));
    return rule ? getRecipeStepCoverageWarning(rule, name) : `关键材料${name}未在做法中明确出现，请确认加入时机。`;
  });
  const evidenceText = [sourceText, evidenceActionText].map(s => String(s || '').trim()).filter(Boolean).join('\n');
  const hasMeat = items.some(name => MEAT_RECIPE_INGREDIENT_PATTERN.test(name));
  const rawMethodStepCount = countRecipeMethodSteps(methodText);
  const methodStepCount = Math.max(rawMethodStepCount, countRecipeMethodStages(methodText));
  if (hasMeat && methodStepCount > 0 && methodStepCount < 3) {
    warnings.push('做法步骤过于简略，可能遗漏腌制、调味或出锅步骤，请确认。');
  }
  if (hasMeat && evidenceText && MARINADE_SOURCE_PATTERN.test(evidenceText) && !MARINADE_METHOD_PATTERN.test(methodText)) {
    warnings.push('原内容可能包含肉类腌制信息，但做法中未明确保留腌制步骤，请确认。');
  }
  const missingSeasonings = [...new Set(items.filter(name =>
    IMPORTANT_SEASONING_PATTERN.test(name) &&
    !WATER_LIKE_PATTERN.test(name) &&
    !isIngredientMentionedInMethod(name, methodText)
  ))];
  if (hasMeat && missingSeasonings.length >= 2) {
    warnings.push(`做法可能遗漏部分调味料的使用方式：${missingSeasonings.join('、')}。`);
  }
  if (hasMeat && rawMethodStepCount > 0 && rawMethodStepCount < 3 && missingSeasonings.length >= 2) {
    warnings.push('做法步骤过于简略，可能遗漏腌制、调味或出锅步骤，请确认。');
  }
  const missingNonSodaSeasonings = missingSeasonings.filter(name => name !== '小苏打');
  if (hasMeat && /小苏打/u.test(methodText) && missingNonSodaSeasonings.length >= 2) {
    warnings.push('原内容列出多种调味料，但做法中只保留了小苏打，可能遗漏腌制或调味步骤，请确认。');
  }
  const sourceConfidence = String(evidence?.sourceConfidence || '').trim().toLowerCase();
  const observedActionCount = Array.isArray(evidence?.observedActions) ? evidence.observedActions.length : 0;
  if (sourceConfidence === 'low' || (observedActionCount > 0 && observedActionCount < 3 && methodStepCount > 0 && methodStepCount < 3)) {
    warnings.push('链接可提取信息较少，菜谱可能缺少食材、调料或步骤，请人工确认。');
  }

  return {
    missingInSteps: uniqueMissing,
    warnings: [...new Set([...warnings, ...getSourceDiagnosticsWarnings(diagnostics)])]
  };
}

export function classifyReceiptItem(name, originalName = '') {
  const local = classifyReceiptCandidate({ name, originalName });
  return { group: local.group, reason: local.reason || '' };
}

function normalizeReceiptItem(item) {
  let nameStr = '';
  let originalNameStr = '';
  let qty = 1;
  let unitStr = '';
  let reason = '';

  if (typeof item === 'string') {
    nameStr = item.trim();
    originalNameStr = nameStr;
  } else if (item && typeof item === 'object') {
    nameStr = String(item.name || item.item || '').trim();
    originalNameStr = String(item.originalName || '').trim() || nameStr;
    qty = item.qty ?? item.amount ?? 1;
    unitStr = String(item.unit || '').trim();
    reason = String(item.reason || '').trim();
  }

  const displayName = nameStr || originalNameStr;
  if (!displayName) return null;

  return {
    name: nameStr || originalNameStr,
    originalName: originalNameStr || nameStr,
    rawText: String(item?.rawText || item?.originalText || originalNameStr || nameStr || '').trim(),
    zhText: String(item?.zhText || item?.chineseName || '').trim(),
    enText: String(item?.enText || item?.englishName || '').trim(),
    canonicalName: String(item?.canonicalName || nameStr || originalNameStr || '').trim(),
    confidence: item?.confidence ?? '',
    qty: qty || 1,
    unit: unitStr,
    ...(reason ? { reason } : {})
  };
}

function toReceiptNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const cleaned = String(value).trim().replace(/[^\d.-]/g, '');
  if (!cleaned) return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function formatReceiptNumber(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value || '').trim();
  return Number.isInteger(n) ? String(n) : String(Number(n.toFixed(2))).replace(/\.0+$/, '');
}

function normalizeReceiptWeightUnit(unit) {
  const u = String(unit || '').trim().toLowerCase();
  if (['lb', 'lbs', 'pound', 'pounds', '磅'].includes(u)) return { type: 'lb', label: 'lb' };
  if (['kg', '公斤', '千克'].includes(u)) return { type: 'kg', label: 'kg' };
  if (['g', 'gram', 'grams', '克'].includes(u)) return { type: 'g', label: 'g' };
  if (['斤'].includes(u)) return { type: 'jin', label: '斤' };
  if (['两'].includes(u)) return { type: 'liang', label: '两' };
  return null;
}

function findReceiptWeight(item) {
  const qty = toReceiptNumber(item.qty);
  const unitInfo = normalizeReceiptWeightUnit(item.unit);
  if (unitInfo && qty !== null && qty > 0) {
    return { value: qty, unit: unitInfo.label, type: unitInfo.type };
  }

  const text = `${item.originalName || ''} ${item.name || ''} ${item.reason || ''}`;
  const match = text.match(/(\d+(?:\.\d+)?)\s*(lb|lbs|pound|pounds|磅|kg|公斤|千克|g|gram|grams|克|斤|两)/i);
  if (!match) return null;
  const info = normalizeReceiptWeightUnit(match[2]);
  const value = toReceiptNumber(match[1]);
  if (!info || value === null || value <= 0) return null;
  return { value, unit: info.label, type: info.type };
}

function estimateServingsFromWeight(weight) {
  if (!weight) return 1;
  if (weight.type === 'kg') return Math.max(1, Math.round(weight.value * 2));
  if (weight.type === 'g') return Math.max(1, Math.round(weight.value / 500));
  if (weight.type === 'liang') return Math.max(1, Math.round(weight.value / 5));
  return Math.max(1, Math.round(weight.value));
}

function isPackageLikeUnit(unit) {
  return ['个', '颗', '只', '根', '块', '片', '份', '把', '袋', '包', '瓶', '盒', '罐', '条', '张', '件'].includes(String(unit || '').trim());
}

export function normalizeReceiptQuantityForKitchen(item, category = 'inventory') {
  const out = { ...item };
  const safeCategory = ['inventory', 'pantry', 'review', 'ignored'].includes(category) ? category : 'review';
  if (safeCategory === 'ignored') return out;

  const weight = findReceiptWeight(out);
  if (safeCategory === 'inventory' && weight) {
    out.qty = estimateServingsFromWeight(weight);
    out.unit = '份';
    out.note = `按 ${formatReceiptNumber(weight.value)} ${weight.unit} 估算，可在加入前调整份数`;
    return out;
  }

  const qty = toReceiptNumber(out.qty);
  const unit = String(out.unit || '').trim();

  if (safeCategory === 'inventory' && !unit) {
    out.qty = 1;
    out.unit = '份';
    if (qty !== null && qty !== 1) out.note = '数量单位需要确认，先按 1 份估算';
    return out;
  }

  if (isPackageLikeUnit(unit) && qty !== null && qty > 0 && !Number.isInteger(qty)) {
    out.qty = Math.max(1, Math.round(qty));
    out.unit = unit;
    out.note = '数量已按包装取整，可在加入前调整';
    return out;
  }

  return out;
}

export function validateReceiptResult(input) {
  const parsed = safeParseJson(input, '小票识别结果');
  const groups = {
    inventory: [],
    pantry: [],
    review: [],
    ignored: []
  };

  const append = (item, safeGroup = 'inventory') => {
    const normalized = normalizeReceiptItem(item);
    if (!normalized) return;
    const adjusted = normalizeReceiptQuantityForKitchen(normalized, safeGroup);
    const baseReason = normalized.reason || (
      safeGroup === 'review' ? '需要确认是否加入厨房' :
      safeGroup === 'pantry' ? '更适合放在常备货架' :
      safeGroup === 'ignored' ? '不是厨房食材' : ''
    );
    const reasonParts = [baseReason, adjusted.note].filter(Boolean);
    const reason = [...new Set(reasonParts)].join('；');
    delete adjusted.note;
    groups[safeGroup].push({ ...adjusted, ...(reason ? { reason } : {}) });
  };

  if ((!Array.isArray(parsed) && (!parsed || typeof parsed !== 'object'))) {
    throw new Error('小票识别结果里没有能处理的内容。');
  }
  const processed = postProcessReceiptItems(parsed);
  Object.entries(processed).forEach(([group, list]) => {
    if (Array.isArray(list)) list.forEach(item => append(item, group));
  });

  const total = groups.inventory.length + groups.pantry.length + groups.review.length + groups.ignored.length;
  if (!total) throw new Error('小票识别结果里没有能处理的内容。');
  return groups;
}

export function validateReceiptItems(input) {
  const result = validateReceiptResult(input);
  if (!result.inventory.length) throw new Error('小票识别结果里没有能加入厨房的食材。');
  return result.inventory;
}

export function validateRecipeResult(input) {
  const data = safeParseJson(input, 'AI 菜谱结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('AI 菜谱结果不是对象。');

  const name = String(data.name || '').trim();
  const method = String(data.method || '').trim();
  const ingredients = normalizeAiIngredients(data.ingredients);
  const dishMode = String(data.dishMode || '').trim();
  const reason = String(data.reason || '').trim();

  if (!name) throw new Error('AI 菜谱缺少菜名。');
  if (!ingredients.length) throw new Error('AI 菜谱缺少食材数组。');
  if (!method) throw new Error('AI 菜谱缺少做法。');

  return {
    name,
    ingredients,
    method,
    ...(dishMode ? { dishMode } : {}),
    ...(reason ? { reason } : {}),
    isAiDraft: true,
    draftSource: 'ai-search'
  };
}

export function validateRecommendationResult(input) {
  const data = safeParseJson(input, '推荐结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('推荐结果格式不对。');

  const local = Array.isArray(data.local)
    ? data.local.map(item => ({
      name: String(item?.name || '').trim(),
      reason: String(item?.reason || '今日推荐').trim()
    })).filter(item => item.name)
    : [];

  let creative = null;
  if (data.creative && typeof data.creative === 'object') {
    const name = String(data.creative.name || '').trim();
    const reason = String(data.creative.reason || 'AI 草稿').trim();
    const ingredients = normalizeAiIngredients(data.creative.ingredients);
    if (name && ingredients.length) {
      creative = {
        name,
        reason,
        ingredients,
        isAiDraft: true,
        draftSource: 'ai-recommendation'
      };
    }
  }

  if (!local.length && !creative) throw new Error('推荐结果里没有可用菜谱。');
  return { local, creative };
}

export function validateWeeklyMenuPlanResult(input) {
  const data = safeParseJson(input, '本周菜单规划结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('本周菜单规划结果格式不对。');
  const meals = Array.isArray(data.meals)
    ? data.meals.map(item => {
      const name = String(item?.name || '').trim();
      if (!name) return null;
      const recipeId = String(item?.recipeId || '').trim();
      const daySuggestion = String(item?.daySuggestion || '').trim();
      const reason = String(item?.reason || '').trim();
      const difficulty = String(item?.difficulty || '').trim();
      const servings = Math.trunc(Number(item?.servings || 0));
      const toTextList = value => Array.isArray(value)
        ? value.map(x => String(x || '').trim()).filter(Boolean).slice(0, 6)
        : [];
      return {
        name,
        ...(recipeId ? { recipeId } : {}),
        ...(daySuggestion ? { daySuggestion } : {}),
        ...(Number.isFinite(servings) && servings > 0 ? { servings } : {}),
        ...(reason ? { reason } : {}),
        ...(difficulty ? { difficulty } : {}),
        balanceTags: toTextList(item?.balanceTags),
        uses: toTextList(item?.uses),
        missing: toTextList(item?.missing)
      };
    }).filter(Boolean).slice(0, 10)
    : [];
  const shoppingSummary = Array.isArray(data.shoppingSummary)
    ? data.shoppingSummary.map(item => String(item || '').trim()).filter(Boolean).slice(0, 12)
    : [];
  const notes = String(data.notes || '').trim();
  if (!meals.length) throw new Error('本周菜单规划结果里没有可用建议。');
  return { meals, shoppingSummary, notes };
}

function validateMethodResult(input) {
  const data = safeParseJson(input, 'AI 做法结果');
  const method = String(data?.method || '').trim();
  if (!method) throw new Error('AI 做法结果缺少 method 字段。');
  return method;
}

export function validateCookedMealResult(input) {
  const data = safeParseJson(input, '刚做了什么分析结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('刚做了什么分析结果不是对象。');

  const rawDishes = Array.isArray(data.dishes)
    ? data.dishes
    : (Array.isArray(data.usedIngredients) ? [{ name: '', matchedRecipeName: '', usedIngredients: data.usedIngredients }] : []);
  const dishes = rawDishes
    .map(dish => {
      const name = String(dish?.name || '').trim();
      const matchedRecipeName = String(dish?.matchedRecipeName || '').trim();
      const usedIngredients = Array.isArray(dish?.usedIngredients)
        ? dish.usedIngredients.map(item => {
          const name = String(item?.name || item?.item || '').trim();
          if (!name || classifyRecipeIngredient(name).role !== 'core') return null;
          return {
            name,
            qty: item?.qty ?? '',
            unit: String(item?.unit || '').trim(),
            reason: String(item?.reason || 'AI 推测，需确认').trim()
          };
        }).filter(Boolean)
        : [];
      return { name, matchedRecipeName, usedIngredients };
    }).filter(dish => dish.name || dish.matchedRecipeName || dish.usedIngredients.length);

  if (!dishes.length) throw new Error('AI 没有判断出可确认的食材。');
  return { dishes, needsReview: data.needsReview !== false };
}

function getDataUrlPayloadLength(dataUrl) {
  const raw = String(dataUrl || '');
  const payload = raw.includes(',') ? raw.split(',').pop() : raw;
  return payload.replace(/\s+/g, '').length;
}

function fitImageSize(width, height, maxSide) {
  let w = Number(width) || 0;
  let h = Number(height) || 0;
  const max = Number(maxSide) || 0;
  if (!w || !h || !max) return { w: 1, h: 1 };
  if (w > h) {
    if (w > max) { h *= max / w; w = max; }
  } else if (h > max) {
    w *= max / h;
    h = max;
  }
  return { w: Math.max(1, Math.round(w)), h: Math.max(1, Math.round(h)) };
}

function compressImage(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.readAsDataURL(file);
    reader.onload = (e) => {
      const img = new Image();
      img.src = e.target.result;
      img.onload = () => {
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        let bestDataUrl = '';

        for (const attempt of RECEIPT_IMAGE_COMPRESSION_ATTEMPTS) {
          const { w, h } = fitImageSize(img.width, img.height, attempt.maxSide);
          canvas.width = w;
          canvas.height = h;
          ctx.clearRect(0, 0, w, h);
          ctx.drawImage(img, 0, 0, w, h);
          const dataUrl = canvas.toDataURL('image/jpeg', attempt.quality);
          bestDataUrl = dataUrl;
          if (getDataUrlPayloadLength(dataUrl) <= CLOUD_IMAGE_TARGET_BASE64_BYTES) {
            resolve(dataUrl);
            return;
          }
        }

        resolve(bestDataUrl);
      };
      img.onerror = () => reject(new Error('图片读取失败，请换一张更清晰的小票。'));
    };
    reader.onerror = reject;
  });
}

async function callAiService(prompt, imageBase64 = null, options = {}) {
  const conf = getAiConfig();
  const taskType = String(options.taskType || 'general').trim() || 'general';

  if (conf.mode === 'cloud') {
    let res;
    try {
      res = await fetch(conf.apiUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt, imageBase64, taskType })
      });
    } catch (_) {
      throw new Error(CLOUD_AI_ERROR);
    }
    let data = null;
    try { data = await res.json(); } catch (_) { /* non-json cloud failure */ }
    if (!res.ok) {
      const status = data && data.status ? data.status : res.status;
      const code = data && (data.code || data.upstreamCode) ? (data.code || data.upstreamCode) : '';
      const upstreamStatus = data && data.upstreamStatus ? data.upstreamStatus : 0;
      const upstreamCode = data && data.upstreamCode ? data.upstreamCode : '';
      const detail = data && (data.detail || data.error || data.message) ? (data.detail || data.error || data.message) : '云端服务暂时不可用';
      throw createCloudAiError({ status, code, upstreamStatus, upstreamCode, detail });
    }
    const content = data && typeof data.content === 'string' ? data.content : '';
    if (!content) throw createCloudAiError({ status: 502, code: 'empty_response', detail: 'AI 没有返回内容' });
    return content;
  }

  if (!conf || conf.missingKey) throw new Error(BYOK_MISSING_KEY_ERROR);

  let messages = [];
  let activeModel = conf.textModel;

  if (imageBase64) {
    activeModel = conf.visionModel;
    messages = [{ role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: imageBase64 } }] }];
  } else {
    messages = [{ role: 'user', content: prompt }];
  }

  const res = await fetch(conf.apiUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${conf.apiKey}` },
    body: JSON.stringify({ model: activeModel, messages, temperature: 0.2 })
  });

  if (!res.ok) {
    const errData = await res.json().catch(() => ({}));
    throw new Error(`API 错误 (${res.status}): ${errData.error?.message || '未知错误'}`);
  }
  const data = await res.json();
  return data.choices?.[0]?.message?.content || '';
}

export function withTimeout(promise, ms, message) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(message)), ms))
  ]);
}

export function formatAiErrorMessage(error) {
  const msg = String(error?.message || error || '');
  const details = getAiErrorDetails(error);
  const code = details.code || details.upstreamCode;
  const status = details.status || details.upstreamStatus;
  const marker = formatAiStatusCode(details);
  if (msg.includes('云端服务暂时不可用')) return CLOUD_AI_ERROR;
  if (msg.includes('还没有配置 API Key')) return BYOK_MISSING_KEY_ERROR;
  if (msg.includes('未配置')) return `AI 暂不可用：还没有配置 API Key${marker}。本地功能仍可正常使用。`;
  if (status === 401 || msg.includes('401')) return `AI 暂不可用：API Key 可能已过期${marker}。本地功能仍可正常使用。`;
  if (status === 413 || code === 'image_too_large' || msg.includes('image_too_large')) return `AI 暂不可用：图片太大，请换一张更小或更清晰的小票图${marker}。本地功能仍可正常使用。`;
  if (status === 429 || code === 'rate_limited' || code === 'rate_limit' || msg.includes('429')) return `AI 暂不可用：请求太频繁或额度不足${marker}。本地功能仍可正常使用。`;
  if (status === 404 || code === 'model_not_found' || msg.includes('404')) return `AI 暂不可用：模型名称可能不正确${marker}。本地功能仍可正常使用。`;
  if (status === 503 || code === 'missing_api_key' || msg.includes('missing_api_key')) return `AI 暂不可用：云端服务还没有配置好${marker}。本地功能仍可正常使用。`;
  if (msg.includes('超时')) return 'AI 暂不可用：响应超时。本地功能仍可正常使用。';
  if (msg.includes('格式不正确') || msg.includes('缺少') || msg.includes('没有返回可识别')) return `AI 返回内容不能直接使用：${msg}`;
  return `AI 暂不可用：${msg || '未知错误'}。本地功能仍可正常使用。`;
}

export function getReceiptAiFailureCopy(error) {
  const details = getAiErrorDetails(error);
  const status = details.status || details.upstreamStatus;
  const code = details.code || details.upstreamCode;
  if (status === 413 || code === 'image_too_large') {
    return {
      title: '小票识别暂时不可用',
      message: '图片太大，请换一张更清晰但文件更小的图片，或改用文本批量记。'
    };
  }
  if (status === 404 || code === 'model_not_found') {
    return {
      title: '小票识别暂时不可用',
      message: '图片识别模型暂不可用，请稍后再试或改用文本批量记。'
    };
  }
  if (status === 429 || code === 'rate_limited' || code === 'rate_limit') {
    return {
      title: '小票识别暂时不可用',
      message: '请求太频繁，请稍后再试。你也可以先改用文本批量记。'
    };
  }
  if (status === 503 || code === 'missing_api_key') {
    return {
      title: '小票识别暂时不可用',
      message: '内置 AI 服务尚未配置，请改用文本批量记。本地功能仍可正常使用。'
    };
  }
  return {
    title: '小票识别暂时不可用',
    message: '云端服务暂时不可用，本地功能仍可正常使用。你可以先改用文本批量记。'
  };
}

export function getRecipeImportAiFailureCopy(error) {
  const details = getAiErrorDetails(error);
  const marker = formatAiStatusCode(details);
  if (details.importTextReady && isRecipeJsonFailedError(error)) {
    return {
      title: 'AI 导入暂时不可用',
      message: `视频文字已读取成功，但 AI 整理菜谱失败。可以稍后重试，或复制视频文字手动整理${marker ? ` ${marker}` : ''}。`
    };
  }
  if (isRateLimitExceededError(error)) {
    if (details.importTextReady) {
      return {
        title: 'AI 导入暂时不可用',
        message: `视频文字已读取成功，但 AI 整理菜谱时触发限流。请稍后点击重试整理${marker ? ` ${marker}` : ''}。`
      };
    }
    return {
      title: 'AI 导入暂时不可用',
      message: `AI 服务请求过于频繁，请稍后再试${marker ? ` ${marker}` : ''}。`
    };
  }
  return {
    title: 'AI 导入暂时不可用',
    message: `你可以改用粘贴文本整理，或稍后再试${marker ? ` ${marker}` : ''}。`
  };
}

export async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `你是一个中文家庭厨房小票整理助手。请分析图片收据，把商品分成四类：做菜食材、常备货架、需要确认、已忽略。

请严格返回 JSON 格式，不要包含 Markdown 标记（如 \`\`\`json），也不要任何解释或说明。
返回结构如下：
{
  "inventory": [
    { "rawText": "五花肉 Pork Belly", "zhText": "五花肉", "enText": "Pork Belly", "canonicalName": "五花肉", "name": "五花肉", "qty": 1, "unit": "盒", "group": "inventory", "confidence": "high", "reason": "中英一致，原始食材" }
  ],
  "pantry": [
    { "rawText": "散装生姜 Loose Ginger", "zhText": "散装生姜", "enText": "Loose Ginger", "canonicalName": "姜", "name": "姜", "qty": 1, "unit": "份", "group": "pantry", "confidence": "high", "reason": "中文优先，调味基础品" }
  ],
  "review": [
    { "rawText": "鲜肉白菜水饺 TC Pork Cabbage Dumplings", "zhText": "鲜肉白菜水饺", "enText": "Pork Cabbage Dumplings", "canonicalName": "鲜肉白菜水饺", "name": "鲜肉白菜水饺", "qty": 1, "unit": "袋", "group": "review", "confidence": "high", "reason": "冷冻/熟制面点，默认不加入做菜食材" }
  ],
  "ignored": [
    { "rawText": "Shopping Bag", "enText": "Shopping Bag", "reason": "非食品" }
  ]
}

字段及要求：
- rawText: 该商品在小票上的完整原始文本；尽量保留中英文、重量、内部商品名。
- zhText: 如果该行有中文，提取中文部分；没有中文则填空字符串。
- enText: 如果该行有英文，提取英文部分；没有英文则填空字符串。
- canonicalName/name: 最终给用户看的厨房名称；有中文时必须优先按中文判断，英文只做辅助证据；没有中文时再用英文判断。
- group: 必须是 inventory | pantry | review | ignored 之一。
- confidence: "high" | "medium" | "low"。
- reason: 简短说明为什么这样分组，特别是 review 和中英文冲突。
- originalName: 如果保留该旧字段，也应等同 rawText，方便兼容。
- name: 必须是常见的中厨房常见中文食材名称。不要做生硬的字面直译。
  - 如果是英文商品名，请先按照常见华人超市/家庭厨房的惯用中文名称进行翻译和归一。
  - 必须参考以下常见英文名与中文食材名的映射范例：
    - "king oyster mushroom" -> "杏鲍菇"（绝对不能直译成"王菇"）
    - "enoki mushroom" -> "金针菇"
    - "shiitake mushroom" -> "香菇"
    - "oyster mushroom" -> "平菇"
    - "button mushroom" / "white mushroom" -> "口蘑"
    - "bok choy" -> "青菜"
    - "baby bok choy" -> "小白菜"
    - "napa cabbage" / "chinese cabbage" -> "白菜"
    - "scallion" / "green onion" -> "葱"
    - "cilantro" / "coriander" -> "香菜"
    - "eggplant" -> "茄子"
    - "potato" -> "土豆"
    - "tomato" -> "番茄"
    - "tofu" -> "豆腐"
    - "pork belly" -> "五花肉"
    - "ground pork" / "minced pork" -> "肉末"
    - "chicken breast" -> "鸡脯肉"
    - "chicken thigh" -> "鸡腿"
    - "shrimp" / "prawns" -> "虾"
- qty: 食材数量，可以是数字。不确定时填 1。
- unit: 单位，必须是字符串。不确定时填空字符串。
- 中英双证据规则：
  - 同时参考中文和英文。
  - 有中文时优先用中文判断；英文只作为辅助。
  - 中英文一致时 confidence 可为 high。
  - 中文和英文明显冲突时，不要放入 inventory/pantry，必须放入 review，reason 写“中英文信息不一致，需要确认”。
  - 不确定但看起来像食物时，放入 review，不要直接 ignored。
  - 只有明显非食物、购物袋、税、折扣、会员、押金、收银/支付信息、纸巾、清洁用品、餐具/容器费等才 ignored。
- 普通做菜食材最终建议按“份”管理；如果小票显示 lb/kg/g，请保留原始重量信息，但 qty/unit 优先输出成估算份数，例如 2 lb 猪肉 -> { "qty": 2, "unit": "份" }，0.8 lb 虾 -> { "qty": 1, "unit": "份" }。
- 包装商品 qty 应为整数，不要输出 0.81 包 / 0.81 个这类小数包装数量。
- inventory 只放真正适合作为做菜库存的核心食材：肉、鱼虾、蔬菜、蛋、豆腐、菌菇等鲜货。
- tofu / medium firm tofu / firm tofu / soft tofu 必须识别为“豆腐”，放入 inventory。
- 青菜、油菜、莴笋、豆芽、choy、yu choy、stem lettuce、beansprout、鸡腿、pork、beef、shrimp、fish 等鲜货放入 inventory。
- pantry 放常备货架 / 干货 / 主食基础：姜、葱、蒜、干辣椒、花椒、八角、香叶、桂皮、大米、糯米、杂粮、面条、挂面、意面、米粉、粉丝、面粉、淀粉、干木耳、干香菇、腐竹、海带、紫菜、罐头、干豆，以及盐糖油酱醋等基础调味。
- pantry 不是所有耐放食品。只有做饭基础储备、普通干面、原料型干货和调味基础品进入 pantry；加工食品不要放 pantry。
- review 放需要用户确认、不默认加入普通库存的食品：水果、零食、饮料、甜品、酸奶、熟食、即食食品、方便面、泡面、spicy seafood noodle、instant noodle、ramen、cup noodle、速冻水饺、抄手、馄饨、云吞、汤圆、粽子、包子、馒头、披萨、鸡块、薯条、糕点、snowy cake、cake、Dried Anchovy w/Peanut 等冷冻/即食/加工食品。
- 不认识的食品、中文/英文缩写、内部商品名，只要像食物就放 review，reason 写“需要确认”，不要 ignored。
- ignored 放完全不应处理的内容：购物袋、税费、折扣、会员信息、押金、纸巾、清洁用品、非食品、收银/支付信息。
- 葱姜蒜、盐、糖、酱油、醋、味精、花椒、辣椒、油等佐料不要放入 inventory，可放 pantry。`;
  const raw = await callAiService(prompt, base64, { taskType: 'receipt' });
  return validateReceiptResult(raw);
}

export async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item || i.name).filter(Boolean).join('、');
  const prompt = `你是一位精通川菜和中式家常菜的资深大厨。请为菜品【${recipeName}】生成一份“可编辑草稿做法”。已知用料：${ingStr}。

请严格返回 JSON，不要 markdown，不要解释：
{
  "method": "1. 第一步...\\n2. 第二步..."
}

字段要求：
- method 必须是字符串。
- 步骤要清晰、家常、可执行。
- 不要把结果说成最终答案，只作为用户可编辑草稿。`;

  const raw = await callAiService(prompt, null, { taskType: 'method' });
  return validateMethodResult(raw);
}

export async function callAiForCookedMeal(text, inventory = [], recipes = []) {
  const inventoryNames = (inventory || [])
    .map(item => item && item.name)
    .filter(Boolean)
    .slice(0, 80);
  const recipeNames = (recipes || [])
    .map(recipe => recipe && recipe.name)
    .filter(Boolean)
    .slice(0, 120);
  const prompt = `你是一个谨慎的家庭厨房助手。用户刚刚描述自己做了什么，请只从“用户描述”和“当前厨房库存”里提取可能实际用掉的核心食材候选。你只能生成候选，绝不能决定扣库存。

用户描述：
${String(text || '').trim()}

当前厨房库存：
${inventoryNames.join('、') || '无'}

可参考的已有菜谱名：
${recipeNames.join('、') || '无'}

请严格返回 JSON，不要 markdown，不要解释：
{
  "dishes": [
    {
      "name": "青菜豆腐汤",
      "matchedRecipeName": "",
      "usedIngredients": [
        { "name": "青菜", "qty": 1, "unit": "份", "reason": "用户提到青菜" }
      ]
    }
  ],
  "needsReview": true
}

硬性规则：
- usedIngredients 只能包含当前厨房库存里存在或能明确同义匹配的食材。
- 不要凭空编造库存里没有的食材。
- 只列核心主材：肉、鱼虾、蔬菜、蛋、豆制品、菌菇等。
- 不要列葱姜蒜、盐糖油酱醋、料酒、淀粉、水、高汤、汤汁、适量等调料或非库存项。
- 用户说得很模糊时，少列或不列候选，needsReview 必须为 true。
- qty 是估算用量；不确定填 1。`;
  const raw = await callAiService(prompt, null, { taskType: 'cooked-meal' });
  return validateCookedMealResult(raw);
}

export const CREATIVE_DISH_MODES = [
  { key: 'stir_fry', label: '快炒' },
  { key: 'braised_rice', label: '焖饭' },
  { key: 'risotto', label: '烩饭' },
  { key: 'rice_bowl', label: '盖饭' },
  { key: 'noodle', label: '汤面/拌面' },
  { key: 'soup_stew', label: '炖煮' },
  { key: 'oven_roast', label: '烤盘/焗烤' },
  { key: 'warm_salad', label: '温沙拉' },
  { key: 'pancake', label: '蛋饼/煎饼' },
  { key: 'wrap', label: '卷饼' }
];

export function getCreativeDishModeLabel(key) {
  return CREATIVE_DISH_MODES.find(mode => mode.key === key)?.label || '创意做法';
}

export function pickNextCreativeDishMode(usedModes = [], lastMode = '') {
  const used = new Set((usedModes || []).map(mode => String(mode || '').trim()).filter(Boolean));
  const previous = String(lastMode || usedModes?.[usedModes.length - 1] || '').trim();
  return CREATIVE_DISH_MODES.find(mode => !used.has(mode.key) && mode.key !== previous)
    || CREATIVE_DISH_MODES.find(mode => mode.key !== previous)
    || CREATIVE_DISH_MODES[0];
}

export function inferCreativeDishModeFromName(name) {
  const text = String(name || '');
  if (/焖饭|煲仔饭|饭煲/.test(text)) return 'braised_rice';
  if (/烩饭|炖饭/.test(text)) return 'risotto';
  if (/盖饭|浇饭|丼/.test(text)) return 'rice_bowl';
  if (/汤面|拌面|面条|炒面|面$/.test(text)) return 'noodle';
  if (/炖|煮|汤|煲|烩菜/.test(text)) return 'soup_stew';
  if (/烤|焗|焙|烤盘/.test(text)) return 'oven_roast';
  if (/沙拉|温拌/.test(text)) return 'warm_salad';
  if (/蛋饼|煎饼|饼/.test(text)) return 'pancake';
  if (/卷饼|春卷|卷/.test(text)) return 'wrap';
  if (/炒|爆|小炒|快炒|清炒/.test(text)) return 'stir_fry';
  return '';
}

export function normalizeCreativeRecipeName(name) {
  return String(name || '')
    .replace(/\s+/g, '')
    .replace(/[·,，、/／\\-]/g, '')
    .replace(/鸡肉[片丁丝块粒末]/g, '鸡肉')
    .replace(/鸡[丁丝片]/g, '鸡肉')
    .replace(/牛肉[片丁丝块粒末]/g, '牛肉')
    .replace(/猪肉[片丁丝块粒末]/g, '猪肉')
    .replace(/肉[片丁丝块粒末]/g, '肉')
    .replace(/切[片丁丝块]/g, '')
    .trim();
}

export function areCreativeRecipeNamesSimilar(a, b) {
  const modeA = inferCreativeDishModeFromName(a);
  const modeB = inferCreativeDishModeFromName(b);
  if (modeA && modeB && modeA !== modeB) return false;

  const nameA = normalizeCreativeRecipeName(a);
  const nameB = normalizeCreativeRecipeName(b);
  if (!nameA || !nameB) return false;
  if (nameA === nameB) return true;
  return Boolean(modeA && modeB && modeA === modeB && (nameA.includes(nameB) || nameB.includes(nameA)));
}

// AI 草稿的食材二次过滤：只留核心食材（盐/水/葱姜蒜/高汤等绝不进 ingredients）。
// 纯函数，供「指定食材创意做法」与测试复用。
export function filterAiDraftCoreIngredients(draft) {
  const ingredients = normalizeAiIngredients(draft.ingredients || [])
    .filter(it => classifyRecipeIngredient(it.item).role === 'core');
  if (!ingredients.length) throw new Error('AI 没有返回可用核心食材');
  return { ...draft, ingredients };
}

/**
 * 「想用这些食材」AI 创意做法：基于用户指定食材 + 当前库存生成一道家常草稿。
 * 只返回草稿（isAiDraft），绝不自动保存；调用方让用户确认后再入库。
 */
export async function callAiCreativeRecipeByIngredients({
  targets = [],
  inventoryNames = [],
  localRecipeNames = [],
  preferredDishMode = '',
  avoidedRecipeNames = [],
  avoidedDishModes = []
} = {}) {
  const preferred = CREATIVE_DISH_MODES.find(mode => mode.key === preferredDishMode)
    || pickNextCreativeDishMode(avoidedDishModes);
  const avoidedModes = [...new Set((avoidedDishModes || []).filter(Boolean))]
    .map(getCreativeDishModeLabel)
    .filter(Boolean);
  const avoidedNames = [...new Set([...(localRecipeNames || []), ...(avoidedRecipeNames || [])]
    .map(name => String(name || '').trim())
    .filter(Boolean))];
  const modeOptions = CREATIVE_DISH_MODES.map(mode => `${mode.key}=${mode.label}`).join('；');
  const prompt = `用户想用这些食材做一道菜：【${targets.join('、')}】。
当前厨房里还有：【${inventoryNames.join('、') || '没有更多库存信息'}】。
已经出现过或需要避开的菜名：【${avoidedNames.join('、') || '无'}】。
已经用过的烹饪形态：【${avoidedModes.join('、') || '无'}】。

本次必须优先使用这个烹饪形态：${preferred.label}（dishMode=${preferred.key}）。
可选形态池：${modeOptions}。

请生成一道「家常、可执行、不夸张」的创意菜草稿，必须尽量用上用户指定的食材，做法适合家庭厨房（3-6 步），不要餐厅级复杂做法。

请严格返回 JSON，不要 markdown，不要解释：
{
  "name": "菜名",
  "dishMode": "${preferred.key}",
  "reason": "为什么适合这些食材",
  "ingredients": [
    {"item": "核心食材", "qty": "", "unit": ""}
  ],
  "method": "1. 步骤...\\n2. 步骤..."
}

硬性要求：
- dishMode 必须是上面形态池里的 key，优先返回 ${preferred.key}。
- 如果刚推荐过炒菜，本次不要再推荐炒菜；不要把同一道菜从鸡肉片改成鸡肉丁/鸡肉丝来伪装变化。
- 菜品形态要明显不同，可以是焖饭、烩饭、盖饭、汤面/拌面、炖煮、烤盘/焗烤、温沙拉、蛋饼/煎饼、卷饼等方向。
- ingredients 只列肉、菜、蛋、豆制品、菌菇等核心主材。
- 不要把葱姜蒜、盐糖油酱醋、料酒、淀粉、水、高汤、汤汁列入 ingredients；需要调料只写在 method 里。
- 不要主动使用“韭葱”这个食材名；英文 leek/leeks 不要直译成“韭葱”，按中餐语境改写为葱/大葱、蒜苗或韭菜。
- name 不要和上面列出的菜名重复，也不要只是刀工变化。`;
  const raw = await callAiService(prompt, null, { taskType: 'creative-recipe' });
  const draft = validateRecipeResult(raw);
  const cleaned = filterAiDraftCoreIngredients(draft);
  if (avoidedNames.some(name => areCreativeRecipeNamesSimilar(name, cleaned.name))) {
    throw new Error('AI 返回的做法和上一道太像，请再点一次换一种。');
  }
  const dishMode = CREATIVE_DISH_MODES.some(mode => mode.key === cleaned.dishMode)
    ? cleaned.dishMode
    : preferred.key;
  return { ...cleaned, dishMode, draftSource: 'target-ingredients' };
}

export async function callAiSearchRecipe(query, invNames) {
  const prompt = `我冰箱里有：【${invNames}】。我想找菜谱：【${query}】。请生成一道“AI 草稿菜谱”，等待用户确认后再保存。

请严格返回 JSON，不要 markdown，不要解释：
{
  "name": "标准菜名",
  "ingredients": [
    {"item": "核心食材1", "qty": "", "unit": ""},
    {"item": "核心食材2", "qty": "", "unit": ""}
  ],
  "method": "1. 步骤...\\n2. 步骤..."
}

字段要求：
- name 必须是字符串。
- ingredients 必须是数组，只列肉、菜、蛋、豆制品等核心主材。
- method 必须是字符串。
- 不要把葱姜蒜、盐糖油酱醋等佐料列入 ingredients。
- 不要主动使用“韭葱”这个食材名；英文 leek/leeks 不要直译成“韭葱”，按中餐语境改写为葱/大葱、蒜苗或韭菜。`;
  const raw = await callAiService(prompt, null, { taskType: 'recipe-search' });
  return validateRecipeResult(raw);
}

export async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');

  // ── 反疲劳机制：读取后台烹饪频次账本（recipe_activity）──
  const activity = S.load(S.keys.recipe_activity, {});
  const now = Date.now();
  const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;
  // lastCookedAt 为数值毫秒；兼容旧数据回退到 cookedAt(ISO 日期字符串)。
  const lastCookedMs = (act) => {
    if (!act) return 0;
    if (typeof act.lastCookedAt === 'number') return act.lastCookedAt;
    return act.cookedAt ? Date.parse(act.cookedAt) : 0;
  };

  const allRecipes = pack.recipes || [];
  // 【硬过滤】72 小时内做过的菜，从喂给 AI 的候选池中直接剔除，杜绝短期高频重复。
  const candidates = allRecipes.filter(r => {
    const last = lastCookedMs(activity[r.id]);
    return !(last && (now - last < THREE_DAYS_MS));
  });
  // 兜底：过滤后候选过少时回退全量，避免「无菜可推」。
  const pool = candidates.length >= 5 ? candidates : allRecipes;
  const recipeNames = pool.map(r => r.name).join(',');

  // 【软降权】取累计烹饪次数(cookedCount)最高的前 5 道菜名，提示 AI 极力避开。
  const topFrequent = allRecipes
    .map(r => ({ name: r.name, count: (activity[r.id]?.cookedCount || 0) }))
    .filter(x => x.count > 0)
    .sort((a, b) => b.count - a.count)
    .slice(0, 5)
    .map(x => x.name);
  const antiFatigueRule = topFrequent.length
    ? `\n- 【重要反疲劳规则】：以下菜谱由于用户近期或频繁烹饪，本次推荐中请极力避开或大幅降低其出现概率，请多推荐其他冷门、未尝试或不常做的食材搭配：[${topFrequent.join('、')}]`
    : '';

  const prompt = `你是一位严谨的中式家庭厨房助手。请根据冰箱库存：【${invNames}】规划今日菜单。

请严格返回 JSON，不要 markdown，不要解释：
{
  "local": [
    {"name": "必须从菜谱库里选择的菜名", "reason": "基于库存匹配度的推荐理由"}
  ],
  "creative": {
    "name": "不在菜谱库中的家常菜草稿名",
    "reason": "简短说明为什么适合",
    "ingredients": [
      {"item": "核心食材1", "qty": "", "unit": ""},
      {"item": "核心食材2", "qty": "", "unit": ""}
    ]
  }
}

字段要求：
- local 必须是数组，name 必须尽量从这个菜谱库中挑选：【${recipeNames}】。
- creative.name 必须是字符串。
- creative.ingredients 必须是数组，只列核心主材。
- creative 是 AI 草稿，不是最终菜谱。
- 严禁用葱姜蒜、香菜、调料替代肉菜蛋豆等主材。
- 不要主动使用“韭葱”这个食材名；英文 leek/leeks 不要直译成“韭葱”，按中餐语境改写为葱/大葱、蒜苗或韭菜。${antiFatigueRule}`;

  const raw = await callAiService(prompt, null, { taskType: 'recommendation' });
  return validateRecommendationResult(raw);
}

export async function callAiWeeklyMenuPlan({
  mealsCount = 4,
  peopleCount = 2,
  preferences = {},
  userRequest = '',
  inventory = [],
  expiringItems = [],
  favoriteRecipes = [],
  localCandidateRecipes = [],
  existingPlan = []
} = {}) {
  const payload = {
    mealsCount: Math.max(1, Math.min(10, Math.trunc(Number(mealsCount) || 4))),
    peopleCount: Math.max(1, Math.min(8, Math.trunc(Number(peopleCount) || 2))),
    preferences: {
      useExpiring: Boolean(preferences.useExpiring ?? preferences.expiring),
      useInventory: Boolean(preferences.useInventory ?? preferences.inventory),
      quickMeals: Boolean(preferences.quickMeals ?? preferences.quick),
      lunchboxFriendly: Boolean(preferences.lunchboxFriendly ?? preferences.lunchbox)
    },
    userRequest: String(userRequest || '').trim().slice(0, 500),
    inventory: (inventory || []).slice(0, 40),
    expiringItems: (expiringItems || []).slice(0, 12),
    favoriteRecipes: (favoriteRecipes || []).slice(0, 10),
    localCandidateRecipes: (localCandidateRecipes || []).slice(0, 12),
    existingPlan: (existingPlan || []).slice(0, 10)
  };

  const prompt = `你是 Kitchen Manager 的家庭厨房周菜单规划助手。请根据用户库存、临期食材、偏好和本地候选菜，规划接下来一周在家做的 ${payload.mealsCount} 顿饭，服务 ${payload.peopleCount} 人。

请优先从 localCandidateRecipes 中选择；如果某道建议来自候选菜，必须保留它的 recipeId。
可以提出少量本地没有的新菜名，但不要自动创建菜谱，也不要写入计划或买菜清单。

输入数据：
${JSON.stringify(payload, null, 2)}

请严格只返回 JSON 对象，不要 markdown，不要解释：
{
  "meals": [
    {
      "name": "菜名",
      "recipeId": "optional-existing-recipe-id",
      "daySuggestion": "周一",
      "servings": ${payload.peopleCount},
      "reason": "为什么适合本周",
      "difficulty": "简单",
      "balanceTags": ["蛋白质", "带饭"],
      "uses": ["会用到的库存食材"],
      "missing": ["需要买的核心食材"]
    }
  ],
  "shoppingSummary": ["需要买的核心食材"],
  "notes": "一句话总结"
}

规则：
- meals 数量尽量接近 mealsCount。
- servings 默认等于 peopleCount；如果适合带饭，可以设为 peopleCount + 1。
- 每道菜按 peopleCount 人份规划，不要让每顿菜量明显过少。
- missing 只放核心食材，不放盐、糖、油、生抽、老抽、料酒、水、葱姜蒜、适量、少许。
- 如果用户要求不吃某类食材，必须避开。
- 如果 useExpiring 为 true，优先安排临期食材。
- 如果 lunchboxFriendly 为 true，至少安排适合带饭的菜。
- 如果 lunchboxFriendly 为 true，可以安排部分菜多做 1 份。
- 尽量兼顾蛋白质、蔬菜、主食搭配。
- 不要安排连续多顿口味或主蛋白重复太高的菜，难度不要都太高。`;

  const raw = await callAiService(prompt, null, { taskType: 'weekly-menu-plan' });
  return validateWeeklyMenuPlanResult(raw);
}

// 智能录入解析服务：抓取与大模型调用都在后端（server.js）完成。
// 前端只负责把「链接文案 / 截图」传给后端代理，不再读取本地 API Key。

// 抓取小红书/网页菜谱文案：交给同源后端 /api/xhs-extract（server.js）完成
// 302 跟随、移动端 UA 伪造与 __INITIAL_STATE__ 解析，绕过浏览器跨域限制。
async function fetchRecipeSource(url) {
  let res;
  try {
    res = await fetch(buildApiUrl(`/api/xhs-extract?url=${encodeURIComponent(url)}`));
  } catch (e) {
    // 后端不可用（如纯静态托管、未启动 node server.js）
    throw new Error('链接抓取受限，请稍后重试或粘贴菜谱文字。');
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  if (!res.ok) {
    throw new Error((data && data.error) || '链接抓取受限，请稍后重试或粘贴菜谱文字。');
  }
  const text = data && data.text;
  if (!text || String(text).length < 6) {
    throw new Error('没能从链接页面文字中提取到菜谱文案，请稍后重试或手动编辑。');
  }
  return {
    text: String(text),
    metadata: {
      url: data.url || url,
      finalUrl: data.finalUrl || '',
      extractionMode: data.extractionMode || 'link-only',
      hasHtml: Boolean(data.hasHtml),
      hasStructuredMeta: Boolean(data.hasStructuredMeta),
      hasOgDescription: Boolean(data.hasOgDescription),
      hasJsonLd: Boolean(data.hasJsonLd),
      hasInitialState: Boolean(data.hasInitialState),
      trustedTextLength: Number(data.trustedTextLength || String(text).length),
      trustedTextPreview: String(data.trustedTextPreview || text).slice(0, 500),
      rawTextLength: Number(data.rawTextLength || 0),
      rawTextPreview: String(data.rawTextPreview || '').slice(0, 500),
      warnings: Array.isArray(data.warnings) ? data.warnings : []
    }
  };
}

// 解析 120B 返回，校验并对齐编辑器字段（name / tags / ingredients / method）。
function validateImportedRecipe(input, { sourceText = '', evidence = null, diagnostics = null, debugEvidenceSummary = null, sourceType = 'manual', imageBase64 = null } = {}) {
  const data = safeParseJson(input, 'AI 菜谱结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('AI 菜谱结果不是对象。');

  const name = String(data.name || '').trim();
  // method 兼容三种形态：纯文本字符串 / 步骤数组（method[] 或 steps[]）。
  // 数组步骤会自动剥离模型可能仍然附带的「1.」「步骤一：」等数字/序号前缀，
  // 再统一加序号拼成多行文本，保证前端列表样式干净换行。
  const stripStepPrefix = (s) => String(s || '')
    .replace(/^[\s\-•·]*(?:第[一二三四五六七八九十百零\d]+步[:：]?|步骤[一二三四五六七八九十百零\d]+[:：]?|[一二三四五六七八九十]+[、.．。)）][\s]*|\d+\s*[.、．。)）:：][\s]*)/u, '')
    .trim();
  const arraySteps = Array.isArray(data.method) ? data.method
    : (Array.isArray(data.steps) ? data.steps : null);
  let method = '';
  if (arraySteps) {
    method = arraySteps
      .map(stripStepPrefix)
      .filter(s => s && s.length > 1)
      .map((s, i) => `${i + 1}. ${s}`)
      .join('\n');
  } else {
    method = String(data.method || '').trim();
  }
  const methodBeforeGenericFilter = method;
  method = stripUnsupportedGenericMethodLines(method, evidence);
  const ingredients = normalizeAiIngredients(data.ingredients);
  const seasonings = normalizeAiIngredients(data.seasonings);
  const tags = Array.isArray(data.tags) ? data.tags.map(t => String(t || '').trim()).filter(Boolean).slice(0, 4) : [];
  const importedWarnings = Array.isArray(data.warnings)
    ? data.warnings.map(w => String(w || '').trim()).filter(Boolean)
    : [];
  if (methodBeforeGenericFilter && methodBeforeGenericFilter !== method) {
    importedWarnings.push('清洗后可用菜谱正文较少，未能可靠提取完整做法，请补充原文或手动编辑。');
  }
  const sourceDiagnostics = diagnostics && typeof diagnostics === 'object'
    ? diagnostics
    : (evidence ? buildRecipeImportSourceDiagnostics({ sourceType, sourceText, imageBase64, evidence, method }) : null);
  const coverage = checkImportedRecipeStepCoverage({ ingredients, seasonings, method, sourceText, evidence, diagnostics: sourceDiagnostics });
  const warnings = [...new Set([...importedWarnings, ...coverage.warnings])];

  if (!name) throw new Error('AI 菜谱缺少菜名。');
  if (!ingredients.length && !warnings.length && !data.needsReview) throw new Error('AI 菜谱缺少食材。');
  if (!method && !warnings.length && !data.needsReview) throw new Error('AI 菜谱缺少做法。');

  return {
    name,
    tags,
    ingredients,
    seasonings,
    method,
    warnings,
    diagnostics: sourceDiagnostics,
    debugEvidenceSummary,
    needsReview: Boolean(data.needsReview || warnings.length),
    isAiDraft: true,
    draftSource: 'ai-import'
  };
}

// 通过后端 /api/ai-parse 调用 AI：文本菜谱导入用 OPENAI_IMPORT_MODEL，图片用 OPENAI_VISION_MODEL。
// 前端不再校验本地 API Key，未配置也能正常点击、走后端代理。
async function parseRecipeWith120B({ text = '', imageBase64 = null, sourceType = 'manual', sourceMetadata = null } = {}) {
  let res;
  try {
    res = await fetch(buildApiUrl('/api/ai-parse'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, imageBase64, sourceType, sourceMetadata })
    });
  } catch (e) {
    throw new Error('AI 服务暂不可用（后端未启动？），请稍后重试。');
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  if (!res.ok) {
    throw createCloudAiError({
      status: data?.status || res.status,
      code: data?.code || data?.upstreamCode || '',
      upstreamStatus: data?.upstreamStatus || 0,
      upstreamCode: data?.upstreamCode || '',
      detail: data?.detail || data?.error || data?.message || 'AI 解析失败',
      importTextReady: Boolean(data?.importTextReady),
      mediaDiagnostics: data?.mediaDiagnostics || null,
      transcriptPreview: data?.transcriptPreview || '',
      ocrPreview: data?.ocrPreview || '',
      pageTextPreview: data?.pageTextPreview || '',
      fallback: 'AI 解析失败'
    });
  }
  // 后端返回模型原文 content，由前端统一校验对齐编辑器字段。
  return validateImportedRecipe((data && (data.recipe || data.content)) || '', {
    sourceText: text,
    evidence: data?.evidence || null,
    diagnostics: data?.diagnostics || null,
    debugEvidenceSummary: data?.debugEvidenceSummary || null,
    sourceType,
    imageBase64
  });
}

async function importXiaohongshuRecipeFromUrl({ url = '', userText = '' } = {}) {
  let res;
  try {
    res = await fetch(buildApiUrl('/api/recipe-import-from-url'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url, userText })
    });
  } catch (e) {
    throw new Error('AI 服务暂不可用（后端未启动？），请稍后重试。');
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  const buildDraftFromResponse = () => {
    const draftInput = (data && (data.recipe || data.content)) || (
      data?.fallbackUsed
        ? {
            name: 'AI 导入菜谱草稿',
            tags: ['AI草稿', '视频导入'],
            ingredients: [],
            seasonings: [],
            method: ['视频文字已读取成功，但菜谱结构化结果不完整，请根据原文预览手动整理。'],
            warnings: ['视频文字已读取成功，但 AI 整理菜谱失败。当前草稿需要人工确认。'],
            needsReview: true
          }
        : ''
    );
    const draft = validateImportedRecipe(draftInput, {
      evidence: data?.evidence || null,
      diagnostics: data?.diagnostics || null,
      debugEvidenceSummary: data?.debugEvidenceSummary || null,
      sourceType: 'xiaohongshu'
    });
    if (data?.mediaDiagnostics) draft.mediaDiagnostics = data.mediaDiagnostics;
    if (data?.fallbackUsed) draft.fallbackUsed = true;
    if (data?.fallbackReason) draft.fallbackReason = String(data.fallbackReason);
    if (data?.importTextReady) draft.importTextReady = true;
    return draft;
  };
  if (!res.ok) {
    if (data && (data.recipe || data.content || data.fallbackUsed)) {
      return buildDraftFromResponse();
    }
    throw createCloudAiError({
      status: data?.status || res.status,
      code: data?.code || data?.upstreamCode || '',
      upstreamStatus: data?.upstreamStatus || 0,
      upstreamCode: data?.upstreamCode || '',
      detail: data?.detail || data?.error || data?.message || 'AI 解析失败',
      importTextReady: Boolean(data?.importTextReady),
      mediaDiagnostics: data?.mediaDiagnostics || null,
      transcriptPreview: data?.transcriptPreview || '',
      ocrPreview: data?.ocrPreview || '',
      pageTextPreview: data?.pageTextPreview || '',
      fallback: 'AI 解析失败'
    });
  }
  return buildDraftFromResponse();
}

/**
 * 解析外部菜谱来源（优先小红书/网页链接，其次手动文字/图片文件）→ 可编辑菜谱草稿。
 * @param {{ url?: string, file?: File }} input
 * @returns {Promise<{name, tags, ingredients:[{item,qty,unit}], method, isAiDraft, draftSource}>}
 */
export async function importRecipeFromSource({ url = '', file = null, text = '' } = {}) {
  const cleanUrl = String(url || '').trim();
  const pastedText = String(text || '').trim();
  if (!cleanUrl && !file && !pastedText) throw new Error('请粘贴链接或菜谱文字。');
  const isXiaohongshuUrl = /(?:xhslink|xiaohongshu|小红书)/i.test(cleanUrl);

  // 图片文件 → 走视觉解析；视频文件暂不支持逐帧，链接导入仍是主流程。
  let imageBase64 = null;
  if (file) {
    if (/^image\//.test(file.type)) imageBase64 = await compressImage(file);
    else if (!cleanUrl) throw new Error('暂不支持直接解析视频文件，请粘贴小红书链接或菜谱文字。');
  }

  if (cleanUrl && isXiaohongshuUrl && !imageBase64) {
    try {
      return await importXiaohongshuRecipeFromUrl({ url: cleanUrl, userText: pastedText });
    } catch (err) {
      if (isRateLimitExceededError(err) || isRecipeJsonFailedError(err)) throw err;
      if (!pastedText) throw err;
      return parseRecipeWith120B({
        text: pastedText,
        sourceType: 'manual',
        sourceMetadata: {
          url: cleanUrl,
          finalUrl: '',
          extractionMode: 'link-fallback-text',
          warnings: ['链接解析失败，已改用粘贴文字生成草稿。'],
          hasUserSupplement: true,
          userSupplementPreview: pastedText.slice(0, 300)
        }
      });
    }
  }

  // 链接 → 抓取页面文字；textarea 中链接以外的内容作为补充上下文。
  let sourceText = '';
  let sourceMetadata = null;
  if (cleanUrl) {
    try {
      const linkSource = await fetchRecipeSource(cleanUrl);
      sourceText = pastedText
        ? `【链接提取内容】\n${linkSource.text}\n\n【用户补充内容】\n${pastedText}`
        : linkSource.text;
      sourceMetadata = {
        ...(linkSource.metadata || {}),
        ...(pastedText
          ? {
              hasUserSupplement: true,
              userSupplementPreview: pastedText.slice(0, 300)
            }
          : {})
      };
    } catch (err) {
      if (!pastedText) throw err;
      sourceText = pastedText;
      sourceMetadata = {
        url: cleanUrl,
        finalUrl: '',
        extractionMode: 'link-fallback-text',
        warnings: ['链接解析失败，已改用粘贴文字生成草稿。'],
        hasUserSupplement: true,
        userSupplementPreview: pastedText.slice(0, 300)
      };
    }
  } else {
    sourceText = pastedText;
  }

  if (!sourceText && !imageBase64) throw new Error('没有可解析的链接文字，请粘贴链接或菜谱文字。');

  let sourceType = pastedText ? 'manual' : 'manual';
  if (cleanUrl) {
    sourceType = isXiaohongshuUrl ? 'xiaohongshu' : 'web';
  } else if (file && /^video\//.test(file.type)) {
    sourceType = 'video';
  }

  return parseRecipeWith120B({ text: sourceText, imageBase64, sourceType, sourceMetadata });
}
