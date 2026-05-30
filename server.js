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
请把其中的菜谱信息做语义清洗后，严格只返回一个 JSON 对象（不要 markdown 代码块、不要任何解释文字）。

⚠️ 三条最高优先级铁律（违反任意一条即视为输出失败，必须严格执行）：
1. 【严禁空数量】ingredients 数组里每个对象的 qty 必须是有效数字字符串（如 "1"、"2"、"0.5"），不允许 "" / null / undefined / 缺省字段 / "适量" / "少许" / "半" / "一" 等任何非数字内容。
2. 【常备品彻底过滤】ingredients 数组里严禁出现：水、食用油（及任何基础烹饪油：植物油/菜籽油/大豆油/玉米油/葵花籽油/调和油/色拉油）、盐、味精、鸡精。这些只能出现在 method 步骤文字里，不允许出现在食材列表中。
3. 【method 格式干净】method 必须是字符串数组，每个元素的文本【严禁包含任何序号前缀】（如 "1. " / "1、" / "第一步：" / "步骤2：" / "一、" / "(1) "）；直接以动词或主语开头。

JSON 字段如下：
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
2. 需要单独采购的特殊调味料（生抽、老抽、蚝油、料酒、醋、糖、淀粉、豆瓣酱、花椒、干辣椒等）：
   - 允许并推荐使用精准的烹饪计量：勺 / 茶匙 / 克 / 毫升，或模糊量「适量」「少许」。
   - 示例：{"item":"生抽","qty":"2","unit":"勺"}、{"item":"糖","qty":"5","unit":"克"}。

【🚫 厨房常备品过滤——不要进 ingredients】这是和「双轨制」并列的必须遵守规则：
- 以下「家庭基础常备品」绝对不能出现在 ingredients 数组里，因为它们无需作为库存追踪：
  · 水（清水、热水、凉水、开水、纯净水均一律不列入）。
  · 基础烹饪油：食用油、植物油、菜籽油、大豆油、玉米油、葵花籽油、调和油、色拉油等。
  · 基础调味粉：盐、味精、鸡精。
- 唯一例外：当上述常备品本身就是【主料】或【点睛核心料】（例如「花生油拌面」里的花生油、「盐焗鸡」里的粗盐），才允许保留在 ingredients。
- 即便被剔除出 ingredients，它们仍必须出现在 method 的步骤文字里以保持烹饪指导连贯（如「锅中倒油烧热」、「加水大火焖煮」、「调入盐」）。
- 实施口径：先生成完整食材表，再按上述规则过滤一遍，确认最终 ingredients 不包含 水/油类/盐/味精/鸡精 这五类基础常备品。

【qty 必须是纯数字字符串】——这是必须遵守的铁律，任何例外都视为输出错误：
- qty 只能是数字组成的字符串，如 "1"、"2"、"3"、"0.5"、"5"；可以含小数点，不得包含任何汉字、字母或符号。
- 严禁出现："" / null / undefined / 缺省字段 / "适量" / "少许" / "若干" / "些许" / "半" / "一" / "两"。
- 文案/视频里没明确数量时，按当前菜品的【三人份家常用量】智能估算并强行填合理数字：
  · 主料：土豆 "2"/"3"、青椒 "2"、五花肉 "1"、鸡蛋 "2"、葱 "1"、虾 "1"；
  · 调料：生抽 "2"、老抽 "1"、醋 "1"、料酒 "1"、糖 "5"、干辣椒粉 "1"、花椒 "1"、葱花 "1"。
- 当 unit 取「适量」「少许」「杯」「把」或其它无量纲单位时，qty 仍必须填 "1"，例如 {"item":"豆瓣酱","qty":"1","unit":"勺"}。
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
  // 模糊提取：允许用户传整段小红书分享语，服务端再用同一条正则兜底捕获 URL。
  const raw = String(req.query.url || '').trim();
  const m = raw.match(/https?:\/\/[^\s]+/g);
  const url = m ? m[0].replace(/[，。、,.;；]+$/, '') : raw;
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

function sanitizeRecipe(recipe) {
  if (!recipe || typeof recipe !== 'object') return recipe;

  // 1) ingredients：过滤常备品 + 强制 qty/unit 非空
  if (Array.isArray(recipe.ingredients)) {
    recipe.ingredients = recipe.ingredients.map(ing => {
      if (!ing || typeof ing !== 'object') return null;
      const item = String(ing.item || '').trim();
      if (!item) return null;

      // (a) 常备品黑名单：item 命中即剔除（用 includes 容忍模型加修饰词，如「热水」「食用油」）
      if (PANTRY_BLACKLIST.some(b => item.includes(b))) return null;

      // (b) qty 强制为有效数字字符串；空 / null / 非数字 / 中文都兜底为 "1"
      let qty = String(ing.qty == null ? '' : ing.qty).trim();
      if (!qty || qty === 'null' || qty === 'undefined' || !/^\d+(?:\.\d+)?$/.test(qty)) qty = '1';

      // (c) unit 规范：为空给「份」
      let unit = String(ing.unit == null ? '' : ing.unit).trim();
      if (!unit) unit = '份';

      return { item, qty, unit };
    }).filter(Boolean);
  }

  // 2) method：统一成纯文本字符串数组，剥掉可能残留的序号前缀
  let steps = null;
  if (Array.isArray(recipe.method)) steps = recipe.method;
  else if (Array.isArray(recipe.steps)) steps = recipe.steps;
  else if (typeof recipe.method === 'string') steps = recipe.method.split(/\n+/);
  if (Array.isArray(steps)) {
    recipe.method = steps
      .map(stripStepPrefix)
      .filter(s => s && s.length > 1);
  }

  // 3) tags 收敛为字符串数组
  if (Array.isArray(recipe.tags)) {
    recipe.tags = recipe.tags.map(t => String(t || '').trim()).filter(Boolean).slice(0, 4);
  }
  if (recipe.name != null) recipe.name = String(recipe.name).trim();

  return recipe;
}

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
