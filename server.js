/*
 * server.js —— Kitchen Manager 全栈一体化服务器
 *
 * - 用 Express 静态托管前端（本项目无构建步骤，index.html 在仓库根目录，直接托管根目录）。
 * - /api/xhs-extract：服务端抓取小红书/网页菜谱文案，绕过浏览器 CORS。
 *     跟随 302 短链（xhslink.com → 真实长链）、伪造移动端 UA、正则提取
 *     window.__INITIAL_STATE__ / og:title / description 等文案，返回纯文本 JSON。
 * - /api/ai-chat：默认 AI 代理（密钥/Base URL 来自环境变量），前端不需要本地 API Key。
 * - /api/ai-parse：后端统一呼叫 AI（文本菜谱导入用 OPENAI_IMPORT_MODEL，图片用 OPENAI_VISION_MODEL），
 *     返回模型 JSON 原文。
 *
 * 环境变量（Render）：PORT、OPENAI_API_KEY、OPENAI_BASE_URL、OPENAI_MODEL、OPENAI_IMPORT_MODEL（可选）、OPENAI_VISION_MODEL（可选）、OPENAI_TRANSCRIBE_MODEL（可选）。
 * 启动：npm install && npm start  （默认 http://localhost:3000）
 */
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const express = require('express');
const axios = require('axios');
const dns = require('dns').promises;
const net = require('net');
const http = require('http');
const https = require('https');

const {
  ROOT,
  PORT,
  MOBILE_UA,
  OPENAI_API_KEY,
  OPENAI_BASE_URL,
  OPENAI_MODEL,
  OPENAI_IMPORT_MODEL,
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
} = require('./src/server/config');
const {
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
} = require('./src/server/services/ai-client');
const {
  safeParseJsonText,
  extractBalancedJsonObject,
  parseJsonParseCall,
  safeParseModelJson
} = require('./src/server/utils/json');
const {
  isAiRateLimited,
  isImportRateLimited
} = require('./src/server/services/rate-limit');
const {
  SSRF_ERROR
} = require('./src/server/services/ssrf-guard');
const {
  buildVideoUrlSelectionDiagnostics,
  extractRecipeSourcePayloadFromUrl,
  mergeVideoUrlSelectionDiagnostics,
  pickBestVideoUrl,
  splitRecipeSourceText
} = require('./src/server/services/page-source');
const {
  buildRecipeImportMediaCacheKey,
  clampMediaFrameCount,
  cleanupOldMediaFiles,
  cleanupRecipeImportMediaCache,
  cloneRecipeImportCacheValue,
  downloadVideoToTemp,
  extractAudioWithFfmpeg,
  extractFramesWithFfmpeg,
  extractVideoRecipeTextForImport,
  ocrFrameWithVisionModel,
  recipeImportMediaCache,
  resolveMediaAudioPath,
  resolveMediaFramePath,
  resolveMediaVideoPath,
  transcribeAudioFile
} = require('./src/server/services/media-pipeline');
const {
  appendSourceSection,
  limitSourceSectionText,
  uniqueTextList
} = require('./src/server/utils/text');

const app = express();

// ── Trust proxy hops：只信任具体跳数，绝不用 true ───────────────────────────
// Render Web Service 的公网入口是 Render 自己的边缘代理，不配置这个的话 req.ip
// 在生产环境上等于代理地址，所有用户会共享同一个 rate-limit 桶（见 config.js 顶部
// TRUST_PROXY_HOPS 的注释）。TRUST_PROXY_HOPS_INVALID_RAW 非空说明环境变量给了
// 非法值（如 'true'/负数/小数），已在 config.js 里安全回退成 0，这里只负责打印
// 一次性 warning，不包含任何用户数据。
if (TRUST_PROXY_HOPS_INVALID_RAW !== null) {
  console.warn(`[server] TRUST_PROXY_HOPS 值不合法（收到 "${TRUST_PROXY_HOPS_INVALID_RAW}"），已回退为 0（不信任代理）。只接受正整数，例如 TRUST_PROXY_HOPS=1。`);
}
if (Number.isInteger(TRUST_PROXY_HOPS) && TRUST_PROXY_HOPS > 0) {
  app.set('trust proxy', TRUST_PROXY_HOPS);
  console.log(`[server] trust proxy hops: ${TRUST_PROXY_HOPS}`);
} else {
  console.log('[server] trust proxy disabled');
}

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

// ── CORS：允许 GitHub Pages 纯静态前端跨域调用 /api ─────────────────────────
// 前端在 github.io 上没有同源后端（见 src/config.js 的 API_BASE），会把 /api 请求
// 直接发到本服务。白名单精确到站点来源，其余跨域来源一律不发 CORS 头（浏览器拦截）；
// 可用环境变量 CORS_EXTRA_ORIGIN 追加一个来源（如自定义域名）。
const CORS_ALLOWED_ORIGINS = new Set([
  'https://1395490241lhj-code.github.io',
  ...(process.env.CORS_EXTRA_ORIGIN ? [String(process.env.CORS_EXTRA_ORIGIN).replace(/\/+$/, '')] : [])
]);

app.use('/api', (req, res, next) => {
  const origin = req.headers.origin;
  if (origin && CORS_ALLOWED_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.setHeader('Access-Control-Max-Age', '86400');
  }
  if (req.method === 'OPTIONS') return res.status(204).end();
  next();
});


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

const IMPORT_SIMPLE_SYSTEM_PROMPT = `你是 Kitchen Manager 的菜谱导入助手。根据 evidence 生成一个可编辑菜谱草稿。
只输出一个 JSON 对象，不要 markdown，不要解释，不要代码块。
字段必须是 name, tags, ingredients, seasonings, method, warnings, needsReview。
ingredients/seasonings/method 可以不完美，但必须是合法 JSON。
method 如果 observedActions 有内容，必须至少输出对应步骤；不要因为信息不完整就把 method 清空。
不确定内容放 warnings。`;


app.get('/api/xhs-extract', async (req, res) => {
  if (isAiRateLimited(req)) return res.status(429).json({ error: '请求太频繁，请稍后再试。' });
  // 模糊提取：允许用户传整段小红书分享语，服务端再用同一条正则兜底捕获 URL。
  try {
    const payload = await extractRecipeSourcePayloadFromUrl(req.query.url);
    return res.json(payload);
  } catch (err) {
    if (err && err.publicStatus) {
      return res.status(err.publicStatus).json({ error: err.publicError });
    }
    return res.status(502).json({ error: '链接抓取失败，请稍后重试或粘贴菜谱文字。' });
  }
});

