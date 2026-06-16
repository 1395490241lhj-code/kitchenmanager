import { CUSTOM_AI } from './config.js?v=219';
import { S } from './storage.js?v=219';
import { getCanonicalName } from './ingredients.js?v=219';
import { classifyRecipeIngredient } from './utils/recipe-sanitizer.js?v=219';

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

const RECEIPT_REVIEW_RULES = [
  { re: /(苹果|香蕉|橙子|橙|柑橘|桔子|橘子|橘|葡萄|草莓|蓝莓|梨|桃|芒果|西瓜|哈密瓜|柠檬|牛油果|猕猴桃|水果|mandarin|tangerine|orange|apple|banana|pear|grape|strawberry|blueberry|peach|mango|watermelon|lemon|avocado|kiwi)/i, reason: '水果，默认不加入做菜食材' },
  { re: /(方便面|泡面|速食面|instant\s*noodle|ramen|cup\s*noodle|spicy\s*seafood\s*noodle|seafood\s*noodle)/i, reason: '即食/速食，默认不加入做菜食材' },
  { re: /(水饺|水餃|饺子|餃子|抄手|馄饨|餛飩|云吞|雲吞|汤圆|湯圓|包子|馒头|饅頭|粽子|咸肉粽|粽|披萨|披薩|鸡块|雞塊|薯条|薯條|速冻|速凍|冷冻成品|冷凍成品|pizza|spring\s*roll|dumpling|wonton|sticky\s*rice\s*dumpling)/i, reason: '冷冻成品，默认不加入做菜食材' },
  { re: /(薯片|饼干|餅乾|巧克力|糖果|可乐|可樂|饮料|飲料|果汁|奶茶|汽水|甜品|蛋糕|糕点|糕點|雪贝|雪貝|芋泥雪贝|芋泥雪貝|冰淇淋|酸奶|牛奶饮料|牛奶飲料|零食|snowy\s*cake|cake|cola|soda|juice|beverage|drink|cookie|chips|chocolate|candy|yogurt)/i, reason: '零食饮料，默认不加入做菜食材' },
  { re: /(dried\s*anchovy\s*w\/?\s*peanut|anchovy.*peanut|peanut.*anchovy|小鱼干花生|小魚乾花生|鱼干花生|魚乾花生|花生小鱼干|花生小魚乾)/i, reason: '加工食品，默认不加入做菜食材' },
  { re: /(便当|熟食|烤鸡|卤味|沙拉|即食|预制菜)/, reason: '熟食/即食食品，默认不加入做菜食材' }
];

const RECEIPT_PANTRY_RULES = [
  { re: /(大米|糯米|杂粮|小米|黑米|燕麦|米\b|挂面|面条|意面|米粉|粉丝|面粉|淀粉|玉米淀粉)/, reason: '常备主食/干粉' },
  { re: /(干木耳|木耳|干香菇|香菇干|腐竹|海带|紫菜|绿豆|红豆|黄豆|干豆|罐头)/, reason: '干货或常备货架物品' },
  { re: /(红皮花生|花生|red\s*skin\s*peanut|peanut)/i, reason: '常备干货，归入常备货架' },
  { re: /(盐|糖|生抽|老抽|酱油|醋|料酒|蚝油|味精|鸡精|花椒|八角|香叶|桂皮|干辣椒|辣椒粉|胡椒|香油|菜油|猪油|食用油|调料|豆瓣酱|甜面酱|豆豉)/, reason: '基础调味，归入常备货架' },
  { re: /(^|\s)(葱|小葱|大葱|青葱|姜|生姜|老姜|嫩姜|姜片|姜块|蒜|大蒜|蒜头|香菜|小米辣|scallion|green onion|ginger|garlic)(\s|$)/i, reason: '常备货架 / 调味基础品' },
  { re: /(牛奶)$/, reason: '日常补给，归入常备货架' }
];

