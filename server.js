/*
 * server.js —— Kitchen Manager 全栈一体化服务器
 *
 * - 用 Express 静态托管前端（本项目无构建步骤，index.html 在仓库根目录，直接托管根目录）。
 * - /api/xhs-extract：服务端抓取小红书/网页菜谱文案，绕过浏览器 CORS。
 *     跟随 302 短链（xhslink.com → 真实长链）、伪造移动端 UA、正则提取
 *     window.__INITIAL_STATE__ / og:title / description 等文案，返回纯文本 JSON。
 * - /api/ai-parse：后端统一呼叫 openai/gpt-oss-120b（密钥/Base URL 来自环境变量），
 *     返回模型 JSON 原文，前端不再需要本地 API Key。
 *
 * 环境变量（Render）：PORT、OPENAI_API_KEY、OPENAI_BASE_URL、OPENAI_MODEL（可选）。
 * 启动：npm install && npm start  （默认 http://localhost:3000）
 */
const path = require('path');
const express = require('express');
const axios = require('axios');

const app = express();
const ROOT = __dirname;
const PORT = process.env.PORT || 3000;

// 解析 JSON 请求体（截图 base64 较大，放宽上限）。
app.use(express.json({ limit: '12mb' }));

const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1';

// ── AI 解析（120B）配置：密钥与 Base URL 由 Render 环境变量提供 ──
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.groq.com/openai/v1';
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'openai/gpt-oss-120b';

// 把 Base URL 归一为 chat/completions 完整地址。
function resolveChatUrl(base) {
  const b = String(base || '').trim().replace(/\/+$/, '');
  if (/\/chat\/completions$/.test(b)) return b;
  if (/\/v\d+$/.test(b)) return `${b}/chat/completions`;
  return `${b}/v1/chat/completions`;
}

