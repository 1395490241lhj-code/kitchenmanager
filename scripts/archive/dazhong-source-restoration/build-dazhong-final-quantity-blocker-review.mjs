#!/usr/bin/env node
// Builds the final read-only quantity-blocker review for the six remaining
// 《大众川菜》1979 candidates. Visual scan findings are frozen evidence; all
// canonical/readiness/runtime roles and production invariants are re-derived.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { classifyRecipeIngredient } from '../../../src/utils/recipe-sanitizer.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));

const BASELINE = '24c6d4a4a7f4bbcff3feba63e833007bc91602a3';
const DATE = '2026-08-08';
const PDF = '/Users/lianghongjing/Documents/大众川菜 (刘建成等编) (Z-Library).pdf';
const REVIEW_IDS = ['dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226'];
const NONEXACT_IDS = REVIEW_IDS.slice(0, 3);
const CONSUMED_IDS = REVIEW_IDS.slice(3);
const SCAN = {
  'dz1979-p201': { pdfPage: 214, bookPage: 201, quote: '花椒 十余粒' },
  'dz1979-p203': { pdfPage: 216, bookPage: 203, quote: '花椒 十余粒' },
  'dz1979-p207': { pdfPage: 220, bookPage: 207, quote: '花椒 十余粒' },
  'dz1979-p222': { pdfPage: 235, bookPage: 222, quote: '菜油 一斤耗二两' },
  'dz1979-p224': { pdfPage: 237, bookPage: 224, quote: '菜油 一斤耗二两' },
  'dz1979-p226': { pdfPage: 239, bookPage: 226, quote: '菜油 一斤耗二两；干豆粉 一斤耗四两' },
};

const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const recipeById = new Map(recipes.recipes.map((entry) => [entry.entryId, entry]));
const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
const catalogById = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));

let nullQtyUnitPrecedentCount = 0;
for (const ingredients of Object.values(curated.recipe_ingredients ?? {})) {
  nullQtyUnitPrecedentCount += ingredients.filter((item) => item.qty === null && item.unit === null).length;
}

function sourceEvidence(entryId) {
  const catalogEntry = catalogById.get(entryId);
  return {
    originalPdf: PDF,
    pdfPage: SCAN[entryId].pdfPage,
    bookPage: SCAN[entryId].bookPage,
    scanQuote: SCAN[entryId].quote,
    visuallyConfirmed: true,
    matchesCanonical: catalogEntry.pdfPage === SCAN[entryId].pdfPage
      && catalogEntry.bookPage === SCAN[entryId].bookPage,
    canonicalSourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    readinessSourceFile: 'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
  };
}

function reviewNonExact(entryId) {
  const recipe = recipeById.get(entryId);
  const entry = readinessById.get(entryId);
  const sourceIngredient = recipe.ingredients.find((ingredient) => ingredient.rawItemText === '花椒');
  const planIngredient = entry.productionIngredientPlan.inventoryIngredients
    .find((ingredient) => ingredient.productionItem === '花椒');
  const role = classifyRecipeIngredient('花椒');
  return {
    entryId,
    name: recipe.bookName,
    blockerType: 'non-exact-quantity',
    sourceEvidence: sourceEvidence(entryId),
    quantityStructure: {
      rawItemText: sourceIngredient.rawItemText,
      rawQuantityText: sourceIngredient.rawQuantityText,
      normalizedQuantity: sourceIngredient.normalizedQuantity,
      readinessProjection: planIngredient,
    },
    runtimeRole: role,
    downstreamImpact: {
      inventoryCoverage: 'none: classifyRecipeIngredient role=seasoning is excluded from core coverage',
      missingIngredients: 'none: missing calculation iterates core ingredients only',
      recommendations: 'none: score and target matching use core ingredients only',
      shopping: 'none: recipe shortfall shopping is derived from missing core ingredients',
      runtimeQuality: 'adds one existing missing-qty-unit warning; no error',
    },
    recommendation: 'allow-reviewed-nonexact-null',
    productionProjection: { item: '花椒', qty: null, unit: null },
    safeToUnlock: sourceIngredient.rawQuantityText === '十余粒'
      && sourceIngredient.normalizedQuantity.kind === 'approximate-count'
      && sourceIngredient.normalizedQuantity.qty === null
      && role.role === 'seasoning'
      && planIngredient.qty === null
      && planIngredient.unit === null,
    schemaExtensionNeeded: false,
    displayTradeoff: 'production does not retain/display “十余粒”; canonical and review provenance retain it',
  };
}

