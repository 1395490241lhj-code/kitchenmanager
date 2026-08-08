#!/usr/bin/env node
// Builds a read-only triage of the twelve remaining not-promoted
// new-recipe-candidates blocked by Batch 1's frozen hard gates and/or the
// Batch 2+ runtime name gate. This is analysis-only: no production file is
// modified, no alias/unit-conversion/schema is added, and no candidate is
// promoted.
//
// Every blocker classification below is derived mechanically from three
// already-frozen sources:
//   - data/source-restoration/dazhong-chuancai-1979-recipes.v1.json (canonical
//     ingredients / normalizedQuantity / methodOnlyIngredients)
//   - data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json
//     (productionIngredientPlan, quantityReadiness)
//   - scripts/dazhong-runtime-compatibility.mjs (real inventory/recipe
//     canonicalization pipeline, unchanged)
//
// No new heuristic is introduced to decide "safe to fix"; this script only
// aggregates existing facts and applies documented, conservative decision
// rules to each blocker category.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { classifyIngredientCompatibility } from './dazhong-runtime-compatibility.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const batch6DryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');

const catalogByEntryId = new Map(catalog.entries.map((e) => [e.entryId, e]));
const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const readinessByEntryId = new Map(readiness.entries.map((e) => [e.entryId, e]));

// -- Mechanically recompute the current remaining candidate pool -----------
// (must equal readiness.summary.remainingNewRecipeCandidateCount = 12).

const remainingEntries = readiness.entries.filter((e) => (
  e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
));
const remainingIds = remainingEntries.map((e) => e.entryId).sort();

if (remainingIds.length !== readiness.summary.remainingNewRecipeCandidateCount) {
  throw new Error(
    `remaining count mismatch: recomputed=${remainingIds.length} `
    + `!= readiness.summary.remainingNewRecipeCandidateCount=${readiness.summary.remainingNewRecipeCandidateCount}`,
  );
}

// -- Per-entry runtime core-compatibility audit (read-only) ----------------

function auditRuntime(entryId) {
  const entry = readinessByEntryId.get(entryId);
  const coreResults = [];
  for (const ing of entry.productionIngredientPlan.inventoryIngredients) {
    const result = classifyIngredientCompatibility(ing.productionItem, ing.qty, ing.unit);
    if (result.role === 'core') {
      coreResults.push({
        item: ing.productionItem,
        qty: ing.qty,
        unit: ing.unit,
        compatibility: result.compatibility,
        reasons: result.reasons,
      });
    }
  }
  const unresolved = coreResults.filter((r) => r.compatibility === 'unresolved-name-match');
  const unitConfirmation = coreResults.filter((r) => r.compatibility === 'expected-unit-confirmation');
  return {
    coreCount: coreResults.length,
    exactCompatibleCount: coreResults.filter((r) => r.compatibility === 'exact-compatible').length,
    unresolvedItems: unresolved.map((r) => r.item),
    unitConfirmationItems: unitConfirmation.map((r) => r.item),
    blocked: unresolved.length > 0,
    coreResults,
  };
}

// -- Per-blocker-category structural facts (from canonical + readiness) ----

