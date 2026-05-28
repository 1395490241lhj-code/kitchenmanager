#!/usr/bin/env node
/*
 * curate-recipes.js —— 菜谱库“日常化精简”一次性生成器
 *
 * 输入（只读，不修改）：
 *   data/sichuan-recipes.json            原始菜谱库（264 道，仅 id/name/tags，无 method）
 *   data/recipe-completion-overlay.json  做法/食材补全包（method + 细化 ingredients）
 *   data/reference/dazhong-chuancai.pdf  《大众川菜》扫描件（纯图片，无文本层）
 *
 * 输出：
 *   data/sichuan-recipes.curated.json    精简后的日常菜谱库（保留 + 待补全）
 *   data/recipe-curation-removed.json    移出清单（宴席化/罕见/无做法不日常/重复）
 *   data/recipes-needing-completion.json 日常高价值但暂无做法、值得补全的菜
 *   data/recipe-curation-summary.md      统计与说明
 *
 * 处理模型：
 *   1. 复刻 app 的 applyCompletionOverlay 合并逻辑，得到“有效菜谱集”
 *      （base + overlay 的 method / 细化 ingredients / newRecipes）。
 *   2. 凡是合并后“有 method”的菜（全部来自 overlay 的日常家常菜）→ 默认保留。
 *   3. 无 method 的菜：按下方显式名单判定
 *        - 命中 NEEDS_COMPLETION → 保留进 curated，同时记入待补全清单。
 *        - 命中 DUPLICATES        → 移出，并注明 duplicateOf。
 *        - 其余                    → 移出（多为山海味/鸽蛋/田鸡/花式工艺等宴席菜）。
 *   4. 判定名单为人工审定（基于完整菜名列表 + 川菜常识），显式写出便于复核。
 *
 * PDF 说明：该 PDF 为扫描图片（492 图 / 0 字体 / 0 ToUnicode），无可靠文本层。
 * 按需求“OCR 失败不应中断任务”，故未对整本 OCR；做法/食材一律以 overlay 为准，
 * PDF 仅用于核对“哪些是《大众川菜》中的日常家常菜 vs 宴席工艺菜”。
 */

const fs = require('fs');
const path = require('path');

const DATA = path.resolve(__dirname, '..', 'data');
const base = JSON.parse(fs.readFileSync(path.join(DATA, 'sichuan-recipes.json'), 'utf8'));
const overlay = JSON.parse(fs.readFileSync(path.join(DATA, 'recipe-completion-overlay.json'), 'utf8'));

// ── 人工审定名单 ────────────────────────────────────────────────────────────

// 无做法但日常、值得补全（保留进 curated，并记入待补全清单）。
const NEEDS_COMPLETION = {
  high: {
    '水煮肉片': '川菜代表作，最高频家常麻辣菜，base 无做法，需补现代摘要步骤',
    '煳辣鸡丁（宫保鸡丁）': '经典宫保鸡丁，最高频家常川菜，需补现代摘要步骤',
    '辣子鸡丁': '川菜高频家常，干辣椒鸡丁，需补做法',
    '干烧鲫鱼': '经典家常干烧鱼，鲫鱼常见，需补做法',
  },
  medium: {
    '棒棒鸡丝': '凉拌鸡丝，夏季家常，食材常见',
    '怪味鸡': '川味凉菜经典，调味可标准化',
    '家常鸡丝': '家常快手鸡丝，食材常见',
    '花椒鸡丁': '麻香鸡丁，家常可做',
    '魔芋烧鸭': '川菜经典家常炖菜，魔芋+鸭块',
    '椿芽烘蛋': '香椿煎蛋，季节性家常蛋菜',
    '萝卜连锅': '连锅汤，萝卜炖肉家常汤菜',
    '小滑肉': '滑肉汤，川南家常蒸/煮肉',
    '葱末肝片': '爆炒猪肝家常做法，需补步骤',
    '干煸冬笋': '干煸经典素菜，冬笋季节常见',
    '鱼香茄饼': '鱼香茄子家族，茄子家常',
    '碎米豆腐': '家常豆腐碎肉，下饭菜',
    '番茄炒虾仁': '番茄虾仁家常快炒，食材常见',
    '豆腐鲫鱼': '豆腐烧鱼，家常炖鱼',
    '泡菜鱼': '酸菜鱼家族，家常酸辣鱼',
    '辣子鱼': '家常麻辣烧鱼',
    '清蒸鲢鱼': '清蒸鱼家常做法',
    '糖醋脆皮鱼': '糖醋鱼，宴客也家常',
    '冰糖银耳': '银耳羹，常见甜汤',
  },
  low: {
    '豆芽拌鸡丝': '凉拌鸡丝配豆芽，家常凉菜',
    '自拌鸡丝': '自制凉拌鸡丝，与棒棒鸡相近',
    '姜爆鸭丝': '姜爆鸭丝快炒，鸭肉略不日常',
    '陈皮兔': '川味陈皮兔丁，兔肉非全国常见',
    '陈皮肉': '陈皮牛/猪肉干香，偏小吃',
    '大南瓜蒸肉': '南瓜粉蒸肉，与粉蒸肉相近',
    '清汤白菜': '清汤白菜，做法偏功夫汤',
    '糯米圆子': '糯米肉圆，偏年节',
    '干煸鳝鱼': '干煸鳝鱼，鳝鱼非全国常备',
    '葱酥鱼': '葱酥小鱼，下酒家常',
    '生爆虾仁': '油爆虾仁快炒',
    '黄焖大鲢鱼头': '鱼头焖烧，分量偏大',
  },
};

