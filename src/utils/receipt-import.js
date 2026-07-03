import {
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit,
  normalizeReceiptIngredientName
} from '../ingredients.js?v=231';
import { classifyRecipeIngredient } from './recipe-sanitizer.js?v=231';
import { mergeInventoryEntry } from '../inventory.js?v=231';
import {
  STAPLE_STATUS,
  addCustomPantryEntry,
  isStaple,
  loadPantryConfig,
  setStapleStatus
} from '../staples.js?v=231';
import { todayISO } from '../storage.js?v=231';

const RECEIPT_GROUPS = ['inventory', 'pantry', 'review', 'ignored'];
const CJK_RE = /[\u3400-\u9fff]/;

const RECEIPT_NON_FOOD_RULES = [
  { re: /^(tax|hst|gst|pst|subtotal|sub\s*total|total|card|change|payment|cash|visa|mastercard|amex|american\s*express|transaction|terminal|lane|receipt|member|coupon|discount|deposit|bottle\s*return|bag|shopping\s*bag|container|utensil|fee)$/i, reason: '非食品或收银信息' },
  { re: /(购物袋|塑料袋|环保袋|袋费|税费|税|折扣|优惠|会员|收银|小计|合计|总计|找零|付款|银行卡|礼品卡|押金|纸巾|清洁|洗洁精|洗衣|餐具|容器费|非食品)/, reason: '非食品或收银信息' },
  { re: /^(水|清水|冰水|高汤|汤汁|适量)$/i, reason: '不需要加入厨房数据' }
];

const RECEIPT_PROCESSED_RULES = [
  { re: /^(汤圆|元宵)$/i, reason: '冷冻/熟制面点，默认不加入做菜食材' },
  { re: /(饺|餃|水饺|水餃|抄手|馄饨|餛飩|云吞|雲吞|dumpling|wonton)/i, reason: '冷冻/熟制面点，默认不加入做菜食材' },
  { re: /(粽|粽子|sticky\s*rice\s*dumpling)/i, reason: '加工主食，默认不加入做菜食材' },
  { re: /(方便面|泡面|速食面|spicy\s*seafood\s*noodle|instant\s*noodle|cup\s*noodle|ramen)/i, reason: '即食/速食，默认不加入做菜食材' },
  { re: /(雪贝|雪貝|糕点|糕點|蛋糕|点心|點心|甜品|cake|pastry|dessert)/i, reason: '点心甜品，默认不加入做菜食材' },
  { re: /(小鱼干花生|小魚乾花生|鱼干花生|魚乾花生|dried\s*anchovy\s*w\/?\s*peanut|anchovy.*peanut|peanut.*anchovy)/i, reason: '加工食品，默认不加入做菜食材' },
  { re: /(零食|薯片|饼干|餅乾|巧克力|糖果|可乐|可樂|饮料|飲料|果汁|奶茶|汽水|snack|chips|cookie|chocolate|candy|cola|soda|juice|beverage|drink)/i, reason: '零食饮料，默认不加入做菜食材' },
  { re: /(熟食|便当|便當|即食|预制菜|預製菜|烤鸡|烤雞|卤味|滷味|ready\s*to\s*eat|cooked)/i, reason: '熟食/即食食品，默认不加入做菜食材' },
  { re: /(包子|馒头|饅頭|pizza|披萨|披薩|spring\s*roll|鸡块|雞塊|薯条|薯條|丸|鱼丸|魚丸|牛肉丸|香肠|香腸|sausage|fish\s*ball|beef\s*ball)/i, reason: '冷冻/加工食品，默认不加入做菜食材' },
  { re: /(苹果|香蕉|橙子|橙|柑橘|桔子|橘子|橘|葡萄|草莓|蓝莓|梨|桃|芒果|西瓜|哈密瓜|柠檬|牛油果|猕猴桃|水果|mandarin|tangerine|orange|apple|banana|pear|grape|strawberry|blueberry|peach|mango|watermelon|lemon|avocado|kiwi)/i, reason: '水果，默认不加入做菜食材' }
];