function structuralFacts(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  const entry = readinessByEntryId.get(entryId);
  const plan = entry.productionIngredientPlan;

  const sameForEachIngredients = recipe.ingredients
    .filter((ing) => ing.memberQuantityMode === 'same-for-each')
    .map((ing) => ({
      rawItemText: ing.rawItemText,
      rawQuantityText: ing.rawQuantityText,
      members: (ing.members ?? []).map((m) => m.item),
      normalizedQuantity: ing.normalizedQuantity,
    }));

  const nonExactIngredients = recipe.ingredients
    .filter((ing) => !['exact-mass', 'exact-count'].includes(ing.normalizedQuantity?.kind))
    .map((ing) => ({
      rawItemText: ing.rawItemText,
      rawQuantityText: ing.rawQuantityText,
      normalizedQuantity: ing.normalizedQuantity,
      inventoryComparable: plan.inventoryIngredients
        .find((p) => p.sourceRawItemText === ing.rawItemText)?.inventoryComparable ?? null,
      displayQuantity: plan.inventoryIngredients
        .find((p) => p.sourceRawItemText === ing.rawItemText)?.displayQuantity ?? null,
    }));

  const consumedDualQuantityIngredients = recipe.ingredients
    .filter((ing) => (
      'consumedQty' in (ing.normalizedQuantity ?? {})
      || 'consumedReferenceQty' in (ing.normalizedQuantity ?? {})
    ))
    .map((ing) => ({
      rawItemText: ing.rawItemText,
      rawQuantityText: ing.rawQuantityText,
      normalizedQuantity: ing.normalizedQuantity,
    }));

  const methodOnlyCoreNoQuantity = plan.methodOnlyAnalysis
    .filter((m) => m.classification === 'core-no-quantity')
    .map((m) => ({
      sourceRawItemText: m.sourceRawItemText,
      conversionWarning: m.conversionWarning,
      reason: m.reason,
    }));

  return {
    sameForEachIngredients,
    nonExactIngredients,
    consumedDualQuantityIngredients,
    methodOnlyCoreNoQuantity,
  };
}

// -- Per-entry blocker list (must union to the frozen Batch 6 hard-gate
//    exclusions + the frozen runtime-name-gate blocked list; verified below)

function blockersFor(entryId) {
  const facts = structuralFacts(entryId);
  const runtime = auditRuntime(entryId);
  const blockers = [];
  if (facts.methodOnlyCoreNoQuantity.length > 0) blockers.push('methodOnly');
  if (facts.sameForEachIngredients.length > 0) blockers.push('same-for-each');
  if (facts.nonExactIngredients.length > 0) blockers.push('non-exact-quantity');
  if (facts.consumedDualQuantityIngredients.length > 0) blockers.push('consumed-dual-quantity');
  if (runtime.blocked) blockers.push('runtime-unresolved-name');
  return blockers;
}

// -- Category-specific minimal-remediation reasoning ------------------------
// Each function returns { minimalRemediation, requiresAliasChange,
// requiresConversionChange, requiresSchemaChange, requiresHumanSourceReview,
// semanticRiskNote } for one blocker instance. No code change is applied
// here; this is a structured recommendation only.

function methodOnlyRemediation(facts) {
  return {
    minimalRemediation: 'human-source-review: confirm whether the book truly gives no quantity for these method-only items; if confirmed, either allow qty=null/unit=null production entries for core-no-quantity method-only ingredients (a conservative policy change, not a source reinterpretation) or leave them out of production ingredients entirely as today.',
    requiresAliasChange: false,
    requiresConversionChange: false,
    requiresSchemaChange: false,
    requiresHumanSourceReview: true,
    semanticRiskNote: 'Fabricating a qty/unit for an ingredient the book never quantifies would misrepresent the source; must stay display-only or reviewed.',
  };
}

function sameForEachRemediation(entryId, facts, otherBlockers) {
  const onlyBlocker = otherBlockers.length === 1 && otherBlockers[0] === 'same-for-each';
  return {
    minimalRemediation: onlyBlocker
      ? 'mechanical-gate-change: relax the Batch 1 hard gate to allow memberQuantityMode==="same-for-each" (keep unallocated-group-total blocked) — the same-for-each split logic already exists in scripts/build-dazhong-chuancai-promotion-readiness.mjs and is proven correct.'
      : `same-for-each alone would not unblock this entry; it is also blocked by: ${otherBlockers.filter((b) => b !== 'same-for-each').join(', ')}.`,
    requiresAliasChange: false,
    requiresConversionChange: false,
    requiresSchemaChange: false,
    requiresHumanSourceReview: false,
    semanticRiskNote: 'same-for-each split is lossless: "葱节、姜各三钱" becomes 葱节=15g and 姜=15g, exactly what the book states.',
  };
}

