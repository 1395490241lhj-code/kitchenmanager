#!/usr/bin/env node
/**
 * apply-reviewed-methods.js
 *
 * 把【已人工审核通过】的做法候选合并进 data/recipe-completion-overlay.json 的 `recipes` 补丁表。
 *
 * 合并规则（与任务规则一致）：
 *   - 只合并 approved:true 或 needsReview:false 的候选；其余一律跳过。
 *   - 写入「completion 补全 overlay」（附加层），绝不修改原始菜谱 JSON（sichuan-recipes*.json）。
 *   - 不覆盖：若该 id 在 completion-overlay 已有 method，则跳过（保留已有做法）。
 *   - 运行时 applyCompletionOverlay 也仅在 base 无做法时才填入，二次保险不覆盖用户做法。
 *   - 不读写 localStorage、不改 localStorage key。
 *
 * 用法：
 *   node scripts/apply-reviewed-methods.js --dry-run   # 预览将合并哪些（不写文件）
 *   node scripts/apply-reviewed-methods.js             # 实际写入 completion-overlay.json
 *   # 指定候选来源（例如完整库草稿）：
 *   node scripts/apply-reviewed-methods.js --candidates=data/recipe-method-candidates.full.json --dry-run
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');
const args = process.argv.slice(2);
const DRY = args.includes('--dry-run');

function readJSON(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }
function argVal(name) {
  const a = args.find(x => x.startsWith('--' + name + '='));
  return a ? a.split('=').slice(1).join('=') : null;
}
function resolveInput(val, def) {
  if (!val) return path.join(DATA, def);
  return path.isAbsolute(val) ? val : path.resolve(ROOT, val);
}

// 候选来源可覆盖（--candidates=<path>），默认 curated 候选；overlay 目标固定为附加层。
const CAND_PATH = resolveInput(argVal('candidates'), 'recipe-method-candidates.json');
const OVERLAY_PATH = path.join(DATA, 'recipe-completion-overlay.json');

const candFile = readJSON(CAND_PATH);
const candidates = (candFile && candFile.candidates) || {};
const overlay = readJSON(OVERLAY_PATH);
overlay.recipes = overlay.recipes || {};

function toMethodString(method) {
  if (Array.isArray(method)) return method.map((s, i) => `${i + 1}. ${String(s).trim()}`).join('\n');
  return String(method || '').trim();
}

let applied = 0, skippedUnreviewed = 0, skippedExisting = 0, skippedEmpty = 0;
const appliedNames = [];

for (const [id, c] of Object.entries(candidates)) {
  if (!c) continue;
  const reviewed = c.approved === true || c.needsReview === false;
  if (!reviewed) { skippedUnreviewed++; continue; }

  const methodStr = toMethodString(c.method);
  if (!methodStr) { skippedEmpty++; continue; }

  if (overlay.recipes[id] && overlay.recipes[id].method) { skippedExisting++; continue; } // 不覆盖已有做法

  overlay.recipes[id] = { ...(overlay.recipes[id] || {}), method: methodStr };
  applied++;
  appliedNames.push(`${c.name || id}`);
}

console.log(`[apply] 候选来源=${path.relative(ROOT, CAND_PATH).split(path.sep).join('/')}`);
console.log(`[apply] 候选总数=${Object.keys(candidates).length}`);
console.log(`[apply] 将合并(已审核)=${applied} 跳过(未审核)=${skippedUnreviewed} 跳过(已有做法)=${skippedExisting} 跳过(空做法)=${skippedEmpty}`);
if (appliedNames.length) console.log('[apply] 合并菜谱：' + appliedNames.join('、'));

if (DRY) {
  console.log('[apply] --dry-run：未写入任何文件。');
} else if (applied > 0) {
  overlay.updatedAt = new Date().toISOString();
  fs.writeFileSync(OVERLAY_PATH, JSON.stringify(overlay, null, 2) + '\n', 'utf8');
  console.log('[apply] 已写入 data/recipe-completion-overlay.json');
} else {
  console.log('[apply] 没有可合并的已审核候选，未修改文件。');
}
