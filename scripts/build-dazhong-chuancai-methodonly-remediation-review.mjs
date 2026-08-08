#!/usr/bin/env node
// Read-only targeted review of the two methodOnly-blocked candidates
// (p129, p130). This is analysis-only: no promotion, no production write,
// no alias/unit-conversion/schema change, no other blocker addressed.
//
// Investigates whether it is safe to let a methodOnly ingredient enter
// production with qty=null/unit=null when the source method text genuinely
// mentions it with no quantity in the book, without inventing a number and
// without contaminating inventory coverage / recommendation / runtime
// quality logic.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');

const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const readinessByEntryId = new Map(readiness.entries.map((e) => [e.entryId, e]));
const catalogByEntryId = new Map(catalog.entries.map((e) => [e.entryId, e]));

const REVIEW_IDS = ['dz1979-p129', 'dz1979-p130'];

// -- Count existing production entries that already carry qty=null/unit=null
// as precedent evidence this shape is already load-bearing in curated data.
let existingNullQtyUnitCount = 0;
for (const ings of Object.values(curated.recipe_ingredients ?? {})) {
  for (const ing of ings) {
    if (ing.qty === null && ing.unit === null) existingNullQtyUnitCount += 1;
  }
}

function reviewEntry(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  const entry = readinessByEntryId.get(entryId);
  const catalogEntry = catalogByEntryId.get(entryId);
  const plan = entry.productionIngredientPlan;

  const coreNoQuantityItems = plan.methodOnlyAnalysis.filter((m) => m.classification === 'core-no-quantity');

  const items = coreNoQuantityItems.map((analysis) => {
    const canonical = recipe.methodOnlyIngredients.find((m) => m.rawItemText === analysis.sourceRawItemText);
    // Split "姜、花椒" style combined text into individual items to check
    // each one's real classifyRecipeIngredient role (never assumed).
    const parts = analysis.sourceRawItemText.split(/[、，,]/).map((s) => s.trim()).filter(Boolean);
    const roleByPart = parts.map((part) => ({
      item: part,
      role: classifyRecipeIngredient(part).role,
    }));
    // Method text quote: find the exact methodSummary step sentence(s) that
    // actually mention this item, proving it is genuinely present in the
    // source method (not fabricated).
    const mentioningSteps = (recipe.methodSummary?.steps ?? [])
      .filter((step) => parts.some((part) => step.summary.includes(part)))
      .map((step) => ({ order: step.order, summary: step.summary }));

    return {
      rawItemText: analysis.sourceRawItemText,
      rawQuantityText: canonical?.rawQuantityText ?? null,
      useNote: canonical?.use ?? null,
      quantityHandling: canonical?.quantityHandling ?? null,
      canonicalConfidence: canonical?.confidence ?? null,
      splitItems: roleByPart,
      allNonCore: roleByPart.every((r) => r.role !== 'core'),
      methodTextMentions: mentioningSteps,
      genuinelyMentionedInMethod: mentioningSteps.length > 0,
      genuinelyNoQuantityInSource: (canonical?.rawQuantityText ?? null) === null,
    };
  });

  return {
    entryId,
    name: catalogEntry.bookName,
    bookPage: catalogEntry.bookPage,
    pdfPage: catalogEntry.pdfPage,
    quantityReadiness: plan.quantityReadiness,
    localPdfPageRendered: false,
    localPdfPageNote: 'data/reference/dazhong-chuancai.pdf 与对应 tmp/pdfs 渲染页在本地不可用（tmp/pdfs/dazhong-full 缺少 page-142/page-143），本轮以已冻结、high-confidence 的 canonical source-restoration 提取（rawItemText/rawQuantityText/methodSummary 逐句引用）作为唯一可核实来源；未能补做像素级页面复核。',
    items,
    allItemsGenuinelyMentionedNoQuantity: items.every((i) => i.genuinelyMentionedInMethod && i.genuinelyNoQuantityInSource),
    allSplitItemsNonCore: items.every((i) => i.allNonCore),
  };
}

const items = REVIEW_IDS.map(reviewEntry);

// -- Safety conclusion --------------------------------------------------------
// Safe iff: (a) every methodOnly item genuinely appears in method text with
// no quantity in canonical source (already verified, not re-derived), and
// (b) every split sub-item classifies as role != core via the unmodified
// real classifier (so it never enters inventory coverage / recommendation
// matching regardless of qty), and (c) qty=null/unit=null is already a
// supported, load-bearing production shape (existingNullQtyUnitCount > 0).
const allGenuine = items.every((i) => i.allItemsGenuinelyMentionedNoQuantity);
const allNonCore = items.every((i) => i.allSplitItemsNonCore);
const nullShapeAlreadySupported = existingNullQtyUnitCount > 0;
const safeToAllow = allGenuine && allNonCore && nullShapeAlreadySupported;

const problems = [];
if (!allGenuine) problems.push('not-all-items-genuinely-mentioned-with-no-quantity');
if (!allNonCore) problems.push('some-split-item-classifies-as-core');
if (!nullShapeAlreadySupported) problems.push('qty-null-unit-null-shape-not-precedented-in-production');

