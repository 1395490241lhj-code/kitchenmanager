export const RECEIPT_ALIAS_STORAGE_KEY = 'km_v1_receipt_aliases';

const MAX_USER_RECEIPT_ALIASES = 200;
const NON_PRODUCT_ALIAS_RE = /^(?:tax|hst|gst|pst|subtotal|sub\s*total|total|card|cash|visa|mastercard|payment|change|member|coupon|discount|deposit|bag|shopping\s*bag|container|fee|receipt|terminal|lane)$/i;
const NON_PRODUCT_ALIAS_TEXT_RE = /(?:税费|税|小计|合计|总计|付款|收银|会员|折扣|优惠|购物袋|袋费|押金|容器费|非食品)/;

const BUILT_IN_RECEIPT_ALIASES = [
  { re: /上海青|shanghai\s+(?:bok\s*)?choy|shanghai\s+pak\s+choi/i, name: '上海青', group: 'inventory' },
  { re: /小白菜|baby\s+bok\s+choy|baby\s+pak\s+choi/i, name: '小白菜', group: 'inventory' },
  { re: /\bbok\s+choy\b|\bpak\s+choi\b/i, name: '小白菜', group: 'inventory', uncertain: true },
  { re: /菜心|choy\s*sum|yu\s*choy(?:\s*sum)?/i, name: '菜心', group: 'inventory' },
  { re: /芥兰|芥藍|gai\s*lan|kai\s*lan|kailan|chinese\s+broccoli/i, name: '芥兰', group: 'inventory' },
  { re: /茼蒿|皇帝菜|tong\s*ho|garland\s+chrysanthemum|chrysanthemum\s+greens?/i, name: '茼蒿', group: 'inventory' },
  { re: /大白菜|napa\s+cabbage|chinese\s+cabbage/i, name: '大白菜', group: 'inventory' },
  { re: /娃娃菜|baby\s+napa/i, name: '娃娃菜', group: 'inventory' },
  { re: /油麦菜|油麥菜|you\s*mai\s*cai|youmai\s*cai/i, name: '油麦菜', group: 'inventory' },
  { re: /空心菜|通菜|蕹菜|ong\s*choy|water\s+spinach/i, name: '空心菜', group: 'inventory' },
  { re: /莴笋|萵筍|stem\s+lettuce|celtuce/i, name: '莴笋', group: 'inventory' },
  { re: /生菜|lettuce/i, name: '生菜', group: 'inventory' },
  { re: /菠菜|spinach/i, name: '菠菜', group: 'inventory' },
  { re: /韭菜|chinese\s+chive/i, name: '韭菜', group: 'inventory' },
  { re: /豆苗|pea\s+shoots?/i, name: '豆苗', group: 'inventory' },
  { re: /黄豆芽|黃豆芽|soybean\s+sprouts?/i, name: '黄豆芽', group: 'inventory' },
  { re: /绿豆芽|綠豆芽|mung\s+bean\s+sprouts?/i, name: '绿豆芽', group: 'inventory' },
  { re: /豆芽菜|豆芽|bean\s*sprouts?|beansprouts?/i, name: '豆芽', group: 'inventory' },
  { re: /皇子菇|king\s+oyster\s+mushrooms?|eryngii\s+mushrooms?/i, name: '皇子菇', group: 'inventory' },
  { re: /金针菇|金針菇|enoki(?:\s+mushrooms?)?/i, name: '金针菇', group: 'inventory' },
  { re: /杏鲍菇|杏鮑菇/i, name: '杏鲍菇', group: 'inventory' },
  { re: /香菇|shiitake(?:\s+mushrooms?)?/i, name: '香菇', group: 'inventory' },
  { re: /平菇|oyster\s+mushrooms?/i, name: '平菇', group: 'inventory' },
  { re: /蟹味菇|shimeji|beech\s+mushrooms?/i, name: '蟹味菇', group: 'inventory' },
  { re: /白玉菇|white\s+beech\s+mushrooms?|white\s+shimeji/i, name: '白玉菇', group: 'inventory' },
  { re: /油豆腐|tofu\s+puffs?/i, name: '油豆腐', group: 'inventory' },
  { re: /鱼豆腐|魚豆腐|fish\s+tofu/i, name: '鱼豆腐', group: 'review' },
  { re: /\bgreens\b|\bvegetables?\b|leafy\s+veg|chinese\s+veg/i, name: '青菜', group: 'inventory', uncertain: true }
];