function nonExactRemediation(facts) {
  return {
    minimalRemediation: 'policy-decision: either (a) accept qty=null/unit=null for approximate-count items (loses the "十余粒" text but is honest, not fabricated) and promote with only the exact-comparable ingredients carrying real numbers, or (b) extend the curated ingredient schema with a display-only quantity field before promoting so "十余粒" is not silently dropped. Neither is a mechanical converter change.',
    requiresAliasChange: false,
    requiresConversionChange: false,
    requiresSchemaChange: true,
    requiresHumanSourceReview: false,
    semanticRiskNote: 'Converting "十余粒" (approximate) to any single number would misstate the source; current schema also cannot store the approximate text alongside null qty without a field addition.',
  };
}

function consumedDualRemediation(facts) {
  return {
    minimalRemediation: 'schema-or-policy-required: production ingredient schema needs either a second consumed-quantity field, or a documented policy on which of {input qty, consumed qty} the single qty field should represent for consumption-based (耗) ingredients, before this class of ingredient can promote without semantic loss.',
    requiresAliasChange: false,
    requiresConversionChange: false,
    requiresSchemaChange: true,
    requiresHumanSourceReview: false,
    semanticRiskNote: 'Single qty/unit cannot represent "500g bought, ~100g consumed" without silently discarding one of the two book-stated numbers.',
  };
}

function runtimeNameRemediation(entryId, item) {
  const riskNote = item === '子公鸡'
    ? '子公鸡 is a young-rooster-specific term; mapping it into the existing 鸡肉 family/POULTRY_PROBES list without review risks either under-matching (still unresolved) or over-broad matching if merged incorrectly with a different member.'
    : '鸡血 (chicken blood) is a distinct product category from all poultry meat family members and probes; forcing it into the chicken family risks cross-matching blood against meat stock or vice versa.';
  return {
    minimalRemediation: `targeted-review-required: decide whether "${item}" should be (a) added as its own new canonical/family entry (safest, no cross-contamination risk) or (b) mapped into an existing family/probe (needs explicit human confirmation the semantics match); either path is an alias/canonicalization change and is out of scope for this triage round.`,
    requiresAliasChange: true,
    requiresConversionChange: false,
    requiresSchemaChange: false,
    requiresHumanSourceReview: true,
    semanticRiskNote: riskNote,
  };
}

// -- Recommended disposition (one of the four allowed values) --------------

function recommendDisposition(blockers, remediations) {
  const needsSchema = remediations.some((r) => r.requiresSchemaChange);
  const needsAlias = remediations.some((r) => r.requiresAliasChange);
  const needsHumanReview = remediations.some((r) => r.requiresHumanSourceReview);
  const onlySameForEach = blockers.length === 1 && blockers[0] === 'same-for-each';

  if (onlySameForEach) return 'mechanical-fix-candidate';
  if (needsSchema) return 'schema-or-policy-required';
  if (needsAlias || needsHumanReview) return 'targeted-review-required';
  return 'keep-blocked';
}

// -- Build one triage item per remaining entry -------------------------------