const IMPORT_SYSTEM_PROMPT = `你是一位资深中餐大厨兼菜谱结构化助手。用户会给你一段来自小红书/网页的菜谱文案，或一张配料表/视频截图。
请把其中的菜谱信息做语义清洗后，严格只返回一个 JSON 对象（不要 markdown 代码块、不要任何解释文字），字段如下：
{
  "name": "标准菜名",
  "tags": ["家常菜", "口味/菜系等标签"],
  "ingredients": [ {"item": "青椒", "qty": "2", "unit": "个"}, {"item": "生抽", "qty": "2", "unit": "勺"} ],
  "method": ["步骤一文本", "步骤二文本", "步骤三文本"]
}

【用量双轨制】——每个食材的 qty / unit 必须按其类别选用单位，这是最重要的规则：
1. 主材料（肉、禽、蛋、海鲜、蔬菜、豆制品、主食等）：
   - 严禁输出精确克数（如 150g、230g、半斤）。
   - 必须换算为离散、直观的家常单位：个 / 根 / 把 / 棵 / 块 / 袋 / 盒 / 片 / 只 / 条 / 份。
   - 无法判断数量时，统一用 qty "1"、unit "份"。
   - 示例：{"item":"五花肉","qty":"1","unit":"块"}、{"item":"青椒","qty":"2","unit":"个"}、{"item":"虾","qty":"1","unit":"份"}。
2. 调味料（盐、糖、生抽、老抽、醋、料酒、蚝油、油、淀粉、花椒、辣椒等）：
   - 允许并推荐使用精准的烹饪计量：勺 / 茶匙 / 克 / 毫升，或模糊量「适量」「少许」。
   - 示例：{"item":"生抽","qty":"2","unit":"勺"}、{"item":"糖","qty":"5","unit":"克"}。

【qty 必须是纯数字字符串】——这是必须遵守的铁律，任何例外都视为输出错误：
- qty 只能是数字组成的字符串，如 "1"、"2"、"3"、"0.5"、"5"；可以含小数点，不得包含任何汉字、字母或符号。
- 严禁出现："" / null / undefined / 缺省字段 / "适量" / "少许" / "若干" / "些许" / "半" / "一" / "两"。
- 文案/视频里没明确数量时，按当前菜品的【三人份家常用量】智能估算并强行填合理数字：
  · 主料：土豆 "2"/"3"、青椒 "2"、五花肉 "1"、鸡蛋 "2"、葱 "1"、虾 "1"；
  · 调料：食用油 "1"/"2"、生抽 "2"、老抽 "1"、醋 "1"、料酒 "1"、糖 "5"、干辣椒粉 "1"、花椒 "1"、葱花 "1"。
- 当 unit 取「适量」「少许」「杯」「把」或其它无量纲单位（如盐、水、香菜、茴香等）时，qty 仍必须填 "1"，例如 {"item":"盐","qty":"1","unit":"适量"}。
- 这条规则优先于所有其它要求——宁愿估算偏差，也绝不能让 qty 为空或非数字。

【method 数组化】——method 必须是字符串数组，不再是单一字符串：
- 形如 method: ["步骤一文本", "步骤二文本", "步骤三文本"]，每个步骤一个数组元素。
- 铁律：每个步骤字符串内部严禁包含任何数字或文字序号前缀。
  · 严禁开头出现 "1. " / "1、" / "第一步：" / "步骤1：" / "一、" / "(1) " 等任何前缀。
  · 直接以动词或主语开头：错 "1. 土豆切丝"；对 "土豆切丝"。
- 至少 2 个步骤；建议 3–8 个；每步独立、可执行、清晰。

其它要求：
- name 必填，为简洁标准菜名。
- ingredients 必填，至少一项；item / qty / unit 三个字段一律为非空字符串。
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

// 代理路由：抓取并返回菜谱文案。
app.get('/api/xhs-extract', async (req, res) => {
  const url = String(req.query.url || '').trim();
  if (!url) return res.status(400).json({ error: '缺少 url 参数。' });
  if (!/^https?:\/\//i.test(url)) return res.status(400).json({ error: '仅支持 http/https 链接。' });

  try {
    const resp = await axios.get(url, {
      maxRedirects: 5,                 // 跟随 302，把 xhslink.com 短链解析为真实长链
      timeout: 12000,
      responseType: 'text',
      transformResponse: r => r,       // 保留原始 HTML 字符串
      headers: {
        'User-Agent': MOBILE_UA,       // 伪造移动端 UA，避免被直接拦截
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      validateStatus: s => s >= 200 && s < 400
    });

    const html = String(resp.data || '');
    if (/验证码|滑块验证|滑动验证|安全验证|captcha/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
      return res.status(502).json({ error: '链接被验证码拦截，请改用文字或截图导入。' });
    }

    const text = extractXhsText(html);
    if (!text || text.length < 6) {
      return res.status(422).json({ error: '没能从链接里提取到菜谱文案，请改用文字或截图导入。' });
    }

    const finalUrl = (resp.request && resp.request.res && resp.request.res.responseUrl) || url;
    return res.json({ text, finalUrl });
  } catch (err) {
    const status = err.response && err.response.status;
    const msg = status ? `链接抓取失败（${status}），请改用文字或截图导入。` : '链接抓取失败，请改用文字或截图导入。';
    return res.status(502).json({ error: msg });
  }
});

// AI 解析路由：后端统一呼叫 openai/gpt-oss-120b，密钥来自 Render 环境变量。
app.post('/api/ai-parse', async (req, res) => {
  const text = String((req.body && req.body.text) || '').trim();
  const imageBase64 = (req.body && req.body.imageBase64) || null;
  if (!text && !imageBase64) return res.status(400).json({ error: '缺少待解析的文案或图片。' });
  if (!OPENAI_API_KEY) return res.status(503).json({ error: '后端未配置 AI 密钥（OPENAI_API_KEY）。' });

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
        model: OPENAI_MODEL,
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
    if (!content) return res.status(502).json({ error: 'AI 没有返回内容，请稍后重试。' });
    return res.json({ content });
  } catch (err) {
    const status = err.response && err.response.status;
    const apiMsg = err.response && err.response.data && err.response.data.error && err.response.data.error.message;
    const msg = status ? `AI 解析失败（${status}）：${apiMsg || '请稍后重试。'}` : 'AI 解析请求失败，请稍后重试。';
    return res.status(502).json({ error: msg });
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
