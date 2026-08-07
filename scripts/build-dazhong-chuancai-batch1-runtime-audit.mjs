#!/usr/bin/env node
// Audits the Batch 1 promoted recipes against the real inventory / recipe
// canonicalization pipeline. READ-ONLY: no production or runtime files are
// modified. Every audited ingredient gets exactly one compatibility result:
//   exact-compatible | expected-unit-confirmation | unresolved-name-match

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  INGREDIENT_FAMILIES,
  getCanonicalName,
  getIngredientFamilyCandidates,
  getIngredientFamilyKey,
  getIngredientMatchNames,
  guessKitchenUnit,
  isSmartIngredientMatch,
  normalizeIngredientAmount,
} from '../src/ingredients.js';
import { getStockCoverageAnalysis } from '../src/inventory.js';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const curated = readJson('data/sichuan-recipes.curated.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-quantity-review.v1.json');

const promotedIds = new Set(
  (ledger.batches ?? []).flatMap((batch) => (
    (batch.entries ?? []).map((entry) => entry.productionId)
  )),
);
const quantityReviewByKey = new Map(
  (quantityReview.records ?? []).map((record) => [
    `${record.productionId}:${record.item}`,
    record,
  ]),
);

// User-realistic poultry stock names for chicken-like items; the recipe
// ingredient itself may not canonicalize to any of these.
const POULTRY_PROBES = ['鸡肉', '仔鸡', '母鸡', '老母鸡', '土鸡', '公鸡', '三黄鸡'];

function userRealisticProbes(item) {
  const canonical = getCanonicalName(item);
  const probes = new Set();
  if (canonical) probes.add(canonical);
  for (const name of getIngredientMatchNames(item)) {
    if (name) probes.add(name);
  }
  const familyKey = getIngredientFamilyKey(item);
  if (familyKey) {
    for (const candidate of getIngredientFamilyCandidates(item, { includeBroad: true })) {
      if (candidate) probes.add(candidate);
    }
  }
  // Any family whose names overlap the item get their broad/member names too.
  for (const group of Object.values(INGREDIENT_FAMILIES)) {
    const familyNames = [...(group.broad || []), ...(group.members || [])];
    if (familyNames.some((name) => name === item || name === canonical)) {
      for (const name of familyNames) probes.add(name);
    }
  }
  if (item.includes('鸡') || canonical.includes('鸡')) {
    for (const name of POULTRY_PROBES) probes.add(name);
  }
  probes.add(item); // identity probe, flagged separately
  return [...probes];
}

function simulateProbe(item, qty, unit, probeName, stockUnit) {
  const stock = [{ name: probeName, qty: 100, unit: stockUnit, stockStatus: 'ok' }];
  const analysis = getStockCoverageAnalysis(stock, item, qty, unit);
  return {
    probeName,
    strictNameMatch: isSmartIngredientMatch(item, probeName, { allowContains: false }),
    softNameMatch: isSmartIngredientMatch(item, probeName),
    coverageWithStockUnit: analysis.confidence,
  };
}