const RECEIPT_PANTRY_RULES = [
  { re: /(姜|生姜|老姜|嫩姜|姜片|姜块|ginger)/i, name: '姜', reason: '常备货架 / 调味基础品' },
  { re: /(葱|小葱|大葱|青葱|scallion|green\s*onion)/i, name: '葱', reason: '常备货架 / 调味基础品' },
  { re: /(蒜|大蒜|蒜头|garlic)/i, name: '蒜', reason: '常备货架 / 调味基础品' },
  { re: /(红衣花生|红皮花生|花生|red\s*skin\s*peanut|peanut)/i, name: '花生', reason: '常备干货，归入常备货架' },
  { re: /(干木耳|dry\s*wood\s*ear|dried\s*black\s*fungus|black\s*fungus)/i, name: '干木耳', reason: '常备货架 / 干货' },
  { re: /(大米|糯米|杂粮|小米|黑米|燕麦|面粉|淀粉|玉米淀粉|干木耳|干香菇|腐竹|海带|紫菜|绿豆|红豆|黄豆|干豆|罐头)/i, reason: '常备货架 / 干货' },
  { re: /(挂面|面条|意面|米粉|粉丝|plain\s*noodle|dry\s*noodle)/i, reason: '常备主食' },
  { re: /(盐|糖|生抽|老抽|酱油|醋|料酒|蚝油|味精|鸡精|花椒|八角|香叶|桂皮|干辣椒|辣椒粉|胡椒|香油|菜油|猪油|食用油|豆瓣酱|甜面酱|豆豉)/, reason: '基础调味，归入常备货架' }
];

const RECEIPT_INVENTORY_RULES = [
  { re: /(板豆腐|豆腐|medium\s*firm\s*tofu|firm\s*tofu|soft\s*tofu|tofu)/i, name: '豆腐' },
  { re: /^(choy)$/i, name: 'choy' },
  { re: /(青菜|油菜苗|油菜|菜心|菜苗|yu\s*choy|bok\s*choy|choy sum)/i, name: '青菜' },
  { re: /(豆芽菜|豆芽|beansprout|bean\s*sprout)/i, name: '豆芽' },
  { re: /(莴笋|萵筍|stem\s*lettuce|celtuce)/i, name: '莴笋' },
  { re: /(有皮无骨鸡扒|有皮無骨雞扒|鸡腿|鸡扒|鸡肉|boneless\s*skin-on\s*chicken\s*leg|chicken\s*leg|chicken\s*thigh)/i, name: '鸡腿' },
  { re: /(猪肉|豬肉|pork)(?!.*dumpling)/i, name: '猪肉' },
  { re: /(牛肉|beef)/i, name: '牛肉' },
  { re: /(虾|蝦|shrimp|prawn)/i, name: '虾' },
  { re: /(鲜鱼|魚|鱼|fish)/i, name: '鲜鱼' }
];

const FOODISH_ENGLISH_RE = /(choy|lettuce|tofu|pork|beef|chicken|fish|shrimp|prawn|peanut|noodle|rice|cake|dumpling|wonton|vegetable|mushroom|bean|sprout|ginger|garlic|onion)/i;
const FOODISH_CHINESE_RE = /(菜|肉|鱼|魚|鸡|雞|鸭|鴨|虾|蝦|豆|腐|菇|笋|筍|面|米|粉|饼|餅|糕|粽|饺|餃|丸|花生|姜|葱|蒜|果|橘|橙|梨|桃)/;

function normalizeChineseReceiptText(text) {
  const map = {
    餃: '饺', 貝: '贝', 魚: '鱼', 雞: '鸡', 豬: '猪', 萵: '莴', 筍: '笋',
    蔥: '葱', 蒜頭: '蒜头', 紅: '红', 衣: '衣', 鹹: '咸', 貨: '货', 乾: '干'
  };
  return String(text || '').replace(/[餃貝魚雞豬萵筍蔥紅鹹貨乾]/g, ch => map[ch] || ch).trim();
}

function firstRule(text, rules) {
  const raw = String(text || '').trim();
  if (!raw) return null;
  return rules.find(rule => rule.re.test(raw)) || null;
}

function extractChineseText(item) {
  const explicit = normalizeChineseReceiptText(item.zhText || item.chineseName || '');
  if (explicit && CJK_RE.test(explicit)) return explicit;
  const candidates = [...new Set([item.rawText, item.originalName, item.name, item.canonicalName]
    .map(value => normalizeChineseReceiptText(value || ''))
    .filter(Boolean))];
  for (const source of candidates) {
    const match = source.match(/[\u3400-\u9fff][\u3400-\u9fff\s·（）()、，,/-]*/);
    if (match) return match[0].replace(/[，,、/()-]+$/g, '').trim();
  }
  return '';
}

function extractEnglishText(item) {
  const explicit = String(item.enText || item.englishName || '').trim();
  if (explicit) return explicit;
  const candidates = [...new Set([item.rawText, item.originalName, item.name, item.canonicalName]
    .map(value => String(value || '').replace(/[\u3400-\u9fff]+/g, ' ').replace(/\s+/g, ' ').trim())
    .filter(Boolean))];
  return candidates[0] || '';
}

