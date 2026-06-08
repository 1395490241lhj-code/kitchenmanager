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
const AROMATICS = ['豆瓣', '郫县豆瓣', '豆瓣酱', '花椒', '干辣椒', '辣椒', '泡椒', '剁椒', '姜', '葱', '蒜'];

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
function detectType(name, tags) {
  const t = String(name || '') + ' ' + (Array.isArray(tags) ? tags.join(' ') : '');
  if (/凉拌|拌|白肉|口水|椒麻|怪味|蒜泥|夫妻肺片/.test(t)) return 'cold';
  if (/汤|羹|煲|清炖|炖汤/.test(t)) return 'soup';
  if (/粉蒸|清蒸|旱蒸|蒸/.test(t)) return 'steam';
  if (/干锅/.test(t)) return 'drypot';
  if (/水煮/.test(t)) return 'boil';
  if (/红烧|家常烧|干烧|烧/.test(t)) return 'braise';
  return 'stirfry';
}

function foodsText(foods) { return foods.length ? foods.slice(0, 3).join('、') : '主料'; }
function mainText(foods) { return foods.length ? foods[0] : '主料'; }
function aromaticText(allNames) {
  const found = AROMATICS.filter(a => allNames.some(n => n.includes(a)));
  const has = (x) => found.some(f => f.includes(x));
  const parts = [];
  if (has('姜') || has('葱') || has('蒜')) parts.push('葱姜蒜');
  if (has('豆瓣')) parts.push('豆瓣酱');
  if (has('花椒')) parts.push('花椒');
  if (has('辣椒') || has('泡椒') || has('剁椒')) parts.push('干辣椒');
  return parts.length ? parts.join('、') : '葱姜蒜';
}

const TEMPLATES = {
  stirfry: (f, a) => [
    `${foodsText(f)}洗净改刀，肉类可加盐、料酒、淀粉上浆码味。`,
    `起锅烧油，下${a}爆香。`,
    `下${mainText(f)}等主料大火快炒至变色断生。`,
    `加盐、生抽等调味，翻炒均匀。`,
    `淋少许水淀粉收汁，起锅装盘。`
  ],
  braise: (f, a) => [
    `${foodsText(f)}洗净切块，肉类先焯水去腥。`,
    `起锅烧油，下${a}炒香（红烧可加豆瓣或糖色上色）。`,
    `下主料煸炒上色，烹入料酒、酱油。`,
    `加热水没过食材，烧开后转小火炖至软糯入味。`,
    `调味后大火收汁，起锅装盘。`
  ],
  cold: (f, _a) => [
    `${foodsText(f)}处理干净，焯水或煮熟后晾凉。`,
    `改刀装盘。`,
    `用蒜泥、生抽、醋、辣椒油、花椒面等调成味汁。`,
    `淋汁拌匀即可食用。`
  ],
  soup: (f, _a) => [
    `${foodsText(f)}洗净改刀，肉类先焯水。`,
    `锅中加清水或高汤烧开，下主料。`,
    `小火煮至食材熟软。`,
    `加盐等调味，按需勾薄芡，撒葱花起锅。`
  ],
  steam: (f, _a) => [
    `${foodsText(f)}处理干净，加调料码味腌制。`,
    `摆入蒸碗（粉蒸可裹米粉、垫红薯或土豆）。`,
    `上笼大火蒸至熟透软糯。`,
    `取出翻扣装盘，按需撒葱花。`
  ],
  drypot: (f, _a) => [
    `${foodsText(f)}处理改刀，主料先煸炒或焯水。`,
    `起锅烧油，爆香干辣椒、花椒和姜蒜。`,
    `下主料与配菜翻炒，加豆瓣等调味。`,
    `炒匀收汁，转干锅小火保温上桌。`
  ],
  boil: (f, _a) => [
    `${foodsText(f)}改刀，肉类上浆码味，配菜焯熟垫底。`,
    `起锅烧油，下豆瓣、干辣椒和花椒炒出红油，掺汤烧开。`,
    `下主料煮至刚熟，连汤倒入碗中。`,
    `表面撒干辣椒、花椒面，淋热油激香即成。`
  ],
};

const TYPE_LABEL = { stirfry: '炒菜', braise: '烧菜/红烧', cold: '凉菜', soup: '汤羹', steam: '蒸菜', drypot: '干锅', boil: '水煮' };

function buildCandidate(r) {
  const allNames = ingredientNames(r.id);
  const foods = allNames.filter(n => !isSeasoningName(n));
  const type = detectType(r.name, r.tags);
  const steps = TEMPLATES[type](foods, aromaticText(allNames));
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
  const miss = ['method'];
  if (ingredientsCoarse(r.id)) miss.push('ingredients');
  missing.push({
    id: r.id,
    name: r.name,
    tags: r.tags || [],
    missing: miss,
    type: TYPE_LABEL[detectType(r.name, r.tags)],
    ingredientPreview: allNames.slice(0, 8),
    suggestedConfidence: allNames.filter(n => !isSeasoningName(n)).length ? 'medium' : 'low'
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
