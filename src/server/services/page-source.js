/*
 * src/server/services/page-source.js —— 页面抓取与解析：meta/JSON-LD/INITIAL_STATE 文案提取、媒体地址收集挑选、社交文案清洗分段、来源载荷组装。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */
const net = require('net');
const {
  createPublicApiError
} = require('./ai-client');
const {
  extractBalancedJsonObject,
  parseJsonParseCall,
  safeParseJsonText
} = require('../utils/json');
const {
  SSRF_ERROR,
  extractHttpUrl,
  fetchFollowingRedirectsSafely,
  isBlockedHostname,
  isBlockedIp,
  normalizeIp
} = require('./ssrf-guard');
const {
  uniqueTextList
} = require('../utils/text');

function decodeHtmlText(value) {
  return String(value || '')
    .replace(/\\u([0-9a-fA-F]{4})/g, (_m, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\n/g, '\n')
    .replace(/\\"/g, '"')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

function stripHtmlTags(html) {
  return decodeHtmlText(String(html || '')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' '));
}

function getHtmlAttr(tag, attrName) {
  const re = new RegExp(`${attrName}\\s*=\\s*["']([^"']*)["']`, 'i');
  const match = String(tag || '').match(re);
  return match ? decodeHtmlText(match[1]) : '';
}

function extractMetaContent(html, matcher) {
  const tags = String(html || '').match(/<meta\b[^>]*>/gi) || [];
  for (const tag of tags) {
    const property = getHtmlAttr(tag, 'property').toLowerCase();
    const name = getHtmlAttr(tag, 'name').toLowerCase();
    if (matcher({ property, name })) {
      const content = getHtmlAttr(tag, 'content');
      if (content) return content;
    }
  }
  return '';
}

function extractMetaContents(html, matcher) {
  const tags = String(html || '').match(/<meta\b[^>]*>/gi) || [];
  const output = [];
  for (const tag of tags) {
    const property = getHtmlAttr(tag, 'property').toLowerCase();
    const name = getHtmlAttr(tag, 'name').toLowerCase();
    if (matcher({ property, name })) {
      const content = getHtmlAttr(tag, 'content');
      if (content) output.push(content);
    }
  }
  return uniqueTextList(output, 20);
}

function extractCanonicalUrl(html, finalUrl = '') {
  const tags = String(html || '').match(/<link\b[^>]*>/gi) || [];
  for (const tag of tags) {
    const rel = getHtmlAttr(tag, 'rel').toLowerCase();
    if (!rel.split(/\s+/).includes('canonical')) continue;
    const href = getHtmlAttr(tag, 'href');
    if (!href) continue;
    try {
      const parsed = new URL(href, finalUrl || undefined);
      if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
        parsed.hash = '';
        return parsed.href;
      }
    } catch (_) {}
  }
  return finalUrl;
}

function collectInstructionText(value, output = [], depth = 0) {
  if (value == null || depth > 8 || output.length >= 60) return output;
  if (typeof value === 'string') {
    const text = stripHtmlTags(value);
    if (text) output.push(text);
    return output;
  }
  if (Array.isArray(value)) {
    value.forEach(item => collectInstructionText(item, output, depth + 1));
    return output;
  }
  if (typeof value !== 'object') return output;
  const directText = value.text || value.description || value.name;
  if (typeof directText === 'string') {
    const text = stripHtmlTags(directText);
    if (text) output.push(text);
  }
  if (value.itemListElement) collectInstructionText(value.itemListElement, output, depth + 1);
  if (value.steps) collectInstructionText(value.steps, output, depth + 1);
  if (value.recipeInstructions) collectInstructionText(value.recipeInstructions, output, depth + 1);
  return output;
}

function collectIngredientText(value) {
  const items = [];
  collectInstructionText(value, items);
  return uniqueTextList(items, 40).join('、');
}

function collectStructuredTextFromObject(value, output = [], depth = 0) {
  if (!value || depth > 8 || output.length >= 80) return output;
  if (Array.isArray(value)) {
    value.forEach(item => collectStructuredTextFromObject(item, output, depth + 1));
    return output;
  }
  if (typeof value !== 'object') return output;
  const keys = ['name', 'title', 'desc', 'description', 'noteText', 'content', 'caption', 'summary', 'subtitle', 'text'];
  for (const key of keys) {
    if (typeof value[key] === 'string') output.push(value[key]);
  }
  const ingredientKeys = ['recipeIngredient', 'ingredients'];
  for (const key of ingredientKeys) {
    if (value[key]) {
      const ingredientText = collectIngredientText(value[key]);
      if (ingredientText) output.push(`食材：${ingredientText}`);
    }
  }
  const instructionKeys = ['recipeInstructions', 'instructions', 'steps', 'method'];
  for (const key of instructionKeys) {
    if (value[key]) {
      const instructionText = uniqueTextList(collectInstructionText(value[key], []), 60).join('\n');
      if (instructionText) output.push(`做法：${instructionText}`);
    }
  }
  if (value.shareInfo && typeof value.shareInfo === 'object') {
    collectStructuredTextFromObject(value.shareInfo, output, depth + 1);
  }
  for (const item of Object.values(value)) {
    if (item && typeof item === 'object') collectStructuredTextFromObject(item, output, depth + 1);
  }
  return output;
}

function extractJsonLdText(html) {
  const output = [];
  const scripts = String(html || '').match(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>[\s\S]*?<\/script>/gi) || [];
  scripts.forEach(script => {
    const body = script.replace(/^<script\b[^>]*>/i, '').replace(/<\/script>$/i, '').trim();
    const parsed = safeParseJsonText(decodeHtmlText(body));
    collectStructuredTextFromObject(parsed, output);
  });
  return uniqueTextList(output, 16).join('\n');
}

function extractInitialStateText(html) {
  const output = [];
  const scripts = String(html || '').match(/<script\b[^>]*>[\s\S]*?<\/script>/gi) || [];
  scripts.forEach(script => {
    if (/type=["']application\/ld\+json["']/i.test(script)) return;
    if (!/(__INITIAL_STATE__|__NEXT_DATA__|hydration|note|desc|title|shareInfo)/i.test(script)) return;
    const body = script.replace(/^<script\b[^>]*>/i, '').replace(/<\/script>$/i, '').trim();
    const nextData = /id=["']__NEXT_DATA__["']/i.test(script) ? safeParseJsonText(decodeHtmlText(body)) : null;
    collectStructuredTextFromObject(nextData, output);
    const assignmentPattern = /(?:window\.)?__(?:INITIAL_STATE|NEXT_DATA)__\s*=\s*/gi;
    let assignment;
    while ((assignment = assignmentPattern.exec(body))) {
      const afterAssignment = body.slice(assignmentPattern.lastIndex);
      const jsonParseObject = parseJsonParseCall(afterAssignment);
      if (jsonParseObject) {
        collectStructuredTextFromObject(jsonParseObject, output);
      } else {
        const balancedObject = extractBalancedJsonObject(body, assignmentPattern.lastIndex);
        if (balancedObject) collectStructuredTextFromObject(safeParseJsonText(decodeHtmlText(balancedObject)), output);
      }
    }
    const fieldPattern = /["']?(?:desc|title|content|noteText|description|caption|summary)["']?\s*:\s*(["'])((?:\\.|(?!\1)[\s\S])*?)\1/g;
    let field;
    while ((field = fieldPattern.exec(body))) {
      output.push(field[2]);
    }
  });
  return uniqueTextList(output.map(decodeHtmlText), 24).join('\n');
}

function extractVisibleText(html) {
  const bodyMatch = String(html || '').match(/<body\b[^>]*>([\s\S]*?)<\/body>/i);
  const body = bodyMatch ? bodyMatch[1] : html;
  return stripHtmlTags(body).slice(0, 4000);
}

function guessSourceTypeFromUrl(url) {
  return /(?:xhslink|xiaohongshu|小红书)/i.test(String(url || '')) ? 'xiaohongshu' : 'web';
}

function getStructuredRecipeText(parts) {
  const structuredText = uniqueTextList(parts, 60).join('\n').trim();
  if (!structuredText) return '';
  const split = splitRecipeSourceText(structuredText);
  return uniqueTextList([
    ...split.sourceBuckets.trusted,
    ...split.sourceBuckets.weak.filter(line => line && !isHashtagOnlyLine(line) && !isSocialNoiseLine(line))
  ], 40).join('\n').trim();
}

function hasContinuousRecipeSteps(text) {
  const raw = String(text || '').trim();
  if (!raw) return false;
  const segments = splitRawSourceIntoCandidateSegments(raw)
    .map(normalizeSourceLine)
    .filter(Boolean);
  const actionSegments = segments.filter(segment => RECIPE_SIGNAL_PATTERN.test(segment));
  if (actionSegments.length >= 3) return true;
  const actionMatches = raw.match(/洗净|擦干|去骨|切|改刀|加入|放入|倒入|撒入|腌|腌制|抓匀|拌匀|煎|炒|焖|炖|煮|蒸|烤|炸|空气炸|调味|翻炒|出锅|装盘/gu) || [];
  return actionMatches.length >= 4 && /[。；;\n]/u.test(raw);
}

function chooseRecipeExtractionMode({ initialStateText, jsonLdText, metaText, visibleText }) {
  if (initialStateText) return 'initial-state';
  if (jsonLdText) return 'json-ld';
  if (metaText) return 'meta';
  if (visibleText) return 'html-text';
  return 'link-only';
}

const MEDIA_URL_PATTERN = /https?:\/\/[^\s"'<>`),\]]+/gi;
const VIDEO_FIELD_PATTERN = /(?:^|\.|_)(video|videourl|video_url|masterurl|master_url|streamurl|stream_url|h264|h265|backupurls|backup_urls|originvideokey|origin_video_key)(?:$|\.|_)/i;
const IMAGE_FIELD_PATTERN = /(?:^|\.|_)(image|images|imagelist|image_list|img|photo|photos|poster)(?:$|\.|_)/i;
const COVER_FIELD_PATTERN = /(?:^|\.|_)(cover|coverurl|cover_url|poster)(?:$|\.|_)/i;
const VIDEO_URL_HINT_PATTERN = /\.(?:mp4|m3u8)(?:[?#]|$)|video|stream|sns-video|vod|h264|h265/i;
const IMAGE_URL_HINT_PATTERN = /\.(?:jpe?g|png|webp|gif|avif)(?:[?#]|$)|image|cover|sns-img|photo/i;
const STRONG_VIDEO_FIELD_PATTERN = /(?:^|\.|_)(playurl|play_url|masterurl|master_url|streamurl|stream_url|h264|h265|backupurls|backup_urls|videourl|video_url)(?:$|\.|_)/i;

function normalizeMediaUrl(candidate) {
  const cleaned = decodeHtmlText(candidate)
    .replace(/\\\//g, '/')
    .replace(/[\\，。、,.;；]+$/g, '')
    .trim();
  if (!/^https?:\/\//i.test(cleaned)) return '';
  try {
    const parsed = new URL(cleaned);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return '';
    if (isBlockedHostname(parsed.hostname)) return '';
    if (net.isIP(normalizeIp(parsed.hostname)) && isBlockedIp(parsed.hostname)) return '';
    return parsed.href;
  } catch (_) {
    return '';
  }
}

function extractHttpUrlsFromText(text) {
  const normalized = decodeHtmlText(text)
    .replace(/\\u002f/gi, '/')
    .replace(/\\\//g, '/');
  return uniqueTextList((normalized.match(MEDIA_URL_PATTERN) || []).map(normalizeMediaUrl).filter(Boolean), 80);
}

function parsePublicHttpUrl(url) {
  const normalized = normalizeMediaUrl(url);
  if (!normalized) return null;
  try {
    const parsed = new URL(normalized);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    return parsed;
  } catch (_) {
    return null;
  }
}

function isXiaohongshuPageUrl(url) {
  const parsed = parsePublicHttpUrl(url);
  if (!parsed) return false;
  const host = parsed.hostname.toLowerCase();
  const pathname = parsed.pathname.toLowerCase();
  if (!host.includes('xiaohongshu.com')) return false;
  if (pathname.includes('/discovery/item') || pathname.includes('/explore')) return true;
  return !VIDEO_URL_HINT_PATTERN.test(`${host}${pathname}`);
}

function scoreVideoMediaUrl(url) {
  const parsed = parsePublicHttpUrl(url);
  if (!parsed) return -1000;
  const host = parsed.hostname.toLowerCase();
  const pathname = parsed.pathname.toLowerCase();
  const full = parsed.href.toLowerCase();
  if (host.includes('xiaohongshu.com') && (pathname.includes('/discovery/item') || pathname.includes('/explore'))) return -1000;
  if (host.includes('xiaohongshu.com') && !VIDEO_URL_HINT_PATTERN.test(full)) return -1000;

  let score = 0;
  if (/\.mp4(?:[?#]|$)/i.test(full)) score += 100;
  if (/\.m3u8(?:[?#]|$)/i.test(full)) score += 90;
  if (/sns-video/i.test(full)) score += 80;
  if (/xhscdn\.com/i.test(host)) score += 60;
  if (/\/stream\//i.test(pathname)) score += 50;
  if (/h264|h265/i.test(full)) score += 30;
  if (/video|vod/i.test(full)) score += 20;
  return score || -100;
}

function isLikelyVideoMediaUrl(url) {
  const parsed = parsePublicHttpUrl(url);
  if (!parsed || isXiaohongshuPageUrl(parsed.href)) return false;
  return scoreVideoMediaUrl(parsed.href) > 0;
}

function pickBestVideoUrl(videoUrls = []) {
  const candidates = uniqueTextList((Array.isArray(videoUrls) ? videoUrls : [])
    .map(normalizeMediaUrl)
    .filter(Boolean), 40)
    .filter(isLikelyVideoMediaUrl)
    .sort((a, b) => scoreVideoMediaUrl(b) - scoreVideoMediaUrl(a));
  return candidates[0] || '';
}

function buildVideoUrlSelectionDiagnostics(videoUrls = [], selectedVideoUrl = '') {
  const normalized = uniqueTextList((Array.isArray(videoUrls) ? videoUrls : [])
    .map(normalizeMediaUrl)
    .filter(Boolean), 40);
  const rejected = normalized.filter(url => !isLikelyVideoMediaUrl(url));
  const rejectedHosts = uniqueTextList(rejected.map(url => {
    try { return new URL(url).hostname; } catch (_) { return ''; }
  }).filter(Boolean), 8);
  return {
    selectedVideoUrlRanked: Boolean(selectedVideoUrl),
    rejectedVideoUrlCount: rejected.length,
    rejectedVideoUrlHosts: rejectedHosts
  };
}

function mergeVideoUrlSelectionDiagnostics(primary = {}, secondary = {}) {
  return {
    selectedVideoUrlRanked: Boolean(primary.selectedVideoUrlRanked),
    rejectedVideoUrlCount: Number(primary.rejectedVideoUrlCount || 0) + Number(secondary.rejectedVideoUrlCount || 0),
    rejectedVideoUrlHosts: uniqueTextList([
      ...(Array.isArray(primary.rejectedVideoUrlHosts) ? primary.rejectedVideoUrlHosts : []),
      ...(Array.isArray(secondary.rejectedVideoUrlHosts) ? secondary.rejectedVideoUrlHosts : [])
    ], 8)
  };
}

function createMediaAccumulator() {
  const video = [];
  const image = [];
  const cover = [];
  const rejectedVideo = [];
  const seen = {
    video: new Set(),
    image: new Set(),
    cover: new Set()
  };
  const hints = [];
  const seenHints = new Set();

  function addHint(hint) {
    if (hint && !seenHints.has(hint)) {
      seenHints.add(hint);
      hints.push(hint);
    }
  }

  function addUrl(rawUrl, bucket, hint = '') {
    const url = normalizeMediaUrl(rawUrl);
    if (!url || !seen[bucket] || seen[bucket].has(url)) return;
    if (bucket === 'video' && !isLikelyVideoMediaUrl(url)) {
      if (!rejectedVideo.includes(url)) rejectedVideo.push(url);
      addHint(hint ? `${hint}:rejected-non-media-video` : 'rejected-non-media-video');
      return;
    }
    seen[bucket].add(url);
    if (bucket === 'video') video.push(url);
    if (bucket === 'image') image.push(url);
    if (bucket === 'cover') cover.push(url);
    addHint(hint);
  }

  return { video, image, cover, rejectedVideo, hints, addUrl, addHint };
}

function classifyMediaUrl(url, keyPath = '') {
  const hint = String(keyPath || '');
  if (isXiaohongshuPageUrl(url)) return '';
  if (COVER_FIELD_PATTERN.test(hint)) return 'cover';
  if (IMAGE_FIELD_PATTERN.test(hint) && !VIDEO_FIELD_PATTERN.test(hint)) return 'image';
  const urlLooksVideo = isLikelyVideoMediaUrl(url);
  const strongVideoField = STRONG_VIDEO_FIELD_PATTERN.test(hint);
  if (urlLooksVideo && (strongVideoField || VIDEO_URL_HINT_PATTERN.test(url) || VIDEO_FIELD_PATTERN.test(hint))) return 'video';
  if (IMAGE_URL_HINT_PATTERN.test(url)) return 'image';
  return '';
}

function collectMediaFromObject(value, media, keyPath = '', depth = 0) {
  if (value == null || depth > 8) return;
  if (typeof value === 'string') {
    for (const url of extractHttpUrlsFromText(value)) {
      const bucket = classifyMediaUrl(url, keyPath);
      if (bucket) media.addUrl(url, bucket, keyPath ? `script-field:${keyPath}` : 'script-url');
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach(item => collectMediaFromObject(item, media, keyPath, depth + 1));
    return;
  }
  if (typeof value !== 'object') return;
  for (const [key, item] of Object.entries(value)) {
    const nextPath = keyPath ? `${keyPath}.${key}` : key;
    collectMediaFromObject(item, media, nextPath, depth + 1);
  }
}

function collectMediaFromScript(script, media) {
  const body = script.replace(/^<script\b[^>]*>/i, '').replace(/<\/script>$/i, '').trim();
  const isInitialState = /__(?:INITIAL_STATE|NEXT_DATA)__|hydration/i.test(script);
  const hint = isInitialState ? 'initial-state' : 'script';

  for (const url of extractHttpUrlsFromText(body)) {
    const bucket = classifyMediaUrl(url, body.slice(Math.max(0, body.indexOf(url) - 80), body.indexOf(url) + 80));
    if (bucket) media.addUrl(url, bucket, `${hint}:url-scan`);
  }

  const parsedScriptJson = safeParseJsonText(decodeHtmlText(body));
  collectMediaFromObject(parsedScriptJson, media, hint);
  const parsedJsonString = parseJsonParseCall(body);
  collectMediaFromObject(parsedJsonString, media, hint);

  const assignmentPattern = /(?:window\.)?__(?:INITIAL_STATE|NEXT_DATA)__\s*=\s*/gi;
  let assignment;
  while ((assignment = assignmentPattern.exec(body))) {
    const afterAssignment = body.slice(assignmentPattern.lastIndex);
    collectMediaFromObject(parseJsonParseCall(afterAssignment), media, 'initial-state');
    const balancedObject = extractBalancedJsonObject(body, assignmentPattern.lastIndex);
    if (balancedObject) collectMediaFromObject(safeParseJsonText(decodeHtmlText(balancedObject)), media, 'initial-state');
  }
}

// 从页面源码中提取媒体 URL 供诊断；不下载、不探测、不请求这些 URL。
function extractMediaFromHtml(html, context = {}) {
  const media = createMediaAccumulator();
  const source = String(html || '');

  const metaVideoUrls = extractMetaContents(source, ({ property, name }) => (
    ['og:video', 'og:video:url', 'og:video:secure_url', 'video', 'twitter:player:stream'].includes(property)
    || ['og:video', 'og:video:url', 'og:video:secure_url', 'video', 'twitter:player:stream'].includes(name)
  ));
  metaVideoUrls.forEach(url => media.addUrl(url, 'video', 'meta-video'));

  const metaImageUrls = extractMetaContents(source, ({ property, name }) => (
    ['og:image', 'og:image:url', 'og:image:secure_url', 'twitter:image'].includes(property)
    || ['og:image', 'og:image:url', 'og:image:secure_url', 'twitter:image'].includes(name)
  ));
  metaImageUrls.forEach(url => media.addUrl(url, 'cover', 'meta-image'));

  const videoTags = source.match(/<video\b[^>]*>/gi) || [];
  videoTags.forEach(tag => {
    media.addUrl(getHtmlAttr(tag, 'src'), 'video', 'video-tag');
    media.addUrl(getHtmlAttr(tag, 'poster'), 'cover', 'video-poster');
  });
  const sourceTags = source.match(/<source\b[^>]*>/gi) || [];
  sourceTags.forEach(tag => media.addUrl(getHtmlAttr(tag, 'src'), 'video', 'source-tag'));

  const imageTags = source.match(/<img\b[^>]*>/gi) || [];
  imageTags.forEach(tag => {
    const src = getHtmlAttr(tag, 'src') || getHtmlAttr(tag, 'data-src');
    if (src) media.addUrl(src, 'image', 'img-tag');
  });

  const scripts = source.match(/<script\b[^>]*>[\s\S]*?<\/script>/gi) || [];
  scripts.forEach(script => collectMediaFromScript(script, media));

  media.video.sort((a, b) => scoreVideoMediaUrl(b) - scoreVideoMediaUrl(a));
  return {
    videoUrls: media.video.slice(0, 20),
    imageUrls: media.image.slice(0, 30),
    coverUrls: media.cover.slice(0, 20),
    mediaDiagnostics: {
      hasVideo: media.video.length > 0,
      videoUrlCount: media.video.length,
      imageUrlCount: media.image.length,
      rejectedVideoUrlCount: media.rejectedVideo.length,
      rejectedVideoUrlHosts: uniqueTextList(media.rejectedVideo.map(url => {
        try { return new URL(url).hostname; } catch (_) { return ''; }
      }).filter(Boolean), 8),
      extractionHints: media.hints,
      sourceType: guessSourceTypeFromUrl(context.finalUrl || context.url || '')
    }
  };
}

// 从小红书/网页源码尽力提取链接页面文字。只返回页面可抓取字段，不执行 JS、不下载视频。
function extractRecipeSourceFromHtml(html, { url = '', finalUrl = '' } = {}) {
  const titleText = decodeHtmlText((String(html || '').match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || '');
  const ogTitle = extractMetaContent(html, ({ property, name }) => property === 'og:title' || name === 'og:title');
  const ogDescription = extractMetaContent(html, ({ property, name }) => property === 'og:description' || name === 'og:description');
  const metaDescription = extractMetaContent(html, ({ name }) => name === 'description');
  const twitterTitle = extractMetaContent(html, ({ property, name }) => property === 'twitter:title' || name === 'twitter:title');
  const twitterDescription = extractMetaContent(html, ({ property, name }) => property === 'twitter:description' || name === 'twitter:description');
  const jsonLdText = extractJsonLdText(html);
  const initialStateText = extractInitialStateText(html);
  const visibleText = extractVisibleText(html);
  const visibleSplit = splitRecipeSourceText(visibleText);
  const visibleTextPreview = visibleText.slice(0, 500);
  const sourceTitle = ogTitle || twitterTitle || titleText;
  const sourceAuthor = extractMetaContent(
    html,
    ({ property, name }) => property === 'article:author' || name === 'author'
  );
  const metaModeText = getStructuredRecipeText([
    ogTitle,
    ogDescription,
    metaDescription,
    twitterTitle,
    twitterDescription
  ]);
  const metaText = getStructuredRecipeText([
    ogTitle,
    ogDescription,
    metaDescription,
    twitterTitle,
    twitterDescription,
    titleText
  ]);
  const jsonLdRecipeText = getStructuredRecipeText([jsonLdText]);
  const initialStateRecipeText = getStructuredRecipeText([initialStateText]);
  const trustedText = uniqueTextList([
    initialStateRecipeText,
    jsonLdRecipeText,
    metaText,
    visibleSplit.cleanedRecipeText
  ], 40).join('\n').trim();
  const rawText = uniqueTextList([
    ogTitle,
    ogDescription,
    metaDescription,
    twitterTitle,
    twitterDescription,
    titleText,
    jsonLdText,
    initialStateText,
    visibleText
  ], 40).join('\n').trim();
  const split = splitRecipeSourceText(trustedText || visibleText);
  const textForWarnings = trustedText || split.cleanedRecipeText || visibleSplit.cleanedRecipeText || rawText;
  const warnings = [];
  if (!jsonLdText && !initialStateText && !ogDescription && !metaDescription && !twitterDescription) {
    warnings.push('当前链接只能解析到部分页面文字，平台可能限制了视频内容读取，菜谱可能需要人工确认。');
  }
  if (!split.cleanedRecipeText) {
    warnings.push('未从链接页面文字中提取到明确配料或步骤。');
  }
  if (textForWarnings.length > 0 && textForWarnings.length < 100) {
    warnings.push('链接可提取内容较少，可能需要人工确认。');
  }
  if (textForWarnings && !hasContinuousRecipeSteps(textForWarnings)) {
    warnings.push('未提取到完整做法步骤。');
  }
  return {
    url,
    finalUrl,
    sourceType: guessSourceTypeFromUrl(finalUrl || url),
    extractionMode: chooseRecipeExtractionMode({
      initialStateText: initialStateRecipeText,
      jsonLdText: jsonLdRecipeText,
      metaText: metaModeText,
      visibleText: visibleSplit.cleanedRecipeText
    }),
    hasHtml: Boolean(html),
    hasStructuredMeta: Boolean(ogTitle || ogDescription || metaDescription || twitterTitle || twitterDescription || titleText),
    hasOgDescription: Boolean(ogDescription),
    hasJsonLd: Boolean(jsonLdText),
    hasInitialState: Boolean(initialStateText),
    titleText,
    metaDescription,
    ogTitle,
    ogDescription,
    twitterTitle,
    twitterDescription,
    jsonLdText,
    initialStateText,
    authorCaptionText: split.authorCandidateText,
    sourceTitle,
    sourceAuthor,
    visibleTextPreview,
    rawText,
    trustedText,
    weakText: split.weakRecipeHints.join('\n'),
    excludedTextPreview: split.excludedSocialTextPreview,
    cleanedRecipeText: split.cleanedRecipeText,
    sourceBuckets: split.sourceBuckets,
    sourceSegmentsPreview: split.sourceSegmentsPreview,
    warnings
  };
}

// Backward-compatible helper for older tests/callers.
function extractXhsText(html) {
  const source = extractRecipeSourceFromHtml(html);
  return source.trustedText || source.cleanedRecipeText || '';
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
const COMMENT_STYLE_PATTERN = /^(?:评论[:：]?|如果|可以|建议|为啥|为什么|是不是|求|老师|我|你|他|她|这|太|好|希望|感觉|觉得|评论区)/u;

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
  const isExplicitCommentRequest = /^(?:评论[:：]?|求教程|求做法|求配方|求比例)/u.test(normalizedText);

  if (isExplicitCommentRequest) {
    return { text, normalizedText, type: 'comment', reasons: ['comment-request'] };
  }
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

function segmentSocialRecipeText(rawText) {
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


function splitRecipeSourceText(rawText) {
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

function buildRecipeSourcePayload({ startUrl, fetched, html, source, media, allowEmptyText = false }) {
  const text = source.trustedText || source.cleanedRecipeText || '';
  if (!text && !allowEmptyText) {
    throw createPublicApiError(422, '没能从链接页面文字中提取到菜谱文案，请稍后重试或手动编辑。', 'no_recipe_text');
  }
  const sourceSplit = splitRecipeSourceText(text);
  const warnings = uniqueTextList([
    ...source.warnings,
    ...(media.mediaDiagnostics.hasVideo ? [] : ['未从页面中提取到可用视频地址。'])
  ], 12);
  return {
    text,
    finalUrl: fetched.finalUrl,
    canonicalUrl: extractCanonicalUrl(html, fetched.finalUrl),
    url: startUrl.href,
    sourceTitle: source.sourceTitle || '',
    sourceAuthor: source.sourceAuthor || '',
    extractionMode: source.extractionMode,
    hasHtml: source.hasHtml,
    hasStructuredMeta: source.hasStructuredMeta,
    hasOgDescription: source.hasOgDescription,
    hasJsonLd: source.hasJsonLd,
    hasInitialState: source.hasInitialState,
    trustedText: source.trustedText,
    trustedTextLength: source.trustedText.length,
    trustedTextPreview: source.trustedText.slice(0, 500),
    rawTextLength: source.rawText.length,
    rawTextPreview: source.rawText.slice(0, 500),
    warnings,
    cleanedRecipeText: sourceSplit.cleanedRecipeText,
    excludedSocialTextPreview: sourceSplit.excludedSocialTextPreview,
    sourceBuckets: sourceSplit.sourceBuckets,
    sourceSegmentsPreview: sourceSplit.sourceSegmentsPreview,
    media
  };
}

async function extractRecipeSourcePayloadFromUrl(urlInput, { allowEmptyText = false } = {}) {
  const startUrl = extractHttpUrl(urlInput);
  if (!startUrl) {
    throw createPublicApiError(400, '仅支持 http/https 链接。', 'invalid_url');
  }

  let fetched;
  try {
    fetched = await fetchFollowingRedirectsSafely(startUrl, 5);
  } catch (err) {
    if (err === SSRF_ERROR) {
      throw createPublicApiError(400, '不支持的链接地址，请粘贴公开的小红书/网页链接或菜谱文字。', 'blocked_url');
    }
    throw createPublicApiError(502, '链接抓取失败，请稍后重试或粘贴菜谱文字。', 'fetch_failed');
  }

  const html = String(fetched.resp.data || '');
  if (/(?:请先登录|登录后查看|扫码登录|login\s+required)/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
    throw createPublicApiError(401, '该内容需要登录后才能访问。', 'login_required');
  }
  if (/验证码|滑块验证|滑动验证|安全验证|captcha/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
    throw createPublicApiError(502, '链接被平台验证拦截，当前只能解析公开页面文字。', 'blocked_by_captcha');
  }

  const source = extractRecipeSourceFromHtml(html, { url: startUrl.href, finalUrl: fetched.finalUrl });
  const media = extractMediaFromHtml(html, { url: startUrl.href, finalUrl: fetched.finalUrl });
  return buildRecipeSourcePayload({ startUrl, fetched, html, source, media, allowEmptyText });
}

// 代理路由：抓取并返回菜谱文案。

module.exports = {
  AUTHOR_RECIPE_DESCRIPTION_PATTERN,
  COMMENT_STYLE_PATTERN,
  COVER_FIELD_PATTERN,
  HASHTAG_PATTERN,
  IMAGE_FIELD_PATTERN,
  IMAGE_URL_HINT_PATTERN,
  LEADING_EMOJI_PATTERN,
  MEDIA_URL_PATTERN,
  RECIPE_SIGNAL_PATTERN,
  SOCIAL_DISTRACTOR_PATTERN,
  SOCIAL_EMOJI_PATTERN,
  SOCIAL_NOISE_PATTERN,
  SOCIAL_SEGMENT_MARKER_GLOBAL_PATTERN,
  SOCIAL_SEGMENT_MARKER_PATTERN,
  STRONG_VIDEO_FIELD_PATTERN,
  VIDEO_FIELD_PATTERN,
  VIDEO_URL_HINT_PATTERN,
  buildRecipeSourcePayload,
  buildVideoUrlSelectionDiagnostics,
  chooseRecipeExtractionMode,
  classifyMediaUrl,
  classifyRecipeSourceSegment,
  cleanAuthorCandidateLine,
  collectIngredientText,
  collectInstructionText,
  collectMediaFromObject,
  collectMediaFromScript,
  collectStructuredTextFromObject,
  createMediaAccumulator,
  decodeHtmlText,
  extractHttpUrlsFromText,
  extractInitialStateText,
  extractJsonLdText,
  extractMediaFromHtml,
  extractMetaContent,
  extractMetaContents,
  extractRecipeSourceFromHtml,
  extractRecipeSourcePayloadFromUrl,
  extractVisibleText,
  extractXhsText,
  getHtmlAttr,
  getStructuredRecipeText,
  guessSourceTypeFromUrl,
  hasContinuousRecipeSteps,
  isHashtagOnlyLine,
  isLikelyVideoMediaUrl,
  isSocialNoiseLine,
  isTrustedRecipeLine,
  isXiaohongshuPageUrl,
  mergeVideoUrlSelectionDiagnostics,
  normalizeMediaUrl,
  normalizeSourceLine,
  parsePublicHttpUrl,
  pickBestVideoUrl,
  scoreVideoMediaUrl,
  segmentSocialRecipeText,
  splitRawSourceIntoCandidateSegments,
  splitRecipeSourceText,
  stripHtmlTags
};