function isClearlyDifferent(a, b) {
  if (!a || !b) return false;
  const ca = getCanonicalName(a);
  const cb = getCanonicalName(b);
  if (!ca || !cb || ca === cb) return false;
  if (['猪肉', '牛肉', '鸡肉', '鸡腿', '虾', '鲜鱼', '豆腐', '青菜', '豆芽', '莴笋', '姜', '葱', '蒜', '花生'].includes(ca)
    && ['猪肉', '牛肉', '鸡肉', '鸡腿', '虾', '鲜鱼', '豆腐', '青菜', '豆芽', '莴笋', '姜', '葱', '蒜', '花生'].includes(cb)) {
    return true;
  }
  return false;
}

function classifyReceiptText(text, source = 'raw') {
  const raw = source === 'zh' ? normalizeChineseReceiptText(text) : String(text || '').trim();
  if (!raw) return null;

  const ignored = firstRule(raw, RECEIPT_NON_FOOD_RULES);
  if (ignored) return { group: 'ignored', name: raw, reason: ignored.reason, recognized: true };

  const review = firstRule(raw, RECEIPT_PROCESSED_RULES);
  if (review) return { group: 'review', name: raw, reason: review.reason, recognized: true };

  const pantry = firstRule(raw, RECEIPT_PANTRY_RULES);
  if (pantry) {
    const name = pantry.name || getCanonicalName(normalizeReceiptIngredientName(raw) || raw);
    return { group: 'pantry', name, reason: pantry.reason, recognized: true };
  }

  const inventory = firstRule(raw, RECEIPT_INVENTORY_RULES);
  if (inventory) {
    const name = inventory.name || getCanonicalName(normalizeReceiptIngredientName(raw) || raw);
    return { group: 'inventory', name, reason: '', recognized: true };
  }

  const normalized = source === 'en' ? normalizeReceiptIngredientName(raw) : getCanonicalName(raw);
  const recognizedEnglishAlias = source !== 'en' || normalized.toLowerCase() !== raw.toLowerCase();
  const role = normalized ? classifyRecipeIngredient(normalized).role : 'unknown';
  if (role === 'seasoning') return { group: 'pantry', name: normalized, reason: '基础调味，归入常备货架', recognized: true };
  if (role === 'core' && recognizedEnglishAlias) return { group: 'inventory', name: normalized, reason: '', recognized: true };

  if ((source === 'zh' && FOODISH_CHINESE_RE.test(raw)) || (source !== 'zh' && FOODISH_ENGLISH_RE.test(raw))) {
    return { group: 'review', name: raw, reason: '像食品但无法稳定归类，需要确认', recognized: false };
  }
  return null;
}

function normalizeReceiptEvidenceItem(item, group = '') {
  if (typeof item === 'string') {
    return { name: item.trim(), originalName: item.trim(), rawText: item.trim(), group };
  }
  const source = item && typeof item === 'object' ? item : {};
  const rawText = String(source.rawText || source.originalText || '').trim();
  const originalName = String(source.originalName || source.original || rawText || source.name || source.item || source.canonicalName || '').trim();
  const canonicalName = String(source.canonicalName || source.name || source.item || '').trim();
  return {
    ...source,
    name: canonicalName || originalName,
    originalName,
    rawText: rawText || originalName,
    zhText: normalizeChineseReceiptText(source.zhText || source.chineseName || ''),
    enText: String(source.enText || source.englishName || '').trim(),
    group: source.group || group,
    reason: String(source.reason || '').trim()
  };
}