const coreCompatibility = [];
const nonCoreObservations = [];
for (const id of [...promotedIds].sort()) {
  const recipe = curated.recipes.find((entry) => entry.id === id);
  if (!recipe) throw new Error(`missing promoted recipe ${id}`);
  const ingredients = curated.recipe_ingredients[id] || [];
  for (const ingredient of ingredients) {
    const { item, qty, unit } = ingredient;
    const canonical = getCanonicalName(item);
    const role = classifyRecipeIngredient(item).role;
    const guessUnit = guessKitchenUnit(item);
    const familyKey = getIngredientFamilyKey(item);
    const quantityRecord = quantityReviewByKey.get(`${id}:${item}`);
    const probes = userRealisticProbes(item).map((probeName) => {
      const isIdentity = probeName === item || probeName === canonical;
      return {
        probeName,
        isIdentity,
        ...simulateProbe(item, qty, unit, probeName, unit),
        withDefaultUnit: simulateProbe(item, qty, unit, probeName, guessUnit).coverageWithStockUnit,
      };
    });

    const userProbes = probes.filter((probe) => !probe.isIdentity);
    const identityProbe = probes.find((probe) => probe.isIdentity);
    const isPoultryLike = item.includes('鸡') || canonical.includes('鸡');
    // Name resolution rules:
    //  - family items: a strict match against a user-realistic family name is
    //    required (the family is the user-facing vocabulary).
    //  - poultry-like items without a family: a common poultry name must
    //    strictly resolve, otherwise the recipe name is invisible to users.
    //  - other items: their canonical name is already user-facing vocabulary.
    const familyResolved = getIngredientFamilyKey(item)
      ? userProbes.some((probe) => probe.strictNameMatch)
      : true;
    const poultryResolved = isPoultryLike
      ? userProbes.some((probe) => probe.strictNameMatch)
      : true;
    const strictResolved = familyResolved && poultryResolved;
    const unitNatural = unit === 'g' || unit === guessUnit;
    const normalized = normalizeIngredientAmount(qty, unit);

    let compatibility = null;
    const reasons = [];
    const baseRecord = {
      productionId: id,
      recipeName: recipe.name,
      item,
      qty,
      unit,
      canonical,
      role,
      ingredientFamilyKey: familyKey || null,
      guessKitchenUnit: guessUnit,
      sourceRawQuantityText: quantityRecord?.sourceRawQuantityText ?? null,
      normalizedQuantitySource: quantityRecord?.normalizedQuantity ?? null,
      quantityProvenanceNote: quantityRecord
        ? `qty/unit 来自 source-restoration canonical 数量（raw「${quantityRecord.sourceRawQuantityText}」→ ${quantityRecord.normalizedQuantity.kind} ${quantityRecord.normalizedQuantity.qty}${quantityRecord.normalizedQuantity.unit ?? ''}），未经人工改值。`
        : null,
      normalizedQuantity: {
        qty: normalized.qty,
        unit: normalized.unit,
        finite: Number.isFinite(Number(normalized.qty)),
      },
    };

    if (role !== 'core') {
      // Seasoning / non-stock items never enter the inventory compatibility
      // classification; keep them only for quantity provenance.
      nonCoreObservations.push({
        ...baseRecord,
        observation: `role=${role}，不参与库存名称兼容三分类；qty/unit 仍受 quantity-review 质量门禁约束。`,
      });
      continue;
    }

    const canonicalProbe = probes.find((probe) => probe.isIdentity && probe.probeName === canonical);
    const evidenceProbes = canonicalProbe
      ? [canonicalProbe, ...userProbes]
      : [...userProbes];
    const exactEvidence = evidenceProbes.some((probe) => probe.coverageWithStockUnit === 'exact');

    if (!strictResolved) {
      compatibility = 'unresolved-name-match';
      const containsOnly = userProbes.filter((probe) => probe.softNameMatch && !probe.strictNameMatch)
        .map((probe) => probe.probeName);
      reasons.push('现有 canonicalization 无法把该 production item 解析到任何常见用户库存名称（严格名称层失败）。');
      if (containsOnly.length > 0) {
        reasons.push(`仅存在 contains 级脆弱匹配（不可靠）：${containsOnly.join('、')}。`);
      }
    } else if (!unitNatural) {
      compatibility = 'expected-unit-confirmation';
      reasons.push(`名称可解析，但 production unit「${unit}」与常用库存单位「${guessUnit}」无可安全换算，需用户按 production unit 录入库存或人工确认。`);
    } else if (exactEvidence) {
      compatibility = 'exact-compatible';
      reasons.push('名称严格可解析，且存在 production unit 下真实 getStockCoverageAnalysis=exact 的证据（非仅因 unit=g 判定）。');
    } else {
      compatibility = 'expected-unit-confirmation';
      reasons.push('名称可解析且 unit 自然，但缺少真实 coverage=exact 证据，需人工确认。');
    }

    coreCompatibility.push({
      ...baseRecord,
      identityMatch: identityProbe ? {
        probeName: identityProbe.probeName,
        coverageWithProductionUnit: identityProbe.coverageWithStockUnit,
      } : null,
      probes: evidenceProbes.map((probe) => ({
        probeName: probe.probeName,
        strictNameMatch: probe.strictNameMatch,
        softNameMatch: probe.softNameMatch,
        coverageWithProductionUnit: probe.coverageWithStockUnit,
        coverageWithDefaultUnit: probe.withDefaultUnit,
      })),
      compatibility,
      reasons,
    });
  }
}

const entries = coreCompatibility;

// -- Summary / verification -------------------------------------------------

const counts = {
  exactCompatible: 0,
  expectedUnitConfirmation: 0,
  unresolvedNameMatch: 0,
};
for (const entry of entries) {
  counts[{
    'exact-compatible': 'exactCompatible',
    'expected-unit-confirmation': 'expectedUnitConfirmation',
    'unresolved-name-match': 'unresolvedNameMatch',
  }[entry.compatibility]] += 1;
}

const affectedRecipes = [...new Set(
  entries
    .filter((entry) => entry.compatibility !== 'exact-compatible')
    .map((entry) => entry.productionId),
)].sort();

const unresolvedDetails = entries
  .filter((entry) => entry.compatibility === 'unresolved-name-match')
  .map((entry) => ({
    productionId: entry.productionId,
    item: entry.item,
    failedPairs: entry.probes
      .filter((probe) => !probe.softNameMatch)
      .map((probe) => `${entry.item} vs ${probe.probeName}`),
  }));