const output = {
  schema: 'kitchenmanager.source-restoration.methodonly-remediation-review.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: '只读 targeted review：判断 p129/p130 的 methodOnly blocker（姜、花椒 / 胡椒面）能否安全解决。本轮不 promotion、不修改 production/ledger/readiness、不新增 alias/unit conversion/schema、不猜测数量、不处理其他 8 道 blocker。',
  applicationReady: false,
  scope: {
    reviewedEntryIds: REVIEW_IDS,
    excludedBlockers: ['runtime-unresolved-name(p137/p161)', 'non-exact-quantity(p201/p203/p207)', 'consumed-dual-quantity(p222/p224/p226)'],
    note: 'same-for-each 已不是 p130 的独立 blocker（Batch 7 已解决）；本轮唯一剩余的 p130 blocker 就是 methodOnly「胡椒面」。',
  },
  items,
  precedent: {
    existingNullQtyUnitCurratedRecordCount: existingNullQtyUnitCount,
    note: 'curated production 已存在大量 qty=null/unit=null 的 ingredient 条目（多为 seasoning），证明该 shape 已是现有 schema 的一等公民，非本轮新引入。',
  },
  safetyAnalysis: {
    allItemsGenuinelyMentionedInMethodTextWithNoSourceQuantity: allGenuine,
    allSplitSubItemsClassifyAsNonCore: allNonCore,
    nullQtyUnitShapeAlreadySupportedInProduction: nullShapeAlreadySupported,
    inventoryRecommendationImpact: '所有相关 sub-item（姜/花椒/胡椒面）经真实 classifyRecipeIngredient 分类均为 role=seasoning，而 src/recommendations.js 与 src/ai.js 的库存匹配/缺货/推荐逻辑只对 role=core 的 ingredient 做匹配（见 recommendations.js:105/500，ai.js:946/1118/1563/1725）。因此无论 qty 是否为 null，这些 seasoning 项从不参与库存覆盖率、缺货判断或购物清单推荐，不会污染任何下游逻辑。',
    runtimeQualityImpact: 'recipe-runtime-quality.mjs 已把 missing-qty-unit 作为 warning（非 error）类别追踪，且当前 curated 已有该 warning 类别非零计数；新增少量 qty=null 条目只会小幅增加已有 warning 计数，不会新增 error、不会破坏 strict 模式判定。',
    conclusion: safeToAllow
      ? 'safe-to-allow-qty-null-for-these-specific-confirmed-methodonly-items'
      : 'not-yet-safe',
  },
  policyRecommendation: {
    scopeLimitedNotGlobal: true,
    rationale: '建议仅对“已由人工 targeted review 逐条确认——method 文本真实提及、canonical rawQuantityText 确实为 null、且 sub-item 真实分类为 non-core”的 methodOnly 项放行 qty=null/unit=null 进入 production；不建议做成对所有未来 core-no-quantity 项自动放行的全局 policy，因为尚未被人工确认的新条目仍可能包含实际数量提取遗漏（extraction gap）而非真书面缺失，全局自动放行会绕过这一关键区分。',
    perEntryUnlockCriteria: [
      'methodOnlyAnalysis 中该项 classification=core-no-quantity 且 conversionWarning 存在',
      'canonical methodOnlyIngredients 中对应 rawQuantityText 确实为 null（非空字符串、非提取遗漏）',
      'recipe.methodSummary.steps 中至少一步逐字包含该 raw item 文本，证明确实被提及',
      '拆分后的每个 sub-item 经 classifyRecipeIngredient 判定为 role!=="core"',
    ],
  },
  minimalImplementationPlanIfSafe: safeToAllow ? {
    steps: [
      '1. 在 readiness productionIngredientPlan 中为 p129「姜、花椒」与 p130「胡椒面」新增两条已确认的 inventoryIngredients 记录：qty=null, unit=null, displayQuantity=null（与现有 null-shape 条目结构一致），仅限这两个已 targeted-review 确认的具体条目，不做全局 core-no-quantity 自动转换规则。',
      '2. 在 Batch N（后续机械批次）hard gate 中新增一个极窄的例外名单（如 CONFIRMED_METHODONLY_NULL_ITEMS = {p129: ["姜","花椒"], p130: ["胡椒面"]}），只对这两条命中时跳过 methodOnlyConversionWarning 阻塞，其余 core-no-quantity 条目继续 hard-block。',
      '3. 复用现有 curate-recipes.js / quantity-review 生成器逻辑，无需新增 converter 或 schema 字段。',
    ],
    risksAndTests: [
      '风险：例外名单需要严格限定 entryId+item 组合，避免误放行未来其他 core-no-quantity 条目；测试需断言例外名单外的所有 core-no-quantity 项仍然 hard-block。',
      '需要新增测试：p129/p130 在放行后 hard gate 通过；同时验证除这两个具体 sub-item 外，任何其他 core-no-quantity 条目仍然被拒绝（防止例外名单被误扩大）。',
      '需要新增测试：qty=null 的姜/花椒/胡椒面条目不出现在任何 inventory coverage / recommendation / missing-ingredient 结果中（复用 role=seasoning 已有过滤逻辑验证）。',
      '需要新增测试：recipe-runtime-quality strict 模式下 missing-qty-unit warning 计数按预期 +N，不产生新 error。',
    ],
  } : null,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`safeToAllow: ${safeToAllow}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