export function classifyReceiptCandidate(item) {
  const normalized = normalizeReceiptEvidenceItem(item);
  const zhText = extractChineseText(normalized);
  const enText = extractEnglishText(normalized);
  const nameText = normalized.name || normalized.canonicalName || normalized.originalName || normalized.rawText;
  const zhHit = classifyReceiptText(zhText, 'zh');
  const enHit = classifyReceiptText(enText, 'en');
  const nameHit = classifyReceiptText(nameText, CJK_RE.test(String(nameText || '')) ? 'zh' : 'en');
  const preferred = zhHit || nameHit || enHit;

  if (zhHit && enHit && isClearlyDifferent(zhHit.name, enHit.name)) {
    return {
      group: 'review',
      name: zhHit.name || normalized.name,
      reason: '中英文信息不一致，需要确认',
      confidence: 'low',
      zhText,
      enText
    };
  }

  if (zhHit) {
    const reasonParts = [
      zhHit.reason,
      enHit && getCanonicalName(enHit.name) === getCanonicalName(zhHit.name) ? '中英一致' : '',
      zhText ? '中文优先' : ''
    ].filter(Boolean);
    return {
      ...zhHit,
      reason: [...new Set(reasonParts)].join('；'),
      confidence: enHit && getCanonicalName(enHit.name) === getCanonicalName(zhHit.name) ? 'high' : 'medium',
      zhText,
      enText
    };
  }

  if (preferred) {
    return {
      ...preferred,
      confidence: preferred.recognized ? 'medium' : 'low',
      zhText,
      enText
    };
  }

  const raw = [normalized.rawText, normalized.originalName, normalized.name].filter(Boolean).join(' ');
  if (FOODISH_CHINESE_RE.test(raw) || FOODISH_ENGLISH_RE.test(raw)) {
    return {
      group: 'review',
      name: normalized.name || normalized.originalName,
      reason: '像食品但无法稳定归类，需要确认',
      confidence: 'low',
      zhText,
      enText
    };
  }

  const aiGroup = RECEIPT_GROUPS.includes(normalized.group) ? normalized.group : '';
  if (aiGroup && aiGroup !== 'ignored') {
    return {
      group: aiGroup,
      name: normalized.name || normalized.originalName,
      reason: normalized.reason || '按识别结果归类',
      confidence: normalized.confidence || 'low',
      zhText,
      enText
    };
  }

  return {
    group: 'ignored',
    name: normalized.name || normalized.originalName || '未命名',
    reason: normalized.reason || '非食品或无法处理',
    confidence: normalized.confidence || 'low',
    zhText,
    enText
  };
}

export function postProcessReceiptItems(input) {
  const output = { inventory: [], pantry: [], review: [], ignored: [] };
  const append = (item, group = '') => {
    const normalized = normalizeReceiptEvidenceItem(item, group);
    if (!normalized.name && !normalized.originalName && !normalized.rawText) return;
    const local = classifyReceiptCandidate(normalized);
    const safeGroup = RECEIPT_GROUPS.includes(local.group) ? local.group : 'review';
    const finalName = local.name || normalized.name || normalized.originalName;
    const reasonParts = [local.reason, normalized.reason].filter(Boolean);
    output[safeGroup].push({
      ...normalized,
      name: finalName,
      canonicalName: finalName,
      originalName: normalized.originalName || normalized.rawText || finalName,
      rawText: normalized.rawText || normalized.originalName || finalName,
      ...(local.zhText ? { zhText: local.zhText } : {}),
      ...(local.enText ? { enText: local.enText } : {}),
      ...(local.confidence ? { confidence: local.confidence } : {}),
      ...(reasonParts.length ? { reason: [...new Set(reasonParts)].join('；') } : {})
    });
  };

  if (Array.isArray(input)) {
    input.forEach(item => append(item, 'inventory'));
    return output;
  }

  if (input && typeof input === 'object') {
    for (const group of RECEIPT_GROUPS) {
      const list = Array.isArray(input[group]) ? input[group] : [];
      list.forEach(item => append(item, group));
    }
    if (Array.isArray(input.items)) input.items.forEach(item => append(item, 'inventory'));
  }

  return output;
}

function hasCustomPantryEntry(name) {
  const canonical = getCanonicalName(name || '');
  const config = loadPantryConfig();
  return (config.custom || []).some(item =>
    item && item.type === 'pantry' && getCanonicalName(item.name) === canonical
  );
}

export function applyReceiptPantryItems(items, inv) {
  if (!Array.isArray(items) || !items.length || !Array.isArray(inv)) return 0;
  let count = 0;
  for (const item of items) {
    const name = getCanonicalName(item.name || item.item || '');
    if (!name) continue;
    const unit = (item.unit && String(item.unit).trim()) || guessKitchenUnit(name) || '份';
    const qty = Number(item.qty);
    const safeQty = Number.isFinite(qty) && qty > 0 ? qty : 1;

    if (isStaple(name)) {
      setStapleStatus(name, STAPLE_STATUS.SUFFICIENT);
      count++;
      continue;
    }

    if (!hasCustomPantryEntry(name)) {
      addCustomPantryEntry({
        name,
        group: '干货',
        type: 'pantry',
        kind: 'dry',
        unit,
        source: '常备干货',
        prep: getDryPrepText(name)
      });
    }

    mergeInventoryEntry(inv, {
      name,
      qty: safeQty,
      unit,
      buyDate: todayISO(),
      kind: 'dry',
      shelf: 365,
      stockStatus: 'ok',
      dryPrep: getDryPrepText(name),
      isFrozen: false
    }, { mode: 'add' });
    count++;
  }
  return count;
}