const items = remainingEntries
  .slice()
  .sort((a, b) => a.entryId.localeCompare(b.entryId))
  .map((entry) => {
    const entryId = entry.entryId;
    const recipe = recipeByEntryId.get(entryId);
    const catalogEntry = catalogByEntryId.get(entryId);
    const facts = structuralFacts(entryId);
    const runtime = auditRuntime(entryId);
    const blockers = blockersFor(entryId);

    const remediations = [];
    if (blockers.includes('methodOnly')) remediations.push(methodOnlyRemediation(facts));
    if (blockers.includes('same-for-each')) {
      remediations.push(sameForEachRemediation(entryId, facts, blockers));
    }
    if (blockers.includes('non-exact-quantity')) remediations.push(nonExactRemediation(facts));
    if (blockers.includes('consumed-dual-quantity')) remediations.push(consumedDualRemediation(facts));
    if (blockers.includes('runtime-unresolved-name')) {
      for (const item of runtime.unresolvedItems) {
        remediations.push(runtimeNameRemediation(entryId, item));
      }
    }

    const requiresAliasChange = remediations.some((r) => r.requiresAliasChange);
    const requiresConversionChange = remediations.some((r) => r.requiresConversionChange);
    const requiresSchemaChange = remediations.some((r) => r.requiresSchemaChange);
    const requiresHumanSourceReview = remediations.some((r) => r.requiresHumanSourceReview);
    const recommendedDisposition = recommendDisposition(blockers, remediations);

    return {
      entryId,
      name: catalogEntry.bookName,
      category: catalogEntry.category,
      bookPage: catalogEntry.bookPage,
      blockers,
      sourceFacts: {
        sameForEachIngredients: facts.sameForEachIngredients,
        nonExactIngredients: facts.nonExactIngredients,
        consumedDualQuantityIngredients: facts.consumedDualQuantityIngredients,
        methodOnlyCoreNoQuantity: facts.methodOnlyCoreNoQuantity,
      },
      currentProductionPlan: {
        quantityReadiness: readinessByEntryId.get(entryId).productionIngredientPlan.quantityReadiness,
        inventoryIngredients: readinessByEntryId.get(entryId).productionIngredientPlan.inventoryIngredients,
      },
      runtimeStatus: {
        coreCount: runtime.coreCount,
        exactCompatibleCount: runtime.exactCompatibleCount,
        unresolvedItems: runtime.unresolvedItems,
        unitConfirmationItems: runtime.unitConfirmationItems,
        blocked: runtime.blocked,
      },
      semanticRisk: remediations.map((r) => r.semanticRiskNote),
      minimalRemediation: remediations.map((r) => r.minimalRemediation),
      requiresAliasChange,
      requiresConversionChange,
      requiresSchemaChange,
      requiresHumanSourceReview,
      recommendedDisposition,
    };
  });

// -- Overall priority grouping -----------------------------------------------

const mechanicalFixCandidates = items.filter((i) => i.recommendedDisposition === 'mechanical-fix-candidate');
const targetedReviewRequired = items.filter((i) => i.recommendedDisposition === 'targeted-review-required');
const schemaOrPolicyRequired = items.filter((i) => i.recommendedDisposition === 'schema-or-policy-required');
const keepBlocked = items.filter((i) => i.recommendedDisposition === 'keep-blocked');

const nextMechanicalBatchCandidates = mechanicalFixCandidates.map((i) => i.entryId);

// -- Verification -------------------------------------------------------------

const problems = [];

const EXPECTED_IDS = [
  'dz1979-p129', 'dz1979-p130', 'dz1979-p137', 'dz1979-p144', 'dz1979-p161',
  'dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p211', 'dz1979-p222',
  'dz1979-p224', 'dz1979-p226',
];
const itemIds = items.map((i) => i.entryId).sort();
if (JSON.stringify(itemIds) !== JSON.stringify(EXPECTED_IDS.slice().sort())) {
  problems.push('coverage-mismatch');
}
if (new Set(itemIds).size !== itemIds.length) problems.push('duplicate-entries');

