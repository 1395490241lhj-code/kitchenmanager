/*
 * server.js —— Kitchen Manager 全栈一体化服务器
 *
 * - 用 Express 静态托管前端（本项目无构建步骤，index.html 在仓库根目录，直接托管根目录）。
 * - /api/xhs-extract：服务端抓取小红书/网页菜谱文案，绕过浏览器 CORS。
 *     跟随 302 短链（xhslink.com → 真实长链）、伪造移动端 UA、正则提取
 *     window.__INITIAL_STATE__ / og:title / description 等文案，返回纯文本 JSON。
 * - /api/ai-chat：默认 AI 代理（密钥/Base URL 来自环境变量），前端不需要本地 API Key。
 * - /api/ai-parse：后端统一呼叫 AI（文本用 OPENAI_MODEL，图片用 OPENAI_VISION_MODEL），
 *     返回模型 JSON 原文。
 *
 * 环境变量（Render）：PORT、OPENAI_API_KEY、OPENAI_BASE_URL、OPENAI_MODEL、OPENAI_VISION_MODEL（可选）、OPENAI_TRANSCRIBE_MODEL（可选）。
 * 启动：npm install && npm start  （默认 http://localhost:3000）
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const express = require('express');
const axios = require('axios');
const dns = require('dns').promises;
const net = require('net');
const http = require('http');
const https = require('https');
const { spawn } = require('child_process');
let ffmpegPath = '';
try {
  ffmpegPath = require('ffmpeg-static') || '';
} catch (_) {
  ffmpegPath = '';
}

const app = express();
const ROOT = __dirname;
const PORT = process.env.PORT || 3000;

// 解析 JSON 请求体（截图 base64 较大，放宽上限）。
app.use(express.json({ limit: '12mb' }));
app.use((err, req, res, next) => {
  if (!err) return next();
  if (err.type === 'entity.too.large' || err.status === 413) {
    return sendAiJsonError(res, 413, 'request_too_large', '请求体过大。');
  }
  if (err.type === 'entity.parse.failed' || err.status === 400) {
    return sendAiJsonError(res, 400, 'bad_json', 'JSON 请求格式不正确。');
  }
  return next(err);
});

const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1';

// ── AI 解析（120B）配置：密钥与 Base URL 由 Render 环境变量提供 ──
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.groq.com/openai/v1';
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'openai/gpt-oss-120b';
const DEFAULT_OPENAI_VISION_MODEL = 'meta-llama/llama-4-scout-17b-16e-instruct';
const OPENAI_VISION_MODEL = process.env.OPENAI_VISION_MODEL || DEFAULT_OPENAI_VISION_MODEL;
const OPENAI_TRANSCRIBE_MODEL = process.env.OPENAI_TRANSCRIBE_MODEL || 'gpt-4o-mini-transcribe';

const AI_PROMPT_MAX_CHARS = 12000;
const AI_IMAGE_MAX_BASE64_BYTES = 4 * 1024 * 1024;
const AI_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
const AI_RATE_LIMIT_MAX = 30;
const aiRateLimitBuckets = new Map();

// 把 Base URL 归一为 chat/completions 完整地址。
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

function getClientIp(req) {
  const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return forwarded || req.ip || req.socket?.remoteAddress || 'unknown';
}

function isAiRateLimited(req) {
  const ip = getClientIp(req);
  const now = Date.now();
  const bucket = aiRateLimitBuckets.get(ip) || { start: now, count: 0 };
  if (now - bucket.start > AI_RATE_LIMIT_WINDOW_MS) {
    bucket.start = now;
    bucket.count = 0;
  }
  bucket.count += 1;
  aiRateLimitBuckets.set(ip, bucket);
  return bucket.count > AI_RATE_LIMIT_MAX;
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

function getAiMessageContent(resp) {
  return resp?.data?.choices?.[0]?.message?.content || '';
}

const RECIPE_EVIDENCE_SYSTEM_PROMPT = `你是 Kitchen Manager 的视频/网页菜谱证据抽取器。用户会给你小红书/网页菜谱文案、caption、OCR、transcript 或截图。
你的任务只是在来源内容里抽取"明确出现的证据"，不要生成最终菜谱，不要根据常识补全。

请严格返回 JSON 对象，不要 markdown，不要解释：
{
  "dishNameCandidates": [],
  "observedMainIngredients": [],
  "observedSeasonings": [],
  "observedAromatics": [],
  "observedLiquids": [],
  "observedActions": [
    {
      "order": 1,
      "action": "来源明确支持的动作",
      "ingredients": ["相关食材或调料"],
      "evidenceText": "支持该动作的原文/OCR/字幕片段",
      "confidence": "high|medium|low"
    }
  ],
  "observedTimes": [],
  "observedTools": [],
  "uncertainItems": [],
  "missingInfo": [],
  "sourceConfidence": "low|medium|high"
}

规则：
- 只抽取来源中明确出现的信息；不因为常见做法补动作。
- 只从 cleanedRecipeText / trusted source buckets 里抽取 evidence；不要从 comments、弹幕、hashtags、用户讨论、推荐文案或 excludedSocialText 中抽取食材、调料或步骤。
- hashtags 只能辅助判断菜名/标签，不能作为 ingredients、seasonings 或 observedActions 的证据。
- 作者标题/描述可以辅助判断菜名、口味和置信度；只有出现明确配料、调料、用量或烹饪动作时，才可抽取 observedMainIngredients、observedSeasonings 或 observedActions。
- 如果某个材料或步骤只出现在评论/弹幕/用户讨论里，不要加入 evidence。
- 如果来源只有零散关键词、标题、配料名，observedActions 必须很少或为空，不要扩写成完整做法。
- 有"水"不等于加水焖煮；除非来源明确出现加水、倒水、清水、高汤、焖、炖、煮、收汁、盖盖焖，否则 observedActions 里不要写加水/焖/煮/收汁。
- 鲜藤椒、藤椒、藤椒粉、花椒必须保持原词，不要互相改写。
- 如果看到腌、腌制、抓匀、拌匀，或肉类加入生抽/老抽/料酒/盐/糖/胡椒/淀粉等腌料处理，必须作为 observedActions 保留。
- 如果看到"加入鲜藤椒和生抽等调味料"，必须作为 observedActions 保留鲜藤椒。
- 如果字幕/OCR/文案不完整，或没有连续做法文本，把 sourceConfidence 降低，并在 missingInfo/uncertainItems 里说明。
- 如果看到调料但不确定用途，放入 observedSeasonings 或 uncertainItems，不要编入 observedActions。`;

const IMPORT_SYSTEM_PROMPT = `你是一位资深中餐大厨兼菜谱结构化助手。用户会给你一份已经抽取好的 evidence JSON。
请只根据 evidence 和 sourceDiagnostics 生成最终菜谱 JSON；不要查看常识补全 observedActions 里没有支持的关键动作。

⚠️ 最高优先级铁律（违反任意一条即视为输出失败，必须严格执行）：
1. 【严禁空数量】ingredients 与 seasonings 数组里每个对象的 qty 必须是有效数字字符串（如 "1"、"2"、"0.5"），不允许 "" / null / undefined / 缺省字段 / "适量" / "少许" / "半" / "一" 等任何非数字内容。
2. 【食材 / 调料 双列表】必须输出两个独立数组：
   · ingredients = 核心食材（肉、禽、蛋、海鲜、蔬菜、豆制品、主食、特色配料等，参与库存扣减）。
   · seasonings  = 常备调料与背景介质（如 水、生抽、老抽、醋、糖、盐、味精、鸡精、食用油 / 植物油 / 菜籽油 / 大豆油 / 玉米油 / 葵花籽油 / 调和油 / 色拉油、料酒、淀粉、香油、花椒、干辣椒、八角、桂皮、葱姜蒜等）。不参与库存扣减；除水/高汤等用途不明确项外，来源明确支持的调味动作应出现在 method 步骤文字里。
   · ingredients 数组里严禁出现 seasonings 类目；反之亦然。
3. 【method 格式干净】method 必须是字符串数组，每个元素的文本【严禁包含任何序号前缀】（如 "1. " / "1、" / "第一步：" / "步骤2：" / "一、" / "(1) "）；直接以动词或主语开头。
4. 【method 只写 evidence 支持的动作】油/盐/生抽等调味动作只有在 observedActions 明确支持时才写入 method。水/清水/高汤是高风险项：只有 observedActions 明确出现"加水"、"倒水"、"清水"、"高汤"、"焖"、"炖"、"煮"、"收汁"、"盖盖焖"等动作时，才允许写入加水/焖煮/收汁步骤。
5. 【严格依据 evidence】不要把小红书/视频菜谱改写成泛用做法；必须保留 observedActions 里的烹饪顺序、加料顺序、火候变化和收尾动作。
6. 【禁止脑补加水焖煮】不要因为 ingredients 或 seasonings 里出现"水"，就生成"加水焖熟"、"加水焖煮"、"加水炖煮"、"加水收汁"等步骤。若来源只列出水但没有明确用途，method 不要写水，只在 warnings 中写"原内容列出了水，但未明确说明用途，请人工确认。"
7. 【关键动作覆盖】如果 observedActions 明确提到加汤/焖煮/收汁/撒藤椒/下藤椒/加辣椒/加葱姜蒜/豆瓣酱/咖喱块/泡菜等关键动作或风味材料，method 中必须体现其真实用途和加入时机。
8. 【藤椒形态必须保真】鲜藤椒、藤椒、藤椒粉、花椒不要互相改写。如果来源是"鲜藤椒"，步骤也应保留为"鲜藤椒"或"新鲜藤椒"；不要改成"藤椒粉腌制"，除非来源明确就是藤椒粉和腌制。
9. 【保守但完整】只能写来源内容明确支持的动作，不能根据常识脑补；但也不能因为保守而省略来源中明确出现的关键步骤。视频类菜谱要按时间顺序拆成多个清晰阶段，不要压缩成一句泛用描述。
10. 【肉类腌制必须保留】如果来源内容对鸡腿/鸡肉/牛肉/猪肉/肉片/肉丝/排骨/鱼片/虾仁等肉类出现腌、腌制、抓匀、拌匀，或明确出现加入生抽/老抽/料酒/盐/糖/胡椒/淀粉等腌料处理，method 必须有独立腌制步骤。不要凭空添加"15分钟"/"30分钟"等时间；来源没有时间时可写"抓匀腌制"或"腌制片刻"。
11. 【observedActions 驱动 method】method 必须覆盖 evidence.observedActions；如果 observedActions 少于 3 个或肉类菜谱缺少调味/收尾动作，仍可生成 draft，但必须在 warnings 中标记信息不足。
12. 【warning 与 method 分离】method 只能包含烹饪步骤；"需要确认"、"原内容未明确"、"可能遗漏"等提醒必须放入 warnings，严禁写进 method。
13. 【不确定要标记】如果抓取内容像视频片段、配料表或不完整文案，或者某个关键材料没有明确加入时机，不要自信脑补；在 warnings 中写明"原内容未明确说明 X 的加入时机，请确认"，并把 needsReview 设为 true。
14. 【sourceDiagnostics 低置信度】如果 sourceDiagnostics.sourceConfidence 是 low，或 diagnostics 显示 rawTextLength 很短、observedActionCount 少于 3、observedIngredientCount 少于 3，只能生成证据支持的 draft。不要把"鸡腿 小苏打 藤椒"这类少量关键词扩写成完整菜谱；warnings 必须包含"链接可提取信息较少，菜谱可能缺少食材、调料或步骤，请人工确认。"。

JSON 字段如下：
{
  "name": "标准菜名",
  "tags": ["家常菜", "口味/菜系等标签"],
  "ingredients": [ {"item": "土豆", "qty": "2", "unit": "个"}, {"item": "牛肉", "qty": "1", "unit": "份"} ],
  "seasonings":  [ {"item": "生抽", "qty": "2", "unit": "勺"}, {"item": "盐", "qty": "1", "unit": "适量"}, {"item": "水", "qty": "1", "unit": "杯"} ],
  "method": ["步骤一文本", "步骤二文本", "步骤三文本"],
  "warnings": ["原内容未明确说明某调料的加入时机，请确认"],
  "needsReview": true
}

【用量与单位规则】
1. ingredients（核心食材）：
   - 严禁输出精确克数（如 150g、230g、半斤）。
   - 必须换算为离散、直观的家常单位：个 / 根 / 把 / 棵 / 块 / 袋 / 盒 / 片 / 只 / 条 / 份。
   - 无法判断数量时，统一用 qty "1"、unit "份"。
   - 示例：{"item":"五花肉","qty":"1","unit":"块"}、{"item":"青椒","qty":"2","unit":"个"}。
2. seasonings（常备调料/介质）：
   - 允许使用精准的烹饪计量：勺 / 茶匙 / 克 / 毫升，或常用单位「适量」「少许」「杯」「把」。
   - 示例：{"item":"生抽","qty":"2","unit":"勺"}、{"item":"糖","qty":"5","unit":"克"}、{"item":"盐","qty":"1","unit":"适量"}、{"item":"水","qty":"1","unit":"杯"}。

【qty 必须是纯数字字符串】——ingredients 与 seasonings 两个数组里每一项都必须遵守：
- qty 只能是数字组成的字符串，如 "1"、"2"、"3"、"0.5"、"5"；可以含小数点，不得包含任何汉字、字母或符号。
- 严禁出现："" / null / undefined / 缺省字段 / "适量" / "少许" / "若干" / "些许" / "半" / "一" / "两"。
- 文案/视频里没明确数量时，按当前菜品的【三人份家常用量】智能估算并强行填合理数字：
  · ingredients：土豆 "2"/"3"、青椒 "2"、五花肉 "1"、鸡蛋 "2"、虾 "1"；
  · seasonings：生抽 "2"、老抽 "1"、醋 "1"、料酒 "1"、糖 "5"、干辣椒粉 "1"、花椒 "1"、葱花 "1"、食用油 "1"、盐 "1"、水 "1"。
- 当 unit 取「适量」「少许」「杯」「把」或其它无量纲单位时，qty 仍必须填 "1"，例如 {"item":"盐","qty":"1","unit":"适量"}。
- 这条规则优先于所有其它要求——宁愿估算偏差，也绝不能让 qty 为空或非数字。

【method 数组化】——method 必须是字符串数组，不再是单一字符串：
- 形如 method: ["步骤一文本", "步骤二文本", "步骤三文本"]，每个步骤一个数组元素。
- 铁律：每个步骤字符串内部严禁包含任何数字或文字序号前缀。
  · 严禁开头出现 "1. " / "1、" / "第一步：" / "步骤1：" / "一、" / "(1) " 等任何前缀。
  · 直接以动词或主语开头：错 "1. 土豆切丝"；对 "土豆切丝"。
- 至少 2 个步骤；建议 3–8 个；每步独立、可执行、清晰。
- 视频/图文菜谱宁可拆成更细步骤，也不要压缩成 1-2 步通用做法；来源支持时建议拆成 4-6 个短步骤。
- 必须保留来源中明确出现的主要阶段：洗净/去骨/切块/擦干/改刀；肉类腌制/抓匀/拌匀；煎/炒/烤/空气炸/蒸；明确出现的炖/焖/煮；加入鲜藤椒/藤椒/藤椒粉/生抽/老抽/料酒/盐/糖等调味；撒葱花/出锅/装盘。
- 肉类菜谱通常至少应覆盖：处理肉、腌制/抓匀、下锅煎/炒/烤、加关键风味材料/调味料、出锅/装盘；这些步骤必须来自来源内容支持，不能凭空添加加水焖煮。
- 如果来源内容没有明确说明水/高汤的用途，不要把它写成加水焖煮步骤，只在 warnings 中提醒用户确认。
- 如果 method 中没有体现鲜藤椒/藤椒粉/花椒/辣椒/豆瓣酱/咖喱块/泡菜/葱姜蒜等关键风味材料的用途，应在 warnings 中提醒用户确认。

其它要求：
- name 必填，为简洁标准菜名。
- ingredients 必填，至少一项；seasonings 可以为空数组但建议至少列出主要调料；两个数组里每条 item / qty / unit 都必须是非空字符串。
- tags 给 1-4 个，体现菜系/口味/类别。
- 只输出 JSON 本身。`;

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

function safeParseJsonText(text) {
  try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; }
}

function extractBalancedJsonObject(text, startIndex) {
  const source = String(text || '');
  const firstBrace = source.indexOf('{', startIndex);
  if (firstBrace < 0) return '';
  let depth = 0;
  let inString = false;
  let quote = '';
  let escaped = false;
  for (let i = firstBrace; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === quote) {
        inString = false;
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = true;
      quote = ch;
      continue;
    }
    if (ch === '{') depth += 1;
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(firstBrace, i + 1);
    }
  }
  return '';
}

function parseJsonParseCall(text) {
  const source = String(text || '').trim();
  const match = source.match(/^JSON\.parse\(\s*(["'])((?:\\.|(?!\1)[\s\S])*)\1\s*\)/);
  if (!match) return null;
  try {
    const decodedString = JSON.parse(`${match[1]}${match[2]}${match[1]}`);
    return safeParseJsonText(decodedString);
  } catch (_) {
    return null;
  }
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

function createMediaAccumulator() {
  const video = [];
  const image = [];
  const cover = [];
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
    seen[bucket].add(url);
    if (bucket === 'video') video.push(url);
    if (bucket === 'image') image.push(url);
    if (bucket === 'cover') cover.push(url);
    addHint(hint);
  }

  return { video, image, cover, hints, addUrl, addHint };
}

function classifyMediaUrl(url, keyPath = '') {
  const hint = String(keyPath || '');
  if (COVER_FIELD_PATTERN.test(hint)) return 'cover';
  if (IMAGE_FIELD_PATTERN.test(hint) && !VIDEO_FIELD_PATTERN.test(hint)) return 'image';
  if (VIDEO_FIELD_PATTERN.test(hint) || VIDEO_URL_HINT_PATTERN.test(url)) return 'video';
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

  media.video.sort((a, b) => Number(VIDEO_URL_HINT_PATTERN.test(b)) - Number(VIDEO_URL_HINT_PATTERN.test(a)));
  return {
    videoUrls: media.video.slice(0, 20),
    imageUrls: media.image.slice(0, 30),
    coverUrls: media.cover.slice(0, 20),
    mediaDiagnostics: {
      hasVideo: media.video.length > 0,
      videoUrlCount: media.video.length,
      imageUrlCount: media.image.length,
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

// ── SSRF 加固：阻止抓取 localhost / 私网 / 链路本地 / 云元数据，含 DNS 解析与逐跳重定向校验 ──
const SSRF_ERROR = new Error('BLOCKED_URL'); // 统一对外泛化文案，不泄露内部细节

// 从用户输入里抽出一个 http(s) URL（兼容整段分享语）。
function extractHttpUrl(input) {
  const raw = String(input || '').trim();
  const m = raw.match(/https?:\/\/[^\s]+/i);
  const candidate = m ? m[0].replace(/[，。、,.;；]+$/, '') : raw;
  if (!/^https?:\/\//i.test(candidate)) return null;
  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u;
  } catch (_) { return null; }
}

// 主机名层面的硬拒绝（localhost 及其子域）。
function isBlockedHostname(hostname) {
  const h = String(hostname || '').trim().toLowerCase().replace(/\.$/, '');
  if (!h) return true;
  if (h === 'localhost' || h.endsWith('.localhost')) return true;
  return false;
}

// 归一化 IP：去掉 IPv6 方括号 / zone id，IPv4-mapped IPv6（::ffff:a.b.c.d）拆出内嵌 v4。
function normalizeIp(ip) {
  let s = String(ip || '').trim().replace(/^\[/, '').replace(/\]$/, '');
  const pct = s.indexOf('%'); // 去掉 zone id（fe80::1%eth0）
  if (pct >= 0) s = s.slice(0, pct);
  // IPv4-mapped IPv6（点分形式）：::ffff:127.0.0.1 → 127.0.0.1
  const mappedDotted = s.match(/^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i);
  if (mappedDotted) return mappedDotted[1];
  // IPv4-mapped IPv6（十六进制形式，URL 解析后常见）：::ffff:7f00:1 → 127.0.0.1
  const mappedHex = s.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i);
  if (mappedHex) {
    const hi = parseInt(mappedHex[1], 16), lo = parseInt(mappedHex[2], 16);
    return [(hi >> 8) & 255, hi & 255, (lo >> 8) & 255, lo & 255].join('.');
  }
  return s;
}

// 判定 IP 是否落在被禁网段（环回 / 私网 / 链路本地 / CGNAT / 云元数据 / ULA 等）。
function isBlockedIp(rawIp) {
  const ip = normalizeIp(rawIp);
  const fam = net.isIP(ip);
  if (fam === 4) {
    const p = ip.split('.').map(Number);
    if (p.length !== 4 || p.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return true;
    const [a, b] = p;
    if (a === 0) return true;                         // 0.0.0.0/8（含 unspecified）
    if (a === 127) return true;                       // 127.0.0.0/8 环回
    if (a === 10) return true;                        // 10.0.0.0/8
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a === 192 && b === 168) return true;          // 192.168.0.0/16
    if (a === 169 && b === 254) return true;          // 169.254.0.0/16（含 169.254.169.254 / .170.2）
    if (a === 100 && b >= 64 && b <= 127) return true;// 100.64.0.0/10 CGNAT
    if (a === 192 && b === 0) return true;            // 192.0.0.0/24 + 192.0.2.0/24（保留/文档）
    if (a === 198 && (b === 18 || b === 19)) return true; // 198.18.0.0/15 基准测试
    if (a >= 224) return true;                        // 224/4 组播 + 240/4 保留
    return false;
  }
  if (fam === 6) {
    const s = ip.toLowerCase();
    if (s === '::1' || s === '::') return true;        // 环回 / unspecified
    if (s.startsWith('fe8') || s.startsWith('fe9') || s.startsWith('fea') || s.startsWith('feb')) return true; // fe80::/10 链路本地
    if (s.startsWith('fc') || s.startsWith('fd')) return true; // fc00::/7 ULA
    if (s.startsWith('ff')) return true;               // ff00::/8 组播
    return false;
  }
  return true; // 非法 / 无法识别 → 一律拒绝
}

// 解析并校验一个 URL 是否为「可抓取的公网地址」；返回已校验的 { hostname, ip, family }。
// host 本身是 IP → 直接判定，不做 DNS；否则解析全部 A/AAAA，任一被禁即拒绝。
async function resolveAndValidatePublicUrl(urlObj) {
  if (urlObj.protocol !== 'http:' && urlObj.protocol !== 'https:') throw SSRF_ERROR;
  const hostname = urlObj.hostname;
  if (isBlockedHostname(hostname)) throw SSRF_ERROR;

  const literal = net.isIP(normalizeIp(hostname));
  if (literal) {
    if (isBlockedIp(hostname)) throw SSRF_ERROR;
    return { hostname, ip: normalizeIp(hostname), family: literal };
  }

  let records = [];
  try { records = await dns.lookup(hostname, { all: true }); }
  catch (_) { throw SSRF_ERROR; }
  if (!records.length) throw SSRF_ERROR;
  for (const r of records) { if (isBlockedIp(r.address)) throw SSRF_ERROR; }

  // 钉死其中一个已校验地址用于实际连接，规避 DNS rebinding。
  const chosen = records[0];
  return { hostname, ip: normalizeIp(chosen.address), family: chosen.family };
}

// 自定义 lookup：始终返回已校验过的 IP，让连接钉在该 IP（仍保留原 hostname → Host/SNI 不变）。
function createPinnedLookup(ip, family) {
  return function pinnedLookup(_hostname, options, callback) {
    const cb = typeof options === 'function' ? options : callback;
    if (options && typeof options === 'object' && options.all) return cb(null, [{ address: ip, family }]);
    return cb(null, ip, family);
  };
}

// 手动逐跳跟随重定向（最多 maxHops 跳），每跳都重新做 URL/DNS/IP 校验并钉死 IP。
async function fetchFollowingRedirectsSafely(startUrl, maxHops = 5) {
  let current = startUrl;
  for (let hop = 0; hop <= maxHops; hop++) {
    const validated = await resolveAndValidatePublicUrl(current);
    const lookup = createPinnedLookup(validated.ip, validated.family);
    const agent = current.protocol === 'https:'
      ? new https.Agent({ lookup, keepAlive: false })
      : new http.Agent({ lookup, keepAlive: false });

    const resp = await axios.get(current.href, {
      maxRedirects: 0,                 // 禁用自动重定向，手动逐跳校验
      timeout: 12000,
      responseType: 'text',
      transformResponse: r => r,
      maxContentLength: 5 * 1024 * 1024,
      maxBodyLength: 5 * 1024 * 1024,
      httpAgent: agent,
      httpsAgent: agent,
      headers: {
        'User-Agent': MOBILE_UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      validateStatus: s => s >= 200 && s < 400
    });

    if (resp.status >= 300 && resp.status < 400) {
      const loc = resp.headers && resp.headers.location;
      if (!loc) throw SSRF_ERROR;
      let next;
      try { next = new URL(loc, current); } catch (_) { throw SSRF_ERROR; } // 支持相对 Location
      if (next.protocol !== 'http:' && next.protocol !== 'https:') throw SSRF_ERROR;
      current = next;
      continue;
    }
    return { resp, finalUrl: current.href };
  }
  throw SSRF_ERROR; // 超过最大跳数
}

const MEDIA_TMP_DIR = path.join(os.tmpdir(), 'kitchenmanager-media');
const MEDIA_MAX_VIDEO_BYTES = 80 * 1024 * 1024;
const MEDIA_DOWNLOAD_TIMEOUT_MS = 30000;
const MEDIA_FILE_TTL_MS = 60 * 60 * 1000;
const MEDIA_TOO_LARGE_ERROR = new Error('MEDIA_TOO_LARGE');
const MEDIA_DOWNLOAD_ERROR = new Error('MEDIA_DOWNLOAD_FAILED');
const MEDIA_FFMPEG_ERROR = new Error('MEDIA_FFMPEG_FAILED');
const MEDIA_TRANSCRIBE_ERROR = new Error('MEDIA_TRANSCRIBE_FAILED');
const MEDIA_EMPTY_TRANSCRIPT_ERROR = new Error('MEDIA_EMPTY_TRANSCRIPT');

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

function resolveMediaAudioPath(audioPath) {
  const basename = String(audioPath || '').trim();
  if (!basename || basename !== path.basename(basename)) return null;
  if (!/^[a-zA-Z0-9._-]+\.(?:m4a|mp3|wav|aac)$/i.test(basename)) return null;
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

function getTranscriptText(payload) {
  if (!payload || typeof payload !== 'object') return '';
  return String(payload.text || payload.transcript || '').trim();
}

async function transcribeAudioFile(audioFilePath) {
  if (!OPENAI_API_KEY) throw new Error('MISSING_OPENAI_API_KEY');
  if (typeof fetch !== 'function' || typeof FormData === 'undefined' || typeof Blob === 'undefined') {
    throw MEDIA_TRANSCRIBE_ERROR;
  }
  const audioBuffer = await fs.promises.readFile(audioFilePath);
  const form = new FormData();
  form.append('model', OPENAI_TRANSCRIBE_MODEL);
  form.append('response_format', 'json');
  form.append('language', 'zh');
  form.append('file', new Blob([audioBuffer], { type: getAudioMimeType(audioFilePath) }), path.basename(audioFilePath));

  let response;
  try {
    response = await fetch(resolveAudioTranscriptionsUrl(OPENAI_BASE_URL), {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`
      },
      body: form
    });
  } catch (_) {
    throw MEDIA_TRANSCRIBE_ERROR;
  }

  let payload = null;
  try {
    payload = await response.json();
  } catch (_) {
    payload = null;
  }
  if (!response.ok) throw MEDIA_TRANSCRIBE_ERROR;
  const transcript = getTranscriptText(payload);
  if (!transcript) throw MEDIA_EMPTY_TRANSCRIPT_ERROR;
  return {
    transcript,
    model: OPENAI_TRANSCRIBE_MODEL,
    transcriptLength: transcript.length
  };
}

// 代理路由：抓取并返回菜谱文案。
app.get('/api/xhs-extract', async (req, res) => {
  // 模糊提取：允许用户传整段小红书分享语，服务端再用同一条正则兜底捕获 URL。
  const startUrl = extractHttpUrl(req.query.url);
  if (!startUrl) return res.status(400).json({ error: '仅支持 http/https 链接。' });

  let fetched;
  try {
    fetched = await fetchFollowingRedirectsSafely(startUrl, 5);
  } catch (err) {
    if (err === SSRF_ERROR) {
      // 泛化文案：不回显内部 IP / 主机 / DNS / stack
      return res.status(400).json({ error: '不支持的链接地址，请粘贴公开的小红书/网页链接或菜谱文字。' });
    }
    return res.status(502).json({ error: '链接抓取失败，请稍后重试或粘贴菜谱文字。' });
  }

  try {
    const resp = fetched.resp;
    const html = String(resp.data || '');
    if (/验证码|滑块验证|滑动验证|安全验证|captcha/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
      return res.status(502).json({ error: '链接被平台验证拦截，当前只能解析公开页面文字。' });
    }

    const source = extractRecipeSourceFromHtml(html, { url: startUrl.href, finalUrl: fetched.finalUrl });
    const media = extractMediaFromHtml(html, { url: startUrl.href, finalUrl: fetched.finalUrl });
    const text = source.trustedText || source.cleanedRecipeText;
    if (!text) {
      return res.status(422).json({ error: '没能从链接页面文字中提取到菜谱文案，请稍后重试或手动编辑。' });
    }
    const sourceSplit = splitRecipeSourceText(text);
    const warnings = uniqueTextList([
      ...source.warnings,
      ...(media.mediaDiagnostics.hasVideo ? [] : ['未从页面中提取到可用视频地址。'])
    ], 12);

    // finalUrl 已逐跳校验，只会是公网地址，不泄露内部主机。
    return res.json({
      text,
      finalUrl: fetched.finalUrl,
      url: startUrl.href,
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
    });
  } catch (err) {
    return res.status(502).json({ error: '链接抓取失败，请稍后重试或粘贴菜谱文字。' });
  }
});

app.post('/api/media/extract-audio', async (req, res) => {
  const videoUrl = String(req.body?.videoUrl || '').trim();
  if (!videoUrl) {
    return res.status(400).json({ ok: false, error: '缺少 videoUrl。', message: '缺少 videoUrl。' });
  }

  let downloaded = null;
  try {
    await cleanupOldMediaFiles();
    downloaded = await downloadVideoToTemp(videoUrl);
    const audioPath = path.join(MEDIA_TMP_DIR, `${downloaded.id}.m4a`);
    const { durationSeconds } = await extractAudioWithFfmpeg(downloaded.videoPath, audioPath);
    const audioStat = await fs.promises.stat(audioPath);
    await cleanupOldMediaFiles();
    return res.json({
      ok: true,
      audioPath: path.basename(audioPath),
      durationSeconds,
      bytes: audioStat.size,
      videoBytes: downloaded.bytes
    });
  } catch (err) {
    if (err === MEDIA_TOO_LARGE_ERROR) {
      return res.status(413).json({ ok: false, error: '视频文件过大，暂不支持导入。', message: '视频文件过大，暂不支持导入。' });
    }
    if (err === MEDIA_FFMPEG_ERROR) {
      return res.status(502).json({ ok: false, error: '音频提取失败，请稍后重试。', message: '音频提取失败，请稍后重试。' });
    }
    if (err === SSRF_ERROR) {
      return res.status(400).json({ ok: false, error: '不支持的视频地址。', message: '不支持的视频地址。' });
    }
    return res.status(502).json({ ok: false, error: '视频下载失败，请稍后重试。', message: '视频下载失败，请稍后重试。' });
  }
});

app.post('/api/media/transcribe', async (req, res) => {
  if (!OPENAI_API_KEY) {
    return res.status(503).json({ ok: false, error: '后端未配置 AI 密钥。', message: '后端未配置 AI 密钥。' });
  }
  const audioPathInput = String(req.body?.audioPath || '').trim();
  const audioPath = resolveMediaAudioPath(audioPathInput);
  if (!audioPath) {
    return res.status(400).json({ ok: false, error: '音频文件标识不合法。', message: '音频文件标识不合法。' });
  }
  try {
    await fs.promises.access(audioPath, fs.constants.R_OK);
  } catch (_) {
    return res.status(404).json({ ok: false, error: '音频文件不存在。', message: '音频文件不存在。' });
  }

  try {
    const result = await transcribeAudioFile(audioPath);
    return res.json({ ok: true, ...result });
  } catch (err) {
    if (err === MEDIA_EMPTY_TRANSCRIPT_ERROR) {
      return res.status(502).json({ ok: false, error: '音频转录结果为空，请稍后重试。', message: '音频转录结果为空，请稍后重试。' });
    }
    return res.status(502).json({ ok: false, error: '音频转录失败，请稍后重试。', message: '音频转录失败，请稍后重试。' });
  }
});

// ── 终极降级兜底：把模型的 JSON 在服务端再清洗一遍，确保「常备品过滤 / qty 非空 / method 无序号前缀」三条铁律生效。──
const PANTRY_BLACKLIST = ['水', '油', '食用油', '盐', '味精', '鸡精', '植物油', '菜籽油', '大豆油', '玉米油', '葵花籽油', '调和油', '色拉油'];

function safeParseModelJson(raw) {
  if (raw && typeof raw === 'object') return raw;
  const s = String(raw || '').replace(/```json/gi, '').replace(/```/g, '').trim();
  const a = s.indexOf('{'), b = s.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try { return JSON.parse(s.slice(a, b + 1)); } catch (_) { return null; }
}

function stripStepPrefix(s) {
  return String(s || '')
    .replace(/^[\s\-•·]*(?:第[一二三四五六七八九十百零\d]+步[:：]?|步骤[一二三四五六七八九十百零\d]+[:：]?|[一二三四五六七八九十]+[、.．。)）][\s]*|\d+\s*[.、．。)）:：][\s]*|\(\d+\)\s*)/u, '')
    .trim();
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

function stripUnsupportedGenericMethodSteps(steps, evidence) {
  if (!Array.isArray(steps) || hasUsefulEvidenceActions(evidence)) return steps;
  return steps.filter(step => {
    const text = String(step || '').trim();
    return !GENERIC_UNSUPPORTED_METHOD_PATTERN.test(text) && !SHORT_GENERIC_FINISH_PATTERN.test(text);
  });
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

function uniqueTextList(list, limit = 12) {
  const seen = new Set();
  return list.map(item => String(item || '').trim())
    .filter(Boolean)
    .filter(item => !seen.has(item) && seen.add(item))
    .slice(0, limit);
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

function normalizeSourceType(sourceType, { imageBase64 = null } = {}) {
  const raw = String(sourceType || '').trim().toLowerCase();
  if (['xiaohongshu', 'video', 'web', 'manual'].includes(raw)) return raw;
  return imageBase64 ? 'manual' : 'manual';
}

function getObservedActionCount(evidence) {
  return Array.isArray(evidence?.observedActions) ? evidence.observedActions.length : 0;
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

function buildSourceExtractionDiagnostics({ sourceType = 'manual', sourceText = '', imageBase64 = null, evidence = null, recipe = null, sourceSplit = null, sourceMetadata = null } = {}) {
  const normalizedSourceType = normalizeSourceType(sourceType, { imageBase64 });
  const rawText = String(sourceText || '').trim();
  const split = sourceSplit || splitRecipeSourceText(rawText);
  const metadata = sourceMetadata && typeof sourceMetadata === 'object' ? sourceMetadata : {};
  const cleanedRecipeText = String(split.cleanedRecipeText || '').trim();
  const excludedSocialText = String(split.excludedSocialTextPreview || split.commentText || '').trim();
  const observedIngredientCount = getObservedIngredientCount(evidence);
  const observedSeasoningCount = getObservedSeasoningCount(evidence);
  const observedActionCount = getObservedActionCount(evidence);
  const methodText = recipe
    ? (Array.isArray(recipe.method) ? recipe.method.join('\n') : String(recipe.method || ''))
    : '';
  const methodStepCount = recipe ? countRecipeMethodSteps(methodText) : 0;
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
  if (metadata.extractionMode === 'link-only') warnings.push('链接解析结果：仅从页面文字中提取，未读取视频画面。');
  if (Array.isArray(metadata.warnings)) metadata.warnings.forEach(w => warnings.push(String(w || '').trim()));
  if (excludedSocialText) warnings.push('已忽略疑似评论/弹幕/推荐文案，避免污染菜谱。');
  if (observedIngredientCount < 3) warnings.push('识别到的核心食材较少。');
  if (observedActionCount < 3) warnings.push('识别到的明确做法步骤较少。');
  if (!hasCaption && !hasDescription && !hasOcrText && !hasTranscript && !hasVideoFrames && !hasImages) {
    warnings.push('未获取到可用的正文、字幕、OCR、视频帧或图片信息。');
  }
  if (recipe && ['xiaohongshu', 'video', 'web'].includes(normalizedSourceType) && methodStepCount > 0 && methodStepCount < 3) {
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
    (recipe && ['xiaohongshu', 'video', 'web'].includes(normalizedSourceType) && methodStepCount > 0 && methodStepCount < 3)
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
    url: metadata.url || '',
    finalUrl: metadata.finalUrl || '',
    extractionMode: metadata.extractionMode || '',
    hasHtml: Boolean(metadata.hasHtml),
    hasStructuredMeta: Boolean(metadata.hasStructuredMeta),
    hasOgDescription: Boolean(metadata.hasOgDescription),
    hasJsonLd: Boolean(metadata.hasJsonLd),
    hasInitialState: Boolean(metadata.hasInitialState),
    trustedTextLength: Number.isFinite(metadata.trustedTextLength) ? metadata.trustedTextLength : rawText.length,
    trustedTextPreview: String(metadata.trustedTextPreview || rawText.slice(0, 400)).trim().slice(0, 400),
    rawTextLength: Number.isFinite(metadata.rawTextLength) ? metadata.rawTextLength : rawText.length,
    rawTextPreview: String(metadata.rawTextPreview || rawText.slice(0, 400)).trim().slice(0, 400),
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
    warnings: [...new Set(warnings.map(w => String(w || '').trim()).filter(Boolean))]
  };
}

function getSourceDiagnosticsWarnings(diagnostics) {
  if (!diagnostics || typeof diagnostics !== 'object') return [];
  const warnings = [];
  if (diagnostics.sourceConfidence === 'low') {
    warnings.push('链接可提取信息较少，菜谱可能缺少食材、调料或步骤，请人工确认。');
  }
  return warnings;
}

function buildDebugEvidenceSummary({ sourceText = '', evidence = null, diagnostics = null, sourceSplit = null } = {}) {
  const actions = Array.isArray(evidence?.observedActions)
    ? evidence.observedActions.map(action => String(action?.action || '').trim()).filter(Boolean).slice(0, 8)
    : [];
  const split = sourceSplit || splitRecipeSourceText(sourceText);
  return {
    sourceTextSnippet: String(sourceText || '').trim().slice(0, 400),
    cleanedTextSnippet: String(split.cleanedRecipeText || '').trim().slice(0, 400),
    excludedSocialTextSnippet: String(split.excludedSocialTextPreview || split.commentText || '').trim().slice(0, 400),
    sourceSegmentsPreview: Array.isArray(split.sourceSegmentsPreview) ? split.sourceSegmentsPreview.slice(0, 8) : [],
    observedIngredients: [
      ...listEvidenceField(evidence, 'observedMainIngredients'),
      ...listEvidenceField(evidence, 'observedAromatics'),
      ...listEvidenceField(evidence, 'observedLiquids')
    ].slice(0, 20),
    observedSeasonings: listEvidenceField(evidence, 'observedSeasonings').slice(0, 20),
    observedActions: actions,
    diagnostics
  };
}

function normalizeEvidenceName(name) {
  return String(name || '').replace(/^#+/u, '').trim();
}

function pickDraftRecipeNameFromEvidence(evidence, sourceSplit) {
  const names = [
    ...listEvidenceField(evidence, 'dishNameCandidates'),
    ...(Array.isArray(sourceSplit?.weakRecipeHints) ? sourceSplit.weakRecipeHints : []),
    String(sourceSplit?.authorCandidateText || '').split(/\n+/)[0] || ''
  ]
    .flatMap(item => String(item || '').split(/\s+/))
    .map(normalizeEvidenceName)
    .filter(Boolean)
    .filter(name => !/家常菜|美食|教程|详细版|食谱|下饭菜/u.test(name));
  return names.sort((a, b) => b.length - a.length)[0] || '未命名菜谱';
}

function evidenceItemsToRecipeRows(items) {
  return uniqueTextList(items, 12).map(item => ({ item, qty: '', unit: '' }));
}

function shouldReturnLowEvidenceDraft({ sourceType, evidence }) {
  const normalizedSourceType = normalizeSourceType(sourceType);
  if (!['xiaohongshu', 'video', 'web'].includes(normalizedSourceType)) return false;
  return getObservedActionCount(evidence) === 0;
}

function buildLowEvidenceRecipeDraft({ sourceType, evidence, sourceSplit, diagnostics }) {
  const warning = '清洗后可用菜谱正文较少，未能可靠提取完整做法，请补充原文或手动编辑。';
  return {
    name: pickDraftRecipeNameFromEvidence(evidence, sourceSplit),
    tags: ['AI草稿', 'AI导入'],
    ingredients: evidenceItemsToRecipeRows([
      ...listEvidenceField(evidence, 'observedMainIngredients'),
      ...listEvidenceField(evidence, 'observedAromatics'),
      ...listEvidenceField(evidence, 'observedLiquids')
    ]),
    seasonings: evidenceItemsToRecipeRows(listEvidenceField(evidence, 'observedSeasonings')),
    method: [],
    warnings: [...new Set([warning, ...getSourceDiagnosticsWarnings(diagnostics)])],
    needsReview: true,
    sourceType: normalizeSourceType(sourceType)
  };
}

function applySourceDiagnosticsWarnings(recipe, diagnostics) {
  if (!recipe || typeof recipe !== 'object') return recipe;
  const existingWarnings = Array.isArray(recipe.warnings)
    ? recipe.warnings.map(w => String(w || '').trim()).filter(Boolean)
    : [];
  recipe.warnings = [...new Set([...existingWarnings, ...getSourceDiagnosticsWarnings(diagnostics)])];
  if (recipe.warnings.length) recipe.needsReview = true;
  return recipe;
}

function checkRecipeStepCoverage(recipe, { sourceText = '', evidence = null, diagnostics = null } = {}) {
  const items = [
    ...(Array.isArray(recipe?.ingredients) ? recipe.ingredients : []),
    ...(Array.isArray(recipe?.seasonings) ? recipe.seasonings : []),
    ...listEvidenceItems(evidence)
  ].map(item => String(item?.item || item?.name || item || '').trim()).filter(Boolean);
  const methodText = Array.isArray(recipe?.method)
    ? recipe.method.join('\n')
    : Array.isArray(recipe?.steps)
      ? recipe.steps.join('\n')
      : String(recipe?.method || '');
  const missingInSteps = [];
  const evidenceActionText = getEvidenceActionText(evidence);
  const evidenceText = [sourceText, evidenceActionText].map(s => String(s || '').trim()).filter(Boolean).join('\n');

  for (const rule of RECIPE_STEP_COVERAGE_RULES) {
    const matched = items.find(name => rule.ingredient.test(name));
    if (!matched) continue;
    rule.ingredient.lastIndex = 0;
    rule.method.lastIndex = 0;
    if (!rule.method.test(methodText)) missingInSteps.push(matched);
  }

  const uniqueMissing = [...new Set(missingInSteps)];
  const warnings = uniqueMissing.map(name => {
    const rule = RECIPE_STEP_COVERAGE_RULES.find(item => item.ingredient.test(name));
    if (rule) rule.ingredient.lastIndex = 0;
    return rule ? getRecipeStepCoverageWarning(rule, name) : `关键材料${name}未在做法中明确出现，请确认加入时机。`;
  });
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

// 强制 qty / unit 兜底；qty 必须是数字字符串，否则统一 "1"；空 unit → "份"（食材）或 "适量"（调料）。
function normalizeQtyUnitItem(ing, defaultUnit) {
  if (!ing || typeof ing !== 'object') return null;
  const item = String(ing.item || '').trim();
  if (!item) return null;
  let qty = String(ing.qty == null ? '' : ing.qty).trim();
  if (!qty || qty === 'null' || qty === 'undefined' || /[一-龥]/.test(qty) || !/^\d+(?:\.\d+)?$/.test(qty)) qty = '1';
  let unit = String(ing.unit == null ? '' : ing.unit).trim();
  if (!unit) unit = defaultUnit;
  return { item, qty, unit };
}

function sanitizeRecipe(recipe, options = {}) {
  if (!recipe || typeof recipe !== 'object') return recipe;

  // 收集 seasonings（先建好，方便把 ingredients 里漏网的常备调料挪过来）。
  const seasonings = [];
  if (Array.isArray(recipe.seasonings)) {
    for (const s of recipe.seasonings) {
      const cleaned = normalizeQtyUnitItem(s, '适量');
      if (cleaned) seasonings.push(cleaned);
    }
  }

  // 1) ingredients：常备品兜底 —— 模型漏放了水/油/盐/味精/鸡精 → 转移到 seasonings，不直接丢弃。
  if (Array.isArray(recipe.ingredients)) {
    const cleanIngredients = [];
    for (const ing of recipe.ingredients) {
      const cleaned = normalizeQtyUnitItem(ing, '份');
      if (!cleaned) continue;
      if (PANTRY_BLACKLIST.some(b => cleaned.item.includes(b))) {
        // 漏放的常备品改投 seasonings，unit 若为「份」改为「适量」更贴切。
        seasonings.push({ ...cleaned, unit: cleaned.unit === '份' ? '适量' : cleaned.unit });
      } else {
        cleanIngredients.push(cleaned);
      }
    }
    recipe.ingredients = cleanIngredients;
  }
  recipe.seasonings = seasonings;

  // 2) method：统一为字符串数组，剥掉可能残留的序号前缀
  let steps = null;
  if (Array.isArray(recipe.method)) steps = recipe.method;
  else if (Array.isArray(recipe.steps)) steps = recipe.steps;
  else if (typeof recipe.method === 'string') steps = recipe.method.split(/\n+/);
  if (Array.isArray(steps)) {
    recipe.method = steps
      .map(stripStepPrefix)
      .filter(s => s && s.length > 1);
    const beforeGenericFilterCount = recipe.method.length;
    recipe.method = stripUnsupportedGenericMethodSteps(recipe.method, options.evidence);
    if (beforeGenericFilterCount > recipe.method.length) {
      recipe.warnings = [
        ...(Array.isArray(recipe.warnings) ? recipe.warnings : []),
        '清洗后可用菜谱正文较少，未能可靠提取完整做法，请补充原文或手动编辑。'
      ];
      recipe.needsReview = true;
    }
  }

  const coverage = checkRecipeStepCoverage(recipe, options);
  const existingWarnings = Array.isArray(recipe.warnings)
    ? recipe.warnings.map(w => String(w || '').trim()).filter(Boolean)
    : [];
  recipe.warnings = [...new Set([...existingWarnings, ...coverage.warnings])];
  if (recipe.warnings.length) recipe.needsReview = true;

  // 3) tags 收敛 + name 去空白
  if (Array.isArray(recipe.tags)) {
    recipe.tags = recipe.tags.map(t => String(t || '').trim()).filter(Boolean).slice(0, 4);
  }
  if (recipe.name != null) recipe.name = String(recipe.name).trim();

  return recipe;
}

app.get('/api/ai-status', (req, res) => {
  const baseUrlConfigured = Boolean(String(OPENAI_BASE_URL || '').trim());
  const apiKeyConfigured = Boolean(String(OPENAI_API_KEY || '').trim());
  const rawTextModelConfigured = Boolean(String(OPENAI_MODEL || '').trim());
  const rawVisionModelConfigured = Boolean(String(OPENAI_VISION_MODEL || '').trim());
  const textModelConfigured = apiKeyConfigured && rawTextModelConfigured;
  const visionModelConfigured = apiKeyConfigured && rawVisionModelConfigured;
  const available = apiKeyConfigured && baseUrlConfigured && rawTextModelConfigured && rawVisionModelConfigured;
  let code = '';
  let message = available ? '内置 AI 服务已配置' : '内置 AI 服务暂不可用';
  if (!apiKeyConfigured) {
    code = 'missing_api_key';
    message = '内置 AI 服务未配置';
  } else if (!baseUrlConfigured) {
    code = 'missing_base_url';
    message = '内置 AI 服务地址未配置';
  } else if (!rawTextModelConfigured) {
    code = 'missing_text_model';
    message = '文本模型未配置';
  } else if (!rawVisionModelConfigured) {
    code = 'missing_vision_model';
    message = '图片识别模型未配置';
  }
  res.json({
    available,
    mode: 'cloud',
    textModelConfigured,
    visionModelConfigured,
    baseUrlConfigured,
    modelConfigured: textModelConfigured,
    imageMaxBase64Bytes: AI_IMAGE_MAX_BASE64_BYTES,
    ...(code ? { code } : {}),
    message
  });
});

// 默认 AI 代理：前端不持有密钥；只返回模型内容和安全的错误状态，不透出密钥。
app.post('/api/ai-chat', async (req, res) => {
  if (isAiRateLimited(req)) return sendAiJsonError(res, 429, 'rate_limited', 'AI 请求太频繁，请稍后再试。');
  if (!OPENAI_API_KEY) return sendAiJsonError(res, 503, 'missing_api_key', 'AI 服务暂时不可用。');

  const body = req.body || {};
  const prompt = String(body.prompt || '').trim();
  const imageBase64 = body.imageBase64 ? String(body.imageBase64) : '';
  const taskType = String(body.taskType || 'general').trim().slice(0, 40) || 'general';

  if (!prompt) return sendAiJsonError(res, 400, 'missing_prompt', '缺少 prompt。');
  if (prompt.length > AI_PROMPT_MAX_CHARS) return sendAiJsonError(res, 413, 'prompt_too_large', 'prompt 过长。', { maxChars: AI_PROMPT_MAX_CHARS });
  if (estimateBase64EncodedBytes(imageBase64) > AI_IMAGE_MAX_BASE64_BYTES) {
    return sendAiJsonError(res, 413, 'image_too_large', '图片过大。', { maxBase64Bytes: AI_IMAGE_MAX_BASE64_BYTES });
  }

  const userContent = imageBase64
    ? [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: imageBase64 } }]
    : prompt;
  const model = imageBase64 ? OPENAI_VISION_MODEL : OPENAI_MODEL;

  try {
    const resp = await axios.post(
      resolveChatUrl(OPENAI_BASE_URL),
      {
        model,
        messages: [
          { role: 'system', content: `Kitchen Manager task: ${taskType}. Return only the requested content.` },
          { role: 'user', content: userContent }
        ],
        temperature: 0.2
      },
      {
        timeout: 45000,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
      }
    );
    const content = resp.data && resp.data.choices && resp.data.choices[0] && resp.data.choices[0].message
      ? (resp.data.choices[0].message.content || '')
      : '';
    if (!content) return sendAiJsonError(res, 502, 'empty_response', 'AI 服务暂时不可用。');
    return res.json({ content });
  } catch (err) {
    return sendAiUpstreamError(res, err);
  }
});

// AI 解析路由：文本用 OPENAI_MODEL，图片用 OPENAI_VISION_MODEL，密钥来自 Render 环境变量。
app.post('/api/ai-parse', async (req, res) => {
  const text = String((req.body && req.body.text) || '').trim();
  const imageBase64 = (req.body && req.body.imageBase64) || null;
  const sourceMetadata = req.body && req.body.sourceMetadata && typeof req.body.sourceMetadata === 'object'
    ? req.body.sourceMetadata
    : null;
  if (!text && !imageBase64) return sendAiJsonError(res, 400, 'missing_input', '缺少待解析的文案或图片。');
  if (!OPENAI_API_KEY) return sendAiJsonError(res, 503, 'missing_api_key', '后端未配置 AI 密钥（OPENAI_API_KEY）。');
  if (estimateBase64EncodedBytes(imageBase64) > AI_IMAGE_MAX_BASE64_BYTES) {
    return sendAiJsonError(res, 413, 'image_too_large', '图片过大。', { maxBase64Bytes: AI_IMAGE_MAX_BASE64_BYTES });
  }

  const sourceType = normalizeSourceType(req.body && req.body.sourceType, { imageBase64 });
  const sourceSplit = splitRecipeSourceText(text);
  const evidenceSourceText = sourceSplit.cleanedRecipeText || (sourceType === 'manual' ? text : '');
  const evidenceInstruction = text
    ? `请从下面这段【cleanedRecipeText】抽取菜谱 evidence。只记录明确出现的信息，不要生成最终菜谱。不要使用 comments/excludedSocialText 中的内容：\n\n${evidenceSourceText}`
    : '请根据这张配料表/菜谱截图抽取菜谱 evidence。只记录明确出现的信息，不要生成最终菜谱。';
  const evidenceUserContent = imageBase64
    ? [{ type: 'text', text: evidenceInstruction }, { type: 'image_url', image_url: { url: imageBase64 } }]
    : evidenceInstruction;

  try {
    const evidenceResp = await axios.post(
      resolveChatUrl(OPENAI_BASE_URL),
      {
        model: imageBase64 ? OPENAI_VISION_MODEL : OPENAI_MODEL,
        messages: [
          { role: 'system', content: RECIPE_EVIDENCE_SYSTEM_PROMPT },
          { role: 'user', content: evidenceUserContent }
        ],
        temperature: 0.2,
        response_format: { type: 'json_object' }
      },
      {
        timeout: 45000,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
      }
    );
    const evidenceContent = getAiMessageContent(evidenceResp);
    if (!evidenceContent) return sendAiJsonError(res, 502, 'empty_response', 'AI 没有返回证据内容，请稍后重试。');
    const evidence = safeParseModelJson(evidenceContent);
    if (!evidence) return sendAiJsonError(res, 502, 'bad_evidence_json', 'AI 没有返回可识别的菜谱证据，请稍后重试。');

    const initialDiagnostics = buildSourceExtractionDiagnostics({ sourceType, sourceText: text, imageBase64, evidence, sourceSplit, sourceMetadata });
    if (shouldReturnLowEvidenceDraft({ sourceType, evidence })) {
      const draft = buildLowEvidenceRecipeDraft({ sourceType, evidence, sourceSplit, diagnostics: initialDiagnostics });
      const diagnostics = buildSourceExtractionDiagnostics({ sourceType, sourceText: text, imageBase64, evidence, recipe: draft, sourceSplit, sourceMetadata });
      applySourceDiagnosticsWarnings(draft, diagnostics);
      const debugEvidenceSummary = buildDebugEvidenceSummary({ sourceText: text, evidence, diagnostics, sourceSplit });
      return res.json({ content: JSON.stringify(draft), recipe: draft, evidence, diagnostics, debugEvidenceSummary });
    }
    const recipeInstruction = `请根据下面的 evidence JSON 和 sourceDiagnostics 生成最终菜谱 JSON。method 必须按 observedActions 顺序生成；不要新增 evidence 不支持的关键动作。若 sourceDiagnostics.sourceConfidence 为 low，只生成证据支持的 draft，并在 warnings 中提示信息不足。\n\n${JSON.stringify({ evidence, sourceDiagnostics: initialDiagnostics })}`;
    const recipeResp = await axios.post(
      resolveChatUrl(OPENAI_BASE_URL),
      {
        model: OPENAI_MODEL,
        messages: [
          { role: 'system', content: IMPORT_SYSTEM_PROMPT },
          { role: 'user', content: recipeInstruction }
        ],
        temperature: 0.2,
        response_format: { type: 'json_object' }
      },
      {
        timeout: 45000,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
      }
    );
    const content = getAiMessageContent(recipeResp);
    if (!content) return sendAiJsonError(res, 502, 'empty_response', 'AI 没有返回内容，请稍后重试。');

    // ── 终极降级兜底：在后端先清洗一遍 AI 的 JSON，再回给前端。──
    //   保险栈：① 系统提示已硬约束；② 这里 JS 兜底过滤常备品 + qty 必填 + method 剥序号。
    const parsed = safeParseModelJson(content);
    if (parsed) {
      const cleaned = sanitizeRecipe(parsed, { sourceText: evidenceSourceText, evidence, diagnostics: initialDiagnostics });
      const diagnostics = buildSourceExtractionDiagnostics({ sourceType, sourceText: text, imageBase64, evidence, recipe: cleaned, sourceSplit, sourceMetadata });
      applySourceDiagnosticsWarnings(cleaned, diagnostics);
      const debugEvidenceSummary = buildDebugEvidenceSummary({ sourceText: text, evidence, diagnostics, sourceSplit });
      // 同时回传清洗后的对象 + 原 content（前端 validateImportedRecipe 兼容字符串/对象/数组）。
      return res.json({ content: JSON.stringify(cleaned), recipe: cleaned, evidence, diagnostics, debugEvidenceSummary });
    }
    return res.json({ content });
  } catch (err) {
    return sendAiUpstreamError(res, err, 'AI 解析请求失败，请稍后重试。');
  }
});

// 静态托管前端（仓库根目录即站点根）。
app.use(express.static(ROOT, { extensions: ['html'] }));

// 兜底：未匹配的页面请求返回首页（哈希路由由前端处理）。
app.get('*', (req, res) => {
  if (req.path.startsWith('/api/')) return res.status(404).json({ error: 'Not found' });
  res.sendFile(path.join(ROOT, 'index.html'));
});

// 绑定 0.0.0.0：Render 等云平台要求监听所有网卡，并通过 process.env.PORT 注入端口。
app.listen(PORT, '0.0.0.0', () => {
  console.log(`🍳 Kitchen Manager 全栈服务已启动，端口 ${PORT}`);
});
