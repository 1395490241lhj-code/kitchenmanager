/*
 * src/server/services/media-pipeline.js —— 视频导入媒体管道：安全下载(限80MB)、ffmpeg 抽音频/关键帧、ASR、视觉 OCR、结果缓存与临时文件回收。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const axios = require('axios');
const { spawn } = require('child_process');
const {
  MEDIA_DOWNLOAD_ERROR,
  MEDIA_DOWNLOAD_TIMEOUT_MS,
  MEDIA_FFMPEG_ERROR,
  MEDIA_FILE_TTL_MS,
  MEDIA_MAX_FRAME_BYTES,
  MEDIA_MAX_FRAME_COUNT,
  MEDIA_MAX_VIDEO_BYTES,
  MEDIA_TMP_DIR,
  MEDIA_TOO_LARGE_ERROR,
  MOBILE_UA,
  OPENAI_API_KEY,
  OPENAI_BASE_URL,
  OPENAI_TRANSCRIBE_MODEL,
  OPENAI_VISION_MODEL,
  RECIPE_IMPORT_MEDIA_CACHE_TTL_MS
} = require('../config');
const {
  getAiMessageContent,
  getUpstreamAiErrorInfo,
  isRateLimitExceeded,
  redactSecret,
  resolveAudioTranscriptionsUrl,
  resolveChatUrl
} = require('./ai-client');
const {
  safeParseModelJson
} = require('../utils/json');
const {
  SSRF_ERROR,
  createPinnedLookup,
  extractHttpUrl,
  resolveAndValidatePublicUrl
} = require('./ssrf-guard');
const {
  uniqueTextList
} = require('../utils/text');

let ffmpegPath = '';
try {
  ffmpegPath = require('ffmpeg-static') || '';
} catch (_) {
  ffmpegPath = '';
}

const recipeImportMediaCache = new Map();

async function ensureMediaTempDir() {
  await fs.promises.mkdir(MEDIA_TMP_DIR, { recursive: true });
  return MEDIA_TMP_DIR;
}

async function cleanupOldMediaFiles(now = Date.now()) {
  await ensureMediaTempDir();
  let entries = [];
  try {
    entries = await fs.promises.readdir(MEDIA_TMP_DIR, { withFileTypes: true });
  } catch (_) {
    return;
  }
  await Promise.all(entries.map(async entry => {
    if (!entry.isFile()) return;
    const filePath = path.join(MEDIA_TMP_DIR, entry.name);
    try {
      const stat = await fs.promises.stat(filePath);
      if (now - stat.mtimeMs > MEDIA_FILE_TTL_MS) await fs.promises.unlink(filePath);
    } catch (_) {
      // 临时文件清理是 best-effort，失败不影响本次请求。
    }
  }));
}

function normalizeRecipeImportCacheUrl(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    const parsed = new URL(raw);
    parsed.hash = '';
    return parsed.href;
  } catch (_) {
    return raw;
  }
}

function getVideoCacheKeyPart(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    const parsed = new URL(raw);
    return `${parsed.hostname}${parsed.pathname}`;
  } catch (_) {
    return raw.slice(0, 180);
  }
}

function buildRecipeImportMediaCacheKey({ rawUrl = '', finalUrl = '', selectedVideoUrl = '' } = {}) {
  const pageKey = normalizeRecipeImportCacheUrl(finalUrl || rawUrl);
  const videoKey = getVideoCacheKeyPart(selectedVideoUrl);
  return [pageKey, videoKey].filter(Boolean).join('|');
}

function cloneRecipeImportCacheValue(value, fallback = null) {
  if (!value || typeof value !== 'object') return fallback;
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (_) {
    return fallback;
  }
}

function cleanupRecipeImportMediaCache(now = Date.now()) {
  for (const [key, entry] of recipeImportMediaCache.entries()) {
    if (!entry || now - Number(entry.createdAt || 0) > RECIPE_IMPORT_MEDIA_CACHE_TTL_MS) {
      recipeImportMediaCache.delete(key);
    }
  }
}

function parseContentLength(headers = {}) {
  const raw = headers['content-length'] || headers['Content-Length'];
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

async function fetchMediaFollowingRedirectsSafely(startUrl, maxHops = 5) {
  let current = startUrl;
  for (let hop = 0; hop <= maxHops; hop++) {
    const validated = await resolveAndValidatePublicUrl(current);
    const lookup = createPinnedLookup(validated.ip, validated.family);
    const agent = current.protocol === 'https:'
      ? new https.Agent({ lookup, keepAlive: false })
      : new http.Agent({ lookup, keepAlive: false });

    const resp = await axios.get(current.href, {
      maxRedirects: 0,
      timeout: MEDIA_DOWNLOAD_TIMEOUT_MS,
      responseType: 'stream',
      maxContentLength: MEDIA_MAX_VIDEO_BYTES,
      maxBodyLength: MEDIA_MAX_VIDEO_BYTES,
      httpAgent: agent,
      httpsAgent: agent,
      headers: {
        'User-Agent': MOBILE_UA,
        'Accept': 'video/*,application/octet-stream,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      validateStatus: s => s >= 200 && s < 400
    });

    if (resp.status >= 300 && resp.status < 400) {
      const loc = resp.headers && resp.headers.location;
      if (!loc) throw SSRF_ERROR;
      let next;
      try { next = new URL(loc, current); } catch (_) { throw SSRF_ERROR; }
      if (next.protocol !== 'http:' && next.protocol !== 'https:') throw SSRF_ERROR;
      current = next;
      continue;
    }

    const contentLength = parseContentLength(resp.headers || {});
    if (contentLength != null && contentLength > MEDIA_MAX_VIDEO_BYTES) throw MEDIA_TOO_LARGE_ERROR;
    return { resp, finalUrl: current.href, contentLength };
  }
  throw SSRF_ERROR;
}

async function writeMediaStreamToFile(stream, filePath) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    let settled = false;
    const out = fs.createWriteStream(filePath, { flags: 'wx' });
    function finish(err) {
      if (settled) return;
      settled = true;
      if (err) {
        stream.destroy?.();
        out.destroy?.();
        fs.promises.unlink(filePath).catch(() => {});
        reject(err);
      } else {
        resolve(bytes);
      }
    }
    stream.on('data', chunk => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > MEDIA_MAX_VIDEO_BYTES) finish(MEDIA_TOO_LARGE_ERROR);
    });
    stream.on('error', err => finish(err || MEDIA_DOWNLOAD_ERROR));
    out.on('error', err => finish(err || MEDIA_DOWNLOAD_ERROR));
    out.on('finish', () => finish(null));
    stream.pipe(out);
  });
}

async function downloadVideoToTemp(videoUrl) {
  const startUrl = extractHttpUrl(videoUrl);
  if (!startUrl) throw SSRF_ERROR;
  await cleanupOldMediaFiles();
  await ensureMediaTempDir();
  const id = crypto.randomUUID ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex');
  const videoPath = path.join(MEDIA_TMP_DIR, `${id}.video`);
  const fetched = await fetchMediaFollowingRedirectsSafely(startUrl, 5);
  const bytes = await writeMediaStreamToFile(fetched.resp.data, videoPath);
  return { id, videoPath, bytes, finalUrl: fetched.finalUrl };
}

function parseFfmpegDuration(stderrText) {
  const match = String(stderrText || '').match(/Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)/);
  if (!match) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  if (![hours, minutes, seconds].every(Number.isFinite)) return null;
  return Math.round((hours * 3600 + minutes * 60 + seconds) * 1000) / 1000;
}

function runFfmpegProcess(args, { timeoutMs = 60000, allowNonZero = false } = {}) {
  if (!ffmpegPath) return Promise.reject(MEDIA_FFMPEG_ERROR);
  return new Promise((resolve, reject) => {
    let stderr = '';
    let settled = false;
    const child = spawn(ffmpegPath, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    const finish = (err, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(result);
    };
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (_) {}
      finish(MEDIA_FFMPEG_ERROR);
    }, timeoutMs);
    child.stderr?.on('data', chunk => {
      stderr += String(chunk || '').slice(0, 4000);
      if (stderr.length > 12000) stderr = stderr.slice(-12000);
    });
    child.on('error', () => finish(MEDIA_FFMPEG_ERROR));
    child.on('close', code => {
      if (code === 0 || allowNonZero) finish(null, { code, stderr });
      else finish(MEDIA_FFMPEG_ERROR);
    });
  });
}

async function extractAudioWithFfmpeg(videoPath, audioPath) {
  if (!ffmpegPath) throw MEDIA_FFMPEG_ERROR;
  return new Promise((resolve, reject) => {
    const args = [
      '-y',
      '-i', videoPath,
      '-vn',
      '-ac', '1',
      '-ar', '16000',
      '-b:a', '64k',
      audioPath
    ];
    let stderr = '';
    const child = spawn(ffmpegPath, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(MEDIA_FFMPEG_ERROR);
    }, 60000);
    child.stderr?.on('data', chunk => {
      stderr += String(chunk || '').slice(0, 4000);
      if (stderr.length > 12000) stderr = stderr.slice(-12000);
    });
    child.on('error', () => {
      clearTimeout(timer);
      reject(MEDIA_FFMPEG_ERROR);
    });
    child.on('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve({ durationSeconds: parseFfmpegDuration(stderr) });
      else reject(MEDIA_FFMPEG_ERROR);
    });
  });
}

async function probeVideoDurationSeconds(videoPath) {
  try {
    const result = await runFfmpegProcess(['-hide_banner', '-i', videoPath], { timeoutMs: 15000, allowNonZero: true });
    return parseFfmpegDuration(result.stderr);
  } catch (_) {
    return null;
  }
}

function clampMediaFrameCount(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return MEDIA_MAX_FRAME_COUNT;
  return Math.max(1, Math.min(MEDIA_MAX_FRAME_COUNT, Math.floor(n)));
}

function buildEvenFrameTimestamps(durationSeconds, count) {
  const duration = Number(durationSeconds);
  if (!Number.isFinite(duration) || duration <= 0 || count <= 0) return [];
  return Array.from({ length: count }, (_, index) => {
    const t = duration * (index + 1) / (count + 1);
    return Math.max(0.1, Math.round(t * 1000) / 1000);
  });
}

async function assertMediaFrameSize(filePath) {
  const stat = await fs.promises.stat(filePath);
  return stat.size;
}

async function extractFramesWithFfmpeg(videoPath, { maxFrames = MEDIA_MAX_FRAME_COUNT } = {}) {
  if (!ffmpegPath) throw MEDIA_FFMPEG_ERROR;
  await cleanupOldMediaFiles();
  await ensureMediaTempDir();
  const count = clampMediaFrameCount(maxFrames);
  const baseId = path.basename(videoPath).replace(/\.[^.]+$/, '');
  const durationSeconds = await probeVideoDurationSeconds(videoPath);
  const frames = [];

  if (durationSeconds) {
    const timestamps = buildEvenFrameTimestamps(durationSeconds, count);
    for (let index = 0; index < timestamps.length; index++) {
      const frameId = `${baseId}-frame-${String(index + 1).padStart(2, '0')}.jpg`;
      const framePath = path.join(MEDIA_TMP_DIR, frameId);
      await runFfmpegProcess([
        '-y',
        '-ss', String(timestamps[index]),
        '-i', videoPath,
        '-frames:v', '1',
        '-vf', 'scale=512:-2',
        '-q:v', '10',
        framePath
      ], { timeoutMs: 60000 });
      const bytes = await assertMediaFrameSize(framePath);
      frames.push({ frameId, bytes, timestampSeconds: timestamps[index] });
    }
  } else {
    const prefix = `${baseId}-frame-`;
    const pattern = path.join(MEDIA_TMP_DIR, `${prefix}%02d.jpg`);
    await runFfmpegProcess([
      '-y',
      '-i', videoPath,
      '-vf', 'fps=1/3,scale=512:-2',
      '-frames:v', String(count),
      '-q:v', '10',
      pattern
    ], { timeoutMs: 60000 });
    const entries = await fs.promises.readdir(MEDIA_TMP_DIR, { withFileTypes: true });
    const frameIds = entries
      .filter(entry => entry.isFile() && entry.name.startsWith(prefix) && /\.jpe?g$/i.test(entry.name))
      .map(entry => entry.name)
      .sort()
      .slice(0, count);
    for (const frameId of frameIds) {
      const bytes = await assertMediaFrameSize(path.join(MEDIA_TMP_DIR, frameId));
      frames.push({ frameId, bytes, timestampSeconds: null });
    }
  }

  if (!frames.length) throw MEDIA_FFMPEG_ERROR;
  return { durationSeconds, frames };
}

function resolveMediaAudioPath(audioPath) {
  const basename = String(audioPath || '').trim();
  if (!basename || basename !== path.basename(basename)) return null;
  if (!/^[a-zA-Z0-9._-]+\.(?:m4a|mp3|wav|aac)$/i.test(basename)) return null;
  const resolved = path.resolve(MEDIA_TMP_DIR, basename);
  const root = path.resolve(MEDIA_TMP_DIR) + path.sep;
  return resolved.startsWith(root) ? resolved : null;
}

function resolveMediaVideoPath(videoId) {
  const basename = String(videoId || '').trim();
  if (!basename || basename !== path.basename(basename)) return null;
  if (!/^[a-zA-Z0-9._-]+\.video$/i.test(basename)) return null;
  const resolved = path.resolve(MEDIA_TMP_DIR, basename);
  const root = path.resolve(MEDIA_TMP_DIR) + path.sep;
  return resolved.startsWith(root) ? resolved : null;
}

function resolveMediaFramePath(frameId) {
  const basename = String(frameId || '').trim();
  if (!basename || basename !== path.basename(basename)) return null;
  if (!/^[a-zA-Z0-9._-]+\.(?:jpg|jpeg|png|webp)$/i.test(basename)) return null;
  const resolved = path.resolve(MEDIA_TMP_DIR, basename);
  const root = path.resolve(MEDIA_TMP_DIR) + path.sep;
  return resolved.startsWith(root) ? resolved : null;
}

function getAudioMimeType(audioFilePath) {
  const ext = path.extname(audioFilePath).toLowerCase();
  if (ext === '.mp3') return 'audio/mpeg';
  if (ext === '.wav') return 'audio/wav';
  if (ext === '.aac') return 'audio/aac';
  return 'audio/mp4';
}

function getImageMimeType(imagePath) {
  const ext = path.extname(imagePath).toLowerCase();
  if (ext === '.png') return 'image/png';
  if (ext === '.webp') return 'image/webp';
  return 'image/jpeg';
}

function getTranscriptText(payload) {
  if (!payload || typeof payload !== 'object') return '';
  return String(payload.text || payload.transcript || '').trim();
}

function getEndpointHost(endpoint) {
  try {
    return new URL(String(endpoint || '')).hostname;
  } catch (_) {
    return '';
  }
}

async function readFetchResponsePayload(response) {
  if (!response) return { json: null, text: '' };
  if (typeof response.text === 'function') {
    try {
      const text = await response.text();
      try {
        return { json: text ? JSON.parse(text) : null, text };
      } catch (_) {
        return { json: null, text };
      }
    } catch (_) {
      return { json: null, text: '' };
    }
  }
  if (typeof response.json === 'function') {
    try {
      const json = await response.json();
      return { json, text: JSON.stringify(json || {}) };
    } catch (_) {
      return { json: null, text: '' };
    }
  }
  return { json: null, text: '' };
}

function getUpstreamPayloadCode(payload, fallback = 'upstream_error') {
  const data = payload && typeof payload === 'object' ? payload : null;
  const upstreamError = data && typeof data.error === 'object' ? data.error : null;
  const code = upstreamError?.code || upstreamError?.type || data?.code || fallback;
  return String(code || fallback).slice(0, 80);
}

function getUpstreamPayloadMessage(payload, fallback = '上游服务请求失败。') {
  const data = payload && typeof payload === 'object' ? payload : null;
  const upstreamError = data && typeof data.error === 'object' ? data.error : null;
  const message = upstreamError?.message || data?.message || (typeof payload === 'string' ? payload : '') || fallback;
  return redactSecret(message);
}

function createMediaDiagnosticError(message, fields = {}) {
  const err = new Error(redactSecret(message || fields.message || '媒体处理失败。'));
  Object.assign(err, fields);
  if (err.asrUpstreamMessage && !err.asrErrorPreview) err.asrErrorPreview = redactSecret(err.asrUpstreamMessage);
  if (err.visionUpstreamMessage && !err.visionErrorPreview) err.visionErrorPreview = redactSecret(err.visionUpstreamMessage);
  return err;
}

function copyAsrDiagnostics(target, source = {}) {
  if (!target || !source) return;
  if (source.asrEndpoint) target.asrEndpointHost = getEndpointHost(source.asrEndpoint);
  if (source.asrEndpointHost) target.asrEndpointHost = String(source.asrEndpointHost || '');
  if (source.asrModel) target.asrModel = String(source.asrModel || '');
  if (source.asrUpstreamStatus !== undefined) target.asrUpstreamStatus = source.asrUpstreamStatus;
  if (source.asrUpstreamCode) target.asrUpstreamCode = String(source.asrUpstreamCode || '').slice(0, 80);
  if (source.asrErrorPreview || source.asrUpstreamMessage) {
    target.asrErrorPreview = redactSecret(source.asrErrorPreview || source.asrUpstreamMessage);
  }
  if (source.audioBytes !== undefined) target.audioBytes = Number(source.audioBytes || 0);
  if (source.audioMimeType) target.audioMimeType = String(source.audioMimeType || '');
}

function copyVisionDiagnostics(target, source = {}) {
  if (!target || !source) return;
  if (source.visionEndpoint) target.visionEndpointHost = getEndpointHost(source.visionEndpoint);
  if (source.visionEndpointHost) target.visionEndpointHost = String(source.visionEndpointHost || '');
  if (source.visionModel) target.visionModel = String(source.visionModel || '');
  if (source.visionUpstreamStatus !== undefined) target.visionUpstreamStatus = source.visionUpstreamStatus;
  if (source.visionUpstreamCode) target.visionUpstreamCode = String(source.visionUpstreamCode || '').slice(0, 80);
  if (source.visionErrorPreview || source.visionUpstreamMessage) {
    target.visionErrorPreview = redactSecret(source.visionErrorPreview || source.visionUpstreamMessage);
  }
  if (source.failedFrameId) target.failedFrameId = path.basename(String(source.failedFrameId || ''));
}

async function transcribeAudioFile(audioFilePath) {
  if (!OPENAI_API_KEY) throw new Error('MISSING_OPENAI_API_KEY');
  const asrEndpoint = resolveAudioTranscriptionsUrl(OPENAI_BASE_URL);
  const asrModel = OPENAI_TRANSCRIBE_MODEL;
  const audioMimeType = getAudioMimeType(audioFilePath);
  const audioBuffer = await fs.promises.readFile(audioFilePath);
  const audioBytes = audioBuffer.length;
  if (typeof fetch !== 'function' || typeof FormData === 'undefined' || typeof Blob === 'undefined') {
    throw createMediaDiagnosticError('当前 Node 环境不支持音频上传表单。', {
      mediaKind: 'asr',
      asrEndpoint,
      asrModel,
      asrUpstreamStatus: 0,
      asrUpstreamCode: 'unsupported_form_data',
      asrUpstreamMessage: '当前 Node 环境不支持音频上传表单。',
      audioBytes,
      audioMimeType
    });
  }
  const form = new FormData();
  form.append('model', asrModel);
  form.append('response_format', 'json');
  form.append('language', 'zh');
  form.append('file', new Blob([audioBuffer], { type: audioMimeType }), path.basename(audioFilePath));

  let response;
  try {
    response = await fetch(asrEndpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`
      },
      body: form
    });
  } catch (err) {
    throw createMediaDiagnosticError(err?.message || '音频转录请求失败。', {
      mediaKind: 'asr',
      asrEndpoint,
      asrModel,
      asrUpstreamStatus: 0,
      asrUpstreamCode: err?.code || 'network_error',
      asrUpstreamMessage: err?.message || '音频转录请求失败。',
      audioBytes,
      audioMimeType
    });
  }

  const responsePayload = await readFetchResponsePayload(response);
  const payload = responsePayload.json || responsePayload.text || null;
  if (!response.ok) {
    throw createMediaDiagnosticError(getUpstreamPayloadMessage(payload, '音频转录上游服务请求失败。'), {
      mediaKind: 'asr',
      asrEndpoint,
      asrModel,
      asrUpstreamStatus: response.status,
      asrUpstreamCode: getUpstreamPayloadCode(payload),
      asrUpstreamMessage: getUpstreamPayloadMessage(payload, '音频转录上游服务请求失败。'),
      audioBytes,
      audioMimeType
    });
  }
  const transcript = getTranscriptText(responsePayload.json);
  if (!transcript) {
    throw createMediaDiagnosticError('音频转录结果为空。', {
      mediaKind: 'asr',
      asrEndpoint,
      asrModel,
      asrUpstreamStatus: 502,
      asrUpstreamCode: 'empty_transcript',
      asrUpstreamMessage: '音频转录结果为空。',
      audioBytes,
      audioMimeType
    });
  }
  return {
    transcript,
    model: asrModel,
    transcriptLength: transcript.length,
    asrEndpoint,
    asrModel,
    audioBytes,
    audioMimeType
  };
}

function normalizeOcrConfidence(value) {
  const confidence = String(value || '').trim().toLowerCase();
  return ['low', 'medium', 'high'].includes(confidence) ? confidence : 'low';
}

function parseFrameOcrContent(content) {
  const parsed = safeParseModelJson(content);
  if (parsed && typeof parsed === 'object') {
    const text = Array.isArray(parsed.lines)
      ? parsed.lines.map(line => String(line || '').trim()).filter(Boolean).join('\n')
      : String(parsed.text || parsed.ocrText || parsed.content || '').trim();
    return {
      text,
      confidence: normalizeOcrConfidence(parsed.confidence)
    };
  }
  return {
    text: String(content || '').replace(/```(?:json)?/gi, '').trim(),
    confidence: 'low'
  };
}


async function ocrFrameWithVisionModel(frameId, framePath) {
  if (!OPENAI_API_KEY) throw new Error('MISSING_OPENAI_API_KEY');
  const frameBuffer = await fs.promises.readFile(framePath);
  if (frameBuffer.length > MEDIA_MAX_FRAME_BYTES) {
    return {
      frameId,
      text: '',
      confidence: 'low',
      skipped: true,
      reason: 'frame_too_large',
      bytes: frameBuffer.length
    };
  }
  const dataUrl = `data:${getImageMimeType(framePath)};base64,${frameBuffer.toString('base64')}`;
  const visionEndpoint = resolveChatUrl(OPENAI_BASE_URL);
  const prompt = [
    '你是 Kitchen Manager 的视频菜谱画面文字识别器。',
    '只提取画面中清晰可见、与菜谱相关的文字：食材、调料、用量、火候、时间、步骤字幕。',
    '不要根据画面猜完整做法，不要补全看不见的步骤，不要写菜谱总结。',
    '如果没有看见菜谱文字，text 返回空字符串。',
    '请只返回 JSON：{"text":"逐行 OCR 文本","confidence":"low|medium|high"}'
  ].join('\n');

  let resp;
  try {
    resp = await axios.post(
      visionEndpoint,
      {
        model: OPENAI_VISION_MODEL,
        messages: [
          { role: 'system', content: 'Extract visible recipe text from a video frame. Do not infer a recipe.' },
          {
            role: 'user',
            content: [
              { type: 'text', text: prompt },
              { type: 'image_url', image_url: { url: dataUrl } }
            ]
          }
        ],
        temperature: 0.1
      },
      {
        timeout: 45000,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
      }
    );
  } catch (err) {
    const info = getUpstreamAiErrorInfo(err);
    throw createMediaDiagnosticError(info.detail || '画面文字识别上游服务请求失败。', {
      mediaKind: 'vision',
      visionEndpoint,
      visionModel: OPENAI_VISION_MODEL,
      visionUpstreamStatus: info.status,
      visionUpstreamCode: info.code,
      visionUpstreamMessage: info.detail,
      failedFrameId: frameId
    });
  }
  const content = getAiMessageContent(resp);
  if (!content) {
    throw createMediaDiagnosticError('视觉模型返回空内容。', {
      mediaKind: 'vision',
      visionEndpoint,
      visionModel: OPENAI_VISION_MODEL,
      visionUpstreamStatus: 502,
      visionUpstreamCode: 'empty_response',
      visionUpstreamMessage: '视觉模型返回空内容。',
      failedFrameId: frameId
    });
  }
  const result = parseFrameOcrContent(content);
  return {
    frameId,
    text: result.text,
    confidence: result.text ? result.confidence : 'low'
  };
}

async function extractVideoRecipeTextForImport(videoUrl, videoUrlCount = 0, selectionDiagnostics = {}) {
  const mediaDiagnostics = {
    hasVideo: Boolean(videoUrl),
    videoUrlCount: Number(videoUrlCount || 0),
    selectedVideoUrlRanked: Boolean(selectionDiagnostics.selectedVideoUrlRanked),
    selectedVideoHost: '',
    selectedVideoPathPreview: '',
    rejectedVideoUrlCount: Number(selectionDiagnostics.rejectedVideoUrlCount || 0),
    rejectedVideoUrlHosts: Array.isArray(selectionDiagnostics.rejectedVideoUrlHosts) ? selectionDiagnostics.rejectedVideoUrlHosts : [],
    audioExtracted: false,
    asrAttempted: false,
    asrOk: false,
    asrEndpointHost: getEndpointHost(resolveAudioTranscriptionsUrl(OPENAI_BASE_URL)),
    asrModel: OPENAI_TRANSCRIBE_MODEL,
    asrUpstreamStatus: null,
    asrUpstreamCode: '',
    asrErrorPreview: '',
    audioBytes: 0,
    audioMimeType: '',
    transcriptLength: 0,
    framesExtracted: 0,
    ocrAttempted: false,
    ocrOk: false,
    visionEndpointHost: getEndpointHost(resolveChatUrl(OPENAI_BASE_URL)),
    visionModel: OPENAI_VISION_MODEL,
    visionUpstreamStatus: null,
    visionUpstreamCode: '',
    visionErrorPreview: '',
    failedFrameId: '',
    failedFrameCount: 0,
    skippedFrameCount: 0,
    ocrFrameCount: 0,
    ocrTextLength: 0,
    warnings: []
  };
  if (!videoUrl) return { transcriptText: '', ocrText: '', mediaDiagnostics };

  try {
    const selected = new URL(videoUrl);
    mediaDiagnostics.selectedVideoHost = selected.hostname;
    mediaDiagnostics.selectedVideoPathPreview = selected.pathname.slice(0, 80);
  } catch (_) {
    mediaDiagnostics.selectedVideoHost = '';
    mediaDiagnostics.selectedVideoPathPreview = '';
  }

  let downloaded = null;
  let transcriptText = '';
  let ocrText = '';
  try {
    downloaded = await downloadVideoToTemp(videoUrl);
  } catch (_) {
    mediaDiagnostics.warnings.push('已找到视频地址，但视频下载失败，仅使用页面文字生成草稿。');
    return { transcriptText, ocrText, mediaDiagnostics };
  }

  try {
    const audioPath = path.join(MEDIA_TMP_DIR, `${downloaded.id}.m4a`);
    await extractAudioWithFfmpeg(downloaded.videoPath, audioPath);
    mediaDiagnostics.audioExtracted = true;
    mediaDiagnostics.asrAttempted = true;
    mediaDiagnostics.audioMimeType = getAudioMimeType(audioPath);
    try {
      const audioStat = await fs.promises.stat(audioPath);
      mediaDiagnostics.audioBytes = audioStat.size;
    } catch (_) {
      mediaDiagnostics.audioBytes = 0;
    }
    const transcript = await transcribeAudioFile(audioPath);
    transcriptText = transcript.transcript;
    mediaDiagnostics.transcriptLength = transcript.transcriptLength;
    mediaDiagnostics.asrOk = true;
    copyAsrDiagnostics(mediaDiagnostics, transcript);
  } catch (err) {
    copyAsrDiagnostics(mediaDiagnostics, err);
    if (isRateLimitExceeded(mediaDiagnostics.asrUpstreamStatus, mediaDiagnostics.asrUpstreamCode)) {
      mediaDiagnostics.warnings.push('口播转录触发限流，已跳过口播转录。');
    } else if (mediaDiagnostics.audioExtracted && Number(mediaDiagnostics.asrUpstreamStatus) === 413) {
      mediaDiagnostics.warnings.push('音频转录请求过大，已跳过口播转录。');
    } else {
      mediaDiagnostics.warnings.push(mediaDiagnostics.audioExtracted
        ? '音频已提取，但口播转录失败。'
        : '视频音频提取失败，已继续尝试读取页面文字和画面文字。');
    }
  }

  try {
    const frameResult = await extractFramesWithFfmpeg(downloaded.videoPath, { maxFrames: MEDIA_MAX_FRAME_COUNT });
    mediaDiagnostics.framesExtracted = frameResult.frames.length;
    mediaDiagnostics.ocrAttempted = frameResult.frames.length > 0;
    const ocrFrames = [];
    for (const frame of frameResult.frames) {
      try {
        const ocrFrame = await ocrFrameWithVisionModel(frame.frameId, path.join(MEDIA_TMP_DIR, frame.frameId));
        if (ocrFrame?.skipped) {
          mediaDiagnostics.skippedFrameCount += 1;
          if (ocrFrame.reason === 'frame_too_large') {
            mediaDiagnostics.warnings.push('frame_too_large_skipped：部分视频画面过大，已跳过识别。');
          }
          continue;
        }
        ocrFrames.push(ocrFrame);
      } catch (err) {
        mediaDiagnostics.failedFrameCount += 1;
        if (!mediaDiagnostics.visionUpstreamCode && !mediaDiagnostics.visionErrorPreview) {
          copyVisionDiagnostics(mediaDiagnostics, err);
        }
        if (isRateLimitExceeded(err?.visionUpstreamStatus, err?.visionUpstreamCode)) {
          mediaDiagnostics.warnings.push('画面文字识别触发限流，已跳过部分帧。');
        }
      }
    }
    mediaDiagnostics.ocrFrameCount = ocrFrames.length;
    mediaDiagnostics.ocrOk = ocrFrames.length > 0;
    ocrText = ocrFrames
      .map(frame => String(frame.text || '').trim())
      .filter(Boolean)
      .join('\n\n');
    mediaDiagnostics.ocrTextLength = ocrText.length;
    if (mediaDiagnostics.framesExtracted > 0 && ocrFrames.length === 0) {
      mediaDiagnostics.warnings.push('视频抽帧成功，但画面文字识别失败。');
    } else if (mediaDiagnostics.failedFrameCount > 0) {
      mediaDiagnostics.warnings.push('部分视频画面文字识别失败，已保留成功识别的画面文字。');
    }
  } catch (err) {
    copyVisionDiagnostics(mediaDiagnostics, err);
    mediaDiagnostics.warnings.push('视频画面抽取失败，已继续使用可提取的其他内容生成草稿。');
  }

  if (!transcriptText && !ocrText) {
    mediaDiagnostics.warnings.push('视频转录失败，仅使用页面文字生成草稿。');
  }
  mediaDiagnostics.warnings = uniqueTextList(mediaDiagnostics.warnings, 8);
  return { transcriptText, ocrText, mediaDiagnostics };
}

module.exports = {
  assertMediaFrameSize,
  buildEvenFrameTimestamps,
  buildRecipeImportMediaCacheKey,
  clampMediaFrameCount,
  cleanupOldMediaFiles,
  cleanupRecipeImportMediaCache,
  cloneRecipeImportCacheValue,
  copyAsrDiagnostics,
  copyVisionDiagnostics,
  createMediaDiagnosticError,
  downloadVideoToTemp,
  ensureMediaTempDir,
  extractAudioWithFfmpeg,
  extractFramesWithFfmpeg,
  extractVideoRecipeTextForImport,
  fetchMediaFollowingRedirectsSafely,
  getAudioMimeType,
  getEndpointHost,
  getImageMimeType,
  getTranscriptText,
  getUpstreamPayloadCode,
  getUpstreamPayloadMessage,
  getVideoCacheKeyPart,
  normalizeOcrConfidence,
  normalizeRecipeImportCacheUrl,
  ocrFrameWithVisionModel,
  parseContentLength,
  parseFfmpegDuration,
  parseFrameOcrContent,
  probeVideoDurationSeconds,
  readFetchResponsePayload,
  recipeImportMediaCache,
  resolveMediaAudioPath,
  resolveMediaFramePath,
  resolveMediaVideoPath,
  runFfmpegProcess,
  transcribeAudioFile,
  writeMediaStreamToFile
};