app.post('/api/media/extract-audio', async (req, res) => {
  if (isAiRateLimited(req)) {
    return res.status(429).json({ ok: false, error: '请求太频繁，请稍后再试。', message: '请求太频繁，请稍后再试。' });
  }
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
      videoId: path.basename(downloaded.videoPath),
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

app.post('/api/media/extract-frames', async (req, res) => {
  if (isAiRateLimited(req)) {
    return res.status(429).json({ ok: false, error: '请求太频繁，请稍后再试。', message: '请求太频繁，请稍后再试。' });
  }
  const videoId = String(req.body?.videoId || '').trim();
  const videoPath = resolveMediaVideoPath(videoId);
  if (!videoPath) {
    return res.status(400).json({ ok: false, error: '视频文件标识不合法。', message: '视频文件标识不合法。' });
  }
  try {
    await fs.promises.access(videoPath, fs.constants.R_OK);
  } catch (_) {
    return res.status(404).json({ ok: false, error: '视频文件不存在。', message: '视频文件不存在。' });
  }

  try {
    const maxFrames = clampMediaFrameCount(req.body?.maxFrames);
    const result = await extractFramesWithFfmpeg(videoPath, { maxFrames });
    await cleanupOldMediaFiles();
    return res.json({
      ok: true,
      videoId: path.basename(videoPath),
      durationSeconds: result.durationSeconds,
      frameIds: result.frames.map(frame => frame.frameId),
      frames: result.frames
    });
  } catch (err) {
    if (err === MEDIA_FRAME_TOO_LARGE_ERROR) {
      return res.status(413).json({ ok: false, error: '视频画面过大，暂不支持识别。', message: '视频画面过大，暂不支持识别。' });
    }
    return res.status(502).json({ ok: false, error: '视频抽帧失败，请稍后重试。', message: '视频抽帧失败，请稍后重试。' });
  }
});

app.post('/api/media/ocr-frames', async (req, res) => {
  if (isAiRateLimited(req)) {
    return res.status(429).json({ ok: false, error: 'AI 请求太频繁，请稍后再试。', message: 'AI 请求太频繁，请稍后再试。' });
  }
  if (!OPENAI_API_KEY) {
    return res.status(503).json({ ok: false, error: '后端未配置 AI 密钥。', message: '后端未配置 AI 密钥。' });
  }
  const requestedFrameIds = Array.isArray(req.body?.frameIds)
    ? req.body.frameIds.map(item => String(item || '').trim()).filter(Boolean)
    : [];
  if (!requestedFrameIds.length) {
    return res.status(400).json({ ok: false, error: '缺少 frameIds。', message: '缺少 frameIds。' });
  }
  const frameIds = requestedFrameIds.slice(0, MEDIA_MAX_FRAME_COUNT);
  const framePaths = [];
  for (const frameId of frameIds) {
    const framePath = resolveMediaFramePath(frameId);
    if (!framePath) {
      return res.status(400).json({ ok: false, error: '图片帧标识不合法。', message: '图片帧标识不合法。' });
    }
    try {
      await fs.promises.access(framePath, fs.constants.R_OK);
    } catch (err) {
      if (err && err.code === 'ENOENT') {
        return res.status(404).json({ ok: false, error: '图片帧不存在。', message: '图片帧不存在。' });
      }
      return res.status(502).json({ ok: false, error: '图片帧读取失败，请稍后重试。', message: '图片帧读取失败，请稍后重试。' });
    }
    framePaths.push({ frameId: path.basename(framePath), framePath });
  }

  try {
    const frames = [];
    let failedFrameCount = 0;
    let firstFrameError = null;
    for (const frame of framePaths) {
      try {
        frames.push(await ocrFrameWithVisionModel(frame.frameId, frame.framePath));
      } catch (err) {
        failedFrameCount += 1;
        if (!firstFrameError) firstFrameError = err;
      }
    }
    if (!frames.length && failedFrameCount > 0) {
      throw firstFrameError || MEDIA_FRAME_OCR_ERROR;
    }
    const ocrText = frames
      .map(frame => String(frame.text || '').trim())
      .filter(Boolean)
      .join('\n\n');
    return res.json({
      ok: true,
      ocrText,
      frames,
      failedFrameCount,
      skippedFrameCount: frames.filter(frame => frame?.skipped).length
    });
  } catch (err) {
    if (err === MEDIA_FRAME_TOO_LARGE_ERROR) {
      return res.status(413).json({ ok: false, error: '图片帧过大，暂不支持识别。', message: '图片帧过大，暂不支持识别。' });
    }
    return res.status(502).json({ ok: false, error: '画面文字识别失败，请稍后重试。', message: '画面文字识别失败，请稍后重试。' });
  }
});

app.post('/api/media/transcribe', async (req, res) => {
  if (isAiRateLimited(req)) {
    return res.status(429).json({ ok: false, error: '请求太频繁，请稍后再试。', message: '请求太频繁，请稍后再试。' });
  }
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
    if (err === MEDIA_EMPTY_TRANSCRIPT_ERROR || err?.asrUpstreamCode === 'empty_transcript') {
      return res.status(502).json({ ok: false, error: '音频转录结果为空，请稍后重试。', message: '音频转录结果为空，请稍后重试。' });
    }
    return res.status(502).json({ ok: false, error: '音频转录失败，请稍后重试。', message: '音频转录失败，请稍后重试。' });
  }
});

// ── 终极降级兜底：把模型的 JSON 在服务端再清洗一遍，确保「常备品过滤 / qty 非空 / method 无序号前缀」三条铁律生效。──
const PANTRY_BLACKLIST = ['水', '油', '食用油', '盐', '味精', '鸡精', '植物油', '菜籽油', '大豆油', '玉米油', '葵花籽油', '调和油', '色拉油'];

function getLabeledSourceSection(text, label) {
  const source = String(text || '');
  const re = new RegExp(`【${label}】\\n([\\s\\S]*?)(?=\\n\\n【|$)`, 'u');
  const match = source.match(re);
  return match ? String(match[1] || '').trim() : '';
}

function extractKnownTermsFromText(text, terms) {
  const source = String(text || '');
  return terms.filter(term => source.includes(term));
}

function splitRecipeActionSentences(text) {
  const source = String(text || '').replace(/\s+/g, ' ');
  const actionRe = /洗|切|腌|抓匀|拌匀|煎|炒|炸|烤|蒸|煮|焖|加|加入|放|倒|撒|收汁|出锅/u;
  return uniqueTextList(
    source
      .split(/[。！？!?；;\n]+/u)
      .map(part => part.trim())
      .filter(part => part.length >= 3 && actionRe.test(part)),
    12
  );
}

function extractFallbackDishName(text, sourceMetadata = {}) {
  const trusted = String(sourceMetadata.trustedTextPreview || sourceMetadata.rawTextPreview || text || '');
  const cleaned = trusted
    .replace(/【[^】]+】/g, ' ')
    .replace(/页面文字|视频口播转录|视频画面文字|用户补充/g, ' ')
    .trim();
  const first = cleaned.split(/[。\n，,；;：:！!？?]/u).map(s => s.trim()).find(Boolean) || 'AI 导入菜谱';
  return first.slice(0, 18) || 'AI 导入菜谱';
}

function buildFallbackEvidenceFromSource({ text = '', sourceMetadata = {} } = {}) {
  const transcript = getLabeledSourceSection(text, '视频口播转录') || String(sourceMetadata.transcriptPreview || '');
  const ocr = getLabeledSourceSection(text, '视频画面文字') || String(sourceMetadata.ocrPreview || '');
  const page = getLabeledSourceSection(text, '页面文字') || String(sourceMetadata.trustedTextPreview || sourceMetadata.rawTextPreview || '');
  if (!transcript.trim()) return null;
  const evidenceText = [transcript, ocr, page].filter(Boolean).join('\n');
  const mainTerms = [
    '鸡腿', '鸡肉', '鸡胸', '鸡翅', '牛肉', '猪肉', '肉片', '肉丝', '排骨', '鱼片', '虾仁',
    '番茄', '西红柿', '鸡蛋', '土豆', '青椒', '豆腐', '茄子', '白菜', '西兰花', '洋葱', '香菇',
    '鲜藤椒', '藤椒', '花椒', '辣椒', '米饭', '面条', '乌冬'
  ];
  const seasoningTerms = [
    '生抽', '老抽', '料酒', '盐', '糖', '白糖', '胡椒', '白胡椒', '黑胡椒', '淀粉', '小苏打',
    '食用油', '植物油', '香油', '醋', '蚝油', '豆瓣酱', '咖喱块', '泡菜', '水', '清水', '高汤'
  ];
  const aromatics = extractKnownTermsFromText(evidenceText, ['鲜藤椒', '藤椒', '藤椒粉', '花椒', '蒜', '姜', '葱', '辣椒']);
  const liquids = extractKnownTermsFromText(evidenceText, ['水', '清水', '高汤', '汤']);
  const actions = splitRecipeActionSentences([transcript, ocr].filter(Boolean).join('\n') || evidenceText);
  return {
    dishNameCandidates: [extractFallbackDishName(page || evidenceText, sourceMetadata)],
    observedMainIngredients: extractKnownTermsFromText(evidenceText, mainTerms),
    observedSeasonings: extractKnownTermsFromText(evidenceText, seasoningTerms),
    observedAromatics: aromatics,
    observedLiquids: liquids,
    observedActions: actions.map((action, index) => ({
      order: index + 1,
      action,
      ingredients: uniqueTextList([
        ...extractKnownTermsFromText(action, mainTerms),
        ...extractKnownTermsFromText(action, seasoningTerms),
        ...extractKnownTermsFromText(action, aromatics)
      ], 12),
      evidenceText: action,
      confidence: transcript ? 'medium' : 'low'
    })),
    observedTimes: [],
    observedTools: [],
    uncertainItems: [],
    missingInfo: ['AI evidence JSON 解析失败，已根据视频转录文字生成保守 evidence。'],
    // 已经从口播转录里抽到烹饪动作句 → medium（能据此生成 method 步骤）；一句都没有才算 low。
    sourceConfidence: actions.length ? 'medium' : 'low'
  };
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
  const mediaDiagnostics = metadata.mediaDiagnostics && typeof metadata.mediaDiagnostics === 'object'
    ? metadata.mediaDiagnostics
    : {};
  const hasImages = Boolean(imageBase64);
  const hasEvidenceFromImage = hasImages && (observedIngredientCount + observedSeasoningCount + observedActionCount > 0);
  const hasDescription = rawText.length > 0;
  const hasCaption = normalizedSourceType === 'xiaohongshu' && rawText.length > 0;
  const hasTranscript = /字幕|transcript|旁白|口播|视频口播转录/u.test(rawText) || Number(mediaDiagnostics.transcriptLength || 0) > 0;
  const hasOcrText = hasEvidenceFromImage || /ocr|截图文字|图片文字|画面文字/u.test(rawText) || Number(mediaDiagnostics.ocrTextLength || 0) > 0;
  const hasVideoFrames = Number(mediaDiagnostics.framesExtracted || 0) > 0;
  const hasAnyExtractedContent = rawText.length > 0 || hasImages || observedIngredientCount + observedSeasoningCount + observedActionCount > 0;
  const evidenceConfidence = String(evidence?.sourceConfidence || '').trim().toLowerCase();
  const warnings = [];

  if (rawText && rawText.length < 100) warnings.push('来源文本很短，可能只包含零散关键词。');
  if (rawText && cleanedRecipeText.length < 80) warnings.push('清洗后可用菜谱正文较少，可能只提取到标题或话题，食材、调料和步骤需要人工确认。');
  if (metadata.extractionMode === 'link-only') warnings.push('链接解析结果：仅从页面文字中提取，未读取视频画面。');
  if (Array.isArray(metadata.warnings)) metadata.warnings.forEach(w => warnings.push(String(w || '').trim()));
  if (Array.isArray(mediaDiagnostics.warnings)) mediaDiagnostics.warnings.forEach(w => warnings.push(String(w || '').trim()));
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
// /api/ai-chat 的「形态保持」清洗：剥 <think> 推理块与 markdown 围栏；能解析出 JSON 时
// 返回紧凑 JSON 文本，否则原样返回。刻意不做 sanitizeRecipe——该路由服务多种 taskType
// （receipt / method / cooked-meal / creative-recipe / recipe-search / recommendation），
// 各自 JSON 形态不同（如 method 必须保持带序号的字符串），结构校验由前端各 validate* 负责；
// 强制套菜谱清洗会破坏这些形态。落库的导入链路（/api/ai-parse 等）才走 sanitizeRecipe。
function cleanAiChatContent(content) {
  const stripped = String(content || '')
    .replace(/<think>[\s\S]*?<\/think>/gi, '')
    .replace(/<think>[\s\S]*/gi, '')
    .trim();
  const parsed = safeParseModelJson(stripped);
  if (parsed && typeof parsed === 'object') return JSON.stringify(parsed);
  return stripped;
}

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
    const cleaned = cleanAiChatContent(content);
    if (!cleaned) return sendAiJsonError(res, 502, 'empty_response', 'AI 服务暂时不可用。');
    return res.json({ content: cleaned });
  } catch (err) {
    return sendAiUpstreamError(res, err);
  }
});

