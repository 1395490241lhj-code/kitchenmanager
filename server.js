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
 * 环境变量（Render）：PORT、OPENAI_API_KEY、OPENAI_BASE_URL、OPENAI_MODEL、OPENAI_VISION_MODEL（可选）。
 * 启动：npm install && npm start  （默认 http://localhost:3000）
 */
const path = require('path');
const express = require('express');
const axios = require('axios');
const dns = require('dns').promises;
const net = require('net');
const http = require('http');
const https = require('https');

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

const IMPORT_SYSTEM_PROMPT = `你是一位资深中餐大厨兼菜谱结构化助手。用户会给你一段来自小红书/网页的菜谱文案，或一张配料表/视频截图。
请把其中的菜谱信息做语义清洗后，严格只返回一个 JSON 对象（不要 markdown 代码块、不要任何解释文字）。

⚠️ 四条最高优先级铁律（违反任意一条即视为输出失败，必须严格执行）：
1. 【严禁空数量】ingredients 与 seasonings 数组里每个对象的 qty 必须是有效数字字符串（如 "1"、"2"、"0.5"），不允许 "" / null / undefined / 缺省字段 / "适量" / "少许" / "半" / "一" 等任何非数字内容。
2. 【食材 / 调料 双列表】必须输出两个独立数组：
   · ingredients = 核心食材（肉、禽、蛋、海鲜、蔬菜、豆制品、主食、特色配料等，参与库存扣减）。
   · seasonings  = 常备调料与背景介质（如 水、生抽、老抽、醋、糖、盐、味精、鸡精、食用油 / 植物油 / 菜籽油 / 大豆油 / 玉米油 / 葵花籽油 / 调和油 / 色拉油、料酒、淀粉、香油、花椒、干辣椒、八角、桂皮、葱姜蒜等）。不参与库存扣减，但仍要出现在 method 步骤文字里。
   · ingredients 数组里严禁出现 seasonings 类目；反之亦然。
3. 【method 格式干净】method 必须是字符串数组，每个元素的文本【严禁包含任何序号前缀】（如 "1. " / "1、" / "第一步：" / "步骤2：" / "一、" / "(1) "）；直接以动词或主语开头。
4. 【method 文字保留调料】即便 seasonings 列出了水/油/盐，method 步骤文字里仍要写出对应动作（"锅中倒油烧热"、"加水大火焖煮"、"调入盐"），保持烹饪指导连贯。

JSON 字段如下：
{
  "name": "标准菜名",
  "tags": ["家常菜", "口味/菜系等标签"],
  "ingredients": [ {"item": "土豆", "qty": "2", "unit": "个"}, {"item": "牛肉", "qty": "1", "unit": "份"} ],
  "seasonings":  [ {"item": "生抽", "qty": "2", "unit": "勺"}, {"item": "盐", "qty": "1", "unit": "适量"}, {"item": "水", "qty": "1", "unit": "杯"} ],
  "method": ["步骤一文本", "步骤二文本", "步骤三文本"]
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

其它要求：
- name 必填，为简洁标准菜名。
- ingredients 必填，至少一项；seasonings 可以为空数组但建议至少列出主要调料；两个数组里每条 item / qty / unit 都必须是非空字符串。
- tags 给 1-4 个，体现菜系/口味/类别。
- 只输出 JSON 本身。`;