// 重复菜：移出更差的一条，注明 duplicateOf（更日常 / 更完整 / 名字更常见的保留版）。
const DUPLICATES = {
  '罐烧肉（东坡肉）': '东坡肉',
  '干煵肉丝': '干煸肉丝',
  '旱蒸回锅肉': '回锅肉',
  '鱼香肉片': '鱼香肉丝',
};

// ── 1. 复刻 applyCompletionOverlay，得到“有效菜谱集” ─────────────────────────
function coarse(ings) {
  if (!Array.isArray(ings) || ings.length === 0) return true;
  if (ings.length === 1) return true;
  return false;
}

const recipes = base.recipes.map(r => ({ ...r }));
const ing = Object.fromEntries(
  Object.entries(base.recipe_ingredients || {}).map(([k, v]) => [k, v.slice()])
);
const ids = new Set(recipes.map(r => r.id));
const nameIdx = new Map(recipes.map((r, i) => [String(r.name || '').trim(), i]));

// 记录 method / ingredients 来自 overlay 的菜（用于统计）。
const methodFromOverlay = new Set();
const ingFromOverlay = new Set();

for (const [id, p] of Object.entries(overlay.recipes || {})) {
  const i = recipes.findIndex(r => r.id === id);
  if (i >= 0 && p.method && !recipes[i].method) {
    recipes[i] = { ...recipes[i], method: p.method };
    methodFromOverlay.add(id);
  }
}
for (const [id, l] of Object.entries(overlay.recipe_ingredients || {})) {
  if (coarse(ing[id])) { ing[id] = l.slice(); ingFromOverlay.add(id); }
}
const nIng = overlay.newRecipeIngredients || {};
for (const r of (overlay.newRecipes || [])) {
  const tn = String(r.name || '').trim();
  if (ids.has(r.id)) continue;
  if (nameIdx.has(tn)) {
    const i = nameIdx.get(tn);
    const eid = recipes[i].id;
    if (r.method && !recipes[i].method) { recipes[i] = { ...recipes[i], method: r.method }; methodFromOverlay.add(eid); }
    if (coarse(ing[eid]) && nIng[r.id]) { ing[eid] = nIng[r.id].slice(); ingFromOverlay.add(eid); }
    continue;
  }
  recipes.push({ ...r });
  if (r.method) methodFromOverlay.add(r.id);
  if (nIng[r.id]) { ing[r.id] = nIng[r.id].slice(); ingFromOverlay.add(r.id); }
  ids.add(r.id);
  nameIdx.set(tn, recipes.length - 1);
}

// ── 2. 分类 ─────────────────────────────────────────────────────────────────
const needsByName = new Map();
for (const [prio, obj] of Object.entries(NEEDS_COMPLETION)) {
  for (const [name, reason] of Object.entries(obj)) needsByName.set(name, { prio, reason });
}

const keptRecipes = [];
const keptIng = {};
const removed = [];
const needing = [];
let methodCompleted = 0;
let ingCompleted = 0;

for (const r of recipes) {
  const name = String(r.name || '').trim();
  const hasMethod = !!(r.method || r.staticMethod);
  const ingList = ing[r.id] || [];
  const hasGoodIng = ingList.length >= 2;

  const keep = (decision) => {
    keptRecipes.push({ ...r });
    keptIng[r.id] = ingList.slice();
    if (methodFromOverlay.has(r.id)) methodCompleted++;
    if (ingFromOverlay.has(r.id)) ingCompleted++;
    return decision;
  };

  if (DUPLICATES[name]) {
    removed.push({ id: r.id, name, reason: '重复菜，保留更日常/更完整的版本', duplicateOf: DUPLICATES[name], hadMethod: hasMethod, hadIngredients: hasGoodIng });
    continue;
  }

  if (hasMethod) { keep(); continue; }

  if (needsByName.has(name)) {
    const { prio, reason } = needsByName.get(name);
    keep();
    const missing = ['method'];
    if (!hasGoodIng) missing.push('ingredients');
    needing.push({ id: r.id, name, missing, reason, suggestedPriority: prio });
    continue;
  }

  // 其余无做法菜：移出（宴席化 / 罕见食材 / 工艺菜 / 不日常）。
  removed.push({ id: r.id, name, reason: '无做法且不日常（宴席化/罕见食材/老式工艺/菜名不清），暂移出', duplicateOf: '', hadMethod: false, hadIngredients: hasGoodIng });
}