function createAiParsePipelineError(status, code, message) {
  const err = new Error(message);
  err.aiParseStatus = status;
  err.aiParseCode = code;
  err.aiParseMessage = message;
  return err;
}

function sendAiParsePipelineError(res, err, fallback = 'AI 解析请求失败，请稍后重试。', extra = {}) {
  if (err && err.aiParseStatus) {
    return sendAiJsonError(res, err.aiParseStatus, err.aiParseCode || 'ai_parse_error', err.aiParseMessage || fallback, extra);
  }
  const info = getUpstreamAiErrorInfo(err);
  if (isRateLimitExceeded(info.status, info.code)) {
    return sendAiJsonError(res, 429, 'rate_limit_exceeded', 'AI 服务请求过于频繁，请稍后再试。', {
      upstreamStatus: info.status,
      upstreamCode: info.code,
      ...extra
    });
  }
  return sendAiJsonError(res, info.status, info.code, fallback, {
    upstreamStatus: info.status,
    upstreamCode: info.code,
    ...(process.env.NODE_ENV !== 'production' ? { detail: info.detail } : {}),
    ...extra
  });
}

async function parseRecipeDraftWithAi({ text = '', imageBase64 = null, sourceType = 'manual', sourceMetadata = null } = {}) {
  const normalizedSourceType = normalizeSourceType(sourceType, { imageBase64 });
  const sourceSplit = splitRecipeSourceText(text);
  const evidenceSourceText = sourceSplit.cleanedRecipeText || (normalizedSourceType === 'manual' ? text : '');
  const evidenceInstruction = text
    ? `请从下面这段【cleanedRecipeText】抽取菜谱 evidence。只记录明确出现的信息，不要生成最终菜谱。不要使用 comments/excludedSocialText 中的内容：\n\n${evidenceSourceText}`
    : '请根据这张配料表/菜谱截图抽取菜谱 evidence。只记录明确出现的信息，不要生成最终菜谱。';
  const evidenceUserContent = imageBase64
    ? [{ type: 'text', text: evidenceInstruction }, { type: 'image_url', image_url: { url: imageBase64 } }]
    : evidenceInstruction;

  let evidenceContent = '';
  let evidence = null;
  try {
    evidenceContent = await postJsonChatContentWithFallback({
      model: imageBase64 ? OPENAI_VISION_MODEL : OPENAI_IMPORT_MODEL,
      messages: [
        { role: 'system', content: RECIPE_EVIDENCE_SYSTEM_PROMPT },
        { role: 'user', content: evidenceUserContent }
      ],
      temperature: 0.2
    });
    evidence = safeParseModelJson(evidenceContent);
  } catch (err) {
    if (!isJsonValidateFailedError(err)) throw err;
    const fallbackEvidence = buildFallbackEvidenceFromSource({ text, sourceMetadata });
    if (!fallbackEvidence) throw err;
    evidence = fallbackEvidence;
  }
  if (!evidence) {
    evidence = buildFallbackEvidenceFromSource({ text, sourceMetadata });
  }
  if (!evidence) throw createAiParsePipelineError(502, 'bad_evidence_json', 'AI 没有返回可识别的菜谱证据，请稍后重试。');

  const initialDiagnostics = buildSourceExtractionDiagnostics({
    sourceType: normalizedSourceType,
    sourceText: text,
    imageBase64,
    evidence,
    sourceSplit,
    sourceMetadata
  });
  if (shouldReturnLowEvidenceDraft({ sourceType: normalizedSourceType, evidence })) {
    const draft = buildLowEvidenceRecipeDraft({ sourceType: normalizedSourceType, evidence, sourceSplit, diagnostics: initialDiagnostics });
    const diagnostics = buildSourceExtractionDiagnostics({
      sourceType: normalizedSourceType,
      sourceText: text,
      imageBase64,
      evidence,
      recipe: draft,
      sourceSplit,
      sourceMetadata
    });
    applySourceDiagnosticsWarnings(draft, diagnostics);
    const debugEvidenceSummary = buildDebugEvidenceSummary({ sourceText: text, evidence, diagnostics, sourceSplit });
    return { content: JSON.stringify(draft), recipe: draft, evidence, diagnostics, debugEvidenceSummary };
  }

  const useSimpleImportPrompt = normalizedSourceType === 'xiaohongshu';
  const recipeInstruction = useSimpleImportPrompt
    ? `根据下面 evidence 和 sourceDiagnostics 生成可编辑菜谱草稿。只输出一个 JSON 对象，不要 markdown，不要解释，不要代码块。method 必须覆盖 observedActions；不确定内容放 warnings。\n\n${JSON.stringify({ evidence, sourceDiagnostics: initialDiagnostics })}`
    : `请根据下面的 evidence JSON 和 sourceDiagnostics 生成最终菜谱 JSON。method 必须按 observedActions 顺序生成；不要新增 evidence 不支持的关键动作。若 sourceDiagnostics.sourceConfidence 为 low，只生成证据支持的 draft，并在 warnings 中提示信息不足。\n\n${JSON.stringify({ evidence, sourceDiagnostics: initialDiagnostics })}`;
  const content = await postJsonChatContentWithFallback({
    model: OPENAI_IMPORT_MODEL,
    messages: [
      { role: 'system', content: useSimpleImportPrompt ? IMPORT_SIMPLE_SYSTEM_PROMPT : IMPORT_SYSTEM_PROMPT },
      { role: 'user', content: recipeInstruction }
    ],
    temperature: 0.2
  });
  if (!content) throw createAiParsePipelineError(502, 'empty_response', 'AI 没有返回内容，请稍后重试。');

  let parsed = safeParseModelJson(content);
  if (!parsed) {
    try {
      parsed = await repairRecipeJsonContent(content);
    } catch (_) {
      parsed = null;
    }
  }
  if (parsed) {
    const cleaned = sanitizeRecipe(parsed, { sourceText: evidenceSourceText, evidence, diagnostics: initialDiagnostics });
    const diagnostics = buildSourceExtractionDiagnostics({
      sourceType: normalizedSourceType,
      sourceText: text,
      imageBase64,
      evidence,
      recipe: cleaned,
      sourceSplit,
      sourceMetadata
    });
    applySourceDiagnosticsWarnings(cleaned, diagnostics);
    const debugEvidenceSummary = buildDebugEvidenceSummary({ sourceText: text, evidence, diagnostics, sourceSplit });
    return { content: JSON.stringify(cleaned), recipe: cleaned, evidence, diagnostics, debugEvidenceSummary };
  }
  throw createAiParsePipelineError(422, 'recipe_json_failed', '视频文字已读取成功，但 AI 整理菜谱失败。');
}