function normalizeChineseReceiptAliasText(text) {
  return String(text || '')
    .replace(/[餃貝魚雞豬萵筍蔥紅鹹貨乾餅]/g, ch => ({
      餃: '饺',
      貝: '贝',
      魚: '鱼',
      雞: '鸡',
      豬: '猪',
      萵: '莴',
      筍: '笋',
      蔥: '葱',
      紅: '红',
      鹹: '咸',
      貨: '货',
      乾: '干',
      餅: '饼'
    }[ch] || ch));
}

export function normalizeReceiptAliasKey(value) {
  let text = normalizeChineseReceiptAliasText(String(value || '').normalize('NFKC').toLowerCase());
  text = text.replace(/（.*?）|\(.*?\)/g, ' ');
  text = text.replace(/\$?\d+(?:\.\d+)?\s*(?:lb|lbs|pound|pounds|kg|公斤|千克|g|gram|grams|克|斤|两|oz|ct|pcs?|pack|pk|袋|盒|包|瓶|个|把|份)\b/gi, ' ');
  text = text.replace(/\$?\d+(?:\.\d+)?/g, ' ');
  text = text.replace(/\b(?:organic|fresh|raw|wild|premium|choice|natural|loose|bulk|sale|regular|reg|each|ea)\b/gi, ' ');
  text = text.replace(/[^\u3400-\u9fff\w]+/g, ' ');
  return text.replace(/\s+/g, ' ').trim();
}

function isUsefulAliasKey(key) {
  const compact = String(key || '').replace(/\s+/g, '');
  if (compact.length < 3 && !/[\u3400-\u9fff]{2,}/.test(compact)) return false;
  if (NON_PRODUCT_ALIAS_RE.test(key) || NON_PRODUCT_ALIAS_TEXT_RE.test(key)) return false;
  return true;
}

export function findBuiltInReceiptAlias(text) {
  const raw = String(text || '').trim();
  const key = normalizeReceiptAliasKey(raw);
  if (!key) return null;
  for (const alias of BUILT_IN_RECEIPT_ALIASES) {
    alias.re.lastIndex = 0;
    if (alias.re.test(raw) || alias.re.test(key)) {
      return {
        name: alias.name,
        group: alias.group || '',
        uncertain: alias.uncertain === true,
        source: 'built-in'
      };
    }
  }
  return null;
}

export function loadReceiptUserAliases() {
  try {
    const data = JSON.parse(localStorage.getItem(RECEIPT_ALIAS_STORAGE_KEY) || '{}');
    if (!data || typeof data !== 'object' || Array.isArray(data)) return {};
    return data;
  } catch (_) {
    return {};
  }
}

function saveReceiptUserAliases(map) {
  try {
    localStorage.setItem(RECEIPT_ALIAS_STORAGE_KEY, JSON.stringify(map || {}));
    return true;
  } catch (_) {
    return false;
  }
}

export function lookupReceiptUserAlias(rawName) {
  const key = normalizeReceiptAliasKey(rawName);
  if (!isUsefulAliasKey(key)) return null;
  const aliases = loadReceiptUserAliases();
  if (typeof aliases[key] === 'string' && aliases[key].trim()) {
    return { name: aliases[key].trim(), group: '', uncertain: false, source: 'user' };
  }
  for (const [storedKey, value] of Object.entries(aliases)) {
    if (!value || !isUsefulAliasKey(storedKey)) continue;
    if (key.length >= 4 && storedKey.length >= 4 && (key.includes(storedKey) || storedKey.includes(key))) {
      return { name: String(value).trim(), group: '', uncertain: false, source: 'user' };
    }
  }
  return null;
}

export function learnReceiptAliasCorrection(rawName, correctedName) {
  const key = normalizeReceiptAliasKey(rawName);
  const value = String(correctedName || '').trim();
  if (!isUsefulAliasKey(key) || !value) return false;
  if (normalizeReceiptAliasKey(value) === key) return false;
  const aliases = loadReceiptUserAliases();
  aliases[key] = value;
  const entries = Object.entries(aliases).filter(([, name]) => String(name || '').trim());
  const limited = Object.fromEntries(entries.slice(-MAX_USER_RECEIPT_ALIASES));
  return saveReceiptUserAliases(limited);
}