function reviewConsumed(entryId) {
  const recipe = recipeById.get(entryId);
  const dualIngredients = recipe.ingredients.filter((ingredient) => {
    const quantity = ingredient.normalizedQuantity ?? {};
    return 'consumedQty' in quantity || 'consumedReferenceQty' in quantity
      || 'consumedQualifier' in quantity || 'consumedUnit' in quantity;
  });
  const pairs = dualIngredients.map((ingredient) => ({
    item: ingredient.rawItemText,
    rawQuantityText: ingredient.rawQuantityText,
    input: { qty: ingredient.normalizedQuantity.qty, unit: ingredient.normalizedQuantity.unit },
    consumed: {
      qty: ingredient.normalizedQuantity.consumedQty ?? null,
      referenceQty: ingredient.normalizedQuantity.consumedReferenceQty ?? null,
      qualifier: ingredient.normalizedQuantity.consumedQualifier ?? null,
      unit: ingredient.normalizedQuantity.consumedUnit ?? null,
    },
    runtimeRole: classifyRecipeIngredient(ingredient.rawItemText),
  }));
  return {
    entryId,
    name: recipe.bookName,
    blockerType: 'consumed-dual-quantity',
    sourceEvidence: sourceEvidence(entryId),
    quantityStructure: pairs,
    downstreamImpact: {
      productionContract: 'current ingredient shape has only item/qty/unit',
      inventoryCoverage: 'single qty/unit is interpreted as the full required amount for core ingredients',
      missingIngredients: 'shortfall is computed from that same single required amount',
      recommendations: 'coverage and score inherit the same single required amount',
      shopping: 'missing quantity is copied from the same single required amount',
    },
    options: {
      A: { proposal: 'store-input-qty', risk: 'consumed amount disappears from production and the one number is treated as the full requirement' },
      B: { proposal: 'store-consumed-qty', risk: 'input/frying/coating amount disappears and purchasing may be understated' },
      C: { proposal: 'store-null-with-source-provenance', risk: 'avoids choosing a false single value but removes structured quantity; unsafe for core 干豆粉 in p226' },
      D: { proposal: 'extend-production-schema', risk: 'lowest-loss future design, but requires an explicit consumer contract for input versus consumed fields' },
      E: { proposal: 'continue-blocked', risk: 'no production behavior change and no semantic loss' },
    },
    recommendation: 'continue-blocked-until-dual-quantity-contract',
    safeToUnlock: false,
    schemaExtensionNeeded: true,
  };
}

const items = [...NONEXACT_IDS.map(reviewNonExact), ...CONSUMED_IDS.map(reviewConsumed)];
const reviewedNonExactNullAllowlist = Object.fromEntries(NONEXACT_IDS.map((id) => [id, ['花椒']]));
const promotedIds = new Set((ledger.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.entryId)));
const productionInvariants = {
  curatedCount: curated.recipes.length,
  fullCount: full.recipes.length,
  promotedCount: readiness.summary.promotedNewRecipeCount,
  remainingCount: readiness.summary.remainingNewRecipeCandidateCount,
  applicationReady: readiness.applicationReady,
  reviewedIdsAbsentFromCurated: REVIEW_IDS.every((id) => !curated.recipes.some((recipe) => recipe.id === id)),
  reviewedIdsAbsentFromFull: REVIEW_IDS.every((id) => !full.recipes.some((recipe) => recipe.id === id)),
  reviewedIdsAbsentFromLedger: REVIEW_IDS.every((id) => !promotedIds.has(id)),
};
const safeToAllow = items.filter((item) => item.blockerType === 'non-exact-quantity').every((item) => item.safeToUnlock);
const problems = [];
if (!safeToAllow) problems.push('nonexact-review-not-safe');
if (items.filter((item) => item.blockerType === 'consumed-dual-quantity').some((item) => item.safeToUnlock)) problems.push('consumed-dual-unexpectedly-safe');
if (items.some((item) => !item.sourceEvidence.matchesCanonical)) problems.push('scan-page-mismatch');
if (productionInvariants.curatedCount !== 159) problems.push('curated-count:' + productionInvariants.curatedCount);
if (productionInvariants.promotedCount !== 33 || productionInvariants.remainingCount !== 6) problems.push('readiness-count-drift');
if (!productionInvariants.reviewedIdsAbsentFromCurated || !productionInvariants.reviewedIdsAbsentFromFull || !productionInvariants.reviewedIdsAbsentFromLedger) problems.push('reviewed-id-already-in-production');

