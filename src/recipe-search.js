/*
 * src/recipe-search.js —— 本地优先的菜谱智能搜索 / 分类筛选（纯函数，无网络、无 AI）
 *
 * 设计要点：
 *  - 不改菜谱数据结构、不改 localStorage key；只读 pack（recipes / recipe_ingredients）+ recipe.seasonings(若有)。
 *  - 中文模糊：菜名 / 标签 / 食材 / 做法 多字段综合评分，按相关性排序。
 *  - 同义词扩展：肉蛋豆等「蛋白质大类」做分组扩展（搜「鸡」命中鸡腿/鸡胸/鸡丁…）；
 *    蔬菜/主食偏精确（搜「土豆」命中土豆丝/土豆片，而不是所有蔬菜）。
 *  - 防污染：调料（盐/油/鸡精…）只给极低权重；「鸡精」不会让搜「鸡」时高排名（调料单独分桶）。
 *  - 防混淆：搜「鸡」优先鸡肉，鸡蛋归「蛋类」低相关；搜「蛋」才优先鸡蛋。
 *
 * 同义词 / 分类表都集中在本文件顶部，便于后续维护。
 */
import { getCanonicalName, isSeasoning, explodeCombinedItems } from './ingredients.js?v=219';

// ── 蛋白质大类：用「分组匹配」做同义词扩展（可广义命中同类食材）──────────────
//   每组第一个元素为「单字锚点」（鸡/猪/牛/鱼/蛋），用于单字查询精确归类。
export const PROTEIN_GROUPS = {
  鸡肉: ['鸡', '鸡肉', '鸡腿', '鸡胸', '鸡脯', '鸡翅', '鸡丁', '鸡块', '鸡爪', '鸡胗', '鸡丝', '三黄鸡', '土鸡', '童子鸡', '乌鸡'],
  猪肉: ['猪', '猪肉', '五花肉', '五花', '里脊', '排骨', '肉末', '肉丝', '肉片', '肉糜', '猪蹄', '猪肝', '腊肉', '回锅肉', '梅菜肉'],
  牛肉: ['牛', '牛肉', '牛腩', '牛柳', '肥牛', '牛筋', '牛腱'],
  鱼虾: ['鱼', '虾', '鱼片', '鱼块', '鲫鱼', '鲈鱼', '草鱼', '黄鱼', '带鱼', '黑鱼', '虾仁', '基围虾', '蟹', '墨鱼', '鳝'],
  蛋类: ['蛋', '鸡蛋', '鸭蛋', '皮蛋', '咸蛋', '鹌鹑蛋', '松花蛋'],
  豆制品: ['豆腐', '豆干', '豆腐干', '香干', '白干', '卤干', '豆皮', '豆腐皮', '百叶', '油皮', '腐竹', '支竹', '千张', '素鸡', '豆花', '油豆腐', '冻豆腐', '内酯豆腐', '老豆腐', '嫩豆腐', '豆筋'],
};

// ── 口味 / 类型：标签 + 菜名上的弱扩展（搜「辣」命中麻辣/香辣/川味…）────────────
export const FLAVOR_GROUPS = {
  川味: ['川菜', '川味', '四川'],
  麻辣: ['麻辣', '麻', '辣', '香辣', '酸辣', '辣椒', '红油', '水煮', '麻婆'],
  清淡: ['清淡', '清炒', '白灼', '清蒸', '蒸菜', '汤羹'],
  快手: ['快手', '快炒', '小炒', '爆炒'],
  下饭: ['下饭', '红烧', '回锅', '鱼香', '糖醋'],
  汤羹: ['汤', '羹', '汤羹', '炖', '煲'],
};