const problems = [];
const coreRoleCount = coreCompatibility.length;
const nonCoreRoleCount = nonCoreObservations.length;
if (coreRoleCount + nonCoreRoleCount !== 19) {
  problems.push(`audited-count-not-19:${coreRoleCount + nonCoreRoleCount}`);
}
if (coreRoleCount !== 7) problems.push(`core-count-not-7:${coreRoleCount}`);
if (nonCoreRoleCount !== 12) problems.push(`non-core-count-not-12:${nonCoreRoleCount}`);
if (counts.exactCompatible !== 5) problems.push(`exact-count-not-5:${counts.exactCompatible}`);
if (counts.expectedUnitConfirmation !== 2) {
  problems.push(`unit-confirm-count-not-2:${counts.expectedUnitConfirmation}`);
}
if (counts.unresolvedNameMatch !== 0) {
  problems.push(`unresolved-count-not-0:${counts.unresolvedNameMatch}`);
}
if (entries.some((entry) => entry.normalizedQuantity.finite === false)) {
  problems.push('non-finite-normalized-quantity');
}
const allEntries = [...coreCompatibility, ...nonCoreObservations];
const recipesWithResults = new Set(allEntries.map((entry) => entry.productionId));
if (recipesWithResults.size !== 5) problems.push(`recipes-covered-not-5:${recipesWithResults.size}`);
if (!entries.every((entry) => ['exact-compatible', 'expected-unit-confirmation', 'unresolved-name-match'].includes(entry.compatibility))) {
  problems.push('invalid-compatibility-value');
}
const nonCoreInClassification = nonCoreObservations.length;
if (nonCoreInClassification > 0 && nonCoreObservations.some((entry) => entry.compatibility)) {
  problems.push('non-core-entry-with-compatibility');
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch1-runtime-audit.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  baselineCommit: '4305bcd52c4247e2cc0e154c09f18e63166ee4c2',
  purpose: '审计 Batch 1 正式上线后的真实库存/推荐兼容性：对 5 道全部 production ingredient，经现有 canonicalization（getCanonicalName / aliases / families / isSmartIngredientMatch）与库存匹配（getStockCoverageAnalysis）模拟用户库存名称/单位行为。只审计，不修改 production/runtime。',
  compatibilityDefinitions: {
    'exact-compatible': 'core ingredient：名称严格可解析，production unit 为该食材自然单位（g 或 guessKitchenUnit），且存在真实 getStockCoverageAnalysis=exact 证据（不因 unit=g 单独判定）。',
    'expected-unit-confirmation': '名称可解析，但 production unit 与常用库存单位无可安全换算，需要用户按 production unit 录入或人工确认；不是 bug，禁止新增换算。',
    'unresolved-name-match': '现有 canonicalization 无法把 production item 解析到常见用户库存名称；需记录具体 name pair，本轮不新增 alias。',
  },
  scopeNote: 'compatibility 三分类只应用于 role=core 的 ingredient（库存/推荐仅对 core 做匹配）；seasoning/non-stock 归入 nonCoreObservations，仅保留 quantity provenance，不计入三分类或 Batch2 gate。',
  batch2GateRules: [
    '只检查 candidate 的 core ingredients。',
    '任何 core unresolved-name-match 阻塞 promotion。',
    'core expected-unit-confirmation 不阻塞，但必须记录。',
    'seasoning 不参与库存名称兼容 gate，但 qty/unit 仍受已有 quantity-review 质量门禁约束。',
  ],
  summary: {
    auditedIngredientCount: coreCompatibility.length + nonCoreObservations.length,
    coreIngredientCount: coreRoleCount,
    nonCoreIngredientCount: nonCoreRoleCount,
    coreCompatibilityCounts: {
      'exact-compatible': counts.exactCompatible,
      'expected-unit-confirmation': counts.expectedUnitConfirmation,
      'unresolved-name-match': counts.unresolvedNameMatch,
    },
    affectedRecipes,
    unresolvedDetails,
    roleBreakdown: {
      core: coreRoleCount,
      seasoning: nonCoreObservations.filter((entry) => entry.role === 'seasoning').length,
      'non-stock': nonCoreObservations.filter((entry) => entry.role === 'non-stock').length,
    },
  },
  coreCompatibility,
  nonCoreObservations,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch1-runtime-audit.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`counts: exact=${counts.exactCompatible} unit-confirm=${counts.expectedUnitConfirmation} unresolved=${counts.unresolvedNameMatch}`);
console.log(`affectedRecipes: ${affectedRecipes.join(', ')}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