keptRecipes.sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'));
removed.sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'));
const prioRank = { high: 0, medium: 1, low: 2 };
needing.sort((a, b) => (prioRank[a.suggestedPriority] - prioRank[b.suggestedPriority]) || a.name.localeCompare(b.name, 'zh-Hans-CN'));

// curated 的 recipe_ingredients 按保留菜重建
const curatedIng = {};
for (const r of keptRecipes) curatedIng[r.id] = keptIng[r.id];

// ── 3. 写出文件 ─────────────────────────────────────────────────────────────
const write = (file, obj) => fs.writeFileSync(path.join(DATA, file), JSON.stringify(obj, null, 2) + '\n');

write('sichuan-recipes.curated.json', { recipes: keptRecipes, recipe_ingredients: curatedIng });
write('recipe-curation-removed.json', { removed });
write('recipes-needing-completion.json', { items: needing });

const dupCount = removed.filter(r => r.duplicateOf).length;
const byCategory = {};
for (const r of removed) {
  const key = r.duplicateOf ? '重复菜（已有更优版本）' : '无做法且不日常（宴席/罕见/工艺/菜名不清）';
  byCategory[key] = (byCategory[key] || 0) + 1;
}

const md = `# 菜谱库日常化精简 · 报告

> 由 \`scripts/curate-recipes.js\` 自动生成。原始数据未被修改。

## 数量总览

| 指标 | 数量 |
| --- | ---: |
| 原始菜谱（base + overlay 合并后的有效集） | ${recipes.length} |
| ├ 其中原始 base | ${base.recipes.length} |
| └ 其中 overlay 新增/补全后净增 | ${recipes.length - base.recipes.length} |
| **curated 保留** | **${keptRecipes.length}** |
| ├ 有做法直接保留 | ${keptRecipes.length - needing.length} |
| └ 无做法但日常、值得补全（仍保留） | ${needing.length} |
| **移出** | **${removed.length}** |
| **待补全（needing-completion）** | **${needing.length}** |
| 从 overlay 补全 method 的菜 | ${methodCompleted} |
| 从 overlay 补全 ingredients 的菜 | ${ingCompleted} |
| 移出中的重复菜 | ${dupCount} |

## 移出原因分类

${Object.entries(byCategory).map(([k, v]) => `- ${k}：${v}`).join('\n')}

## 待补全分布

- 高优先（high）：${needing.filter(n => n.suggestedPriority === 'high').length}
- 中优先（medium）：${needing.filter(n => n.suggestedPriority === 'medium').length}
- 低优先（low）：${needing.filter(n => n.suggestedPriority === 'low').length}

## 重复菜处理

${removed.filter(r => r.duplicateOf).map(r => `- 移出「${r.name}」→ 保留「${r.duplicateOf}」`).join('\n')}

## 关于《大众川菜》PDF 的使用

\`data/reference/dazhong-chuancai.pdf\` 为**纯扫描件**（492 张图片，0 字体 / 0 ToUnicode / 无文本层），
无法稳定提取文字。按需求要求“OCR 失败不应中断任务”，本次**未对整本 PDF 做 OCR**：

- 所有做法（method）与细化食材（ingredients）一律以
  \`data/recipe-completion-overlay.json\` 为权威来源；
- PDF 仅作为概念性核对——确认这些菜名确实出自《大众川菜》，
  并据此判断“日常家常菜 vs 山海味/鸽蛋/田鸡/花式工艺等宴席菜”，
  未逐字抄录 PDF 原文。

## 说明 / 注意事项

- 本脚本只读输入文件，**未修改** \`data/sichuan-recipes.json\`、用户 localStorage overlay 或任何自定义菜谱。
- 移出判定保守：日常但暂无做法的菜放入待补全而非删除；不确定时倾向保留/待补全。
- 原始 base 菜谱本身不含 method 字段，故“保留的有做法菜”全部来自 overlay 的日常家常菜整理。
- 用户常见但**本书未收录**的日常菜（如 麻婆豆腐、番茄炒蛋、土豆丝、家常豆腐、鱼香茄子、土豆烧牛肉、青椒皮蛋、干煸豆角）
  不在本库，建议作为后续新增（可走 overlay.newRecipes）。
`;

fs.writeFileSync(path.join(DATA, 'recipe-curation-summary.md'), md);

console.log(`effective=${recipes.length} kept=${keptRecipes.length} removed=${removed.length} needing=${needing.length} dup=${dupCount} methodFromOverlay=${methodCompleted} ingFromOverlay=${ingCompleted}`);
