#!/usr/bin/env node
// Read-only targeted review for the two remaining runtime-name blockers.
// Writes only the review JSON/MD artifacts; never edits production, ledger,
// readiness, alias tables, canonical data, or unit conversions.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  INGREDIENT_ALIASES,
  getCanonicalName,
  getIngredientFamilyCandidates,
  getIngredientFamilyKey,
  getIngredientMatchNames,
  isSmartIngredientMatch,
} from '../src/ingredients.js';
import { getStockCoverageAnalysis } from '../src/inventory.js';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';
import { classifyIngredientCompatibility } from './dazhong-runtime-compatibility.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const REVIEW_DATE = '2026-08-08';
const BASELINE_COMMIT = '06b2324a4aeca3db915d3c223e758ffa13eff890';
const PDF_SOURCE = '/Users/lianghongjing/Documents/大众川菜 (刘建成等编) (Z-Library).pdf';
const REVIEW_IDS = ['dz1979-p137', 'dz1979-p161'];

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');

const recipeById = new Map(recipes.recipes.map((recipe) => [recipe.entryId, recipe]));
const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
const catalogById = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));

const SOURCE_REVIEW = {
  'dz1979-p137': {
    bookPage: 137,
    pdfPage: 150,
    title: '椒麻鸡块',
    ingredientQuote: '子公鸡一只（约三斤）',
    methodQuote: '选子公鸡杀后去毛及内脏……煮至刚熟时，捞起晾冷。',
    visualFinding: '原料栏明确列出子公鸡；扫描页与冻结 canonical source-restoration 一致。',
  },
  'dz1979-p161': {
    bookPage: 161,
    pdfPage: 174,
    title: '拌鸡血',
    ingredientQuote: '鸡血一斤',
    methodQuote: '将鸡血（或鸭血）切成四分见方的丁……',
    visualFinding: '原料栏明确列出鸡血；做法的“或鸭血”是烹调替代说明，不是鸡血与鸭血的 canonical 等价。',
  },
};

function stockProbe(stockName, recipeName, qty, unit) {
  const inventory = [{ name: stockName, qty: 500, unit: 'g', stockStatus: 'ok' }];
  return {
    stockName,
    strictNameMatch: isSmartIngredientMatch(recipeName, stockName, { allowContains: false }),
    coverage: getStockCoverageAnalysis(inventory, recipeName, qty, unit).confidence,
  };
}

function currentVocabulary(item) {
  const canonical = getCanonicalName(item);
  const familyKey = getIngredientFamilyKey(item);
  return {
    raw: item,
    canonical,
    aliases: [...(INGREDIENT_ALIASES[canonical] ?? [])],
    familyKey: familyKey || null,
    familyCandidates: getIngredientFamilyCandidates(item, { includeBroad: true }),
    matchNames: getIngredientMatchNames(item),
    role: classifyRecipeIngredient(item).role,
  };
}

function productionInvariants() {
  const promotedIds = new Set(
    (ledger.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.productionId)),
  );
  return {
    curatedCount: curated.recipes.length,
    fullCount: full.recipes.length,
    promotedCount: readiness.summary.promotedNewRecipeCount,
    remainingCount: readiness.summary.remainingNewRecipeCandidateCount,
    applicationReady: readiness.applicationReady,
    reviewedIdsAbsentFromCurated: REVIEW_IDS.every((id) => !curated.recipes.some((recipe) => recipe.id === id)),
    reviewedIdsAbsentFromFull: REVIEW_IDS.every((id) => !full.recipes.some((recipe) => recipe.id === id)),
    reviewedIdsAbsentFromLedger: REVIEW_IDS.every((id) => !promotedIds.has(id)),
    readinessStates: Object.fromEntries(REVIEW_IDS.map((id) => [id, readinessById.get(id)?.promotionState])),
  };
}