// 从小红书/网页源码尽力提取菜谱文案（与原 ai.js 中逻辑一致，移植到服务端）。
function extractXhsText(html) {
  const parts = [];
  const push = (v) => { const s = String(v || '').trim(); if (s) parts.push(s); };

  const og = html.match(/<meta[^>]+(?:property|name)=["']og:title["'][^>]*content=["']([^"']+)["']/i);
  if (og) push(og[1]);
  const desc = html.match(/<meta[^>]+name=["']description["'][^>]*content=["']([^"']+)["']/i);
  if (desc) push(desc[1]);

  const state = html.match(/window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\})\s*<\/script>/);
  const blob = state ? state[1] : html;
  const fields = blob.match(/"(?:desc|title|content|noteText)":"((?:[^"\\]|\\.)*)"/g) || [];
  fields.forEach(f => push(f.replace(/^"[^"]+":"/, '').replace(/"$/, '')));

  const seen = new Set();
  return parts
    .map(s => s
      .replace(/\\u[0-9a-fA-F]{4}/g, m => String.fromCharCode(parseInt(m.slice(2), 16)))
      .replace(/\\n/g, '\n')
      .replace(/\\"/g, '"')
      .trim())
    .filter(s => s && !seen.has(s) && seen.add(s))
    .join('\n');
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
      return res.status(400).json({ error: '不支持的链接地址，请改用文字或截图导入。' });
    }
    return res.status(502).json({ error: '链接抓取失败，请改用文字或截图导入。' });
  }

  try {
    const resp = fetched.resp;
    const html = String(resp.data || '');
    if (/验证码|滑块验证|滑动验证|安全验证|captcha/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
      return res.status(502).json({ error: '链接被验证码拦截，请改用文字或截图导入。' });
    }

    const text = extractXhsText(html);
    if (!text || text.length < 6) {
      return res.status(422).json({ error: '没能从链接里提取到菜谱文案，请改用文字或截图导入。' });
    }

    // finalUrl 已逐跳校验，只会是公网地址，不泄露内部主机。
    return res.json({ text, finalUrl: fetched.finalUrl });
  } catch (err) {
    return res.status(502).json({ error: '链接抓取失败，请改用文字或截图导入。' });
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

function sanitizeRecipe(recipe) {
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
  }

  // 3) tags 收敛 + name 去空白
  if (Array.isArray(recipe.tags)) {
    recipe.tags = recipe.tags.map(t => String(t || '').trim()).filter(Boolean).slice(0, 4);
  }
  if (recipe.name != null) recipe.name = String(recipe.name).trim();

  return recipe;
}

app.get('/api/ai-status', (req, res) => {
  res.json({
    available: Boolean(OPENAI_API_KEY),
    mode: 'cloud',
    modelConfigured: Boolean(OPENAI_MODEL),
    visionModelConfigured: Boolean(OPENAI_VISION_MODEL),
    imageMaxBase64Bytes: AI_IMAGE_MAX_BASE64_BYTES
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
  if (!text && !imageBase64) return sendAiJsonError(res, 400, 'missing_input', '缺少待解析的文案或图片。');
  if (!OPENAI_API_KEY) return sendAiJsonError(res, 503, 'missing_api_key', '后端未配置 AI 密钥（OPENAI_API_KEY）。');
  if (estimateBase64EncodedBytes(imageBase64) > AI_IMAGE_MAX_BASE64_BYTES) {
    return sendAiJsonError(res, 413, 'image_too_large', '图片过大。', { maxBase64Bytes: AI_IMAGE_MAX_BASE64_BYTES });
  }

  const instruction = text
    ? `请把下面这段菜谱文案整理成规定的 JSON：\n\n${text}`
    : '请根据这张配料表/菜谱截图，整理成规定的 JSON。';
  const userContent = imageBase64
    ? [{ type: 'text', text: instruction }, { type: 'image_url', image_url: { url: imageBase64 } }]
    : instruction;

  try {
    const resp = await axios.post(
      resolveChatUrl(OPENAI_BASE_URL),
      {
        model: imageBase64 ? OPENAI_VISION_MODEL : OPENAI_MODEL,
        messages: [
          { role: 'system', content: IMPORT_SYSTEM_PROMPT },
          { role: 'user', content: userContent }
        ],
        temperature: 0.2,
        response_format: { type: 'json_object' }
      },
      {
        timeout: 45000,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${OPENAI_API_KEY}` }
      }
    );
    const content = resp.data && resp.data.choices && resp.data.choices[0] && resp.data.choices[0].message
      ? (resp.data.choices[0].message.content || '')
      : '';
    if (!content) return sendAiJsonError(res, 502, 'empty_response', 'AI 没有返回内容，请稍后重试。');

    // ── 终极降级兜底：在后端先清洗一遍 AI 的 JSON，再回给前端。──
    //   保险栈：① 系统提示已硬约束；② 这里 JS 兜底过滤常备品 + qty 必填 + method 剥序号。
    const parsed = safeParseModelJson(content);
    if (parsed) {
      const cleaned = sanitizeRecipe(parsed);
      // 同时回传清洗后的对象 + 原 content（前端 validateImportedRecipe 兼容字符串/对象/数组）。
      return res.json({ content: JSON.stringify(cleaned), recipe: cleaned });
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