const RECEIPT_INVENTORY_RULES = [
  { re: /(豆腐|tofu|medium\s*firm\s*tofu|firm\s*tofu|soft\s*tofu)/i, reason: '' },
  { re: /(青菜|油菜|油菜苗|菜苗|莴笋|萵筍|豆芽|豆芽菜|choy|yu\s*choy|stem\s*lettuce|beansprout|bean\s*sprout)/i, reason: '' },
  { re: /(鸡腿|鸡肉|猪肉|牛肉|虾|鱼|chicken\s*leg|chicken\s*thigh|pork|beef|shrimp|prawn|fish)/i, reason: '' }
];

const RECEIPT_IGNORED_RULES = [
  { re: /(购物袋|塑料袋|环保袋|袋费|税费|税|折扣|优惠|会员|收银|找零|礼品卡|纸巾|清洁|洗洁精|洗衣|非食品)/, reason: '非厨房食材' },
  { re: /^(水|清水|冰水|高汤|汤汁|适量)$/, reason: '不需要加入厨房数据' }
];

function matchReceiptRule(text, rules) {
  return rules.find(rule => rule.re.test(text));
}

export function classifyReceiptItem(name, originalName = '') {
  const cleanName = String(name || '').trim();
  const text = `${cleanName} ${String(originalName || '').trim()}`;
  const ignored = matchReceiptRule(text, RECEIPT_IGNORED_RULES);
  if (ignored) return { group: 'ignored', reason: ignored.reason };
  const review = matchReceiptRule(text, RECEIPT_REVIEW_RULES);
  if (review) return { group: 'review', reason: review.reason };
  const pantry = matchReceiptRule(text, RECEIPT_PANTRY_RULES);
  if (pantry) return { group: 'pantry', reason: pantry.reason };
  const inventory = matchReceiptRule(text, RECEIPT_INVENTORY_RULES);
  if (inventory) return { group: 'inventory', reason: inventory.reason };

  const canonical = getCanonicalName(cleanName);
  const role = classifyRecipeIngredient(canonical || cleanName).role;
  if (role === 'seasoning') return { group: 'pantry', reason: '基础调味，归入常备货架' };
  if (role !== 'core') return { group: 'ignored', reason: '不参与做菜库存' };
  return { group: 'inventory', reason: '' };
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

  const append = (item, aiGroup = 'inventory') => {
    const normalized = normalizeReceiptItem(item);
    if (!normalized) return;
    const local = classifyReceiptItem(normalized.name, normalized.originalName);
    const targetGroup = local.group !== 'inventory' ? local.group : aiGroup;
    const safeGroup = ['inventory', 'pantry', 'review', 'ignored'].includes(targetGroup) ? targetGroup : 'review';
    const adjusted = normalizeReceiptQuantityForKitchen(normalized, safeGroup);
    const baseReason = local.reason || normalized.reason || (
      safeGroup === 'review' ? '需要确认是否加入厨房' :
      safeGroup === 'pantry' ? '更适合放在常备货架' :
      safeGroup === 'ignored' ? '不是厨房食材' : ''
    );
    const reasonParts = [baseReason, adjusted.note].filter(Boolean);
    const reason = [...new Set(reasonParts)].join('；');
    delete adjusted.note;
    groups[safeGroup].push({ ...adjusted, ...(reason ? { reason } : {}) });
  };

  if (Array.isArray(parsed)) {
    parsed.forEach(item => append(item, 'inventory'));
  } else if (parsed && typeof parsed === 'object') {
    const aliases = {
      inventory: parsed.inventory || parsed.items || [],
      pantry: parsed.pantry || [],
      review: parsed.review || [],
      ignored: parsed.ignored || []
    };
    Object.entries(aliases).forEach(([group, list]) => {
      if (Array.isArray(list)) list.forEach(item => append(item, group));
    });
  } else {
    throw new Error('小票识别结果里没有能处理的内容。');
  }

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

function validateMethodResult(input) {
  const data = safeParseJson(input, 'AI 做法结果');
  const method = String(data?.method || '').trim();
  if (!method) throw new Error('AI 做法结果缺少 method 字段。');
  return method;
}

export function validateCookedMealResult(input) {
  const data = safeParseJson(input, '刚做了什么分析结果');
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('刚做了什么分析结果不是对象。');

  const dishes = Array.isArray(data.dishes)
    ? data.dishes.map(dish => {
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
    }).filter(dish => dish.name || dish.matchedRecipeName || dish.usedIngredients.length)
    : [];

  if (!dishes.length) throw new Error('AI 没有判断出可确认的食材。');
  return { dishes, needsReview: data.needsReview !== false };
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
  const prompt = `你是一个中文家庭厨房小票整理助手。请分析图片收据，把商品分成四类：做菜食材、常备货架、需要确认、已忽略。

请严格返回 JSON 格式，不要包含 Markdown 标记（如 \`\`\`json），也不要任何解释或说明。
返回结构如下：
{
  "inventory": [
    { "originalName": "Pork Belly", "name": "五花肉", "qty": 1, "unit": "盒" }
  ],
  "pantry": [
    { "originalName": "Noodles", "name": "挂面", "qty": 1, "unit": "包" }
  ],
  "review": [
    { "originalName": "Frozen Dumplings", "name": "速冻水饺", "qty": 1, "unit": "袋", "reason": "冷冻成品，默认不加入做菜食材" }
  ],
  "ignored": [
    { "originalName": "Shopping Bag", "reason": "非食品" }
  ]
}

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
- 普通做菜食材最终建议按“份”管理；如果小票显示 lb/kg/g，请保留原始重量信息，但 qty/unit 优先输出成估算份数，例如 2 lb 猪肉 -> { "qty": 2, "unit": "份" }，0.8 lb 虾 -> { "qty": 1, "unit": "份" }。
- 包装商品 qty 应为整数，不要输出 0.81 包 / 0.81 个这类小数包装数量。
- inventory 只放真正适合作为做菜库存的核心食材：肉、鱼虾、蔬菜、蛋、豆腐、菌菇等鲜货。
- tofu / medium firm tofu / firm tofu / soft tofu 必须识别为“豆腐”，放入 inventory。
- 青菜、油菜、莴笋、豆芽、choy、yu choy、stem lettuce、beansprout、鸡腿、pork、beef、shrimp、fish 等鲜货放入 inventory。
- pantry 放常备货架 / 干货 / 主食基础：姜、葱、蒜、干辣椒、花椒、八角、香叶、桂皮、大米、糯米、杂粮、面条、挂面、意面、米粉、粉丝、面粉、淀粉、干木耳、干香菇、腐竹、海带、紫菜、罐头、干豆，以及盐糖油酱醋等基础调味。
- pantry 不是所有耐放食品。只有做饭基础储备、普通干面、原料型干货和调味基础品进入 pantry；加工食品不要放 pantry。
- review 放需要用户确认、不默认加入普通库存的食品：水果、零食、饮料、甜品、酸奶、熟食、即食食品、方便面、泡面、spicy seafood noodle、instant noodle、ramen、cup noodle、速冻水饺、抄手、馄饨、云吞、汤圆、粽子、包子、馒头、披萨、鸡块、薯条、糕点、snowy cake、cake、Dried Anchovy w/Peanut 等冷冻/即食/加工食品。
- ignored 放完全不应处理的内容：购物袋、税费、折扣、会员信息、纸巾、清洁用品、非食品、收银信息。
- 葱姜蒜、盐、糖、酱油、醋、味精、花椒、辣椒、油等佐料不要放入 inventory，可放 pantry。`;
  const raw = await callAiService(prompt, base64);
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

  const raw = await callAiService(prompt);
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
  const raw = await callAiService(prompt);
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
- name 不要和上面列出的菜名重复，也不要只是刀工变化。`;
  const raw = await callAiService(prompt);
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
- 不要把葱姜蒜、盐糖油酱醋等佐料列入 ingredients。`;
  const raw = await callAiService(prompt);
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
- 严禁用葱姜蒜、香菜、调料替代肉菜蛋豆等主材。${antiFatigueRule}`;

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