function reviewP137(recipe, entry, catalogEntry) {
  const runtime = classifyIngredientCompatibility('子公鸡', '1', '只');
  const existingChicken = currentVocabulary('鸡肉');
  const chickenStockProbes = ['鸡肉', '仔鸡', '公鸡', '土鸡'].map((stockName) => (
    stockProbe(stockName, '鸡肉', '500', 'g')
  ));
  return {
    entryId: 'dz1979-p137',
    name: recipe.bookName,
    source: { ...SOURCE_REVIEW['dz1979-p137'], catalogEntry, canonicalEntry: recipe },
    currentVocabulary: currentVocabulary('子公鸡'),
    currentRuntime: runtime,
    semanticEquivalence: {
      existingEquivalentCanonical: '鸡肉',
      evidence: '现有 INGREDIENT_ALIASES 已把仔鸡、公鸡、土鸡、三黄鸡、仔母鸡归入鸡肉；子公鸡是其中同一“幼年公鸡/整鸡肉”语义的未覆盖词形。判断依据是既有逐词 alias 约定，不是因为字符串含有“鸡”就自动扩 family。',
      nonEquivalentCandidates: ['鸡脯肉', '鸡腿', '鸡翅'],
    },
    options: {
      exactAlias: {
        status: 'recommended',
        change: '仅新增 INGREDIENT_ALIASES["鸡肉"] 中的精确 alias “子公鸡”；不改 chicken family broad/members。',
        hypotheticalCanonical: '鸡肉',
        chickenFamily: existingChicken,
        stockProbes: chickenStockProbes,
        effect: 'getStockCoverageAnalysis 会让鸡肉/仔鸡/公鸡/土鸡库存满足该 recipe；推荐目标会沿现有鸡肉 family 展开；购物清单会把子公鸡 canonicalize 为鸡肉，丢失“幼公鸡”标签。',
        risk: '现有 chicken broad family 本来就允许鸡肉与鸡脯肉/鸡腿/鸡翅的 sibling match；alias 会把该新词纳入既有宽口径，但不会扩大 family 定义。',
      },
      independentCanonical: {
        status: 'lower-compatibility',
        effect: '保留子公鸡独立，库存/推荐/购物清单只精确识别子公鸡，避免鸡肉 family 的宽匹配；但用户已有鸡肉/仔鸡库存不会满足 recipe。',
      },
      keepBlocked: {
        status: 'safe-now',
        effect: '不改变任何运行时行为，但保留已确认的词汇缺口。',
      },
    },
    recommendation: 'exact-alias-to-鸡肉',
    safeToUnlockAfterReview: true,
    safeToUnlockNow: false,
    minimumCodeChange: '只加一个精确 alias，并补 matcher/inventory/recommendation/shopping 回归；不新增 family member、不做 contains heuristic、不改 unit conversion。',
  };
}

function reviewP161(recipe, entry, catalogEntry) {
  const runtime = classifyIngredientCompatibility('鸡血', '500', 'g');
  const bloodProbes = ['鸡血', '鸭血', '鸡肉'].map((stockName) => (
    stockProbe(stockName, '鸡血', '500', 'g')
  ));
  return {
    entryId: 'dz1979-p161',
    name: recipe.bookName,
    source: { ...SOURCE_REVIEW['dz1979-p161'], catalogEntry, canonicalEntry: recipe },
    currentVocabulary: currentVocabulary('鸡血'),
    currentRuntime: runtime,
    semanticEquivalence: {
      existingEquivalentCanonical: null,
      rejectedMappings: [
        { candidate: '鸡肉', reason: '不同组织；鸡血不得映射鸡肉。' },
        { candidate: '鸭血', reason: '不同物种；扫描中的“或鸭血”是 recipe 替代原料说明，不是 canonical 等价。' },
      ],
      evidence: '当前没有血类 family；鸡血和鸭血都作为各自 raw canonical 回退，库存 matcher 对两者已能精确区分。',
    },
    options: {
      exactAlias: {
        status: 'rejected',
        effect: '不存在安全的现有 canonical alias 目标；映射鸡肉或鸭血都会造成跨组织/跨物种库存、推荐和购物清单污染。',
      },
      independentCanonical: {
        status: 'recommended',
        change: '显式保留独立 canonical “鸡血”，加入窄范围 runtime recognition；不加入 chicken family，不加入 duck-blood alias，不改变 matcher 的 exact species boundary。',
        hypotheticalCanonical: '鸡血',
        stockProbes: bloodProbes,
        effect: '鸡血库存可满足 p161；鸭血、鸡肉均不能满足；推荐与购物清单保留鸡血名称，不跨物种合并。',
        risk: '需要 runtime gate 识别独立血类 canonical；仅新增 alias 表 key 或保留 raw fallback 本身不足以解决当前“含鸡即 poultry” gate。',
      },
      keepBlocked: {
        status: 'safe-now',
        effect: '不改变任何运行时行为，继续阻止 promotion，避免错误映射。',
      },
    },
    recommendation: 'new-independent-canonical-鸡血',
    safeToUnlockAfterReview: true,
    safeToUnlockNow: false,
    minimumCodeChange: '新增独立鸡血 canonical/runtime 分类路径，并补 exact 鸡血、拒绝鸭血/鸡肉的 inventory/recommendation/shopping 回归；不新增 alias 到任何既有 canonical。',
  };
}

