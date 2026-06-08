#!/usr/bin/env node
/**
 * audit-missing-methods.js
 *
 * 扫描菜谱库中「缺少做法」的菜，并生成：
 *   1. data/missing-methods-report.json   —— 机器可读缺失报告
 *   2. data/missing-methods-report.md     —— 人类可读缺失报告
 *   3. data/recipe-method-candidates.json —— 自动生成的家庭版做法候选（全部 needsReview:true）
 *
 * 重要约束（与任务规则一致）：
 *   - 候选做法【完全基于现有菜名 / 食材 / 标签 + 川菜通用技法模板】算法生成，
 *     不读取、不复制任何 PDF / 书中原文；PDF 仅作人工参考目录，不进仓库。
 *   - 只产出候选与报告，绝不直接改原始菜谱 JSON、不改 completion-overlay、不碰 localStorage。
 *   - 所有候选 needsReview:true / approved:false，需人工审核后由 apply-reviewed-methods.js 合并。
 *
 * 用法：
 *   node scripts/audit-missing-methods.js                # 扫描精简库（默认）
 *   node scripts/audit-missing-methods.js --lib=full     # 扫描完整库
 *
 * 重跑安全：已存在 candidates 中 approved:true 的条目会被保留，不会被覆盖。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');

const args = process.argv.slice(2);
const libArg = (args.find(a => a.startsWith('--lib=')) || '--lib=curated').split('=')[1];
const LIB_FILE = libArg === 'full' ? 'sichuan-recipes.json' : 'sichuan-recipes.curated.json';

function readJSON(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }
function readJSONSafe(p, fallback) { try { return readJSON(p); } catch (_) { return fallback; } }

// data/recipe-methods.js / hoc-recipes.js 是浏览器全局赋值脚本（window.X = ...），用 vm 安全求值取出。
function loadWindowGlobal(file, key) {
  try {
    const sandbox = { window: {} };
    vm.runInNewContext(fs.readFileSync(path.join(DATA, file), 'utf8'), sandbox);
    return sandbox.window[key];
  } catch (e) {
    console.warn(`[audit] 加载 ${file} 失败，已跳过该来源：`, e.message);
    return undefined;
  }
}

// ── 加载所有「做法来源」 ───────────────────────────────────────────────────────
const base = readJSON(path.join(DATA, LIB_FILE));
const overlay = readJSONSafe(path.join(DATA, 'recipe-completion-overlay.json'), {});
const RECIPE_METHODS = loadWindowGlobal('recipe-methods.js', 'RECIPE_METHODS') || {};
const HOC_DATA = loadWindowGlobal('hoc-recipes.js', 'HOC_DATA') || [];

const ovById = overlay.recipes || {};
const ovNameMethods = new Set((overlay.newRecipes || []).filter(r => r && r.method).map(r => String(r.name || '').trim()));
const hocNameMethods = new Set((HOC_DATA || []).filter(x => x && x.method).map(x => String(x.name || '').trim()));

// 一道菜是否在「任一来源」已有做法（避免给运行时已有做法的菜生成候选）。
function hasMethod(r) {
  if (r.method && String(r.method).trim()) return true;
  if (r.staticMethod && String(r.staticMethod).trim()) return true;
  if (ovById[r.id] && ovById[r.id].method) return true;
  const nm = String(r.name || '').trim();
  if (RECIPE_METHODS[nm]) return true;
  if (ovNameMethods.has(nm)) return true;
  if (hocNameMethods.has(nm)) return true;
  return false;
}

// ── 食材工具 ──────────────────────────────────────────────────────────────────
const SEASONINGS = new Set([
  '盐', '糖', '醋', '酱油', '生抽', '老抽', '红酱油', '味精', '鸡精', '料酒', '米酒', '黄酒', '绍酒',
  '花椒', '干辣椒', '辣椒', '辣椒面', '泡椒', '剁椒', '胡椒', '胡椒面', '油', '猪油', '菜油', '色拉油',
  '香油', '芝麻油', '豆粉', '淀粉', '水豆粉', '生粉', '豆瓣', '豆瓣酱', '郫县豆瓣', '甜面酱', '豆豉',
  '酸菜', '酸豆角', '清汤', '高汤', '鲜汤', '水', '八角', '桂皮', '香叶', '五香粉', '孜然', '茴香',
  '姜', '葱', '蒜', '大蒜', '生姜', '老姜', '子姜', '蒜泥', '蒜末', '葱花', '葱白', '葱段', '姜米',
  '姜末', '花椒面', '糖色', '冰糖', '蚝油', '醪糟', '红油', '味极鲜'
]);
function isSeasoningName(n) {
  const s = String(n || '').trim();
  if (SEASONINGS.has(s)) return true;
  if (s.length <= 3 && (s.includes('盐') || s.includes('糖') || s.includes('醋') || s.includes('酱') || s.includes('油'))) return true;
  return false;
}

function ingredientNames(id) {
  const list = (base.recipe_ingredients || {})[id] || [];
  const names = [];
  for (const it of list) {
    const raw = String((it && it.item) || '').trim();
    if (!raw) continue;
    for (const part of raw.split(/[，,、/;；]+/).map(s => s.trim()).filter(Boolean)) names.push(part);
  }
  return names;
}

// 食材列表是否「太粗 / 缺失」（与 recipe-completion.js 的 isCoarseOrEmpty 判定一致）。
function ingredientsCoarse(id) {
  const list = (base.recipe_ingredients || {})[id] || [];
  if (!Array.isArray(list) || list.length === 0) return true;
  if (list.length === 1) return true;
  return false;
}

// ── 菜型识别 + 家庭版做法模板（短句、可执行、非书中原文） ──────────────────────
// 设计：识别尽量按「菜名关键词 + 标签 + 食材」综合判断；模板按菜型差异化，
//       且不对非肉菜使用「肉类上浆」等泛化词（仅在确有肉类时才出现码味步骤）。
const MEAT_RE = /(肉|鸡|鸭|鹅|牛|羊|猪|兔|排骨|五花|里脊|肥肠|鳝|蹄|肝|腰)/;
function hasMeat(foods) { return foods.some(f => MEAT_RE.test(f)); }
function foodsText(foods) { return foods.length ? foods.slice(0, 3).join('、') : '主料'; }
function mainText(foods) { return foods.length ? foods[0] : '主料'; }
function othersText(foods, excludeRe) {
  const rest = foods.filter(f => !excludeRe.test(f));
  return rest.length ? rest.slice(0, 3).join('、') : '配料';
}

// 是否「鱼类菜」：按菜名鱼字判断，但排除「鱼香」味型（鱼香茄饼等并无鱼）。
function isFishDish(name) {
  const n = String(name || '');
  if (/鱼香/.test(n)) return false;
  return /(鲫|鲢|鳝|草鱼|鲈鱼|带鱼|黑鱼|鱼头|鱼)/.test(n);
}

function detectType(name, tags, foods) {
  const n = String(name || '');
  const tg = Array.isArray(tags) ? tags.join(' ') : '';
  const t = n + ' ' + tg;
  const foodHas = (re) => foods.some(f => re.test(f));

  // ① 甜品 / 甜羹（不用炒菜模板）
  if (/甜食|甜品/.test(tg) || /银耳|雪耳|冰糖.*(银耳|雪耳|莲|百合)/.test(n)) {
    if (/圆子|汤圆|糍|糕|团|羹.*(糯|米)|醪糟/.test(n)) return 'sweetball';
    return 'sweetsoup';
  }
  if (/圆子|汤圆/.test(n) || (/糯米/.test(n) && !MEAT_RE.test(n))) return 'sweetball';
  // ② 蛋（烘/摊蛋）
  if (/烘蛋|摊蛋|蛋饺|蛋卷|蛋羹/.test(n)) return 'eggbake';
  // ③ 虾仁快炒（优先于鱼类，避免「鱼虾类」误判）
  if (/虾仁|虾球|虾/.test(n) || foodHas(/虾/)) return 'shrimp';
  // ④ 宫保 / 煳辣（…丁）
  if (/宫保|煳辣|糊辣/.test(n)) return 'kungpao';
  // ⑤ 干煸
  if (/干煸|干㸆/.test(n)) return 'dryfry';
  // ⑥ 辣子 / 陈皮（炸后辣炒、干香）
  if (/辣子|陈皮/.test(n)) return 'chilifry';
  // ⑦ 鱼香味型（非鱼）：茄饼 / 茄子 / 肉丝等
  if (/鱼香/.test(n)) return 'yuxiang';
  // ⑧ 鱼类按做法细分
  if (isFishDish(n)) {
    if (/清蒸|蒸/.test(n)) return 'fishSteam';
    if (/糖醋|脆皮/.test(n)) return 'fishSweetSour';
    if (/泡菜/.test(n)) return 'fishPickle';
    if (/豆腐/.test(n) || foodHas(/豆腐/)) return 'fishTofu';
    return 'fishBraise'; // 干烧 / 黄焖 / 葱酥 等默认烧鱼
  }
  // ⑨ 豆腐菜（非鱼）
  if (/豆腐/.test(n) || foodHas(/豆腐/)) return 'tofu';
  // ⑩ 其它常见菜型
  if (/干锅/.test(n)) return 'drypot';
  if (/水煮/.test(n)) return 'boil';
  if (/凉拌|拌|白肉|口水|椒麻|怪味|蒜泥|夫妻肺片/.test(t)) return 'cold';
  if (/粉蒸|清蒸|旱蒸|蒸/.test(n)) return 'steam';
  if (/汤|羹|煲|清炖|炖汤/.test(n)) return 'soup';
  if (/红烧|家常烧|干烧|黄焖|焖|魔芋烧|烧/.test(n)) return 'braise';
  return 'stirfry';
}

const TEMPLATES = {
  // 甜羹（银耳等）
  sweetsoup: (f) => [
    `${mainText(f)}提前用清水泡发，去蒂撕成小朵。`,
    `锅中加足量清水，下${mainText(f)}大火烧开转小火。`,
    `加入冰糖，慢炖至汤汁浓稠、${mainText(f)}软糯出胶。`,
    `可加红枣、枸杞同炖，晾温后食用。`
  ],
  // 甜点圆子（糯米圆子等）
  sweetball: (f) => [
    `糯米提前浸泡，沥干（或磨浆和成糯米团）。`,
    `搓成大小均匀的圆子，可包入豆沙或白糖馅。`,
    `下沸水煮至圆子浮起、熟透软糯（或上笼蒸熟）。`,
    `捞出按口味裹糖、淋醪糟或撒桂花即可。`
  ],
  // 烘蛋
  eggbake: (f) => [
    `${othersText(f, /蛋/)}洗净切碎备用。`,
    `鸡蛋打散，加入切碎配料和盐调匀成蛋液。`,
    `平底锅下油烧热，倒入蛋液铺匀摊开。`,
    `中小火加盖烘至底面金黄，翻面烘熟。`,
    `取出切块装盘。`
  ],
  // 虾仁快炒（按是否有配料 / 番茄分支，避免无关括注）
  shrimp: (f) => {
    const others = f.filter(x => !/虾/.test(x));
    const hasTomato = f.some(x => /番茄|西红柿/.test(x));
    if (!others.length) {
      return [
        `虾仁用盐、料酒、淀粉轻轻抓匀上浆。`,
        `热锅下油烧至五六成热，下虾仁滑散至变色卷起。`,
        `下葱姜蒜爆香，烹少许料酒，加盐调味。`,
        `大火快速颠炒均匀，亮油起锅。`
      ];
    }
    return [
      `虾仁用盐、料酒、淀粉轻轻抓匀上浆。`,
      `${others.slice(0, 3).join('、')}洗净改刀备用。`,
      `热锅下油，滑炒虾仁至变色卷起，盛出。`,
      hasTomato ? `锅留底油，下番茄煸炒出红汁。` : `锅留底油，下配料炒香。`,
      `倒回虾仁，加盐调味，快速翻炒均匀起锅。`
    ];
  },
  // 宫保 / 煳辣
  kungpao: (f) => [
    `鸡肉切丁，加盐、料酒、水淀粉码味上浆。`,
    `用酱油、醋、白糖、水淀粉兑成糖醋味汁。`,
    `热锅下油，炒香干辣椒节和花椒至煳辣出香。`,
    `下鸡丁炒散至变色，烹入味汁快速翻匀。`,
    `下油酥花生米和葱节，炒匀亮油起锅。`
  ],
  // 干煸
  dryfry: (f) => [
    `${mainText(f)}处理干净，改刀成条或段。`,
    `锅下少油，中火把${mainText(f)}煸炒至水分收干、表面微皱。`,
    `下姜蒜、干辣椒、花椒（荤料可加豆瓣）炒香。`,
    `调味后继续翻炒至干香入味，起锅。`
  ],
  // 辣子 / 陈皮（炸后辣炒）
  chilifry: (f) => [
    `${mainText(f)}治净改刀，加盐、料酒码味。`,
    `下油锅炸（或煎）至外表酥香、定型，捞出。`,
    `锅留底油，爆香大量干辣椒节和花椒（陈皮可同下）。`,
    `倒入主料快速翻炒，调味至干香裹味起锅。`
  ],
  // 鱼香味型（非鱼）
  yuxiang: (f) => [
    `${mainText(f)}改刀（茄饼可夹入肉馅、挂糊炸至金黄）。`,
    `用糖、醋、酱油、水淀粉兑成鱼香味汁。`,
    `锅下油，爆香泡椒、姜蒜末出香出色。`,
    `下主料略烧，烹入鱼香汁收汁亮油，撒葱花起锅。`
  ],
  // 清蒸鱼
  fishSteam: (f) => [
    `${mainText(f)}治净，两面打花刀，用盐、料酒抹匀略腌。`,
    `盘底垫姜葱，鱼身铺姜丝，上笼大火蒸约 8 分钟至熟。`,
    `倒掉蒸出的水，撒葱丝，淋蒸鱼豉油。`,
    `浇一勺热油激香即成。`
  ],
  // 糖醋脆皮鱼
  fishSweetSour: (f) => [
    `${mainText(f)}治净改花刀，用盐、料酒腌入味，拍干淀粉。`,
    `下热油炸至外壳金黄酥脆、定型，捞出装盘。`,
    `另起锅用糖、醋、酱油兑汁，加水淀粉熬成糖醋芡。`,
    `将糖醋汁浇淋在鱼身上即成。`
  ],
  // 泡菜鱼
  fishPickle: (f) => [
    `${mainText(f)}治净切块，用盐、料酒码味。`,
    `锅下油，炒香泡菜、泡椒、姜蒜出香出色。`,
    `加适量汤或清水烧开，调味。`,
    `下鱼块煮至刚熟入味，连汤起锅。`
  ],
  // 豆腐鲫鱼等：煎鱼后加汤 / 豆腐煮
  fishTofu: (f) => [
    `${mainText(f)}治净，两面煎至微黄定型。`,
    `爆香姜蒜，加入适量热水或高汤烧开。`,
    `下豆腐同烧，小火煮至入味、汤色乳白。`,
    `调味收汁，撒葱花起锅。`
  ],
  // 烧鱼（干烧 / 黄焖 / 葱酥默认）
  fishBraise: (f) => [
    `${mainText(f)}治净，两面煎（或炸）至定型。`,
    `锅留底油，爆香姜蒜（干烧可下豆瓣炒出红油）。`,
    `加料酒、酱油和适量汤，下鱼烧开转小火。`,
    `烧至入味、汤汁浓稠，大火收汁亮油起锅。`
  ],
  // 豆腐菜（非鱼）
  tofu: (f) => [
    `豆腐改刀成丁或块，入淡盐水焯一下沥干。`,
    `锅下油，爆香姜蒜（可下肉末或豆瓣炒香）。`,
    `加少量汤下豆腐轻烧，调味入味。`,
    `勾薄芡收汁，撒葱花起锅。`
  ],
  // 炒菜（按是否有肉决定首步措辞）
  stirfry: (f) => [
    hasMeat(f)
      ? `${mainText(f)}切丝（片），加盐、料酒、水淀粉码味上浆。`
      : `${foodsText(f)}洗净改刀。`,
    `热锅下油，下葱姜蒜爆香（姜爆类多放姜丝）。`,
    `下主料大火快炒至变色断生。`,
    `加盐、生抽等调味，翻炒均匀起锅。`
  ],
  // 烧菜 / 红烧
  braise: (f) => [
    hasMeat(f)
      ? `${foodsText(f)}洗净切块，肉类先焯水或煸炒定型。`
      : `${foodsText(f)}洗净切块。`,
    `起锅烧油，爆香姜蒜（可下豆瓣、干辣椒、花椒）。`,
    `下主料煸炒上色，烹入料酒、酱油。`,
    `加热水没过食材，烧开转小火炖至软糯入味。`,
    `调味后大火收汁，起锅装盘。`
  ],
  // 凉菜
  cold: (f) => [
    `${foodsText(f)}处理干净，焯水或煮熟后晾凉。`,
    `改刀装盘。`,
    `用蒜泥、生抽、醋、辣椒油、花椒面等调成味汁。`,
    `淋汁拌匀即可食用。`
  ],
  // 汤羹（咸）
  soup: (f) => [
    hasMeat(f)
      ? `${foodsText(f)}洗净改刀，肉类先焯水。`
      : `${foodsText(f)}洗净改刀。`,
    `锅中加清汤或清水烧开，下主料。`,
    `小火煮至食材熟软。`,
    `加盐调味（清汤宜清淡），按需撒葱花起锅。`
  ],
  // 蒸菜（非鱼）
  steam: (f) => [
    `${foodsText(f)}处理干净，加调料码味腌制。`,
    `摆入蒸碗（粉蒸可裹米粉、垫红薯或土豆）。`,
    `上笼大火蒸至熟透软糯。`,
    `取出翻扣装盘，按需撒葱花。`
  ],
  // 干锅
  drypot: (f) => [
    `${foodsText(f)}处理改刀，主料先煸炒或焯水。`,
    `起锅烧油，爆香干辣椒、花椒和姜蒜。`,
    `下主料与配菜翻炒，加豆瓣等调味。`,
    `炒匀收汁，转干锅小火保温上桌。`
  ],
  // 水煮
  boil: (f) => [
    `${foodsText(f)}改刀，主料上浆码味，配菜焯熟垫底。`,
    `起锅烧油，下豆瓣、干辣椒和花椒炒出红油，掺汤烧开。`,
    `下主料煮至刚熟，连汤倒入碗中。`,
    `表面撒干辣椒、花椒面，淋热油激香即成。`
  ],
};

const TYPE_LABEL = {
  sweetsoup: '甜羹', sweetball: '甜点/圆子', eggbake: '烘蛋', shrimp: '虾仁快炒',
  kungpao: '宫保/煳辣', dryfry: '干煸', chilifry: '辣子/陈皮', yuxiang: '鱼香',
  fishSteam: '清蒸鱼', fishSweetSour: '糖醋鱼', fishPickle: '泡菜鱼', fishTofu: '豆腐鱼', fishBraise: '烧鱼',
  tofu: '豆腐菜', stirfry: '炒菜', braise: '烧菜/红烧', cold: '凉菜', soup: '汤羹',
  steam: '蒸菜', drypot: '干锅', boil: '水煮'
};

function buildCandidate(r) {
  const allNames = ingredientNames(r.id);
  const foods = allNames.filter(n => !isSeasoningName(n));
  const type = detectType(r.name, r.tags, foods);
  const steps = TEMPLATES[type](foods);
  return {
    name: r.name,
    method: steps,
    type: TYPE_LABEL[type] || type,
    source: 'generated-from-ingredients',
    reference: '大众川菜目录/川菜通用技法参考',
    needsReview: true,
    approved: false,
    confidence: foods.length ? 'medium' : 'low'
  };
}

// ── 扫描 ──────────────────────────────────────────────────────────────────────
const recipes = base.recipes || [];
const missing = [];
for (const r of recipes) {
  if (hasMethod(r)) continue;
  const allNames = ingredientNames(r.id);
  const foods = allNames.filter(n => !isSeasoningName(n));
  const miss = ['method'];
  if (ingredientsCoarse(r.id)) miss.push('ingredients');
  missing.push({
    id: r.id,
    name: r.name,
    tags: r.tags || [],
    missing: miss,
    type: TYPE_LABEL[detectType(r.name, r.tags, foods)],
    ingredientPreview: allNames.slice(0, 8),
    suggestedConfidence: foods.length ? 'medium' : 'low'
  });
}
missing.sort((a, b) => String(a.name).localeCompare(String(b.name), 'zh-Hans-CN'));

// ── 生成候选（保留已 approved 的条目，重跑不覆盖人工审核） ──────────────────────
const CAND_PATH = path.join(DATA, 'recipe-method-candidates.json');
const prev = readJSONSafe(CAND_PATH, {});
const prevCandidates = (prev && prev.candidates) || {};
const candidates = {};
let preservedApproved = 0;
for (const m of missing) {
  const existing = prevCandidates[m.id];
  if (existing && existing.approved === true) {
    candidates[m.id] = existing; // 人工已批准 → 原样保留
    preservedApproved++;
  } else {
    const r = recipes.find(x => x.id === m.id);
    candidates[m.id] = buildCandidate(r);
  }
}

// ── 写出报告 + 候选 ───────────────────────────────────────────────────────────
const generatedAt = new Date().toISOString();
const report = {
  generatedAt,
  library: LIB_FILE,
  note: '候选做法由本地模板基于食材/标签算法生成，未引用任何书中原文；PDF 仅作人工参考。',
  totals: {
    recipes: recipes.length,
    withMethod: recipes.length - missing.length,
    missingMethod: missing.length
  },
  items: missing
};
fs.writeFileSync(path.join(DATA, 'missing-methods-report.json'), JSON.stringify(report, null, 2) + '\n', 'utf8');

// Markdown 报告
const mdLines = [];
mdLines.push('# 缺失做法报告（Missing Methods Report）');
mdLines.push('');
mdLines.push(`- 生成时间：${generatedAt}`);
mdLines.push(`- 扫描库：\`${LIB_FILE}\``);
mdLines.push(`- 菜谱总数：${report.totals.recipes}`);
mdLines.push(`- 已有做法：${report.totals.withMethod}`);
mdLines.push(`- **缺少做法：${report.totals.missingMethod}**`);
mdLines.push('');
mdLines.push('> 候选做法为本地模板算法生成（基于食材/标签/川菜通用技法），**非书中原文**，全部 `needsReview: true`，需人工审核后再合并。');
mdLines.push('');
const byType = {};
for (const m of missing) { (byType[m.type] = byType[m.type] || []).push(m); }
for (const type of Object.keys(byType)) {
  mdLines.push(`## ${type}（${byType[type].length}）`);
  mdLines.push('');
  mdLines.push('| 菜名 | id | 缺失 | 食材预览 |');
  mdLines.push('| --- | --- | --- | --- |');
  for (const m of byType[type]) {
    mdLines.push(`| ${m.name} | \`${m.id}\` | ${m.missing.join(' / ')} | ${m.ingredientPreview.join('、') || '—'} |`);
  }
  mdLines.push('');
}
fs.writeFileSync(path.join(DATA, 'missing-methods-report.md'), mdLines.join('\n'), 'utf8');

const candFile = {
  generatedAt,
  source: 'generated-from-ingredients',
  reference: '大众川菜目录/川菜通用技法参考',
  note: '全部候选 needsReview:true / approved:false。审核请把要采用的条目改为 approved:true（或 needsReview:false），再运行 scripts/apply-reviewed-methods.js 合并。method 为分步数组，合并时自动编号拼成字符串。',
  count: Object.keys(candidates).length,
  candidates
};
fs.writeFileSync(CAND_PATH, JSON.stringify(candFile, null, 2) + '\n', 'utf8');

console.log(`[audit] 库=${LIB_FILE} 总数=${report.totals.recipes} 缺做法=${report.totals.missingMethod} 候选=${candFile.count}（保留已批准 ${preservedApproved}）`);
console.log('[audit] 已写出：');
console.log('  - data/missing-methods-report.json');
console.log('  - data/missing-methods-report.md');
console.log('  - data/recipe-method-candidates.json');