// 蔬菜 / 主食：偏精确的关键词（用于分类筛选 + 蔬菜类归类）
const VEG_KEYWORDS = ['青菜', '白菜', '土豆', '马铃薯', '番茄', '西红柿', '茄子', '丝瓜', '黄瓜', '生菜', '菠菜', '芹菜', '萝卜', '胡萝卜', '青椒', '蒜苗', '韭菜', '空心菜', '花菜', '西兰花', '菜花', '豆角', '南瓜', '冬瓜', '莴笋', '笋', '木耳', '蘑菇', '香菇', '金针菇', '菌', '茼蒿', '油菜', '包菜', '卷心菜', '娃娃菜', '苦瓜', '豆芽', '莲藕', '藕'];
const STAPLE_KEYWORDS = ['米饭', '米线', '面条', '面粉', '馒头', '饺子', '年糕', '米粉', '河粉', '馄饨', '包子', '饼', '挂面', '粉丝', '粉条'];

// 分类 chips 定义（基础 / 食材 / 口味三组）。defaultVisible = 顶部常用优先展示。
export const RECIPE_CATEGORIES = [
  { key: '全部', label: '全部', kind: 'basic', defaultVisible: true },
  { key: '能做', label: '能做', kind: 'basic', defaultVisible: true },
  { key: '只差一点', label: '只差一点', kind: 'basic', defaultVisible: true },
  { key: '收藏', label: '收藏', kind: 'basic', defaultVisible: true },
  { key: '最近做过', label: '最近做过', kind: 'basic', defaultVisible: false },
  { key: '鸡肉', label: '鸡肉', kind: 'food', defaultVisible: true },
  { key: '猪肉', label: '猪肉', kind: 'food', defaultVisible: true },
  { key: '牛肉', label: '牛肉', kind: 'food', defaultVisible: false },
  { key: '鱼虾', label: '鱼虾', kind: 'food', defaultVisible: false },
  { key: '蛋类', label: '蛋类', kind: 'food', defaultVisible: false },
  { key: '豆制品', label: '豆制品', kind: 'food', defaultVisible: false },
  { key: '蔬菜', label: '蔬菜', kind: 'food', defaultVisible: true },
  { key: '主食', label: '主食', kind: 'food', defaultVisible: false },
  { key: '川味', label: '川味', kind: 'flavor', defaultVisible: false },
  { key: '麻辣', label: '麻辣', kind: 'flavor', defaultVisible: true },
  { key: '清淡', label: '清淡', kind: 'flavor', defaultVisible: false },
  { key: '快手', label: '快手', kind: 'flavor', defaultVisible: true },
  { key: '下饭', label: '下饭', kind: 'flavor', defaultVisible: false },
  { key: '汤羹', label: '汤羹', kind: 'flavor', defaultVisible: false },
];