const items = [
  reviewP137(recipeById.get('dz1979-p137'), readinessById.get('dz1979-p137'), catalogById.get('dz1979-p137')),
  reviewP161(recipeById.get('dz1979-p161'), readinessById.get('dz1979-p161'), catalogById.get('dz1979-p161')),
];

const invariants = productionInvariants();
const problems = [];
if (invariants.curatedCount !== 157) problems.push('curated-count:' + invariants.curatedCount);
if (invariants.promotedCount !== 31) problems.push('promoted-count:' + invariants.promotedCount);
if (invariants.remainingCount !== 8) problems.push('remaining-count:' + invariants.remainingCount);
if (invariants.applicationReady !== false) problems.push('applicationReady-not-false');
if (!invariants.reviewedIdsAbsentFromCurated || !invariants.reviewedIdsAbsentFromFull || !invariants.reviewedIdsAbsentFromLedger) problems.push('reviewed-id-production-presence');
for (const item of items) {
  if (item.currentRuntime.compatibility !== 'unresolved-name-match') problems.push('not-unresolved:' + item.entryId);
  if (item.source.catalogEntry.pdfPage !== item.source.pdfPage) problems.push('pdf-page-mismatch:' + item.entryId);
}

const output = {
  schema: 'kitchenmanager.source-restoration.runtime-name-blocker-review.v1',
  generatedAt: REVIEW_DATE,
  purpose: '《大众川菜》1979 runtime-name blocker targeted review。只读分析 p137 子公鸡与 p161 鸡血；不 promotion、不修改 production/ledger/readiness、不新增 alias/canonical/unit conversion。',
  baseline: {
    commit: BASELINE_COMMIT,
    curatedCount: 157,
    promotedCount: 31,
    remainingCount: 8,
    applicationReady: false,
  },
  scope: {
    reviewedEntryIds: REVIEW_IDS,
    excludedEntryIds: ['dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226'],
    originalPdf: PDF_SOURCE,
    sourceReviewMethod: '原始扫描页由 pdftoppm 渲染后目视核对；canonical/readiness/runtime 证据由本 generator 读取并复算。',
  },
  downstreamCodePaths: [
    'src/ingredients.js: canonical aliases, family candidates, isSmartIngredientMatch',
    'src/inventory.js: getMatchingInventoryItems/getStockCoverageAnalysis',
    'src/recommendations.js: core-only inventory coverage, missing ingredients, target matching',
    'src/shopping.js: addShoppingItem/mergeShoppingItems canonicalize shopping names',
  ],
  productionInvariants: invariants,
  items,
  conclusion: {
    p137: '建议 exact alias 子公鸡 -> 鸡肉；理由是已有仔鸡/公鸡等同义 alias 约定，且不改 chicken family 定义。修复后仍保留只/份的 unit confirmation，不应借此扩大 unit policy。',
    p161: '建议新建独立 canonical 鸡血并增加窄 runtime recognition；绝不 alias 到鸡肉或鸭血。当前 raw canonical 已可精确匹配鸡血库存，但 gate 规则错误地把含鸡词当作 poultry meat vocabulary。',
    safeToUnlock: '两条均可在各自最小修复及回归测试后安全解锁；本轮不实施，因此当前仍 blocked。',
  },
  writeTargets: [
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
  ],
  verificationProblems: problems,
};