const output = {
  schema: 'kitchenmanager.source-restoration.final-quantity-blocker-review.v1',
  generatedAt: DATE,
  generator: 'scripts/build-dazhong-final-quantity-blocker-review.mjs',
  baseline: { commit: BASELINE, curated: 159, promoted: 33, remaining: 6, applicationReady: false },
  purpose: 'Final read-only review of the six remaining quantity blockers. No promotion or consumed-dual remediation.',
  scope: { reviewedEntryIds: REVIEW_IDS, originalPdf: PDF },
  downstreamCodePaths: [
    'src/utils/recipe-sanitizer.js: classifyRecipeIngredient role',
    'src/inventory.js: getStockCoverageAnalysis single qty/unit',
    'src/recommendations.js: core-only coverage/missing/recommendation/shopping shortfall',
    'src/shopping.js: single qty/unit merge and add semantics',
    'scripts/recipe-runtime-quality.mjs: missing qty/unit is warning-only',
  ],
  productionInvariants,
  precedent: { curatedNullQtyUnitRecordCount: nullQtyUnitPrecedentCount, shapeSupported: nullQtyUnitPrecedentCount > 0 },
  lunaWorkerEvidence: {
    role: 'auxiliary-independent-read-only-audit',
    nonExactConclusion: 'scan-authentic; 花椒 is seasoning; exact entryId+item null/null allowlist is safe',
    consumedDualConclusion: 'A/B/C each loses or misstates semantics; D is the only lossless future direction; E is lowest risk now',
    authoritativeDecision: 'main-agent-independent-scan-and-code-review',
  },
  reviewedNonExactNullAllowlist,
  safeToAllow,
  items,
  conclusion: {
    nonExact: 'safe-to-unlock-only-the-three-reviewed-(entryId,花椒)-pairs-as-qty-null-unit-null',
    consumedDual: 'keep-p222-p224-p226-hard-blocked; do not implement in this round',
    schemaExtension: 'not needed for reviewed non-exact null projection; needed before lossless consumed-dual production support',
  },
  writeTargets: [
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.md',
  ],
  verificationProblems: problems,
};

const rows = items.map((item) => `| ${item.entryId} | ${item.name} | ${item.sourceEvidence.scanQuote} | ${item.blockerType} | ${item.safeToUnlock} | ${item.schemaExtensionNeeded} | ${item.recommendation} |`).join('\n');
const markdown = `# 《大众川菜》1979 final quantity blocker review\n\n` +
  `生成日期：${DATE}\nBaseline：${BASELINE}\n范围：最后 6 道；只读 review，不 promotion。\n\n` +
  `## 结论\n\n- p201/p203/p207：扫描原文均为“花椒 十余粒”，真实 role=seasoning；只允许逐条 (entryId,花椒) 以 qty=null/unit=null 解锁，不猜数字，不扩 schema。\n` +
  `- p222/p224/p226：“一斤耗二两/四两”同时表达 input 与 consumed。当前单 qty/unit 无法无损承载；本轮继续 hard-block，未来只有明确双量 schema 与 consumer contract 后再处理。\n` +
  `- luna_worker 是辅助独立审计；最终结论由主代理复核 canonical、原扫描和真实下游代码后作出。\n\n` +
  `## 逐道证据与处置\n\n| entryId | 菜名 | 扫描证据 | blocker | safeToUnlock | schemaExtension | 推荐 |\n| --- | --- | --- | --- | ---: | ---: | --- |\n${rows}\n\n` +
  `## 最小 allowlist\n\n- (dz1979-p201, 花椒)\n- (dz1979-p203, 花椒)\n- (dz1979-p207, 花椒)\n\n` +
  `## 下游判断\n\nnon-exact 花椒经真实 classifier 为 seasoning，不进入核心库存覆盖、缺货、推荐或菜谱缺货购物；null/null 只增加已有 runtime-quality warning。consumed-dual 的 production 单 qty/unit 会被核心库存、缺货、推荐和购物共同当作唯一需求量，不能混用 input 与 consumed。\n\n` +
  `## 保护\n\nreview 生成前 production invariant：curated=${productionInvariants.curatedCount}、Full=${productionInvariants.fullCount}、promoted=${productionInvariants.promotedCount}、remaining=${productionInvariants.remainingCount}、applicationReady=${productionInvariants.applicationReady}。generator 只写本 review JSON/MD。\n`;

fs.writeFileSync(path.join(repoRoot, output.writeTargets[0]), JSON.stringify(output, null, 2) + '\n');
fs.writeFileSync(path.join(repoRoot, output.writeTargets[1]), markdown);
console.log('Wrote final quantity blocker review JSON/MD');
console.log('safeToAllow: ' + safeToAllow);
console.log('verificationProblems: ' + problems.length);
if (problems.length) process.exitCode = 1;