// ── 文本归一化：小写 + 去空白 + 去常见标点（保留中文）──────────────────────────
export function normalizeText(text) {
  return String(text == null ? '' : text)
    .toLowerCase()
    .replace(/\s+/g, '')
    .replace(/[，。、！？；：·…“”‘’（）()【】\[\]{}<>《》!"#$%&'*+,\-./:;=?@^_`|~]/g, '');
}

// ──────────────────────────────────────────────────────────────────────────
// 细粒度归一化词典（canonical → 别名）。与 ingredients.js 的 INGREDIENT_ALIASES 互补：
// 专供「搜索 / 分类」的同义归一，绝不改菜谱 JSON / 库存数据结构 / localStorage key。
// 维护方式：每组键为 canonical 展示名，值数组为别名；要加同义词只需往数组里追加。
// 注意：ingredients.js 已覆盖大量食材（西红柿→番茄、老豆腐→豆腐、干香菇→香菇…），
//       这里只补它没有的酱料 / 调味 / 豆制品细分等。
// ──────────────────────────────────────────────────────────────────────────
export const SEARCH_SYNONYMS = {
  // —— 酱料 / 酱油 / 醋 / 酒 ——
  '豆瓣酱': ['豆瓣酱', '豆瓣', '郫县豆瓣', '郫县豆瓣酱', '红油豆瓣酱', '辣豆瓣酱', '细豆瓣'],
  '黄豆酱': ['黄豆酱', '豆酱', '大豆酱', '黄酱'],
  '甜面酱': ['甜面酱', '面酱', '甜酱'],
  '生抽': ['生抽', '酱油', '鲜酱油', '味极鲜', '红酱油'],
  '老抽': ['老抽', '红烧酱油'],
  '料酒': ['料酒', '黄酒', '绍酒', '绍兴酒', '花雕', '花雕酒', '米酒'],
  '醋': ['醋', '香醋', '陈醋', '米醋', '白醋', '保宁醋', '镇江香醋'],
  '蚝油': ['蚝油', '耗油'],
  '香油': ['香油', '芝麻油', '麻油', '芝麻香油', '小磨香油'],
  // —— 辣味调料 / 花椒 ——
  '花椒': ['花椒', '红花椒', '青花椒', '藤椒', '麻椒', '花椒粒', '花椒面', '花椒粉'],
  '干辣椒': ['干辣椒', '干海椒', '干红辣椒', '辣椒节', '辣椒面', '辣椒粉', '糊辣椒'],
  '辣椒': ['辣椒', '小米辣', '二荆条', '线椒', '朝天椒', '红椒'],
  '泡椒': ['泡椒', '泡辣椒', '泡海椒', '野山椒', '鱼辣椒'],
  '剁椒': ['剁椒', '剁辣椒'],
  // —— 葱姜蒜（与库存口径一致，便于查询侧归一）——
  '葱': ['葱', '小葱', '大葱', '香葱', '青葱', '葱白', '葱花', '葱段', '葱节', '葱米'],
  '姜': ['姜', '生姜', '老姜', '子姜', '嫩姜', '仔姜', '姜片', '姜末', '姜丝', '姜米'],
  '蒜': ['蒜', '大蒜', '蒜末', '蒜蓉', '蒜泥', '蒜瓣', '蒜片', '蒜米', '独蒜', '蒜头'],
  // —— 豆制品细分（ingredients.js 已含豆腐组，这里补豆干 / 豆皮 / 腐竹 / 内酯豆腐）——
  '豆干': ['豆干', '豆腐干', '香干', '白干', '五香豆干', '卤干'],
  '豆皮': ['豆皮', '豆腐皮', '千张', '百叶', '油皮', '素鸡'],
  '腐竹': ['腐竹', '支竹', '豆筋'],
  '豆腐': ['豆腐', '内酯豆腐', '日本豆腐', '玉子豆腐', '老豆腐', '嫩豆腐', '北豆腐', '南豆腐', '石膏豆腐', '盒装豆腐', '冻豆腐'],
};

// 扁平别名 → canonical 反查表（按 normalizeText 归一后的 key）。
const SEARCH_ALIAS_TO_CANON = new Map();
for (const [canon, aliases] of Object.entries(SEARCH_SYNONYMS)) {
  SEARCH_ALIAS_TO_CANON.set(normalizeText(canon), canon);
  for (const a of aliases) SEARCH_ALIAS_TO_CANON.set(normalizeText(a), canon);
}

// 「明确搜调料」判定用：这些 canonical 视为调料（叠加 isSeasoning 的判断）。
const SEASONING_CANON_SET = new Set(
  ['豆瓣酱', '黄豆酱', '甜面酱', '生抽', '老抽', '料酒', '醋', '蚝油', '香油', '花椒', '干辣椒', '辣椒', '泡椒', '剁椒', '葱', '姜', '蒜'].map(normalizeText)
);
// 辣味调料：用于「辣」类口味查询的弱关联（豆瓣酱 / 干辣椒 / 花椒…）。
const SPICY_SEASONING_CANON_SET = new Set(
  ['豆瓣酱', '干辣椒', '辣椒', '泡椒', '剁椒', '花椒'].map(normalizeText)
);
const SPICY_FLAVOR_TERMS = ['辣', '麻辣', '香辣', '酸辣', '红油', '水煮', '麻婆'];

/**
 * 食材 / 调料归一化：先复用库存 getCanonicalName，再套搜索同义词典。
 * 例：郫县豆瓣酱→豆瓣酱、西红柿→番茄、马铃薯→土豆、香干→豆干、内酯豆腐→豆腐。
 * @returns {string} canonical 展示名（找不到则回退库存 canonical / 原名）。
 */
export function normalizeIngredientName(name) {
  const raw = String(name == null ? '' : name).trim();
  if (!raw) return '';
  const canon0 = getCanonicalName(raw); // 复用库存归一（西红柿→番茄、老豆腐→豆腐…）
  const k1 = normalizeText(canon0);
  if (SEARCH_ALIAS_TO_CANON.has(k1)) return SEARCH_ALIAS_TO_CANON.get(k1);
  const k0 = normalizeText(raw);
  if (SEARCH_ALIAS_TO_CANON.has(k0)) return SEARCH_ALIAS_TO_CANON.get(k0);
  return canon0 || raw;
}

/**
 * 取一个食材名的「归类键」：蛋白大类优先（鸡腿→鸡肉），否则用 canonical（番茄 / 豆瓣酱）。
 */
export function getIngredientCanonicalGroup(name) {
  const canon = normalizeIngredientName(name);
  const pg = classifyProteinGroup(normalizeText(canon)) || classifyProteinGroup(normalizeText(name));
  return pg || canon;
}

/**
 * 判断两个食材 / 调料是否相关：同 canonical（强）或同蛋白大类（中）。
 * 例：郫县豆瓣酱≈豆瓣酱(强)、香干≈豆干(强)、豆腐↔豆干(同豆制品大类，中)。
 * 反例：黄豆酱 与 豆瓣酱 canonical 不同、也不同大类 → 不相关。
 */
export function areIngredientsRelated(a, b) {
  if (!a || !b) return false;
  const ca = normalizeText(normalizeIngredientName(a));
  const cb = normalizeText(normalizeIngredientName(b));
  if (ca && ca === cb) return true;
  const ga = classifyProteinGroup(ca);
  const gb = classifyProteinGroup(cb);
  if (ga && gb && ga === gb) return true;
  return false;
}

/**
 * 把查询词扩展成一组归一后的可匹配 term（canonical + 同义别名 + 蛋白大类 + 口味）。
 */
export function getCanonicalSearchTerms(term) {
  const q = normalizeText(term);
  const out = new Set();
  if (!q) return [];
  out.add(q);
  const canon = normalizeIngredientName(term);
  const canonNorm = normalizeText(canon);
  if (canonNorm) out.add(canonNorm);
  if (SEARCH_SYNONYMS[canon]) SEARCH_SYNONYMS[canon].forEach(a => out.add(normalizeText(a)));
  const pg = q.length <= 2 ? queryProteinGroup(q) : null;
  if (pg) PROTEIN_GROUPS[pg].forEach(t => out.add(normalizeText(t)));
  if (q.length <= 3) queryFlavorTerms(q).forEach(t => out.add(normalizeText(t)));
  return Array.from(out);
}

// 把一道菜的可搜索字段拆出来：菜名 / 标签 / 核心食材 / 调料 / 做法（食材与调料分桶）。
export function getRecipeSearchFields(recipe, pack) {
  const map = (pack && pack.recipe_ingredients) || {};
  const rawList = explodeCombinedItems(map[(recipe && recipe.id)] || []);
  const foods = [];
  const seasonings = [];
  for (const it of rawList) {
    const nm = getCanonicalName((it && (it.item || it.name)) || '');
    if (!nm) continue;
    if (isSeasoning(nm)) seasonings.push(nm); else foods.push(nm);
  }
  // overlay / AI 草稿可能带 recipe.seasonings（独立调料表）→ 全部进调料桶（低权重）。
  for (const s of (recipe && recipe.seasonings) || []) {
    const nm = getCanonicalName((s && (s.item || s.name)) || (typeof s === 'string' ? s : ''));
    if (nm) seasonings.push(nm);
  }
  const tags = Array.isArray(recipe && recipe.tags) ? recipe.tags.slice() : [];
  const method = String((recipe && (recipe.method || recipe.staticMethod)) || '');
  return {
    name: (recipe && recipe.name) || '',
    nameNorm: normalizeText(recipe && recipe.name),
    tags,
    foods,
    seasonings,
    method,
    methodNorm: normalizeText(method),
  };
}

// 把「食材名」归类到蛋白质大类（取最长命中关键词，使「鸡蛋」→蛋类 而非 鸡肉）。
function classifyProteinGroup(name) {
  let best = null;
  let bestLen = 0;
  for (const group in PROTEIN_GROUPS) {
    for (const kw of PROTEIN_GROUPS[group]) {
      if (name.includes(kw) && kw.length > bestLen) { best = group; bestLen = kw.length; }
    }
  }
  return best;
}

// 把「查询词」归类到蛋白质大类：
//   优先级 3 = 完全等于关键词（鸡→鸡肉、蛋→蛋类）；
//   优先级 2 = 查询包含某个 ≥2 字关键词（三黄鸡→鸡肉）；
//   优先级 1 = 查询是某 ≥2 字关键词的片段，仅当查询≥2 字（避免「肉」被锁进单一组）。
function queryProteinGroup(q) {
  let best = null;
  let bestPri = 0;
  let bestLen = 0;
  for (const group in PROTEIN_GROUPS) {
    for (const kw of PROTEIN_GROUPS[group]) {
      let pri = 0;
      if (q === kw) pri = 3;
      else if (kw.length >= 2 && q.includes(kw)) pri = 2;
      else if (kw.length >= 2 && q.length >= 2 && kw.includes(q)) pri = 1;
      if (pri > bestPri || (pri === bestPri && pri > 0 && kw.length > bestLen)) {
        best = group; bestPri = pri; bestLen = kw.length;
      }
    }
  }
  return best;
}

// 查询词 → 口味扩展词（搜「辣」→麻辣组关键词）。
//   只在「查询完全等于某口味关键词」时扩展，避免「回锅肉」因含「回锅」误触发整组下饭菜。
function queryFlavorTerms(q) {
  const out = new Set();
  for (const group in FLAVOR_GROUPS) {
    if (FLAVOR_GROUPS[group].includes(q)) FLAVOR_GROUPS[group].forEach(k => out.add(k));
  }
  return Array.from(out);
}

// 对外暴露：把查询词扩展成 { 主类 / canonical / 口味词 / 全部扩展词 }，便于调试与后续维护。
export function expandQuery(query) {
  const q = normalizeText(query);
  const proteinGroup = q && q.length <= 2 ? queryProteinGroup(q) : null;
  const flavorTerms = q && q.length <= 3 ? queryFlavorTerms(q) : [];
  const canonical = q ? normalizeIngredientName(query) : '';
  // terms 直接复用 getCanonicalSearchTerms：canonical + 同义别名 + 蛋白大类 + 口味。
  const terms = q ? getCanonicalSearchTerms(query) : [];
  return { query: q, canonical, proteinGroup, flavorTerms, terms };
}

// 简单字符级模糊：查询几乎所有字符都出现在文本里才给一点点分（仅用于菜名兜底）。
//   阈值取 0.8（而非 0.6）：避免「回锅肉」这种含常见字（肉/锅）的查询把一堆菜按 2/3 命中拖进来。
function fuzzyRatio(text, q) {
  if (!q || q.length < 2) return 0;
  const chars = Array.from(new Set(q.split('')));
  let hit = 0;
  for (const ch of chars) if (text.includes(ch)) hit++;
  const ratio = hit / chars.length;
  return ratio >= 0.8 ? ratio : 0;
}

// 相关性权重（数值越大越靠前）。对应需求里的排序优先级。
const W = {
  nameExact: 1000,     // 菜名完全匹配
  nameIncludes: 240,   // 菜名包含
  fuzzyName: 60,       // 菜名字符模糊（× ratio）
  ingredientCanon: 150,  // 主食材 canonical / 别名精确（郫县豆瓣酱≈豆瓣酱、西红柿≈番茄）
  ingredientDirect: 120, // 主食材精确（食材名直接包含查询词）
  ingredientGroup: 90,   // 主食材同蛋白大类（鸡→鸡腿 / 豆腐↔豆干）
  tag: 100,            // 标签匹配
  flavorText: 50,      // 口味词命中菜名/做法
  method: 40,          // 做法文本命中
  flavorSeasoning: 28, // 辣味查询命中辣味调料（豆瓣酱/干辣椒…，低）
  seasoningCanon: 70,  // 明确搜调料时 canonical 命中（中低）
  seasoning: 10,       // 调料弱命中（很低，仅明确搜调料时计入）
  // 业务加成（仅在已有相关性得分时叠加，避免污染）
  boostStock: 25,      // 库存能做
  boostAlmost: 12,     // 只差一点
  boostFavorite: 18,   // 收藏
  boostRecent: 8,      // 最近做过
};

/**
 * 对单道菜按查询词打分（纯函数）。
 * @returns {{ score:number, reasons:string[] }}
 */
export function scoreRecipe(recipe, query, pack, context = {}) {
  const q = normalizeText(query);
  if (!q) return { score: 0, reasons: [] };
  const fields = context._fields || getRecipeSearchFields(recipe, pack);
  // 同义词扩展只对「类别级」短查询生效：
  //   蛋白质大类扩展仅当查询 ≤2 字（鸡/牛肉/鸡丁…），口味扩展仅当 ≤3 字（辣/麻辣/香辣…）。
  //   否则像「宫保鸡丁」这种完整菜名会被当成「鸡丁→整个鸡肉类」扩散出几十道无关菜。
  const qGroup = q.length <= 2 ? queryProteinGroup(q) : null;
  const flavorTerms = q.length <= 3 ? queryFlavorTerms(q) : [];
  const reasons = [];
  let score = 0;

  // 查询归一化：得到 canonical（郫县豆瓣→豆瓣酱、西红柿→番茄、香干→豆干…）。
  const qCanon = normalizeIngredientName(query);
  const qCanonNorm = normalizeText(qCanon);
  // 是否「明确在搜调料」（决定是否给调料命中正常权重，避免非调料查询被调料污染）。
  const qIsSeasoning = isSeasoning(qCanon) || SEASONING_CANON_SET.has(qCanonNorm);
  // 单字蛋白锚点（鱼/鸡/蛋/牛/猪/虾）：菜名「假朋友」防护用。
  const isSingleProteinAnchor = q.length === 1 && !!qGroup;
  const hasGroupIngredient = qGroup
    ? fields.foods.some(f => classifyProteinGroup(normalizeText(normalizeIngredientName(f))) === qGroup)
    : false;

  // ① 菜名
  if (fields.nameNorm && fields.nameNorm === q) score += W.nameExact;
  else if (fields.nameNorm && fields.nameNorm.includes(q)) {
    // 假朋友防护：单字蛋白查询（鱼/鸡）命中菜名但食材里没有该类（鱼香肉丝 / 鸡蛋羹）→ 不给菜名强分。
    if (!(isSingleProteinAnchor && !hasGroupIngredient)) score += W.nameIncludes;
  }
  else { const fz = fuzzyRatio(fields.nameNorm, q); if (fz) score += Math.round(fz * W.fuzzyName); }

  // ② 标签（直接包含，或命中口味扩展词）
  let tagHit = null;
  for (const t of fields.tags) {
    const tn = normalizeText(t);
    if (!tn) continue;
    if (tn.includes(q) || q.includes(tn) || flavorTerms.some(ft => tn.includes(ft))) { tagHit = t; break; }
  }
  if (tagHit) { score += W.tag; reasons.push(`匹配标签：${tagHit}`); }

  // ③ 核心食材：canonical / 别名精确 > 直接包含 > 同蛋白大类。鸡 vs 鸡蛋 跨组抑制。
  let bestIngScore = 0;
  let bestIngName = '';
  let bestIngKind = '';
  for (const f of fields.foods) {
    const fn = normalizeText(f);
    const fCanonNorm = normalizeText(normalizeIngredientName(f));
    const ingGroup = classifyProteinGroup(fCanonNorm || fn);
    let s = 0;
    let kind = '';
    if (fCanonNorm && fCanonNorm === qCanonNorm) { s = W.ingredientCanon; kind = 'canon'; }
    else if (fn.includes(q)) {
      // 查询与食材分属不同蛋白质大类（查「鸡」遇到「鸡蛋」）→ 视为巧合包含，抑制。
      if (qGroup && ingGroup && qGroup !== ingGroup) s = 0;
      else { s = W.ingredientDirect; kind = 'direct'; }
    }
    if (s === 0 && qGroup && ingGroup && qGroup === ingGroup) { s = W.ingredientGroup; kind = 'group'; }
    if (s > bestIngScore) { bestIngScore = s; bestIngName = f; bestIngKind = kind; }
  }
  if (bestIngScore > 0) {
    score += bestIngScore;
    const recipeDiffers = normalizeText(bestIngName) !== qCanonNorm;
    const queryDiffers = q !== qCanonNorm;
    if (bestIngKind === 'canon' && recipeDiffers) reasons.push(`匹配别名：${bestIngName} ≈ ${qCanon}`);
    else if (bestIngKind === 'canon' && queryDiffers) reasons.push(`匹配别名：${query} ≈ ${qCanon}`);
    else reasons.push(`匹配食材：${bestIngName}`);
  }

  // ④ 做法文本 / 口味词
  //   做法文本匹配仅对 ≥2 字查询生效：单字（鸡/蛋/肉…）在做法里太常见（如做法提到「加鸡蛋」），
  //   否则会把一堆无关菜以低分拖进结果。单字查询靠菜名/标签/食材这些强信号即可。
  if (q.length >= 2 && fields.methodNorm && fields.methodNorm.includes(q)) score += W.method;
  if (flavorTerms.length) {
    const flavorInText = flavorTerms.some(ft => fields.nameNorm.includes(ft) || fields.methodNorm.includes(ft));
    if (flavorInText) { score += W.flavorText; if (!tagHit) reasons.push('匹配口味'); }
    // 「辣」类口味查询额外弱命中辣味调料（豆瓣酱 / 干辣椒 / 泡椒 / 花椒…）。
    const isSpicyQuery = flavorTerms.some(ft => SPICY_FLAVOR_TERMS.includes(ft));
    if (isSpicyQuery) {
      const hasSpicySeasoning = fields.seasonings.some(s => SPICY_SEASONING_CANON_SET.has(normalizeText(normalizeIngredientName(s))));
      if (hasSpicySeasoning) { score += W.flavorSeasoning; if (!reasons.some(r => r.includes('口味'))) reasons.push('匹配口味：辣'); }
    }
  }

  // ⑤ 调料：仅在「用户明确搜调料」时计入中低权重（canonical 精确 > 包含），
  //    防止搜「鸡」时被「鸡精」、搜普通食材时被各种调料污染。
  if (qIsSeasoning) {
    let bestSeas = 0;
    let bestSeasName = '';
    for (const s of fields.seasonings) {
      const sCanonNorm = normalizeText(normalizeIngredientName(s));
      if (sCanonNorm && sCanonNorm === qCanonNorm) { bestSeas = W.seasoningCanon; bestSeasName = s; break; }
      if (!bestSeas && normalizeText(s).includes(q)) { bestSeas = W.seasoning; bestSeasName = s; }
    }
    if (bestSeas > 0) { score += bestSeas; reasons.push(`匹配调料：${bestSeasName}`); }
  }

  // ⑥ 业务加成（只在已有相关性时叠加，不让加成压过搜索相关性）
  if (score > 0) {
    const id = recipe && recipe.id;
    if (context.stockableIds && context.stockableIds.has(id)) score += W.boostStock;
    if (context.almostIds && context.almostIds.has(id)) score += W.boostAlmost;
    if (context.favoriteIds && context.favoriteIds.has(id)) score += W.boostFavorite;
    if (context.recentIds && context.recentIds.has(id)) score += W.boostRecent;
  }

  return { score, reasons };
}

/**
 * 在给定菜谱集合里按查询词搜索并排序（纯函数）。
 * @returns {Array<{ recipe, score, reasons:string[] }>}
 */
export function searchRecipes(recipes, query, pack, options = {}) {
  const q = normalizeText(query);
  const context = options.context || {};
  const out = [];
  for (const r of recipes || []) {
    const fields = getRecipeSearchFields(r, pack);
    const res = scoreRecipe(r, q, pack, { ...context, _fields: fields });
    if (res.score > 0) out.push({ recipe: r, score: res.score, reasons: res.reasons });
  }
  out.sort((a, b) => (b.score - a.score) || String(a.recipe.name || '').localeCompare(String(b.recipe.name || ''), 'zh-Hans-CN'));
  return out;
}

/**
 * 分类筛选：判断一道菜是否属于某分类（与搜索可叠加，由调用方先过滤再搜索）。
 * 基础类（能做/只差一点/收藏/最近做过）依赖 context 里预先算好的 id 集合。
 */
export function matchesCategory(recipe, catKey, pack, context = {}) {
  if (!catKey || catKey === '全部') return true;
  const id = recipe && recipe.id;

  if (catKey === '能做') return !!(context.stockableIds && context.stockableIds.has(id));
  if (catKey === '只差一点') return !!(context.almostIds && context.almostIds.has(id));
  if (catKey === '收藏') return !!(context.favoriteIds && context.favoriteIds.has(id));
  if (catKey === '最近做过') return !!(context.recentIds && context.recentIds.has(id));

  const fields = getRecipeSearchFields(recipe, pack);

  // 蛋白质食材类：标签命中（含单字锚点）或核心食材归入该组。
  if (PROTEIN_GROUPS[catKey]) {
    const anchor = PROTEIN_GROUPS[catKey][0];
    const tagHit = fields.tags.some(t => {
      const tn = normalizeText(t);
      if (catKey === '鱼虾') return /鱼虾|海鲜|虾/.test(tn); // 避免「鱼香」误入鱼虾
      return tn.includes(catKey) || tn.includes(anchor);
    });
    if (tagHit) return true;
    return fields.foods.some(f => classifyProteinGroup(normalizeText(f)) === catKey);
  }

  if (catKey === '蔬菜') {
    if (fields.tags.some(t => /素菜|蔬菜/.test(t))) return true;
    return fields.foods.some(f => { const fn = normalizeText(f); return VEG_KEYWORDS.some(k => fn.includes(k)); });
  }

  if (catKey === '主食') {
    if (fields.tags.some(t => /主食|面食/.test(t))) return true;
    return fields.foods.some(f => { const fn = normalizeText(f); return STAPLE_KEYWORDS.some(k => fn.includes(k)); });
  }

  if (FLAVOR_GROUPS[catKey]) {
    const terms = FLAVOR_GROUPS[catKey];
    if (fields.tags.some(t => { const tn = normalizeText(t); return terms.some(term => tn.includes(term)); })) return true;
    return terms.some(term => fields.nameNorm.includes(term));
  }

  return true;
}