function mdItem(item) {
  const vocabulary = item.currentVocabulary;
  return [
    '## ' + item.entryId + ' ' + item.name,
    '',
    '- 原扫描：书页 ' + item.source.bookPage + ' / PDF page ' + item.source.pdfPage + '；' + item.source.ingredientQuote,
    '- 方法证据：' + item.source.methodQuote,
    '- 当前 canonical：' + vocabulary.canonical + '；alias：' + (vocabulary.aliases.length ? vocabulary.aliases.join('、') : '无') + '；family：' + (vocabulary.familyKey ?? '无') + '；role：' + vocabulary.role,
    '- 当前 runtime：' + item.currentRuntime.compatibility + '；未严格解析 probe：' + item.currentRuntime.probes.filter((probe) => probe.strictNameMatch === false).map((probe) => probe.probeName).join('、'),
    '- 推荐：**' + item.recommendation + '**。',
    '- 最小代码改动：' + item.minimumCodeChange,
    '',
    '### 方案判断',
    '',
    '| 方案 | 结论 | 影响 |',
    '| --- | --- | --- |',
    '| exact alias | ' + item.options.exactAlias.status + ' | ' + item.options.exactAlias.effect + ' |',
    '| 独立 canonical | ' + item.options.independentCanonical.status + ' | ' + item.options.independentCanonical.effect + ' |',
    '| 保持 blocked | ' + item.options.keepBlocked.status + ' | ' + item.options.keepBlocked.effect + ' |',
    '',
  ].join('\n');
}

const markdown = [
  '# 《大众川菜》1979 runtime-name blocker targeted review',
  '',
  '生成日期：' + REVIEW_DATE + '  ',
  'baseline：' + BASELINE_COMMIT + '  ',
  '范围：p137 子公鸡、p161 鸡血；当前 promoted=31、remaining=8、applicationReady=false。',
  '',
  '本轮只读：不 promotion，不修改 production/ledger/readiness，不新增 alias/canonical/unit conversion。原始 PDF：' + PDF_SOURCE,
  '',
  '## 结论',
  '',
  '- **p137 椒麻鸡块 / 子公鸡**：推荐精确 alias 子公鸡 -> 鸡肉。这依赖既有仔鸡、公鸡等明确 alias 约定，不是按“含鸡”自动扩 family；不改 chicken family broad/members。修复后仍需保留只与份的 unit confirmation 语义。',
  '- **p161 拌鸡血 / 鸡血**：推荐独立 canonical 鸡血 + 窄 runtime recognition。不得映射鸡肉，也不得映射鸭血；鸡血库存与鸭血库存必须保持 exact species boundary。',
  '- 两条只有在各自最小修复和回归测试完成后才安全解锁；本轮不实施，当前仍 blocked。',
  '',
  '## Source / runtime / downstream evidence',
  '',
  items.map(mdItem).join('\n'),
  '## 未改动保护',
  '',
  '当前 production/ledger/readiness invariant：',
  '',
  '- curated=' + invariants.curatedCount + '，promoted=' + invariants.promotedCount + '，remaining=' + invariants.remainingCount + '，applicationReady=' + invariants.applicationReady,
  '- p137/p161 不在 curated、Full 或 promoted ledger，readiness state 均为 not-promoted',
  '- review generator 只写 review JSON/MD 两个输出，不写 production、ledger、readiness、alias 或 canonical 文件',
  '',
  '## 风险',
  '',
  '- p137 alias 会把购物清单中的“子公鸡”规范显示为“鸡肉”，并复用现有 chicken family sibling match；这是可接受但必须明确记录的产品语义取舍。',
  '- p161 若误用鸡肉/鸭血 alias，会分别造成跨组织或跨物种库存、推荐、购物清单误匹配；因此只能走独立 canonical 路径。',
  '- 两条都不应借 runtime-name review 顺便修改单位换算、family 定义或其他 8 道 blocker。',
  '',
].join('\n');

const jsonPath = path.join(repoRoot, output.writeTargets[0]);
const mdPath = path.join(repoRoot, output.writeTargets[1]);
fs.writeFileSync(jsonPath, JSON.stringify(output, null, 2) + '\n');
fs.writeFileSync(mdPath, markdown);

console.log('Wrote ' + jsonPath);
console.log('Wrote ' + mdPath);
console.log('recommendations: ' + items.map((item) => item.entryId + '=' + item.recommendation).join(', '));
console.log('verificationProblems: ' + problems.length);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