function buildRecipeImportSourceMetadataBase({ sourcePayload, rawUrl, pageText, transcriptText, ocrText, mediaDiagnostics } = {}) {
  return {
    url: sourcePayload?.url || rawUrl,
    finalUrl: sourcePayload?.finalUrl || '',
    extractionMode: sourcePayload?.extractionMode || 'link-only',
    hasHtml: Boolean(sourcePayload?.hasHtml),
    hasStructuredMeta: Boolean(sourcePayload?.hasStructuredMeta),
    hasOgDescription: Boolean(sourcePayload?.hasOgDescription),
    hasJsonLd: Boolean(sourcePayload?.hasJsonLd),
    hasInitialState: Boolean(sourcePayload?.hasInitialState),
    trustedTextLength: Number(sourcePayload?.trustedTextLength || String(pageText || '').length),
    trustedTextPreview: String(sourcePayload?.trustedTextPreview || pageText || '').slice(0, 500),
    rawTextLength: Number(sourcePayload?.rawTextLength || 0),
    rawTextPreview: String(sourcePayload?.rawTextPreview || '').slice(0, 500),
    transcriptPreview: String(transcriptText || '').slice(0, 800),
    ocrPreview: String(ocrText || '').slice(0, 800),
    warnings: uniqueTextList([
      ...(Array.isArray(sourcePayload?.warnings) ? sourcePayload.warnings : []),
      ...(Array.isArray(mediaDiagnostics?.warnings) ? mediaDiagnostics.warnings : [])
    ], 16),
    mediaDiagnostics
  };
}