const frozenHardGateUnion = new Set(
  Object.values(batch6DryRun.selection.hardGateExclusions).flat(),
);
const frozenRuntimeBlocked = new Set(
  batch6DryRun.selection.runtimeNameGateBlocked.map((b) => b.entryId),
);
for (const item of items) {
  const hasHardGateBlocker = item.blockers.some((b) => b !== 'runtime-unresolved-name');
  const hasRuntimeBlocker = item.blockers.includes('runtime-unresolved-name');
  if (hasHardGateBlocker !== frozenHardGateUnion.has(item.entryId)) {
    problems.push(`hard-gate-union-mismatch:${item.entryId}`);
  }
  if (hasRuntimeBlocker !== frozenRuntimeBlocked.has(item.entryId)) {
    problems.push(`runtime-gate-union-mismatch:${item.entryId}`);
  }
}
for (const item of items) {
  if (item.blockers.length === 0) problems.push(`no-blocker-recorded:${item.entryId}`);
}
const ALLOWED_DISPOSITIONS = ['mechanical-fix-candidate', 'targeted-review-required', 'schema-or-policy-required', 'keep-blocked'];
for (const item of items) {
  if (!ALLOWED_DISPOSITIONS.includes(item.recommendedDisposition)) {
    problems.push(`invalid-disposition:${item.entryId}:${item.recommendedDisposition}`);
  }
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-blocker-triage.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: '对 remaining 12 道 not-promoted new-recipe-candidate 的现有 blocker 做只读机械分类与最低风险解锁方式分析。本轮不实施任何 remediation、不 promotion、不新增 alias/unit conversion/schema，仅基于已冻结的 canonical/readiness/runtime 数据给出结构化建议。',
  applicationReady: false,
  baseline: {
    main: '5b737cf8bc418a8e8c8cd1b057783a1500302b56',
    promotedBatches: 6,
    promotedCount: readiness.summary.promotedNewRecipeCount,
    remainingCount: readiness.summary.remainingNewRecipeCandidateCount,
    curatedCount: 153,
  },
  dispositionDefinitions: {
    'mechanical-fix-candidate': '仅需现有已验证机械规则（如 same-for-each 拆分）放宽 hard gate 即可解锁，无 source 重新解读、无信息损失、无需 alias/schema 变更。',
    'targeted-review-required': '需要人工确认（如 alias/canonicalization 决策），有明确、有限范围的 review 任务。',
    'schema-or-policy-required': '现有 production schema（{item, qty, unit} 单值）无法无损表达该语义（近似量、双数量），需先做 schema 或 policy 决策。',
    'keep-blocked': '暂无已识别的安全解锁路径，维持 blocked。',
  },
  items,
  prioritization: {
    mechanicalFixCandidates: mechanicalFixCandidates.map((i) => ({ entryId: i.entryId, name: i.name })),
    targetedReviewRequired: targetedReviewRequired.map((i) => ({ entryId: i.entryId, name: i.name })),
    schemaOrPolicyRequired: schemaOrPolicyRequired.map((i) => ({ entryId: i.entryId, name: i.name })),
    keepBlocked: keepBlocked.map((i) => ({ entryId: i.entryId, name: i.name })),
    nextMechanicalBatchCandidates,
    note: '优先级顺序：mechanical-fix-candidate（无 source reinterpretation、无信息损失）> targeted-review-required（范围有限的人工确认）> schema-or-policy-required（需先决策）> keep-blocked。不为了多 promotion 而降低任何 gate 标准；此处只给出分析，不改代码。',
  },
  ifNothingChanges: {
    statement: '如果本轮不做任何代码/policy 改动，12 道全部维持 blocked 是当前唯一正确状态：所有 12 道都命中至少一个真实存在的语义完整性风险或未解决的 runtime name gate，现有 hard gate/runtime gate 均未误判。',
    verifiedBy: 'blocker union 与 Batch 6 冻结 dry-run 的 hardGateExclusions + runtimeNameGateBlocked 完全一致（见 verificationProblems）。',
  },
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-blocker-triage.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`items: ${items.length}`);
console.log(`mechanical-fix-candidate: ${mechanicalFixCandidates.map((i) => i.entryId).join(', ') || '(none)'}`);
console.log(`targeted-review-required: ${targetedReviewRequired.map((i) => i.entryId).join(', ') || '(none)'}`);
console.log(`schema-or-policy-required: ${schemaOrPolicyRequired.map((i) => i.entryId).join(', ') || '(none)'}`);
console.log(`keep-blocked: ${keepBlocked.map((i) => i.entryId).join(', ') || '(none)'}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
