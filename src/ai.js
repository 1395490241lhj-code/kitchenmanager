import { CUSTOM_AI } from './config.js?v=89';
import { S } from './storage.js?v=98';

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

function extractJson(text) {
  let cleaned = text.replace(/<think>[\s\S]*?<\/think>/gi, '')
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
  throw new Error('AI 未返回有效的 JSON 数据');
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
  return extractJson(data.choices?.[0]?.message?.content || '');
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
  return `AI 暂不可用：${msg || '未知错误'}。本地功能仍可正常使用。`;
}

export async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = '你是一个中文食材管理助手。请分析图片收据。1. 提取【食品/食材】。2. **重要：请自动忽略所有佐料（如葱、姜、蒜、盐、糖、酱油、醋、味精、花椒、辣椒等），只保留核心肉类、蔬菜、蛋奶等。**3. 提取【名称】、【数量】(默认1)、【单位】。4. 尽可能将英文名或别名转换为通用中文名。返回 JSON 数组: [{"name": "五花肉", "qty": 0.5, "unit": "kg"}]';
  const jsonStr = await callAiService(prompt, base64);
  return JSON.parse(jsonStr);
}

export async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item).join('、');
  const prompt = `你是一位精通川菜和中式家常菜的资深大厨。请为菜品【${recipeName}】编写一份做法。已知用料：${ingStr}。

**严格要求**：
1. 拒绝黑暗料理，不合理则修正。
2. 正宗或家常做法，步骤清晰。
3. 请务必返回如下 **JSON 格式**（不要 markdown）：
{ "method": "1. 第一步...\\n2. 第二步..." }`;

  const jsonStr = await callAiService(prompt);
  try {
    const res = JSON.parse(jsonStr);
    return res.method || jsonStr;
  } catch (e) {
    return jsonStr;
  }
}

export async function callAiSearchRecipe(query, invNames) {
  const prompt = `我冰箱里有：【${invNames}】。我想找菜谱：【${query}】。请提供一道符合搜索的菜谱。要求：1. "ingredients" 字段中，**请剔除所有姜、葱、蒜、花椒、辣椒、油、盐、酱、醋等佐料**，只列出肉、菜等核心食材。2. "method" 字段包含详细做法。返回 JSON：{ "name": "标准菜名", "ingredients": "核心食材1,核心食材2", "method": "1. 步骤... 2. 步骤..." }`;
  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
}

export async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes || []).map(r => r.name).join(',');

  const prompt = `你是一位严谨的、拥有30年经验的中式家庭大厨。请根据冰箱库存：【${invNames}】规划今日菜单。

请严格按照以下 JSON 格式返回：
{
  "local": [
    {"name": "从菜谱库【${recipeNames}】中挑选3道最匹配库存的菜名", "reason": "基于库存匹配度的推荐理由"}
  ],
  "creative": {
    "name": "推荐一道不在菜谱库中，但非常经典、大众熟知的家常菜",
    "reason": "简短介绍这道菜的口味特点",
    "ingredients": ["核心食材1", "核心食材2"]
  }
}

**严格约束（必读）**：
1. **拒绝离谱替代**：绝不允许用葱姜蒜、九层塔、香菜等佐料去替代叶菜、肉类等主材。
2. **拒绝黑暗料理**：禁止奇怪的食材混搭。推荐必须是大众耳熟能详的传统家常菜（如：番茄炒蛋、青椒肉丝）。
3. **ingredients 必须是数组**：只列出肉、菜、蛋、豆制品等核心主材，**严禁**包含葱姜蒜、盐糖油酱醋等佐料。`;

  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
}