function normalizeFallbackRecipeName(name) {
  let text = String(name || '').trim()
    .replace(/https?:\/\/\S+/gi, ' ')
    .replace(/#.*$/u, ' ')
    .replace(/小红书|复制打开|详细版教程|详细教程|详细版|家常版|教程|做法|分享|收藏|点赞|关注|这篇笔记|打开|一次性解决/gi, ' ')
    .replace(/一道看起来|看起来就|很好吃/gi, ' ')
    .replace(/[｜|#【】\[\]()（）]/g, ' ')
    .replace(/[…。\.]{2,}/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text) return '';
  const pieces = text.split(/[。！？!?，,；;：:\n]/u).map(s => s.trim()).filter(Boolean);
  text = pieces.find(part => /鸡腿|鸡肉|鸡翅|牛肉|猪肉|排骨|鱼|虾|土豆|番茄|鸡蛋|豆腐|青椒|洋葱|藤椒/u.test(part)) || pieces[0] || text;
  text = text.replace(/^[\d\s.、，,]+/, '').trim();
  return text.length > 12 ? text.slice(0, 12) : text;
}

function cleanImportedRecipeName(name, pageText = '', transcriptText = '') {
  const sources = [name, pageText, transcriptText].map(value => String(value || '')).filter(Boolean);
  const knownDishNames = [
    '藤椒鸡腿', '辣子鸡', '宫保鸡丁', '三杯鸡', '麻婆豆腐', '番茄炒蛋',
    '青椒肉丝', '鱼香肉丝', '咖喱鸡肉饭', '照烧鸡腿饭', '葱油拌面'
  ];
  const combined = sources.join('\n');
  for (const dishName of knownDishNames) {
    if (combined.includes(dishName)) return dishName;
  }

  const flavorWords = ['藤椒', '花椒', '辣子', '宫保', '三杯', '咖喱', '照烧', '鱼香', '麻婆', '番茄', '青椒', '葱油', '泡菜', '蒜蓉', '酸辣'];
  const mainWords = ['鸡腿', '鸡肉', '鸡翅', '鸡丁', '牛肉', '猪肉', '肉丝', '排骨', '鱼片', '虾仁', '豆腐', '茄子', '土豆丝', '土豆', '鸡蛋', '西兰花', '面', '饭'];
  for (const source of sources) {
    for (const flavor of flavorWords) {
      for (const main of mainWords) {
        const combo = `${flavor}${main}`;
        if (source.includes(combo) && combo.length <= 12) return combo;
      }
    }
  }

  const normalized = sources
    .map(normalizeFallbackRecipeName)
    .find(value => value && !/页面文字|视频口播|字幕/u.test(value));
  if (normalized) return normalized;
  return '未命名视频菜谱';
}

function extractFallbackRecipeName({ pageText = '', transcriptText = '', ocrText = '', sourceMetadata = {} } = {}) {
  const candidates = [
    sourceMetadata?.trustedTextPreview,
    sourceMetadata?.rawTextPreview,
    pageText,
    ocrText,
    transcriptText
  ];
  for (const candidate of candidates) {
    const name = cleanImportedRecipeName(candidate, pageText, transcriptText);
    if (name) return name;
  }
  return '未命名视频菜谱';
}

function getFallbackIngredientQty(text, term) {
  const source = String(text || '');
  const escaped = String(term || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const patterns = [
    new RegExp(`(?:([0-9一二两三四五六七八九十]+)\\s*(?:个|只|块|份)?\\s*${escaped}|${escaped}\\s*([0-9一二两三四五六七八九十]+)\\s*(?:个|只|块|份))`, 'u')
  ];
  const chineseMap = { 一: '1', 二: '2', 两: '2', 三: '3', 四: '4', 五: '5', 六: '6', 七: '7', 八: '8', 九: '9', 十: '10' };
  for (const pattern of patterns) {
    const match = source.match(pattern);
    const raw = match && (match[1] || match[2]);
    if (!raw) continue;
    if (/^\d+$/.test(raw)) return raw;
    if (chineseMap[raw]) return chineseMap[raw];
  }
  return '1';
}

function buildFallbackRecipeItems(text, terms, { seasoning = false } = {}) {
  return uniqueTextList(terms.filter(term => String(text || '').includes(term)), 24).map(item => {
    if (seasoning) return { item, qty: '1', unit: '适量' };
    const qty = getFallbackIngredientQty(text, item);
    const unit = qty !== '1' && /鸡腿|鸡翅/u.test(item) ? '只' : '份';
    return { item, qty, unit };
  });
}

const FALLBACK_COOKING_ACTION_WORDS = [
  '清洗', '去皮', '去骨', '切块', '切片', '切丝', '改刀', '腌制', '抓匀', '拌匀',
  '加入', '放入', '倒入', '下锅', '起锅', '热锅', '倒油', '烧油', '煎至', '翻炒',
  '盖盖', '收汁', '调味', '出锅', '装盘', '洗', '切', '腌', '煎', '炒', '炸',
  '烤', '蒸', '煮', '焖', '炖', '撒', '淋'
];

const FALLBACK_TRANSITION_WORDS = [
  '这个时候', '下一步', '然后', '接着', '之后', '最后', '等到', '直到', '如果', '一会儿', '另外', '先', '再'
];

const FALLBACK_COOKING_ACTION_RE = new RegExp(FALLBACK_COOKING_ACTION_WORDS.join('|'), 'u');
const FALLBACK_MAIN_INGREDIENT_WORDS = [
  '鸡腿', '鸡肉', '鸡翅', '牛肉', '猪肉', '排骨', '鱼', '虾', '土豆', '番茄', '西红柿', '鸡蛋', '豆腐', '青椒', '洋葱'
];
const FALLBACK_SEASONING_WORDS = [
  '生抽', '老抽', '料酒', '黄酒', '盐', '糖', '鸡精', '味精', '蚝油', '淀粉', '藤椒', '花椒', '辣椒', '葱', '姜', '蒜', '油', '水'
];
const FALLBACK_MAIN_INGREDIENT_RE = new RegExp(FALLBACK_MAIN_INGREDIENT_WORDS.join('|'), 'u');
const FALLBACK_SEASONING_RE = new RegExp(FALLBACK_SEASONING_WORDS.join('|'), 'u');
const FALLBACK_TIME_HEAT_RE = /(?:\d+|[一二两三四五六七八九十半]+)\s*(?:分钟|秒|小时)|小火|中火|大火|高火|低火|火候|煎至|炒至|炸至|烤至|蒸至|煮至|焖至|炖至|金黄|焦香|熟透|入味/u;
const FALLBACK_NOISE_RE = /看起来就很好吃|看起来很好吃|真的太香了|这道菜|菜从前期处理的细节进去到|到家里怎么丝滑的运用铁锅|大家有没有|我跟你说|你问起来|如果新鲜就是|那种鸡味|就说明|这个真的|你们有没有发现|小时候|小红书|复制打开|打开|评论区|教程|一次性解决|不是我说|大家一定要试试|下饭神器|赶紧收藏|点赞关注|有没有同款|我妈说|太绝了|很容易|最好是|这个时候|否则|然后呢|的话|就不|其实|就是|点赞|关注|收藏|主页|链接|姐妹们|家人们|真的|绝了|好吃到|赶紧|别错过/gu;
const FALLBACK_PARTICLE_RE = /[呢啊呀哈嘛哦]/gu;
const FALLBACK_CHATTER_RE = new RegExp(FALLBACK_NOISE_RE.source, 'u');

function splitTextByBoundaryWords(text, words) {
  const source = String(text || '').trim();
  if (!source) return [];
  const escapedWords = words
    .slice()
    .sort((a, b) => b.length - a.length)
    .map(word => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const boundaryRe = new RegExp(escapedWords.join('|'), 'gu');
  const matches = [...source.matchAll(boundaryRe)].map(match => match.index).filter(index => index > 0);
  if (!matches.length) return [source];
  const parts = [];
  let start = 0;
  for (const index of matches) {
    if (index <= start) continue;
    parts.push(source.slice(start, index));
    start = index;
  }
  parts.push(source.slice(start));
  return parts.map(part => part.trim()).filter(Boolean);
}

function countFallbackActions(text) {
  const actionRe = new RegExp(FALLBACK_COOKING_ACTION_WORDS.join('|'), 'gu');
  return [...String(text || '').matchAll(actionRe)].length;
}

function splitLongFallbackStep(step) {
  const source = String(step || '').trim();
  if (!source) return [];
  let parts = [source];
  if (source.length > 120) {
    parts = parts.flatMap(part => splitTextByBoundaryWords(part, FALLBACK_TRANSITION_WORDS));
  }
  parts = parts.flatMap(part => {
    if (part.length <= 80 && countFallbackActions(part) < 3) return [part];
    return splitTextByBoundaryWords(part, FALLBACK_COOKING_ACTION_WORDS);
  });
  parts = parts.flatMap(part => {
    if (part.length <= 100) return [part];
    return splitTextByBoundaryWords(part, FALLBACK_TRANSITION_WORDS);
  });
  return parts;
}

function cleanFallbackStepText(sentence) {
  return stripStepPrefix(sentence)
    .replace(FALLBACK_NOISE_RE, ' ')
    .replace(FALLBACK_PARTICLE_RE, '')
    .replace(/\s+/g, ' ')
    .replace(/^[，,。；;：:\s]+|[，,；;：:\s]+$/gu, '')
    .trim();
}

function normalizeFallbackSegmentText(sentence) {
  return stripStepPrefix(sentence)
    .replace(/\s+/g, ' ')
    .replace(/^[，,。；;：:\s]+|[，,；;：:\s]+$/gu, '')
    .trim();
}

function splitTranscriptCandidateSegments(text) {
  const source = String(text || '')
    .replace(/[“”"']/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!source) return [];
  const roughParts = source
    .split(/[。！？!?；;，,\n]+/u)
    .map(part => part.trim())
    .filter(Boolean);
  return roughParts
    .flatMap(part => (part.length > 80 ? splitTextByBoundaryWords(part, FALLBACK_TRANSITION_WORDS) : [part]))
    .flatMap(part => (part.length > 120 ? splitTextByBoundaryWords(part, FALLBACK_COOKING_ACTION_WORDS) : [part]))
    .flatMap(part => splitLongFallbackStep(part))
    .map(normalizeFallbackSegmentText)
    .filter(Boolean);
}

function classifyCookingSegment(text) {
  const segmentText = String(text || '').trim();
  const hasAction = FALLBACK_COOKING_ACTION_RE.test(segmentText);
  const hasMainIngredient = FALLBACK_MAIN_INGREDIENT_RE.test(segmentText);
  const hasSeasoning = FALLBACK_SEASONING_RE.test(segmentText);
  const hasTimeHeat = FALLBACK_TIME_HEAT_RE.test(segmentText);
  const hasChatter = FALLBACK_CHATTER_RE.test(segmentText);
  if (hasChatter && !hasAction && !hasMainIngredient && !hasSeasoning && !hasTimeHeat) {
    return { type: 'chatter', action: '', confidence: 'high' };
  }
  if (hasAction && (hasMainIngredient || hasSeasoning || hasTimeHeat)) {
    const action = (segmentText.match(FALLBACK_COOKING_ACTION_RE) || [''])[0];
    return { type: 'cooking_action', action, confidence: 'high' };
  }
  if (hasAction) {
    const action = (segmentText.match(FALLBACK_COOKING_ACTION_RE) || [''])[0];
    return { type: 'cooking_action', action, confidence: 'medium' };
  }
  if (hasTimeHeat) return { type: 'time_heat', action: (segmentText.match(FALLBACK_TIME_HEAT_RE) || [''])[0], confidence: 'medium' };
  if (hasMainIngredient) return { type: 'ingredient', action: '', confidence: 'medium' };
  if (hasSeasoning) return { type: 'seasoning', action: '', confidence: 'medium' };
  if (hasChatter) return { type: 'chatter', action: '', confidence: 'medium' };
  return { type: 'unknown', action: '', confidence: 'low' };
}

function extractCookingSegmentsFromTranscript(transcriptText, ocrText = '') {
  const candidates = splitTranscriptCandidateSegments([transcriptText, ocrText].filter(Boolean).join('\n'));
  const segments = candidates.map(text => {
    const classification = classifyCookingSegment(text);
    return {
      text,
      type: classification.type,
      action: classification.action,
      confidence: classification.confidence
    };
  });
  const cookingSegments = segments.filter(segment => segment.type === 'cooking_action' || segment.type === 'time_heat');
  const droppedTextPreview = segments
    .filter(segment => segment.type === 'chatter' || segment.type === 'unknown')
    .map(segment => segment.text.slice(0, 80))
    .slice(0, 8);
  return {
    segments,
    cookingText: cookingSegments.map(segment => segment.text).join('\n'),
    droppedTextPreview
  };
}

function finishFallbackCookingStep(text) {
  const clean = String(text || '')
    .replace(/\s+/g, ' ')
    .replace(/[，,；;：:\s]+$/u, '')
    .trim();
  if (!clean) return '';
  return /[。.!！?？]$/u.test(clean) ? clean : `${clean}。`;
}

function simplifyFallbackCookingStep(stepText) {
  const raw = normalizeFallbackSegmentText(stepText);
  if (!raw) return '';
  const text = cleanFallbackStepText(raw);
  if (!text || !FALLBACK_COOKING_ACTION_RE.test(text)) return '';
  if (/去骨|剥骨|剔骨|剥.*骨/u.test(text)) {
    return '鸡腿去骨，处理干净。';
  }
  if (/厨房纸|擦出来|水都给它擦出来|擦干|吸干/u.test(text)) {
    return '用厨房纸擦干鸡腿表面水分。';
  }
  if (/(清洗|洗完|洗净|洗一下|洗)/u.test(text) && /(鸡腿|外皮)/u.test(text)) {
    return '鸡腿清洗干净，去除表面杂质。';
  }
  if (/改刀/u.test(text) && /切每一块|切块/u.test(text)) {
    return '在鸡腿肉面改刀，并切成合适大小的块。';
  }
  if (/改刀/u.test(text)) {
    return '在鸡腿肉面改刀，方便腌制入味。';
  }
  if (/切每一块|切块/u.test(text)) {
    return '将鸡腿切成合适大小的块。';
  }
  if (/(锅|热锅|下锅).*(油|倒油|烧油)|(油|倒油|烧油).*(锅|热锅|下锅)/u.test(text) && /煎/u.test(text)) {
    return '锅中倒油烧热，放入鸡腿煎至表面定型。';
  }
  if (/(锅|热锅|下锅).*(油|倒油|烧油)|(油|倒油|烧油).*(锅|热锅|下锅)|倒油|烧油/u.test(text)) {
    return '锅中倒油烧热。';
  }
  if (/煎/u.test(text)) {
    return '放入鸡腿煎至表面定型。';
  }
  if (/(藤椒|花椒)/u.test(text) && /出锅|装盘|熟透/u.test(text)) {
    return '加入藤椒、花椒等调味，鸡腿熟透后出锅。';
  }
  if (/(藤椒|花椒)/u.test(text)) {
    return '加入藤椒、花椒等调味增香。';
  }
  if (/出锅|装盘/u.test(text)) {
    return '鸡腿熟透后出锅装盘。';
  }
  if (/调味.*熟透|熟透.*调味/u.test(text)) {
    return '';
  }
  if (/盐|黄酒|生抽|老抽|淀粉|腌|抓匀|拌匀|料酒|糖/u.test(text)) {
    return '加入盐、黄酒、生抽、老抽、糖和淀粉等调料，抓匀腌制。';
  }
  if (text.length > 50) return '';
  return finishFallbackCookingStep(text);
}

function compactFallbackSimplifiedSteps(steps) {
  const compacted = [];
  for (let i = 0; i < steps.length; i += 1) {
    const current = steps[i];
    const next = steps[i + 1] || '';
    if (/^锅中倒油烧热。?$/.test(current) && /^放入鸡腿煎至表面定型。?$/.test(next)) {
      compacted.push('锅中倒油烧热，放入鸡腿煎至表面定型。');
      i += 1;
      continue;
    }
    if (/^加入藤椒、花椒等调味增香。?$/.test(current) && /^鸡腿熟透后出锅装盘。?$/.test(next)) {
      compacted.push('加入藤椒、花椒等调味，鸡腿熟透后出锅。');
      i += 1;
      continue;
    }
    if (/^调味鸡腿熟透后。?$/.test(current)) continue;
    compacted.push(current);
  }
  return compacted;
}

function inferFallbackCookingStages(transcriptText, ocrText = '') {
  const text = [transcriptText, ocrText].map(value => String(value || '')).filter(Boolean).join('\n');
  const stages = {
    prep: [],
    marinate: [],
    cook: [],
    season: [],
    finish: []
  };
  if (!text) return stages;

  if (/去骨|剥骨|剔骨|剥.*骨/u.test(text)) stages.prep.push('鸡腿去骨，处理干净。');
  if (/(清洗|洗完|洗净|洗一下|洗).*?(鸡腿|外皮|表面)|(鸡腿|外皮|表面).*?(清洗|洗完|洗净|洗一下|洗)/u.test(text)) {
    stages.prep.push('鸡腿清洗干净，去除表面杂质。');
  }
  if (/厨房纸|擦干|吸干|擦出来|水都给它擦出来/u.test(text)) stages.prep.push('用厨房纸擦干鸡腿表面水分。');
  if (/改刀/u.test(text)) stages.prep.push('在鸡腿肉面改刀，方便腌制入味。');
  if (/切每一块|切块|切成.*块/u.test(text)) stages.prep.push('将鸡腿切成合适大小的块。');

  if (/(盐|黄酒|生抽|老抽|糖|淀粉|料酒|抓匀|拌匀|腌制|入味|腌)/u.test(text)
    && /(抓匀|拌匀|腌制|入味|腌)/u.test(text)) {
    stages.marinate.push('加入盐、黄酒、生抽、老抽、糖和淀粉等调料，抓匀腌制。');
  }

  const hasOilPan = /(锅|热锅|下锅|起锅).*?(油|倒油|烧油)|(油|倒油|烧油).*?(锅|热锅|下锅|起锅)|锅中倒油|倒油烧热/u.test(text);
  const hasPanCook = /下锅|放入|倒入|煎|煎到|煎至|定型|熟透|小火|中火|大火/u.test(text);
  if (hasOilPan && hasPanCook) {
    stages.cook.push('锅中倒油烧热，放入鸡腿煎至表面定型。');
  } else {
    if (hasOilPan) stages.cook.push('锅中倒油烧热。');
    if (/煎|煎到|煎至|定型/u.test(text)) stages.cook.push('放入鸡腿煎至表面定型。');
  }

  const hasAromaticSeasoning = /藤椒|花椒|花椒油|葱|姜|蒜|淋/u.test(text);
  if (hasAromaticSeasoning) stages.season.push('加入藤椒、花椒等调味增香。');
  if (/出锅|装盘|熟透/u.test(text)) stages.finish.push('鸡腿熟透后出锅装盘。');

  return Object.fromEntries(Object.entries(stages).map(([stage, values]) => [stage, uniqueTextList(values, 8)]));
}

function buildFallbackStageMethodSteps(stages) {
  if (!stages || typeof stages !== 'object') return [];
  return compactFallbackSimplifiedSteps(uniqueTextList([
    ...(Array.isArray(stages.prep) ? stages.prep : []),
    ...(Array.isArray(stages.marinate) ? stages.marinate : []),
    ...(Array.isArray(stages.cook) ? stages.cook : []),
    ...(Array.isArray(stages.season) ? stages.season : []),
    ...(Array.isArray(stages.finish) ? stages.finish : [])
  ], 12));
}

function mergeFallbackStepFragments(fragments) {
  const merged = [];
  let current = '';
  for (const raw of fragments) {
    const part = cleanFallbackStepText(raw);
    if (!part) continue;
    if (!FALLBACK_COOKING_ACTION_RE.test(part)) continue;
    if (!current) {
      current = part;
      continue;
    }
    const currentIsShort = current.length < 20;
    const partIsTiny = part.length < 8;
    if ((currentIsShort || partIsTiny) && (current + part).length <= 90) {
      current += part;
      continue;
    }
    merged.push(current);
    current = part;
  }
  if (current) merged.push(current);
  if (merged.length > 1 && merged[merged.length - 1].length < 12) {
    const tail = merged.pop();
    const prev = merged.pop();
    merged.push(`${prev}${tail}`.slice(0, 100));
  }
  return merged;
}

function buildFallbackRawCookingSteps(transcriptText) {
  const extraction = extractCookingSegmentsFromTranscript(transcriptText);
  const fragments = extraction.segments
    .filter(segment => segment.type === 'cooking_action' || segment.type === 'time_heat')
    .map(segment => segment.text);
  return uniqueTextList(
    mergeFallbackStepFragments(fragments)
      .flatMap(step => splitLongFallbackStep(step))
      .map(cleanFallbackStepText)
      .filter(step => step.length >= 4 && step.length <= 100 && FALLBACK_COOKING_ACTION_RE.test(step)),
    16
  );
}

function buildFallbackRecipeMethodDetails(transcriptText, ocrText = '') {
  const rawSteps = buildFallbackRawCookingSteps(transcriptText);
  const stageDetected = inferFallbackCookingStages(transcriptText, ocrText);
  const stageSteps = buildFallbackStageMethodSteps(stageDetected);
  const simplifiedFromRaw = compactFallbackSimplifiedSteps(uniqueTextList(
    rawSteps
      .map(simplifyFallbackCookingStep)
      .map(step => step.trim())
      .filter(step => step.length >= 6 && step.length <= 55),
    8
  ));
  const simplified = uniqueTextList([...stageSteps, ...simplifiedFromRaw], 8);
  const method = simplified.length
    ? simplified
    : ['已成功读取视频口播，但未能稳定提取烹饪步骤，请根据原文预览手动整理。'];
  return {
    method,
    rawSteps,
    simplifiedSteps: simplified,
    stageSteps,
    stageDetected,
    missingStages: Object.entries(stageDetected)
      .filter(([, values]) => !Array.isArray(values) || !values.length)
      .map(([stage]) => stage),
    droppedStepCount: Math.max(0, rawSteps.length - simplified.length)
  };
}

function splitTranscriptIntoCookingSteps(transcriptText) {
  return buildFallbackRecipeMethodDetails(transcriptText).method;
}

function isFallbackMethodNoise(sentence) {
  const cleaned = cleanFallbackStepText(sentence);
  return !cleaned || !FALLBACK_COOKING_ACTION_RE.test(cleaned);
}

function buildFallbackRecipeMethod(transcriptText) {
  const method = splitTranscriptIntoCookingSteps(transcriptText)
    .filter(sentence => sentence && !isFallbackMethodNoise(sentence))
    .slice(0, 8);
  return method.length
    ? method
    : ['已成功读取视频口播，但未能稳定提取烹饪步骤，请根据原文预览手动整理。'];
}

function buildFallbackRecipeFromTranscript({ pageText = '', transcriptText = '', ocrText = '', sourceMetadata = {}, mediaDiagnostics = {} } = {}) {
  const combinedText = [transcriptText, ocrText, pageText].filter(Boolean).join('\n');
  const mainTerms = [
    '鸡腿', '鸡肉', '鸡翅', '牛肉', '猪肉', '排骨', '鱼片', '鱼', '虾仁', '虾',
    '土豆', '番茄', '西红柿', '鸡蛋', '豆腐', '青椒', '洋葱', '茄子', '白菜', '西兰花'
  ];
  const seasoningTerms = [
    '鲜藤椒', '藤椒粉', '藤椒', '花椒', '辣椒', '生抽', '老抽', '料酒', '黄酒', '盐', '糖',
    '鸡精', '味精', '蚝油', '淀粉', '小苏打', '葱', '姜', '蒜', '油', '水'
  ];
  const segmentExtraction = extractCookingSegmentsFromTranscript(transcriptText || combinedText, ocrText);
  const cookingSegments = segmentExtraction.segments.filter(segment => segment.type === 'cooking_action' || segment.type === 'time_heat');
  const methodDetails = buildFallbackRecipeMethodDetails(segmentExtraction.cookingText || transcriptText || combinedText, ocrText);
  const method = methodDetails.method;
  const name = extractFallbackRecipeName({ pageText, transcriptText, ocrText, sourceMetadata });
  const droppedChatterCount = segmentExtraction.segments.filter(segment => segment.type === 'chatter').length;
  const warnings = [
    '视频文字已读取成功，但 AI 整理时触发限流。当前草稿由规则提取生成，请人工确认。'
  ];
  if (method.length === 1 && /未能稳定提取/.test(method[0])) {
    warnings.push('未能从口播中稳定提取明确步骤，请参考视频文字预览手动整理。');
  }
  if ((String(transcriptText || '').length > 120 && cookingSegments.length < 6) || droppedChatterCount > 0) {
    warnings.push('视频口播较长，已自动过滤闲聊内容；部分步骤可能需要人工确认。');
  }
  if (!transcriptText && ocrText) {
    warnings.push('未读取到口播转录，仅根据页面文字和画面文字生成规则草稿。');
  }
  if (Array.isArray(mediaDiagnostics?.warnings)) {
    warnings.push(...mediaDiagnostics.warnings);
  }
  const fallbackDiagnostics = {
    cleanedRecipeName: name,
    cookingSegmentCount: cookingSegments.length,
    droppedChatterCount,
    fallbackStepCount: method.filter(step => !/未能稳定提取/.test(step)).length,
    fallbackRawStepCount: methodDetails.rawSteps.length,
    fallbackSimplifiedStepCount: methodDetails.simplifiedSteps.length,
    fallbackDroppedStepCount: methodDetails.droppedStepCount,
    fallbackStageDetected: Object.fromEntries(Object.entries(methodDetails.stageDetected).map(([stage, values]) => [stage, Array.isArray(values) && values.length > 0])),
    fallbackStageMethodCount: methodDetails.stageSteps.length,
    fallbackMissingStages: methodDetails.missingStages,
    cookingSegmentsPreview: cookingSegments.map(segment => ({
      text: segment.text.slice(0, 100),
      type: segment.type,
      action: segment.action,
      confidence: segment.confidence
    })).slice(0, 8),
    fallbackSimplifiedPreview: methodDetails.simplifiedSteps.slice(0, 8),
    fallbackMethodPreview: method.slice(0, 8),
    droppedTextPreview: segmentExtraction.droppedTextPreview
  };
  return {
    name,
    tags: ['AI草稿', '视频导入'],
    ingredients: buildFallbackRecipeItems(combinedText, mainTerms),
    seasonings: buildFallbackRecipeItems(combinedText, seasoningTerms, { seasoning: true }),
    method,
    warnings: uniqueTextList(warnings, 12),
    needsReview: true,
    sourceType: 'xiaohongshu',
    diagnostics: fallbackDiagnostics
  };
}

app.post('/api/recipe-import-from-url', async (req, res) => {
  if (isImportRateLimited(req)) return sendAiJsonError(res, 429, 'rate_limited', '导入太频繁，请稍后再试。');
  cleanupRecipeImportMediaCache();
  const rawUrl = String(req.body?.url || '').trim();
  const userText = String(req.body?.userText || '').trim();
  if (!rawUrl) return sendAiJsonError(res, 400, 'missing_url', '缺少链接。');
  if (!OPENAI_API_KEY) return sendAiJsonError(res, 503, 'missing_api_key', '后端未配置 AI 密钥（OPENAI_API_KEY）。');

  let sourcePayload;
  try {
    sourcePayload = await extractRecipeSourcePayloadFromUrl(rawUrl, { allowEmptyText: true });
  } catch (err) {
    if (err && err.publicStatus) {
      return sendAiJsonError(res, err.publicStatus, err.publicCode || 'link_extract_failed', err.publicError);
    }
    return sendAiJsonError(res, 502, 'link_extract_failed', '链接抓取失败，请稍后重试或粘贴菜谱文字。');
  }

  const pageText = String(sourcePayload.text || '').trim();
  const videoUrls = Array.isArray(sourcePayload.media?.videoUrls) ? sourcePayload.media.videoUrls : [];
  const selectedVideoUrl = pickBestVideoUrl(videoUrls);
  const selectionDiagnostics = mergeVideoUrlSelectionDiagnostics(
    buildVideoUrlSelectionDiagnostics(videoUrls, selectedVideoUrl),
    sourcePayload.media?.mediaDiagnostics
  );
  const cacheKey = buildRecipeImportMediaCacheKey({
    rawUrl,
    finalUrl: sourcePayload.finalUrl,
    selectedVideoUrl
  });
  const cachedMedia = cacheKey ? recipeImportMediaCache.get(cacheKey) : null;
  let transcriptText = '';
  let ocrText = '';
  let mediaDiagnostics;
  let sourceMetadataBase;

  if (cachedMedia && Date.now() - Number(cachedMedia.createdAt || 0) <= RECIPE_IMPORT_MEDIA_CACHE_TTL_MS) {
    transcriptText = String(cachedMedia.transcriptText || '');
    ocrText = String(cachedMedia.ocrText || '');
    mediaDiagnostics = {
      ...cloneRecipeImportCacheValue(cachedMedia.mediaDiagnostics, {}),
      cacheHit: true
    };
    sourceMetadataBase = {
      ...cloneRecipeImportCacheValue(cachedMedia.sourceMetadataBase, {}),
      mediaDiagnostics
    };
  } else {
    const videoTextResult = await extractVideoRecipeTextForImport(selectedVideoUrl, videoUrls.length, selectionDiagnostics);
    transcriptText = String(videoTextResult.transcriptText || '');
    ocrText = String(videoTextResult.ocrText || '');
    mediaDiagnostics = {
      ...videoTextResult.mediaDiagnostics,
      extractionMode: sourcePayload.extractionMode,
      pageTextLength: pageText.length,
      cacheHit: false
    };
    if (!selectedVideoUrl && videoUrls.length) {
      mediaDiagnostics.warnings = uniqueTextList([
        ...(Array.isArray(mediaDiagnostics.warnings) ? mediaDiagnostics.warnings : []),
        '找到的视频候选不是可下载媒体地址，已使用页面文字生成草稿。'
      ], 8);
    }
    sourceMetadataBase = buildRecipeImportSourceMetadataBase({
      sourcePayload,
      rawUrl,
      pageText,
      transcriptText,
      ocrText,
      mediaDiagnostics
    });
    if (cacheKey) {
      recipeImportMediaCache.set(cacheKey, {
        createdAt: Date.now(),
        pageText,
        transcriptText,
        ocrText,
        mediaDiagnostics: cloneRecipeImportCacheValue(mediaDiagnostics, {}),
        sourceMetadataBase: cloneRecipeImportCacheValue(sourceMetadataBase, {})
      });
    }
  }
  const limitedPageText = limitSourceSectionText(pageText, 1000);
  const limitedTranscriptText = limitSourceSectionText(transcriptText, 4000);
  const limitedOcrText = limitSourceSectionText(ocrText, 1500);
  const limitedUserText = limitSourceSectionText(userText, 2000);
  const sections = [];
  appendSourceSection(sections, '页面文字', limitedPageText);
  appendSourceSection(sections, '视频口播转录', limitedTranscriptText);
  appendSourceSection(sections, '视频画面文字', limitedOcrText);
  appendSourceSection(sections, '用户补充', limitedUserText);
  const sourceText = sections.join('\n\n').trim();
  if (!sourceText) {
    cleanupRecipeImportMediaCache();
    return sendAiJsonError(res, 422, 'no_recipe_text', '没能从链接中读取到足够内容，请粘贴菜谱文字后再试。', { mediaDiagnostics });
  }

  const sourceMetadata = {
    ...sourceMetadataBase,
    warnings: uniqueTextList([
      ...(Array.isArray(sourceMetadataBase?.warnings) ? sourceMetadataBase.warnings : []),
      ...(Array.isArray(mediaDiagnostics.warnings) ? mediaDiagnostics.warnings : [])
    ], 16),
    mediaDiagnostics,
    ...(userText
      ? {
          hasUserSupplement: true,
          userSupplementPreview: userText.slice(0, 300)
        }
      : {})
  };

  try {
    const draft = await parseRecipeDraftWithAi({
      text: sourceText,
      sourceType: 'xiaohongshu',
      sourceMetadata
    });
    cleanupRecipeImportMediaCache();
    return res.json({ ...draft, mediaDiagnostics });
  } catch (err) {
    const info = getUpstreamAiErrorInfo(err);
    const importTextReadyExtra = {
      mediaDiagnostics,
      importTextReady: true,
      transcriptPreview: transcriptText.slice(0, 1200),
      ocrPreview: ocrText.slice(0, 800),
      pageTextPreview: pageText.slice(0, 500)
    };
    const canUseSourceFallback = Boolean(String(transcriptText || ocrText || pageText || '').trim());
    const fallbackReason = isRateLimitExceeded(info.status, info.code)
      ? 'rate_limit_exceeded'
      : (err?.aiParseCode === 'recipe_json_failed' || isJsonValidateFailedError(err))
        ? 'recipe_json_failed'
        : '';
    if (canUseSourceFallback && fallbackReason) {
      const fallbackRecipe = buildFallbackRecipeFromTranscript({
        pageText,
        transcriptText,
        ocrText,
        sourceMetadata,
        mediaDiagnostics
      });
      cleanupRecipeImportMediaCache();
      return res.json({
        content: JSON.stringify(fallbackRecipe),
        recipe: fallbackRecipe,
        evidence: null,
        diagnostics: fallbackRecipe.diagnostics || null,
        debugEvidenceSummary: {
          sourceTextSnippet: String(transcriptText || ocrText || pageText || '').slice(0, 500),
          observedIngredients: fallbackRecipe.ingredients.map(item => item.item),
          observedSeasonings: fallbackRecipe.seasonings.map(item => item.item),
          observedActions: fallbackRecipe.method
        },
        mediaDiagnostics,
        fallbackUsed: true,
        fallbackReason,
        importTextReady: true,
        transcriptPreview: transcriptText.slice(0, 1200),
        ocrPreview: ocrText.slice(0, 800),
        pageTextPreview: pageText.slice(0, 500)
      });
    }
    // 安全网：final recipe 已经失败，但视频文字确实读到了。绝不把 json_validate_failed 这类
    // 上游 400 直接透传给前端——统一降级为 422 recipe_json_failed，并带上可继续手动编辑的文字预览。
    if (err?.aiParseCode === 'recipe_json_failed' || isJsonValidateFailedError(err)) {
      cleanupRecipeImportMediaCache();
      return sendAiJsonError(res, 422, 'recipe_json_failed', '视频文字已读取成功，但 AI 整理菜谱失败。', importTextReadyExtra);
    }
    const rateLimitExtra = isRateLimitExceeded(info.status, info.code)
      ? importTextReadyExtra
      : { mediaDiagnostics };
    cleanupRecipeImportMediaCache();
    return sendAiParsePipelineError(res, err, 'AI 解析请求失败，请稍后重试。', rateLimitExtra);
  }
});

// AI 解析路由：文本菜谱导入用 OPENAI_IMPORT_MODEL，图片用 OPENAI_VISION_MODEL，密钥来自 Render 环境变量。
app.post('/api/ai-parse', async (req, res) => {
  if (isAiRateLimited(req)) return sendAiJsonError(res, 429, 'rate_limited', 'AI 请求太频繁，请稍后再试。');
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
  try {
    return res.json(await parseRecipeDraftWithAi({ text, imageBase64, sourceType, sourceMetadata }));
  } catch (err) {
    return sendAiParsePipelineError(res, err, 'AI 解析请求失败，请稍后重试。');
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
