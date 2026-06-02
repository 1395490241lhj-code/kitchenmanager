import { CUSTOM_AI } from './config.js?v=199';
import { S } from './storage.js?v=199';

function getAiConfig() {
  const localSettings = S.load(S.keys.settings, {});
  let apiKey = localSettings.apiKey || CUSTOM_AI.KEY;
  let apiUrl = localSettings.apiUrl || CUSTOM_AI.URL;
  let model = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;

  if (apiUrl && apiUrl.includes('api.groq.com') && !apiUrl.includes('/chat/completions')) {
    apiUrl = apiUrl.replace(/\/$/, '');
    if (apiUrl.endsWith('/v1')) apiUrl += '/chat/completions';
    else apiUrl = 'https://api.groq.com/openai/v1/chat/completions';
  }

  if (!apiKey) return null;
  return { apiKey, apiUrl, textModel: model, visionModel };
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

export function normalizeAiIngredients(value) {
  let list = value;
  if (typeof value === 'string') list = value.split(/[，,、/;；|]+/).map(item => item.trim());
  if (!Array.isArray(list)) return [];

  return list.map(item => {
    if (typeof item === 'string') {
      return { item: item.trim(), qty: '', unit: '' };
    }
    if (!item || typeof item !== 'object') return null;
    const name = String(item.item || item.name || '').trim();
    if (!name) return null;
    return {
      item: name,
      qty: item.qty ?? item.amount ?? '',
      unit: String(item.unit || '').trim()
    };
  }).filter(Boolean);
}

export function validateReceiptItems(input) {
  const parsed = safeParseJson(input, '小票识别结果');
  const list = Array.isArray(parsed) ? parsed : parsed.items;
  if (!list || !Array.isArray(list)) throw new Error('小票识别结果里没有可入库的食材。');

  const items = list.map(item => {
    let nameStr = '';
    let originalNameStr = '';
    let qty = 1;
    let unitStr = '';

    if (typeof item === 'string') {
      nameStr = item.trim();
      originalNameStr = nameStr;
    } else if (item && typeof item === 'object') {
      nameStr = String(item.name || item.item || '').trim();
      originalNameStr = String(item.originalName || '').trim() || nameStr;
      qty = item.qty ?? item.amount ?? 1;
      unitStr = String(item.unit || '').trim();
    }

    if (!nameStr) return null;

    return {
      name: nameStr,
      originalName: originalNameStr,
      qty: qty || 1,
      unit: unitStr
    };
  }).filter(Boolean);

  if (!items.length) throw new Error('小票识别结果里没有可入库的食材。');
  return items;
}

export function validateRecipeResult(input) {
  const data = safeParseJson(input, 'AI 菜谱结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('AI 菜谱结果不是对象。');

  const name = String(data.name || '').trim();
  const method = String(data.method || '').trim();
  const ingredients = normalizeAiIngredients(data.ingredients);

  if (!name) throw new Error('AI 菜谱缺少菜名。');
  if (!ingredients.length) throw new Error('AI 菜谱缺少食材数组。');
  if (!method) throw new Error('AI 菜谱缺少做法。');

  return {
    name,
    ingredients,
    method,
    isAiDraft: true,
    draftSource: 'ai-search'
  };
}

export function validateRecommendationResult(input) {
  const data = safeParseJson(input, 'AI 推荐结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('AI 推荐结果不是对象。');

  const local = Array.isArray(data.local)
    ? data.local.map(item => ({
      name: String(item?.name || '').trim(),
      reason: String(item?.reason || 'AI 推荐').trim()
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

  if (!local.length && !creative) throw new Error('AI 推荐结果缺少可用菜谱。');
  return { local, creative };
}

function validateMethodResult(input) {
  const data = safeParseJson(input, 'AI 做法结果');
  const method = String(data?.method || '').trim();
  if (!method) throw new Error('AI 做法结果缺少 method 字段。');
  return method;
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
        let w = img.width;
        let h = img.height;
        const max = 1024;
        if (w > h) {
          if (w > max) { h *= max / w; w = max; }
        } else if (h > max) {
          w *= max / h;
          h = max;
        }
        canvas.width = w;
        canvas.height = h;
        ctx.drawImage(img, 0, 0, w, h);
        resolve(canvas.toDataURL('image/jpeg', 0.7));
      };
      img.onerror = () => reject(new Error('图片读取失败，请换一张更清晰的小票。'));
    };
    reader.onerror = reject;
  });
}

async function callAiService(prompt, imageBase64 = null) {
  const conf = getAiConfig();
  if (!conf) throw new Error('未配置 API Key，转为本地模式');

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
  if (msg.includes('未配置')) return 'AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。';
  if (msg.includes('401')) return 'AI 暂不可用：API Key 可能已过期。本地功能仍可正常使用。';
  if (msg.includes('429')) return 'AI 暂不可用：请求太频繁或额度不足。本地功能仍可正常使用。';
  if (msg.includes('404')) return 'AI 暂不可用：模型名称可能不正确。本地功能仍可正常使用。';
  if (msg.includes('超时')) return 'AI 暂不可用：响应超时。本地功能仍可正常使用。';
  if (msg.includes('格式不正确') || msg.includes('缺少') || msg.includes('没有返回可识别')) return `AI 返回内容不能直接使用：${msg}`;
  return `AI 暂不可用：${msg || '未知错误'}。本地功能仍可正常使用。`;
}

export async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `你是一个中文食材管理助手。请分析图片收据，只提取真实食品/食材。

请严格返回 JSON 格式，不要包含 Markdown 标记（如 \`\`\`json），也不要任何解释或说明。
返回结构如下：
[
  {
    "originalName": "King Oyster Mushroom",
    "name": "杏鲍菇",
    "qty": 1,
    "unit": "盒"
  }
]

字段及要求：
- originalName: 小票上的原始名称（包含英文或数字等商品名）。
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
- 忽略非食品、购物袋、折扣、税费、会员信息。并且忽略葱姜蒜、盐、糖、酱油、醋、味精、花椒、辣椒等佐料。`;
  const raw = await callAiService(prompt, base64);
  return validateReceiptItems(raw);
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

  const raw = await callAiService(prompt);
  return validateMethodResult(raw);
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
- 不要把葱姜蒜、盐糖油酱醋等佐料列入 ingredients。`;
  const raw = await callAiService(prompt);
  return validateRecipeResult(raw);
}

export async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes || []).map(r => r.name).join(',');

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
- 严禁用葱姜蒜、香菜、调料替代肉菜蛋豆等主材。`;

  const raw = await callAiService(prompt);
  return validateRecommendationResult(raw);
}

// 智能录入解析服务：抓取与大模型调用都在后端（server.js）完成。
// 前端只负责把「链接文案 / 截图」传给后端代理，不再读取本地 API Key。

// 抓取小红书/网页菜谱文案：交给同源后端 /api/xhs-extract（server.js）完成
// 302 跟随、移动端 UA 伪造与 __INITIAL_STATE__ 解析，绕过浏览器跨域限制。
async function fetchRecipeText(url) {
  let res;
  try {
    res = await fetch(`/api/xhs-extract?url=${encodeURIComponent(url)}`);
  } catch (e) {
    // 后端不可用（如纯静态托管、未启动 node server.js）
    throw new Error('链接抓取受限，请改用文字或截图导入。');
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  if (!res.ok) {
    throw new Error((data && data.error) || '链接抓取受限，请改用文字或截图导入。');
  }
  const text = data && data.text;
  if (!text || String(text).length < 6) {
    throw new Error('没能从链接里提取到菜谱文案，请改用文字或截图导入。');
  }
  return String(text);
}

// 解析 120B 返回，校验并对齐编辑器字段（name / tags / ingredients / method）。
function validateImportedRecipe(input) {
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
  const ingredients = normalizeAiIngredients(data.ingredients);
  const seasonings = normalizeAiIngredients(data.seasonings);
  const tags = Array.isArray(data.tags) ? data.tags.map(t => String(t || '').trim()).filter(Boolean).slice(0, 4) : [];

  if (!name) throw new Error('AI 菜谱缺少菜名。');
  if (!ingredients.length) throw new Error('AI 菜谱缺少食材。');
  if (!method) throw new Error('AI 菜谱缺少做法。');

  return { name, tags, ingredients, seasonings, method, isAiDraft: true, draftSource: 'ai-import' };
}

// 通过后端 /api/ai-parse 调用 openai/gpt-oss-120b（密钥与 Base URL 由 Render 环境变量提供）。
// 前端不再校验本地 API Key，未配置也能正常点击、走后端代理。
async function parseRecipeWith120B({ text = '', imageBase64 = null } = {}) {
  let res;
  try {
    res = await fetch('/api/ai-parse', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, imageBase64 })
    });
  } catch (e) {
    throw new Error('AI 服务暂不可用（后端未启动？），请稍后重试。');
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  if (!res.ok) {
    throw new Error((data && data.error) || `AI 解析失败 (${res.status})。`);
  }
  // 后端返回模型原文 content，由前端统一校验对齐编辑器字段。
  return validateImportedRecipe((data && data.content) || '');
}

/**
 * 解析外部菜谱来源（小红书/网页链接、配料表截图）→ 可编辑菜谱草稿。
 * @param {{ url?: string, file?: File }} input
 * @returns {Promise<{name, tags, ingredients:[{item,qty,unit}], method, isAiDraft, draftSource}>}
 */
export async function importRecipeFromSource({ url = '', file = null } = {}) {
  const cleanUrl = String(url || '').trim();
  if (!cleanUrl && !file) throw new Error('请粘贴链接或上传视频/截图。');

  // 截图 → 走视觉解析；视频暂不支持逐帧，引导用户改用截图。
  let imageBase64 = null;
  if (file) {
    if (/^image\//.test(file.type)) imageBase64 = await compressImage(file);
    else if (!cleanUrl) throw new Error('暂不支持直接解析视频，请改用配料表截图或文字导入。');
  }

  // 链接 → 抓取文案（可能被跨域/验证码拦截，给出友好提示）。
  let sourceText = '';
  if (cleanUrl) sourceText = await fetchRecipeText(cleanUrl);

  if (!sourceText && !imageBase64) throw new Error('没有可解析的内容，请改用文字或截图导入。');

  return parseRecipeWith120B({ text: sourceText, imageBase64 });
}
